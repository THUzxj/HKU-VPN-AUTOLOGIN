$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Config.ps1')
. (Join-Path $PSScriptRoot 'lib\Disconnect.ps1')
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $shell = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $child = Start-Process -FilePath $shell -Verb RunAs -Wait -PassThru -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"')
    exit $child.ExitCode
}
$config = Get-Content -LiteralPath (Join-Path $PSScriptRoot '.local\config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Test-HKUConfig $config $PSScriptRoot
$client = Join-Path (Resolve-HKUPath $config.runtimePath $PSScriptRoot) 'openconnect.exe'
$routeScript = Join-Path $PSScriptRoot '.local\vpnc-route.js'
$processes = @(Get-HKUOwnedProcess $client $routeScript $config.vpn.adapterName)
$statePath = Join-Path $PSScriptRoot '.local\domain-session.json'
$state = $null
if (Test-Path -LiteralPath $statePath) { $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json }
$adapter = Get-NetAdapter -Name $config.vpn.adapterName -ErrorAction SilentlyContinue
$verified = $false
if ($adapter -and $state -and $state.adapter -eq $config.vpn.adapterName -and $adapter.InterfaceIndex -eq $state.index) {
    $verified = [bool](Get-NetIPAddress -InterfaceIndex $state.index -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $state.address })
}
# Snapshot only configured split routes on the verified session interface.
$staticRoutes = @()
if ($verified) {
    $prefixes = @($config.routes | ForEach-Object { (ConvertTo-HKURoute $_).cidr })
    if ($state.PSObject.Properties.Name -contains 'static') { $prefixes = @($state.static) }
    foreach ($prefix in $prefixes) {
        $staticRoutes += @(Get-NetRoute -PolicyStore ActiveStore -InterfaceIndex $state.index -DestinationPrefix $prefix -ErrorAction SilentlyContinue |
            Where-Object { $_.NextHop -in @($state.address,'0.0.0.0') })
    }
}
# Cancel DNS work before stopping the tunnel; preserve session records until cleanup succeeds.
Set-Content -LiteralPath (Join-Path $PSScriptRoot '.local\domain-cancel.flag') -Value 'Disconnect requested'
foreach ($process in $processes) { Stop-HKUOwnedProcess $process }
if (@(Get-HKUOwnedProcess $client $routeScript $config.vpn.adapterName).Count) { throw 'VPN is still running; route cleanup aborted.' }
if ($verified) {
    # Wintun often disappears with its process. Never touch a reused interface index.
    Remove-HKUStaticRoutes $state $staticRoutes
}
$global:LASTEXITCODE = 0
& (Join-Path $PSScriptRoot 'DomainRoutes.ps1') -Cleanup
if ($LASTEXITCODE -ne 0) { throw 'Domain cleanup failed. Retry Disconnect.cmd after the DNS worker finishes.' }
Write-Host 'This project VPN is stopped. Session domain/DNS and static VPN routes were cleaned up.'
if ($adapter -and -not $verified) { Write-Warning 'No matching session record: unverified adapter routes were left untouched.' }
