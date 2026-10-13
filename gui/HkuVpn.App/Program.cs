using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Themes.Fluent;
using HkuVpn.Platform.Windows;

namespace HkuVpn.App;

public static class Program
{
    public static string Root { get; private set; } = "";
    public static bool Demo { get; private set; }
    public static bool ProfileDemo { get; private set; }
    [STAThread]
    public static void Main(string[] args)
    {
        string? Value(string name) { var i = Array.IndexOf(args, name); return i >= 0 && i + 1 < args.Length ? args[i + 1] : null; }
        Root = Path.GetFullPath(Value("--root") ?? FindRoot());
        if (args.Contains("--helper"))
        {
            try { HelperHost.RunAsync(Root, Value("--pipe")!, int.Parse(Value("--parent")!)).GetAwaiter().GetResult(); }
            catch { Environment.ExitCode = 1; }
            return;
        }
        ProfileDemo = args.Contains("--profile-demo"); Demo = args.Contains("--demo") || ProfileDemo;
        var key = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(Root.ToLowerInvariant())));
        using var instance = new Mutex(true, (OperatingSystem.IsWindows() ? "Local\\" : "") + "hku-vpn-gui-" + key, out var first);
        if (!first) { Environment.ExitCode = 2; return; }
        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
    }
    private static string FindRoot()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory != null; directory = directory.Parent)
            if (File.Exists(Path.Combine(directory.FullName, "examples", "config.example.json"))) return directory.FullName;
        return Environment.CurrentDirectory;
    }
    public static AppBuilder BuildAvaloniaApp() => AppBuilder.Configure<VpnApplication>().UsePlatformDetect()
        .With(new Win32PlatformOptions { RenderingMode = [Win32RenderingMode.Software] });
}
public sealed class VpnApplication : Application
{
    public override void Initialize() { Styles.Add(new FluentTheme()); RequestedThemeVariant = Avalonia.Styling.ThemeVariant.Light; }
    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            desktop.MainWindow = new MainWindow(Program.Root, Program.Demo);
            if (Program.ProfileDemo) desktop.MainWindow.Opened += async (_, _) =>
            {
                // Isolated demo profiling, no credentials, networking or system routes.
                desktop.MainWindow.Hide(); await Task.Delay(5000);
                using var process = System.Diagnostics.Process.GetCurrentProcess();
                var cpu = process.TotalProcessorTime; var started = System.Diagnostics.Stopwatch.StartNew();
                var samples = new List<object>();
                for (var i = 0; i < 3; i++) { await Task.Delay(20000); process.Refresh(); samples.Add(new { privateBytes = process.PrivateMemorySize64, workingSet = process.WorkingSet64 }); }
                var result = new { mode = "hidden demo; no VPN/helper", seconds = started.Elapsed.TotalSeconds,
                    singleCoreCpuPercent = (process.TotalProcessorTime - cpu).TotalSeconds / started.Elapsed.TotalSeconds * 100, samples };
                var output = System.IO.Path.Combine(Program.Root, ".local", "gui-tests"); System.IO.Directory.CreateDirectory(output);
                await System.IO.File.WriteAllTextAsync(System.IO.Path.Combine(output, "profile.json"), System.Text.Json.JsonSerializer.Serialize(result));
                desktop.Shutdown();
            };
        }
        base.OnFrameworkInitializationCompleted();
    }
}
