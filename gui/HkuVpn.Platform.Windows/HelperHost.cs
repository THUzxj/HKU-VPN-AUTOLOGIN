using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO.Pipes;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text.Json;
using HkuVpn.Core;

namespace HkuVpn.Platform.Windows;

public sealed class HelperHost
{
    private readonly string root;
    private readonly StreamReader reader;
    private readonly StreamWriter writer;
    private readonly SemaphoreSlim writes = new(1);
    private readonly SemaphoreSlim operations = new(1);
    private readonly ConcurrentDictionary<string, TaskCompletionSource<string?>> inputs = new();
    private readonly List<Task> tasks = [];
    private readonly CancellationTokenSource lifetime = new();
    private CancellationTokenSource? connection;
    private Task? connectionTask;
    private bool tunnelConnected;
    private readonly string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
    private HelperHost(string root, StreamReader reader, StreamWriter writer) { this.root = root; this.reader = reader; this.writer = writer; }
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetNamedPipeServerProcessId(IntPtr handle, out uint pid);
    public static async Task RunAsync(string root, string pipeName, int parent)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
        using var principal = WindowsIdentity.GetCurrent();
        if (!new WindowsPrincipal(principal).IsInRole(WindowsBuiltInRole.Administrator)) throw new InvalidOperationException("需要管理员权限。");
        root = Path.GetFullPath(root);
        if (!File.Exists(Path.Combine(root, "lib", "GuiBridge.ps1"))) throw new InvalidOperationException("辅助脚本缺失。");
        using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
        await pipe.ConnectAsync(15000);
        if (!GetNamedPipeServerProcessId(pipe.SafePipeHandle.DangerousGetHandle(), out var peer) || peer != parent) throw new IOException("GUI 身份不匹配。");
        using var reader = new StreamReader(pipe); using var writer = new StreamWriter(pipe) { AutoFlush = true };
        var host = new HelperHost(root, reader, writer);
        await host.RunLoopAsync();
    }
    private async Task SendAsync(WireMessage message)
    {
        await writes.WaitAsync();
        try { await writer.WriteLineAsync(JsonSerializer.Serialize(message)); }
        finally { writes.Release(); }
    }
    private Task EventAsync(string name, object? data) => SendAsync(WireMessage.Create("event", "", name, data));
    private async Task<string?> AskAsync(string name, CancellationToken ct)
    {
        var id = Guid.NewGuid().ToString("N"); var answer = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
        inputs[id] = answer;
        try { await SendAsync(WireMessage.Create("input", id, name)); return await answer.Task.WaitAsync(TimeSpan.FromMinutes(5), ct); }
        finally { inputs.TryRemove(id, out _); try { await EventAsync("closeInput", null); } catch { } }
    }
    private async Task<JsonElement> BridgeAsync(string operation, object? request = null, CancellationToken ct = default)
    {
        return await WindowsScripts.RunAsync(root, operation, request, ct);
    }
    private VpnConfig Load() { var config = VpnConfig.Load(Path.Combine(root, ".local", "config.json")); config.Validate(); return config; }
    private async Task ConnectAsync(CancellationToken ct)
    {
        var config = Load(); string? master = null; bool prepared = false, gateHeld = false;
        var phase = "准备网卡与路由脚本";
        Directory.CreateDirectory(Path.Combine(root, ".local"));
        using var lease = new FileStream(Path.Combine(root, ".local", "vpn-owner.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        try
        {
            await operations.WaitAsync(ct); gateHeld = true;
            await EventAsync("state", "preparing"); await BridgeAsync("prepare", null, ct);
            prepared = true;
            if (config.Vpn.Proxy.Length > 0)
            {
                phase = "代理端口检查";
                await ProxyConnectivity.CheckAsync(config.Vpn.Proxy, ct);
            }
            var client = Path.Combine(VpnConfig.Resolve(root, config.RuntimePath), "openconnect.exe");
            var common = new List<string> { "--protocol=anyconnect", "--os=win", "--useragent=" + config.Vpn.UserAgent, "--no-dtls" };
            common.Add(config.Vpn.Proxy.Length > 0 ? "--proxy=" + config.Vpn.Proxy : "--no-proxy");
            if (config.Vpn.Tls12) common.Add("--gnutls-priority=NORMAL:-VERS-ALL:+VERS-TLS1.2");
            string? gateway = null; phase = "网关 TLS/XML 检查";
            foreach (var item in config.Vpn.Gateways)
            {
                var probe = await Cli.RunAsync(Cli.StartInfo(client, common.Concat(["--non-inter", item])), null, TimeSpan.FromSeconds(30), ct);
                if (probe.Output.Contains("XML POST enabled") && (!config.Vpn.Tls12 || probe.Output.Contains("(TLS1.2)"))) { gateway = item; break; }
            }
            if (gateway is null) throw new InvalidOperationException("网关 TLS/XML 检查失败，未提交 VPN 凭据。");
            phase = "读取 KeePassXC 凭据";
            master = await AskAsync("master", ct) ?? throw new OperationCanceledException(ct);
            await EventAsync("state", "authenticating");
            config.Keepass.Cli = VpnConfig.Resolve(root, config.Keepass.Cli);
            config.Keepass.Database = VpnConfig.Resolve(root, config.Keepass.Database);
            if (config.Keepass.KeyFile.Length > 0) config.Keepass.KeyFile = VpnConfig.Resolve(root, config.Keepass.KeyFile);
            var credentials = await KeepassReader.CredentialsAsync(config.Keepass, master, ct);
            if (credentials.Password.Any(c => c is < ' ' or > '~')) throw new InvalidOperationException("当前 Windows OpenConnect 构建仅支持可打印 ASCII 密码。");
            var args = common.Concat(["--interface=" + config.Vpn.AdapterName, "--disable-ipv6", "--mtu=" + config.Vpn.Mtu,
                "--script", Path.Combine(root, ".local", "vpnc-route.js"), "--user", credentials.Username, "--passwd-on-stdin", gateway]);
            phase = "启动 OpenConnect 与认证";
            var info = Cli.StartInfo(client, args);
            // A separate hidden console lets Ctrl+C target only this owned OpenConnect console.
            info.CreateNoWindow = false; info.WindowStyle = ProcessWindowStyle.Hidden;
            info.Environment["HKU_PS_EXE"] = powershell;
            info.Environment["HKU_DOMAIN_SCRIPT"] = Path.Combine(root, "DomainRoutes.ps1");
            operations.Release(); gateHeld = false;
            var verification = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            using var verifying = CancellationTokenSource.CreateLinkedTokenSource(ct);
            var verifyTask = VerifyTunnelAsync(verification.Task, () => master = null, verifying.Token);
            int code;
            try
            {
                var pump = AuthenticationPump.RunAsync(info, credentials.Password,
                    async () => { if (!config.Keepass.Enabled || master is null) return null; try { return await KeepassReader.TotpAsync(config.Keepass, master, ct); } catch { return null; } finally { master = null; } },
                    () => AskAsync("mfa", ct),
                    stage => { if (stage == "tunnelReady") verification.TrySetResult(); else _ = EventAsync("state", stage); }, ct,
                    System.Text.Encoding.ASCII, WindowsTermination.StopAsync);
                credentials = default;
                code = await pump;
            }
            finally {
                credentials = default; master = null; verification.TrySetCanceled(ct); verifying.Cancel();
                try { await verifyTask; } catch (OperationCanceledException) { }
            }
            if (code != 0) throw new InvalidOperationException($"OpenConnect 已退出（{code}）；请检查认证、代理和网关。");
        }
        catch (Exception error) when (error is not OperationCanceledException and not InvalidOperationException)
        {
            throw new InvalidOperationException($"连接失败（{phase}，{error.GetType().Name}）；请检查该阶段的配置与依赖。", error);
        }
        finally
        {
            if (gateHeld) operations.Release();
            tunnelConnected = false;
            master = null;
            try { if (prepared) await BridgeAsync("disconnect"); await EventAsync("state", prepared ? "ready" : "recovery"); }
            catch { await EventAsync("state", "recovery"); }
        }
    }
    private async Task VerifyTunnelAsync(Task hint, Action verified, CancellationToken ct)
    {
        // Do not time out route verification while a human is still entering MFA.
        while (!hint.IsCompleted && !File.Exists(Path.Combine(root, ".local", "domain-session.json"))) await Task.Delay(500, ct);
        for (var i = 0; i < 30; i++)
        {
            ct.ThrowIfCancellationRequested();
            var snapshot = await BridgeAsync("snapshot", null, ct);
            if (snapshot.GetProperty("connected").GetBoolean())
            { verified(); tunnelConnected = true; await EventAsync("snapshot", snapshot); await EventAsync("state", "connected"); return; }
            await Task.Delay(1000, ct);
        }
        await EventAsync("state", "recovery");
    }
    private async Task RunLoopAsync()
    {
        try
        {
            while (await reader.ReadLineAsync() is { } line)
            {
                if (line.Length > 1024 * 1024) break;
                var request = JsonSerializer.Deserialize<WireMessage>(line);
                if (request is null || request.Version != 1) break;
                if (request.Kind == "input")
                { if (inputs.TryGetValue(request.Id, out var answer)) answer.TrySetResult(request.Data.ValueKind == JsonValueKind.String ? request.Data.GetString() : null); continue; }
                if (request.Kind != "request") break;
                if (request.Name == "disconnect") {
                    Directory.CreateDirectory(Path.Combine(root, ".local"));
                    File.WriteAllText(Path.Combine(root, ".local", "domain-cancel.flag"), "Disconnect requested");
                    connection?.Cancel();
                }
                var task = DispatchAsync(request); tasks.Add(task); tasks.RemoveAll(t => t.IsCompleted);
            }
        }
        finally
        {
            lifetime.Cancel(); connection?.Cancel();
            foreach (var input in inputs.Values) input.TrySetCanceled();
            try { await Task.WhenAll(tasks); } catch { }
            // ConnectAsync owns cleanup; failed preflight must never stop an existing VPN.
        }
    }
    private async Task DispatchAsync(WireMessage request)
    {
        try
        {
            JsonElement result;
            if (request.Name == "connect")
            {
                if (connectionTask is { IsCompleted: false }) throw new InvalidOperationException("连接操作已经运行。");
                connection?.Dispose(); connection = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                connectionTask = ConnectAsync(connection.Token); await connectionTask;
                result = JsonSerializer.SerializeToElement(true);
            }
            else
            {
                await operations.WaitAsync(lifetime.Token);
                try
                {
                    if (request.Name == "disconnect" && connectionTask != null) { try { await connectionTask; } catch { } }
                    if (request.Name == "refresh" && !tunnelConnected) throw new InvalidOperationException("尚无已连接的 GUI 会话，不能刷新路由。");
                    if (request.Name is "install" or "refresh" && connectionTask is { IsCompleted: false } && request.Name == "install")
                        throw new InvalidOperationException("连接中不能安装运行库。");
                    result = request.Name switch
                    {
                        "install" => await BridgeAsync("install", request.Data, lifetime.Token),
                        "snapshot" => await BridgeAsync("snapshot", null, lifetime.Token),
                        "refresh" => await BridgeAsync("refresh", null, lifetime.Token),
                        "disconnect" => await BridgeAsync("disconnect", null, lifetime.Token),
                        "diagnose" => await BridgeAsync("diagnose", request.Data, lifetime.Token),
                        _ => throw new InvalidOperationException("不支持此操作。")
                    };
                }
                finally { operations.Release(); }
            }
            await SendAsync(WireMessage.Create("result", request.Id, request.Name, result));
        }
        catch (OperationCanceledException) { try { await SendAsync(WireMessage.Create("error", request.Id, request.Name, "操作已取消，已请求会话清理。")); } catch { } }
        catch (Exception error)
        {
            // Bridge emits only controlled errors; external CLI output is never included.
            var message = error is InvalidOperationException ? SafeLog.Redact(error.Message) : "操作失败，请检查配置、依赖和系统权限。";
            try { await SendAsync(WireMessage.Create("error", request.Id, request.Name, message)); } catch { }
        }
    }
}
