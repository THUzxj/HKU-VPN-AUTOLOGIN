using System.Text.Json;

namespace HkuVpn.Core;

public sealed record WireMessage(string Kind, string Id, string Name, JsonElement Data)
{
    public int Version { get; init; } = 1;
    public static WireMessage Create(string kind, string id, string name, object? data = null) =>
        new(kind, id, name, JsonSerializer.SerializeToElement(data));
}
public sealed record RouteRow(string Source, string Target, string Prefix, string Status, string Detail);
public sealed record BackendSnapshot(bool Connected, bool RecoveryNeeded, RouteRow[] Routes, string DomainStatus);
public sealed record DependencyRow(string Name, bool Available, string Detail);
public sealed record DiagnosticRow(string Name, bool Success, string Detail);
public sealed record BackendEvent(string Name, JsonElement Data);

public interface IVpnBackend : IAsyncDisposable
{
    bool Supported { get; }
    event Action<BackendEvent>? Event;
    Func<string, Task<string?>>? RequestSecret { get; set; }
    Task<JsonElement> InvokeAsync(string operation, object? request = null, CancellationToken cancellation = default);
}

public static class SafeLog
{
    // Only controlled event messages are displayed. This is also used for exported diagnostics.
    public static string Redact(string text)
    {
        text = System.Text.RegularExpressions.Regex.Replace(text, @"(?i)(password|passwd|cookie|token|secret|验证码|主密码)\s*[:=]\s*[^\s,;]+", "$1=[hidden]");
        text = System.Text.RegularExpressions.Regex.Replace(text, @"[\w.+-]+@[\w.-]+\.[a-zA-Z]{2,}", "[account]");
        text = System.Text.RegularExpressions.Regex.Replace(text, @"(?i)[a-z]:[\\/][^\r\n\""<>]+", "[local path]");
        text = System.Text.RegularExpressions.Regex.Replace(text, @"(?:/Users/|/home/)[^\s]+", "[local path]");
        text = System.Text.RegularExpressions.Regex.Replace(text, @"\b\d{1,3}(?:\.\d{1,3}){3}\b", "[address]");
        text = System.Text.RegularExpressions.Regex.Replace(text, @"\b(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}\b", "[host]");
        return System.Text.RegularExpressions.Regex.Replace(text, @"\b\d{6}\b", "[code]");
    }
}
