using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text.Json;
using HkuVpn.Core;

namespace HkuVpn.Platform.Windows;

public sealed class WindowsBackend(string root) : IVpnBackend
{
    private NamedPipeServerStream? pipe;
    private StreamReader? reader;
    private StreamWriter? writer;
    private Process? helper;
    private readonly SemaphoreSlim startGate = new(1);
    private readonly SemaphoreSlim writeGate = new(1);
    private readonly ConcurrentDictionary<string, TaskCompletionSource<JsonElement>> pending = new();
    private Task? readTask;
    internal Func<ProcessStartInfo, Process?>? StartProcessOverride { get; set; }
    public bool Supported => OperatingSystem.IsWindows();
    public event Action<BackendEvent>? Event;
    public Func<string, Task<string?>>? RequestSecret { get; set; }
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetNamedPipeClientProcessId(IntPtr handle, out uint pid);
    private async Task StartAsync(CancellationToken ct)
    {
        if (!Supported) throw new PlatformNotSupportedException("macOS 后端尚未实现，可使用 --demo 预览界面。");
        await startGate.WaitAsync(ct);
        try
        {
            if (pipe?.IsConnected == true) return;
            pipe?.Dispose();
            var name = "hku-vpn-" + Guid.NewGuid().ToString("N");
            pipe = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            var executable = Environment.ProcessPath!;
            var start = new ProcessStartInfo(executable) { UseShellExecute = true, Verb = "runas", WorkingDirectory = root };
            // UseShellExecute doesn't support redirected stdin/stdout. Only non-secret launch metadata is passed.
            start.Arguments = string.Join(" ", new[] { "--helper", "--root", root, "--pipe", name, "--parent", Environment.ProcessId.ToString() }.Select(Quote));
            helper = (StartProcessOverride ?? Process.Start)(start) ?? throw new InvalidOperationException("无法启动辅助进程。");
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(30));
            await pipe.WaitForConnectionAsync(deadline.Token);
            if (!GetNamedPipeClientProcessId(pipe.SafePipeHandle.DangerousGetHandle(), out var peer) || peer != helper.Id)
                throw new InvalidOperationException("辅助进程身份不匹配。");
            reader = new StreamReader(pipe); writer = new StreamWriter(pipe) { AutoFlush = true };
            readTask = ReadLoopAsync();
        }
        catch { pipe?.Dispose(); throw; }
        finally { startGate.Release(); }
    }
    private static string Quote(string argument) => "\"" + System.Text.RegularExpressions.Regex.Replace(
        System.Text.RegularExpressions.Regex.Replace(argument, @"(\\*)""", "$1$1\\\""), @"(\\+)$", "$1$1") + "\"";
    private async Task SendAsync(WireMessage message)
    {
        await writeGate.WaitAsync();
        try { await writer!.WriteLineAsync(JsonSerializer.Serialize(message)); }
        finally { writeGate.Release(); }
    }
    private async Task ReadLoopAsync()
    {
        try
        {
            while (await reader!.ReadLineAsync() is { } line)
            {
                if (line.Length > 1024 * 1024) throw new InvalidDataException("辅助进程消息过大。");
                var message = JsonSerializer.Deserialize<WireMessage>(line) ?? throw new InvalidDataException("无效协议。");
                if (message.Version != 1) throw new InvalidDataException("不支持的通信协议版本。");
                if (message.Kind == "input")
                {
                    _ = ReplyInputAsync(message);
                }
                else if (message.Kind == "event") Event?.Invoke(new(message.Name, message.Data));
                else if (pending.TryRemove(message.Id, out var result))
                {
                    if (message.Kind == "error") result.TrySetException(new InvalidOperationException(message.Data.GetString() ?? "操作失败。"));
                    else result.TrySetResult(message.Data);
                }
            }
        }
        catch { /* all in-flight requests fail below, without logging raw IPC */ }
        finally
        {
            pipe?.Dispose();
            foreach (var item in pending) if (pending.TryRemove(item.Key, out var result)) result.TrySetException(new IOException("辅助进程连接已断开，请检查遗留会话。"));
            Event?.Invoke(new("offline", JsonSerializer.SerializeToElement("辅助进程已退出")));
        }
    }
    private async Task ReplyInputAsync(WireMessage message)
    {
        try { var value = RequestSecret == null ? null : await RequestSecret(message.Name); await SendAsync(WireMessage.Create("input", message.Id, message.Name, value)); value = null; }
        catch { try { await SendAsync(WireMessage.Create("input", message.Id, message.Name)); } catch { } }
    }
    public async Task<JsonElement> InvokeAsync(string operation, object? request = null, CancellationToken cancellation = default)
    {
        if (operation is "snapshot" or "diagnose") return await WindowsScripts.RunAsync(root, operation, request, cancellation);
        await StartAsync(cancellation);
        var id = Guid.NewGuid().ToString("N");
        var result = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        pending[id] = result;
        try
        {
            await SendAsync(WireMessage.Create("request", id, operation, request));
            return await result.Task.WaitAsync(cancellation);
        }
        finally { pending.TryRemove(id, out _); }
    }
    public async ValueTask DisposeAsync()
    {
        // EOF is also a disconnect request; the helper owns cleanup even if the UI crashes.
        pipe?.Dispose();
        if (readTask != null) await readTask;
        helper?.Dispose(); startGate.Dispose(); writeGate.Dispose();
    }
}
