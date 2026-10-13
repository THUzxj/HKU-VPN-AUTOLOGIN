using System.Net;
using System.Net.Sockets;

namespace HkuVpn.Core;

public static class ProxyConnectivity
{
    public static async Task CheckAsync(string address, CancellationToken cancellation = default)
    {
        if (string.IsNullOrWhiteSpace(address)) return;
        var uri = new Uri(address);
        // Uri.Host includes square brackets for IPv6; sockets require DnsSafeHost.
        using var socket = IPAddress.TryParse(uri.DnsSafeHost, out var ip)
            ? new TcpClient(ip.AddressFamily) : new TcpClient();
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        deadline.CancelAfter(TimeSpan.FromSeconds(5));
        try { await socket.ConnectAsync(uri.DnsSafeHost, uri.Port, deadline.Token); }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested) {
            throw new InvalidOperationException("代理端口连接超时；请检查 Clash 监听地址、端口与 IPv4/IPv6 设置，或在配置中留空代理使用直连。");
        }
        catch (SocketException error) {
            throw new InvalidOperationException($"无法连接代理端口（{error.SocketErrorCode}）；请检查 Clash 是否已启动及监听地址。", error);
        }
    }
}
