using System.Text.Json;
using HkuVpn.Core;

namespace HkuVpn.Platform.Windows;

public static class WindowsScripts
{
    internal static JsonElement ParseResult(string output, string operation)
    {
        const string marker = "HKU_GUI_RESULT_B64:";
        var line = output.Split('\n').LastOrDefault(x => x.StartsWith(marker, StringComparison.Ordinal));
        if (line is null) throw new InvalidOperationException($"Windows {operation} 未返回完整结果，请确认辅助脚本与 GUI 版本一致。");
        try { return JsonSerializer.Deserialize<JsonElement>(Convert.FromBase64String(line[marker.Length..].Trim())); }
        catch (Exception error) when (error is FormatException or JsonException) {
            throw new InvalidOperationException($"Windows {operation} 返回数据无效，请重新启动 GUI 后重试。", error);
        }
    }
    public static async Task<JsonElement> RunAsync(string root, string operation, object? request = null, CancellationToken ct = default)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
        var powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        var info = Cli.StartInfo(powershell, ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", Path.Combine(root, "lib", "GuiBridge.ps1"), "-Operation", operation]);
        var result = await Cli.RunAsync(info, JsonSerializer.Serialize(request), operation == "install" ? TimeSpan.FromMinutes(15) : TimeSpan.FromSeconds(60), ct);
        var payload = ParseResult(result.Output, operation);
        if (result.Code != 0) throw new InvalidOperationException(payload.TryGetProperty("error", out var error) ? error.GetString() : $"Windows {operation} 操作失败。");
        if (operation == "diagnose" && request != null)
        {
            var data = JsonSerializer.SerializeToElement(request);
            if (data.TryGetProperty("network", out var network) && network.GetBoolean())
            {
                var config = data.GetProperty("config").Deserialize<VpnConfig>(VpnConfig.Json)!;
                var rows = payload.Deserialize<List<DiagnosticRow>>(new JsonSerializerOptions { PropertyNameCaseInsensitive = true })!;
                var executable = Path.Combine(VpnConfig.Resolve(root, config.RuntimePath), "openconnect.exe");
                if (File.Exists(executable))
                {
                    var args = new List<string> { "--protocol=anyconnect", "--os=win", "--useragent=" + config.Vpn.UserAgent, "--no-dtls", "--non-inter" };
                    args.Add(config.Vpn.Proxy.Length > 0 ? "--proxy=" + config.Vpn.Proxy : "--no-proxy");
                    if (config.Vpn.Tls12) args.Add("--gnutls-priority=NORMAL:-VERS-ALL:+VERS-TLS1.2");
                    foreach (var gateway in config.Vpn.Gateways)
                    {
                        try {
                            var probe = await Cli.RunAsync(Cli.StartInfo(executable, args.Append(gateway)), null, TimeSpan.FromSeconds(30), ct);
                            var ok = probe.Output.Contains("XML POST enabled") && (!config.Vpn.Tls12 || probe.Output.Contains("(TLS1.2)"));
                            rows.Add(new("网关 TLS/XML", ok, ok ? "无凭据握手成功；未尝试认证" : "握手未通过；检查代理、证书和兼容参数"));
                        } catch (OperationCanceledException) when (!ct.IsCancellationRequested) { rows.Add(new("网关 TLS/XML", false, "握手超时；未尝试认证")); }
                    }
                }
                return JsonSerializer.SerializeToElement(rows);
            }
        }
        return payload;
    }
}
