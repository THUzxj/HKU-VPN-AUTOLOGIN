using System.Text.Json;

namespace HkuVpn.Core;

public sealed class DemoBackend : IVpnBackend
{
    public bool Supported => true;
    public event Action<BackendEvent>? Event;
    public Func<string, Task<string?>>? RequestSecret { get; set; }
    private bool connected;
    private VpnConfig targets = new() { Routes = ["192.0.2.10/32"], Domains = ["server.example.hk"] };
    private CancellationTokenSource? session;
    public async Task<JsonElement> InvokeAsync(string operation, object? request = null, CancellationToken cancellation = default)
    {
        switch (operation)
        {
            case "connect":
                session = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
                Event?.Invoke(new("state", JsonSerializer.SerializeToElement("authenticating")));
                await Task.Delay(150, session.Token);
                connected = true; Event?.Invoke(new("state", JsonSerializer.SerializeToElement("connected")));
                Event?.Invoke(new("snapshot", JsonSerializer.SerializeToElement(Snapshot())));
                try { await Task.Delay(Timeout.Infinite, session.Token); } catch (OperationCanceledException) { }
                return JsonSerializer.SerializeToElement(true);
            case "disconnect": connected = false; session?.Cancel(); Event?.Invoke(new("state", JsonSerializer.SerializeToElement("ready"))); return JsonSerializer.SerializeToElement(true);
            case "targets": targets = ((VpnConfig)request!).Clone(); return JsonSerializer.SerializeToElement(Snapshot());
            case "snapshot": case "refresh": return JsonSerializer.SerializeToElement(Snapshot());
            case "install": return JsonSerializer.SerializeToElement(new { installed = true });
            case "diagnose": return JsonSerializer.SerializeToElement(new[] { new DiagnosticRow("演示依赖", true, "仅模拟，不检查本机或联网") });
            default: throw new InvalidOperationException("未知操作。");
        }
    }
    private BackendSnapshot Snapshot() => new(connected, false,
        targets.Routes.Select(r => new RouteRow("固定", r, r, connected ? "已安装（模拟）" : "未应用", "演示地址"))
            .Concat(targets.Domains.Select(d => new RouteRow("域名", d, "192.0.2.20/32", connected ? "已安装（模拟）" : "未应用", "TTL 300")))
            .Concat([new RouteRow("VPN DNS", "192.0.2.53", "192.0.2.53/32", connected ? "已安装（模拟）" : "未应用", "全局 DNS 不变")]).ToArray(), "演示数据，不代表真实连接。");
    public ValueTask DisposeAsync() { session?.Cancel(); session?.Dispose(); return ValueTask.CompletedTask; }
}
