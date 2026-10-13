# Third-party components

`vendor/vpnc-script-win.js` is an unmodified snapshot of the OpenConnect
vpnc-scripts Windows routing script, retrieved from the upstream master branch.
Its original copyright notices are preserved. The upstream project supplies
GNU GPL version 2 in its COPYING file; this source distribution uses GPL-2.0.

- Source: https://gitlab.com/openconnect/vpnc-scripts/-/blob/master/vpnc-script-win.js
- Upstream license: https://gitlab.com/openconnect/vpnc-scripts/-/blob/master/COPYING
- This project's `LICENSE` contains the GNU GPL version 2 text.

Setup downloads, but this source package does not distribute, the OpenConnect
GUI 1.6.2 x64 installer. The installer contains CLI v9.12 and its DLLs.
They are extracted locally; their license file is retained in `.local/runtime`.

- Package: https://www.infradead.org/openconnect-gui/download/openconnect-gui-1.6.2-win64.exe
- Release/source: https://gitlab.com/openconnect/openconnect-gui/-/releases/v1.6.2
- CLI source: https://gitlab.com/openconnect/openconnect/-/tree/v9.12
- Wintun: https://www.wintun.net/

The pinned installer SHA-256 was calculated from the previously downloaded,
Authenticode-validated artifact. It is not represented as an upstream-published
checksum. Setup verifies both that hash and a valid Authenticode signature with
the expected publisher before extraction. If the upstream artifact changes,
setup stops rather than accepting the new file silently.

PowerShell, KeePassXC and 7-Zip are installed by winget when absent and retain
their respective upstream licensing. No KeePass database, private configuration
or third-party executable is included in the shareable source archive.

The GUI restores Avalonia 11.3.22 (Desktop, Fluent theme and test-only Headless)
from NuGet. Avalonia is MIT licensed; its source and license are available at
https://github.com/AvaloniaUI/Avalonia and
https://github.com/AvaloniaUI/Avalonia/blob/master/licence.md.
NuGet also restores Avalonia's native/rendering dependencies. A compiled GUI
distribution must retain applicable third-party notices; source exports contain
only project files and versioned PackageReference declarations, not these binaries.

The Windows portable ZIP also distributes the self-contained .NET runtime
and GUI dependencies. Full license and notice texts supplied by NuGet packages
and .NET, plus Avalonia's copyright/license text at the pinned source commit,
are retained in `third-party-licenses/`. The ZIP does not include KeePassXC,
OpenConnect, Wintun or the user's downloaded VPN tools; these remain installed
or extracted through Setup. The source-only archive remains free of binaries.