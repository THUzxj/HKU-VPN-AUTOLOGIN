using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

internal static class Launcher
{
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            string root = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            string executable = Path.Combine(root, ".local", "gui", "HkuVpn.exe");
            if (!File.Exists(executable) || !File.Exists(Path.Combine(root, "examples", "config.example.json")))
                throw new InvalidOperationException("运行包不完整。请解压整个运行包后再打开 HKU-VPN.exe；源码版请先运行 Build-Gui.ps1。");
            bool demo = false;
            foreach (string arg in args)
            {
                if (arg == "--check-start") return 0;
                if (arg == "--demo") demo = true;
                else throw new InvalidOperationException("支持的启动参数：--demo。");
            }
            Process.Start(new ProcessStartInfo(executable, "--root \"" + root + "\"" + (demo ? " --demo" : ""))
            {
                WorkingDirectory = root,
                UseShellExecute = false,
                CreateNoWindow = true
            });
            return 0;
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "HKU VPN 启动失败", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
