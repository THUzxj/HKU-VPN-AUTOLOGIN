using System.Diagnostics;
using System.Runtime.InteropServices;

namespace HkuVpn.Platform.Windows;

internal static class WindowsTermination
{
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll")] private static extern bool FreeConsole();
    [DllImport("kernel32.dll")] private static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GenerateConsoleCtrlEvent(uint controlEvent, uint group);
    public static async Task StopAsync(Process ownedProcess)
    {
        if (ownedProcess.HasExited) return;
        // The helper has no console. The child was started with its own hidden console.
        if (AttachConsole((uint)ownedProcess.Id))
        {
            try
            {
                SetConsoleCtrlHandler(IntPtr.Zero, true);
                if (GenerateConsoleCtrlEvent(0, 0))
                    try { await ownedProcess.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(8)); } catch (TimeoutException) { }
            }
            finally { FreeConsole(); SetConsoleCtrlHandler(IntPtr.Zero, false); }
        }
        // AuthenticationPump force-stops this process only if graceful shutdown didn't finish.
    }
}
