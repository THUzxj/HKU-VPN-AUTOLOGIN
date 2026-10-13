using System.Diagnostics;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Interactivity;
using Avalonia.Threading;
using Avalonia.VisualTree;
using HkuVpn.App;
using HkuVpn.Core;
using HkuVpn.Platform.Windows;
using System.IO.Pipes;

namespace HkuVpn.Tests;

public static class Program
{
    private static int assertions;
    private static void Assert(bool value, string reason) { assertions++; if (!value) throw new Exception(reason); }
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.FirstOrDefault() == "--check-proxy") {
            try { var config = VpnConfig.Load(Path.Combine(Path.GetFullPath(args[1]), ".local", "config.json")); config.Validate(); ProxyConnectivity.CheckAsync(config.Vpn.Proxy).GetAwaiter().GetResult(); Console.WriteLine("Configured proxy reachable from GUI core; no credentials submitted."); return 0; }
            catch (Exception error) { Console.WriteLine(SafeLog.Redact(error.Message)); return 1; }
        }
        if (args.FirstOrDefault() == "--check-snapshot") {
            try { _ = WindowsScripts.RunAsync(Path.GetFullPath(args[1]), "snapshot").GetAwaiter().GetResult(); Console.WriteLine("Actual snapshot JSON parsed successfully; read-only check."); return 0; }
            catch (Exception error) { Console.WriteLine(SafeLog.Redact(error.Message)); return 1; }
        }
        if (args.FirstOrDefault() == "--fake") return Fake(args.ElementAtOrDefault(1) ?? "ok");
        if (args.FirstOrDefault() == "show") {
            Console.InputEncoding = new System.Text.UTF8Encoding(false);
            if (Console.ReadLine() != "fake-主密码") return 7;
            Console.WriteLine(args.Contains("--totp") ? "123456" : args.Contains("UserName") ? "test@example.hk" : "fake-password"); return 0;
        }
        if (args.FirstOrDefault() == "--pipe-fake") { FakePipeAsync(args[1]).GetAwaiter().GetResult(); return 0; }
        var root = Path.GetFullPath(args.FirstOrDefault() ?? ".");
        try
        {
            CoreTestsAsync().GetAwaiter().GetResult();
            if (OperatingSystem.IsWindows()) PipeTestAsync().GetAwaiter().GetResult();
            UiTests(root);
            Console.WriteLine($"PASS: {assertions} assertions; config, route CRUD/search/live demo refresh, redaction, MFA, cancellation, IPC and four-page UI. No real VPN or routes modified.");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error.ToString()); return 1; }
    }
    private static int Fake(string scenario)
    {
        if (Console.ReadLine() != "fake-password") return 8;
        if (scenario == "wait") { Thread.Sleep(30000); return 0; }
        Console.Error.Write("Enter Your Microsoft veri"); Thread.Sleep(70); Console.Error.Write("fication code\nRes"); Thread.Sleep(70); Console.Error.Write("ponse:");
        if (Console.ReadLine() != "123456") return 9;
        if (scenario is "reject" or "flood") {
            Console.Error.WriteLine("Login failed.");
            if (scenario == "flood") for (var i = 0; i < 4000; i++) Console.WriteLine(new string('x', 2048));
            return 2;
        }
        Console.WriteLine("Connected as 192.0.2.10"); return 0;
    }
    private static async Task FakePipeAsync(string name)
    {
        using var pipe = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous); await pipe.ConnectAsync(10000);
        using var reader = new StreamReader(pipe); using var writer = new StreamWriter(pipe) { AutoFlush = true };
        while (await reader.ReadLineAsync() is { } line)
        {
            var request = JsonSerializer.Deserialize<WireMessage>(line)!;
            await writer.WriteLineAsync(JsonSerializer.Serialize(WireMessage.Create("input", "secret-request", "master")));
            var answer = JsonSerializer.Deserialize<WireMessage>((await reader.ReadLineAsync())!)!;
            await writer.WriteLineAsync(JsonSerializer.Serialize(WireMessage.Create("result", request.Id, request.Name, answer.Data.GetString() == "fake-master")));
        }
    }
    private static async Task PipeTestAsync()
    {
        await using var backend = new WindowsBackend(Path.GetTempPath());
        Process? child = null;
        backend.StartProcessOverride = original =>
        {
            var match = System.Text.RegularExpressions.Regex.Match(original.Arguments, "\\\"--pipe\\\" \\\"([^\\\"]+)\\\"");
            Assert(match.Success, "IPC launch metadata");
            var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true };
            start.ArgumentList.Add("--pipe-fake"); start.ArgumentList.Add(match.Groups[1].Value); child = Process.Start(start); return child;
        };
        backend.RequestSecret = _ => Task.FromResult<string?>("fake-master");
        Assert((await backend.InvokeAsync("echo")).GetBoolean(), "IPC secret response failed");
        Assert((await backend.InvokeAsync("echo-again")).GetBoolean(), "IPC request correlation failed");
        if (child != null) {
            using var observer = Process.GetProcessById(child.Id);
            await backend.DisposeAsync(); await observer.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
            Assert(observer.ExitCode == 0, "IPC child exit");
        }
    }
    private static async Task CoreTestsAsync()
    {
        var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.IPv6Loopback, 0);
        listener.Start(); var testPort = ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;
        try {
            await ProxyConnectivity.CheckAsync($"http://[::1]:{testPort}");
            using var accepted = await listener.AcceptTcpClientAsync();
            Assert(true, "IPv6 proxy literal connectivity");
        } finally { listener.Stop(); }
        var proxyRejected = false;
        try { await ProxyConnectivity.CheckAsync($"http://[::1]:{testPort}"); }
        catch (InvalidOperationException error) { proxyRejected = error.Message.Contains("代理"); }
        Assert(proxyRejected, "proxy failure must have actionable error");
        Assert(VpnConfig.NormalizeRoute("10.20.30.47/24") == "10.20.30.0/24", "CIDR normalization");
        Assert(VpnConfig.NormalizeDomain("Server.Example.HK.") == "server.example.hk", "domain normalization");
        foreach (var value in new[] { "0.0.0.0/0", "999.1.1.1/32", "127.0.0.1", "224.1.1.1/32", "10.0.0.1/33" })
        { var rejected = false; try { _ = VpnConfig.NormalizeRoute(value); } catch { rejected = true; } Assert(rejected, "invalid route accepted"); }
        foreach (var value in new[] { "*.hk", "https://server.example.hk", "127.0.0.1", "server.example.hk:22" })
        { var rejected = false; try { _ = VpnConfig.NormalizeDomain(value); } catch { rejected = true; } Assert(rejected, "invalid domain accepted"); }
        var config = new VpnConfig { Keepass = new() { Cli = "mock-cli", Database = "mock.kdbx" }, Routes = [], Domains = ["server.example.hk"] };
        config.Validate();
        var added = RouteTargets.Change(config, RouteKind.Fixed, null, "10.20.30.47/24");
        Assert(added.Routes.Single() == "10.20.30.0/24" && config.Routes.Length == 0, "route add must normalize and preserve source");
        var edited = RouteTargets.Change(added, RouteKind.Fixed, "10.20.30.0/24", "192.0.2.31");
        Assert(edited.Routes.Single() == "192.0.2.31/32", "route edit did not replace original");
        var domainEdited = RouteTargets.Change(edited, RouteKind.Domain, "server.example.hk", "New.Example.HK.");
        Assert(domainEdited.Domains.Single() == "new.example.hk", "domain edit normalization");
        var duplicateRejected = false;
        try { RouteTargets.Change(domainEdited, RouteKind.Domain, null, "new.example.hk"); } catch (InvalidDataException) { duplicateRejected = true; }
        Assert(duplicateRejected && domainEdited.Domains.Length == 1, "duplicate route mutation");
        var missingRejected = false;
        try { RouteTargets.Change(domainEdited, RouteKind.Fixed, "192.0.2.32", null); } catch (InvalidDataException) { missingRejected = true; }
        Assert(missingRejected, "missing original route accepted");
        var empty = RouteTargets.Change(RouteTargets.Change(domainEdited, RouteKind.Fixed, "192.0.2.31", null), RouteKind.Domain, "new.example.hk", null);
        Assert(empty.Routes.Length == 0 && empty.Domains.Length == 0, "last route deletion must be allowed");
        var folder = Path.Combine(Path.GetTempPath(), "hku-gui-test-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(folder);
        try
        {
            var file = Path.Combine(folder, "config.json"); config.Save(file);
            Assert(VpnConfig.Load(file).Domains.Single() == "server.example.hk", "config round trip");
            var old = File.ReadAllText(file); config.Domains = ["*.hk"];
            try { config.Save(file); } catch (InvalidDataException) { }
            Assert(File.ReadAllText(file) == old, "invalid save changed old config");
            config.Domains = ["vpn2fa-b.hku.hk"]; var gatewayRejected = false;
            try { config.Validate(); } catch (InvalidDataException) { gatewayRejected = true; } Assert(gatewayRejected, "gateway route accepted");
            File.WriteAllText(file, old.Replace("\"schemaVersion\": 1", "\"password\": \"unexpected-secret\", \"schemaVersion\": 1"));
            var fieldRejected = false; try { _ = VpnConfig.Load(file); } catch (JsonException) { fieldRejected = true; } Assert(fieldRejected, "unknown secret field accepted");
        }
        finally { File.Delete(Path.Combine(folder, "config.json")); Directory.Delete(folder); }
        var redacted = SafeLog.Redact(@"password=secret cookie=abcd user@example.hk 123456 10.20.1.2 C:\mock\vault.kdbx /Users/mock/vault.kdbx");
        Assert(!redacted.Contains("secret") && !redacted.Contains("abcd") && !redacted.Contains("user@example") && !redacted.Contains("123456") && !redacted.Contains("10.20") && !redacted.Contains("vault"), "redaction leak");
        var settings = new KeepassConfig { Cli = Environment.ProcessPath!, Database = "mock.kdbx", Entry = "Mock", CredentialsEntry = "" };
        var status = "DNS's status: \"查询完成\"\r\nC:\\mock\\status";
        var encoded = Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(new { domainStatus = status }));
        var framed = WindowsScripts.ParseResult("host notice\nHKU_GUI_RESULT_B64:" + encoded + "\r\nother output", "snapshot");
        Assert(framed.GetProperty("domainStatus").GetString() == status, "bridge quotes, Chinese and newlines");
        foreach (var corrupt in new[] { "HKU_GUI_RESULT_B64:!", "HKU_GUI_RESULT_B64:" + Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes("{\"x\":\"value\"s}")) }) {
            var controlled = false; try { _ = WindowsScripts.ParseResult(corrupt, "snapshot"); } catch (InvalidOperationException error) { controlled = !error.Message.Contains("BytePosition"); }
            Assert(controlled, "invalid bridge frame exposed raw JSON error");
        }
        var credentials = await KeepassReader.CredentialsAsync(settings, "fake-主密码", CancellationToken.None);
        Assert(credentials.Username == "test@example.hk" && credentials.Password == "fake-password", "KeePass UTF-8 stdin and attributes");
        Assert(await KeepassReader.TotpAsync(settings, "fake-主密码", CancellationToken.None) == "123456", "KeePass TOTP read");
        var badMasterRejected = false; try { _ = await KeepassReader.CredentialsAsync(settings, "wrong", CancellationToken.None); } catch (InvalidOperationException) { badMasterRejected = true; }
        Assert(badMasterRejected, "wrong KeePass master accepted");
        foreach (var scenario in new[] { "ok", "manual", "reject", "flood", "wait" })
        {
            var stages = new List<string>(); var automatic = 0; var manual = 0;
            using var ct = new CancellationTokenSource(scenario == "wait" ? 400 : 10000);
            var info = Cli.StartInfo(Environment.ProcessPath!, ["--fake", scenario]);
            var watch = Stopwatch.StartNew(); var cancelled = false; var rejected = false;
            try
            {
                var code = await AuthenticationPump.RunAsync(info, "fake-password", () => { automatic++; return Task.FromResult<string?>(scenario == "manual" ? null : "123456"); },
                    () => { manual++; return Task.FromResult<string?>("123456"); }, stage => stages.Add(stage), ct.Token);
                Assert(code == 0, "mock CLI exit");
            }
            catch (OperationCanceledException) { cancelled = true; }
            catch (InvalidOperationException) { rejected = true; }
            Assert(scenario == "wait" ? cancelled && watch.Elapsed.TotalSeconds < 5 : scenario is "reject" or "flood" ? rejected && watch.Elapsed.TotalSeconds < 5 : !rejected && !cancelled, "authentication failure boundary");
            if (scenario != "wait") Assert(automatic == 1 && manual == (scenario == "manual" ? 1 : 0), "MFA retry/input count");
        }
        await using var demo = new DemoBackend();
        var connection = demo.InvokeAsync("connect"); await Task.Delay(200);
        Assert((await demo.InvokeAsync("snapshot")).GetProperty("Connected").GetBoolean(), "demo did not connect");
        await demo.InvokeAsync("disconnect"); await connection;
        Assert(!(await demo.InvokeAsync("snapshot")).GetProperty("Connected").GetBoolean(), "demo did not disconnect");
    }
    private static void UiTests(string root)
    {
        AppBuilder.Configure<VpnApplication>().UseSkia().UseHeadless(new AvaloniaHeadlessPlatformOptions { UseHeadlessDrawing = false }).SetupWithoutStarting();
        var window = new MainWindow(root, true); window.Show(); Dispatcher.UIThread.RunJobs();
        Assert(window.PageCount == 4, "four pages missing"); Assert(window.RouteCount == 2, "configured routes missing");
        var tabs = window.GetVisualDescendants().OfType<TabControl>().Single();
        var output = Path.Combine(root, ".local", "gui-tests"); Directory.CreateDirectory(output);
        for (var page = 0; page < 4; page++)
        {
            tabs.SelectedIndex = page; Dispatcher.UIThread.RunJobs();
            using var frame = window.CaptureRenderedFrame(); Assert(frame != null, "page not rendered"); frame!.Save(Path.Combine(output, $"page-{page}.png"));
        }
        tabs.SelectedIndex = 1; Dispatcher.UIThread.RunJobs();
        var input = window.GetVisualDescendants().OfType<TextBox>().Single(t => t.Name == "RouteTargetInput");
        var search = window.GetVisualDescendants().OfType<TextBox>().Single(t => t.Name == "RouteSearchInput");
        var kind = window.GetVisualDescendants().OfType<ComboBox>().Single(t => t.Name == "RouteKindInput");
        void Click(string name) { window.GetVisualDescendants().OfType<Button>().Single(b => b.Name == name).RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); Pump(100); }
        void RowClick(string target, string action) {
            var row = window.GetVisualDescendants().OfType<TextBlock>().First(t => t.Text == target).GetVisualAncestors().OfType<Grid>().First();
            row.GetVisualDescendants().OfType<Button>().Single(b => b.Content as string == action).RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); Pump(100);
        }
        input.Text = "10.20.30.47/24"; Click("AddRoute"); Assert(window.RouteCount == 3, "UI fixed route add");
        search.Text = "10.20.30"; Pump(30); Assert(window.RouteCount == 1, "route search");
        search.Text = ""; Pump(30);
        RowClick("10.20.30.0/24", "编辑"); input.Text = "192.0.2.31"; Click("SaveRouteEdit");
        Assert(window.GetVisualDescendants().OfType<TextBlock>().Any(t => t.Text == "192.0.2.31/32"), "UI IP edit");
        RowClick("192.0.2.31/32", "删除"); Assert(window.RouteCount == 2, "UI fixed delete");
        kind.SelectedIndex = 1; input.Text = "tmp.example.hk"; Click("AddRoute");
        RowClick("tmp.example.hk", "编辑"); input.Text = "edited.example.hk"; Click("SaveRouteEdit");
        RowClick("edited.example.hk", "删除"); Assert(window.RouteCount == 2, "UI domain CRUD");
        var button = window.GetVisualDescendants().OfType<Button>().Single(b => b.Content as string == "连接 VPN");
        button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Pump(500); Assert(window.RouteCount == 3, "connected route rows missing");
        kind.SelectedIndex = 0; input.Text = "198.51.100.7"; Click("AddRoute"); Assert(window.RouteCount == 4, "connected route add refresh");
        RowClick("198.51.100.7/32", "编辑"); input.Text = "198.51.100.9/24"; Click("SaveRouteEdit");
        RowClick("198.51.100.0/24", "删除"); Assert(window.RouteCount == 3, "connected route edit/delete refresh");
        using (var frame = window.CaptureRenderedFrame()) frame!.Save(Path.Combine(output, "connected.png"));
        var stop = window.GetVisualDescendants().OfType<Button>().Single(b => b.Content as string == "断开 / 恢复清理");
        stop.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); Pump(200); Assert(button.IsEnabled, "disconnect did not restore connect button");
        window.Close(); Pump(100);
    }
    private static void Pump(int milliseconds)
    { var timer = Stopwatch.StartNew(); while (timer.ElapsedMilliseconds < milliseconds) { Dispatcher.UIThread.RunJobs(); Thread.Sleep(10); } }
}
