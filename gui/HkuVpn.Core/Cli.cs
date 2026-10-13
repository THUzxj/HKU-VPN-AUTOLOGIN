using System.Diagnostics;
using System.Text;
using System.Threading.Channels;
using System.Text.RegularExpressions;

namespace HkuVpn.Core;

public static class Cli
{
    public static ProcessStartInfo StartInfo(string executable, IEnumerable<string> args)
    {
        var info = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false) };
        foreach (var arg in args) info.ArgumentList.Add(arg);
        return info;
    }
    public static async Task<(int Code, string Output)> RunAsync(ProcessStartInfo info, string? input,
        TimeSpan timeout, CancellationToken cancellation = default)
    {
        using var process = new Process { StartInfo = info };
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        deadline.CancelAfter(timeout);
        process.Start();
        try
        {
            var output = process.StandardOutput.ReadToEndAsync(deadline.Token);
            var error = process.StandardError.ReadToEndAsync(deadline.Token);
            if (input != null) await process.StandardInput.WriteLineAsync(input.AsMemory(), deadline.Token);
            process.StandardInput.Close();
            await process.WaitForExitAsync(deadline.Token);
            var stdout = await output; var stderr = await error;
            return (process.ExitCode, stdout + (stderr.Length > 0 ? "\n" + stderr : ""));
        }
        finally { if (!process.HasExited) { process.Kill(true); await process.WaitForExitAsync(); } }
    }
}

public static class KeepassReader
{
    private static async Task<string> ReadAsync(KeepassConfig settings, string master, string entry, string[] options, CancellationToken ct)
    {
        var args = new List<string> { "show", "--quiet" }; args.AddRange(options);
        if (settings.KeyFile.Length > 0) args.AddRange(["--key-file", settings.KeyFile]);
        args.AddRange([settings.Database, entry]);
        var result = await Cli.RunAsync(Cli.StartInfo(settings.Cli, args), master, TimeSpan.FromSeconds(30), ct);
        if (result.Code != 0) throw new InvalidOperationException("无法读取 KeePassXC 条目，请检查主密码、条目路径和密钥文件。");
        return result.Output.TrimEnd('\r', '\n');
    }
    public static async Task<(string Username, string Password)> CredentialsAsync(KeepassConfig settings, string master, CancellationToken ct)
    {
        var entry = string.IsNullOrWhiteSpace(settings.CredentialsEntry) ? settings.Entry : settings.CredentialsEntry;
        var username = await ReadAsync(settings, master, entry, ["--attributes", "UserName"], ct);
        var password = await ReadAsync(settings, master, entry, ["--attributes", "Password"], ct);
        if (string.IsNullOrWhiteSpace(username) || username.IndexOfAny(['\r', '\n']) >= 0 || string.IsNullOrEmpty(password) || password.IndexOfAny(['\r', '\n']) >= 0)
            throw new InvalidOperationException("请填写标准用户名/密码字段，且使用单行凭据。");
        return (username, password);
    }
    public static async Task<string> TotpAsync(KeepassConfig settings, string master, CancellationToken ct)
    {
        var code = await ReadAsync(settings, master, settings.Entry, ["--totp"], ct);
        if (!Regex.IsMatch(code, "^[0-9]{6}$")) throw new InvalidOperationException("条目必须提供六位 TOTP。");
        return code;
    }
}

public static class AuthenticationPump
{
    // Raw gateway output is consumed in memory, never emitted to UI or logs.
    public static async Task<int> RunAsync(ProcessStartInfo info, string password,
        Func<Task<string?>> automaticMfa, Func<Task<string?>> manualMfa, Action<string> stage,
        CancellationToken cancellation, Encoding? inputEncoding = null, Func<Process, Task>? terminate = null)
    {
        using var process = new Process { StartInfo = info };
        process.Start();
        using var io = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        var chunks = Channel.CreateBounded<string>(128);
        async Task ReadAsync(StreamReader reader)
        {
            var buffer = new char[1024];
            while (true)
            {
                var n = await reader.ReadAsync(buffer.AsMemory(), io.Token);
                if (n == 0) break;
                await chunks.Writer.WriteAsync(new string(buffer, 0, n), io.Token);
            }
        }
        Task? readers = null;
        try
        {
            using var writer = new StreamWriter(process.StandardInput.BaseStream, inputEncoding ?? new UTF8Encoding(false)) { AutoFlush = true };
            await writer.WriteLineAsync(password.AsMemory(), cancellation); password = "";
            readers = Task.WhenAll(ReadAsync(process.StandardOutput), ReadAsync(process.StandardError));
            _ = readers.ContinueWith(t => chunks.Writer.TryComplete(t.Exception), TaskScheduler.Default);
            var recent = ""; var automaticAttempted = false; var challenge = false; var tunnelReported = false;
            await foreach (var chunk in chunks.Reader.ReadAllAsync(cancellation))
            {
                recent += chunk; if (recent.Length > 8192) recent = recent[^8192..];
                if (recent.Contains("Login failed", StringComparison.OrdinalIgnoreCase) || recent.Contains("Cookie was rejected", StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("网关拒绝认证或会话。请核对凭据/MFA 后重新连接，已停止自动重试。");
                if (recent.Contains("Enter Your Microsoft verification code", StringComparison.OrdinalIgnoreCase)) challenge = true;
                if (challenge && Regex.IsMatch(recent, @"Response:\s*$", RegexOptions.IgnoreCase))
                {
                    stage("mfa"); string? code = null;
                    if (!automaticAttempted) { automaticAttempted = true; code = await automaticMfa(); }
                    code ??= await manualMfa();
                    if (code is null) throw new OperationCanceledException(cancellation);
                    if (!Regex.IsMatch(code, "^[0-9]{6}$")) throw new InvalidOperationException("MFA 必须是六位数字。");
                    await writer.WriteLineAsync(code.AsMemory(), cancellation); code = null;
                    recent = ""; challenge = false; stage("authenticating");
                }
                if (!tunnelReported && (recent.Contains("Connected as ", StringComparison.OrdinalIgnoreCase) || recent.Contains("CSTP connected", StringComparison.OrdinalIgnoreCase)))
                { tunnelReported = true; stage("tunnelReady"); }
            }
            await readers; await process.WaitForExitAsync(cancellation);
            return process.ExitCode;
        }
        finally
        {
            io.Cancel();
            if (!process.HasExited && terminate != null) { try { await terminate(process); } catch { } }
            if (!process.HasExited) { process.Kill(true); await process.WaitForExitAsync(); }
            if (readers != null) { try { await readers; } catch { /* cancellation closes pipes */ } }
        }
    }
}
