$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Config.ps1')
. (Join-Path $PSScriptRoot 'lib\KeePass.ps1')
. (Join-Path $PSScriptRoot 'lib\Client.ps1')
$configPath = Join-Path $PSScriptRoot '.local\config.json'
if (-not (Test-Path -LiteralPath $configPath)) { throw 'Run Setup.cmd first.' }
$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
Test-HKUConfig $config $PSScriptRoot
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $shell = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    Start-Process -FilePath $shell -Verb RunAs -ArgumentList ('-NoProfile -NoExit -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"')
    exit
}
$runtime = Resolve-HKUPath $config.runtimePath $PSScriptRoot
$client = Join-Path $runtime 'openconnect.exe'
$wintunDll = Join-Path $runtime 'wintun.dll'
foreach ($dependency in @($client, $wintunDll, $config.keepass.cli, $config.keepass.database)) {
    if (-not (Test-Path -LiteralPath $dependency -PathType Leaf)) { throw 'A configured dependency is missing; run Setup.cmd again.' }
}
if (Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'Cisco' -and $_.Status -eq 'Up' }) { throw 'Disconnect Cisco VPN before using this launcher.' }
if (Get-Process openconnect -ErrorAction SilentlyContinue) { throw 'Another OpenConnect process is running. Disconnect it first.' }
if (Get-NetAdapter -Name $config.vpn.adapterName -ErrorAction SilentlyContinue) { throw 'The selected adapter already exists. Check its owner instead of deleting it blindly.' }
if ($config.vpn.proxy) {
    $proxyUri = [Uri]$config.vpn.proxy
    $socket = New-Object Net.Sockets.TcpClient
    try {
        $attempt = $socket.ConnectAsync($proxyUri.Host, $proxyUri.Port)
        if (-not $attempt.Wait(5000) -or -not $socket.Connected) { throw 'Proxy connection failed. Start Clash/proxy first.' }
    } finally { $socket.Dispose() }
}
$probeSource = @"
using System;
using System.Runtime.InteropServices;
public class HkuProjectTunProbe {
 [DllImport(@"$wintunDll", EntryPoint="WintunCreateAdapter", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr Create(string name, string type, IntPtr guid);
 [DllImport(@"$wintunDll", EntryPoint="WintunStartSession", SetLastError=true)] public static extern IntPtr Start(IntPtr adapter, uint capacity);
 [DllImport(@"$wintunDll", EntryPoint="WintunEndSession")] public static extern void End(IntPtr session);
 [DllImport(@"$wintunDll", EntryPoint="WintunCloseAdapter")] public static extern void Close(IntPtr adapter);
}
"@
if (-not ('HkuProjectTunProbe' -as [type])) { Add-Type -TypeDefinition $probeSource }
$adapter = [HkuProjectTunProbe]::Create($config.vpn.adapterName, 'OpenConnect', [IntPtr]::Zero)
if ($adapter -eq [IntPtr]::Zero) { throw ('Wintun adapter creation failed: ' + [Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
try {
    $session = [HkuProjectTunProbe]::Start($adapter, 4194304)
    if ($session -eq [IntPtr]::Zero) { throw ('Wintun session creation failed: ' + [Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
    [HkuProjectTunProbe]::End($session)
} finally { [HkuProjectTunProbe]::Close($adapter) }
$routeScript = Join-Path $PSScriptRoot '.local\vpnc-route.js'
New-HKURoutingScript $config $PSScriptRoot $routeScript
$commonArgs = @(Get-HKUClientArguments $config)
$probeArgs = $commonArgs + @('--non-inter')
$server = $null
Write-Host 'Checking TLS/XML authentication without credentials...'
foreach ($gateway in $config.vpn.gateways) {
    for ($i = 0; $i -lt 2; $i++) {
        $saved = $ErrorActionPreference
        try { $ErrorActionPreference = 'Continue'; $probe = (& $client @probeArgs $gateway 2>&1 | Out-String) }
        finally { $ErrorActionPreference = $saved }
        if ($probe -match 'XML POST enabled' -and ($config.vpn.tls12 -ne $true -or $probe -match '\(TLS1\.2\)')) { $server = $gateway; break }
    }
    if ($server) { break }
}
if (-not $server) { throw 'Gateway checks failed. No VPN credentials were submitted. Check proxy, TLS settings and gateway.' }
Write-Host ('Gateway ready: ' + $server)
Write-Host ('VPN split routes: ' + ($config.routes -join ', '))
Write-Host 'Internet/default DNS stay on their existing route. Ctrl+C disconnects.'
$master = Read-Host 'KeePassXC database master password (not saved)' -AsSecureString
$password = $null
$credentials = $null
try {
    $credentials = Get-HKUCredentials $config.keepass $master
    $login = $credentials.username
    $password = $credentials.password
    $credentials = $null
    $totpProvider = $null
    if ($config.keepass.enabled) {
        $check = Get-HKUTotp $config.keepass $master
        $check = $null
        $totpProvider = { Get-HKUTotp $config.keepass $master }
        Write-Host 'Credentials and TOTP ready. Microsoft MFA will be submitted automatically once.'
    } else { Write-Host 'Credentials ready. Enter MFA manually at the Response prompt.' }
    $arguments = $commonArgs + @(('--interface=' + $config.vpn.adapterName), '--disable-ipv6', ('--mtu=' + $config.vpn.mtu),
        '--script', $routeScript, '--user', $login, '--passwd-on-stdin', $server)
    $exitCode = Invoke-HKUClient -Client $client -ClientArguments $arguments -Password $password -TotpProvider $totpProvider
    Write-Host ('OpenConnect exited with code ' + $exitCode)
} finally {
    $password = $null
    $credentials = $null
    $master.Dispose()
}
