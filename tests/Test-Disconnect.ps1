$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'lib\Disconnect.ps1')
$client = 'C:\mock project\runtime\openconnect.exe'
$routeScript = 'C:\mock project\.local\vpnc-route.js'
$global:hkuMockProcesses = @(
    [pscustomobject]@{ProcessId=123; CreationDate='first'; ExecutablePath=$client; CommandLine='"openconnect.exe" "--script" "C:\mock project\.local\vpnc-route.js" "--interface=HKU-Test"'},
    [pscustomobject]@{ProcessId=124; CreationDate='second'; ExecutablePath=$client; CommandLine='"openconnect.exe" "--script" "C:\another\.local\vpnc-route.js" "--interface=HKU-Test"'},
    [pscustomobject]@{ProcessId=125; CreationDate='third'; ExecutablePath='C:\other\openconnect.exe'; CommandLine='"openconnect.exe" "--script" "C:\mock project\.local\vpnc-route.js" "--interface=HKU-Test"'}
)
$global:hkuStopped = @()
function Get-CimInstance {
    param($ClassName, $Filter)
    if ($Filter -match '^ProcessId = (\d+)$') { return $global:hkuMockProcesses | Where-Object { $_.ProcessId -eq [int]$Matches[1] } }
    return $global:hkuMockProcesses
}
function Stop-Process {
    param($Id, [switch]$Force, $ErrorAction)
    $global:hkuStopped += $Id
    $global:hkuMockProcesses = @($global:hkuMockProcesses | Where-Object { $_.ProcessId -ne $Id })
}
function Get-Process { param($Id, $ErrorAction); return $null }
$global:hkuAdapterIndex = 88
$global:hkuRouteDeletes = @()
$static = [pscustomobject]@{DestinationPrefix='192.0.2.10/32';NextHop='10.20.1.2';RouteMetric=6}
function Get-NetAdapter { param($Name, $ErrorAction); [pscustomobject]@{InterfaceIndex=$global:hkuAdapterIndex} }
function Get-NetIPAddress { param($InterfaceIndex,$AddressFamily,$ErrorAction); [pscustomobject]@{IPAddress='10.20.1.2'} }
function Get-NetRoute {
    param($PolicyStore,$InterfaceIndex,$DestinationPrefix,$ErrorAction)
    @($static, [pscustomobject]@{DestinationPrefix=$DestinationPrefix;NextHop='10.20.1.99';RouteMetric=6},
        [pscustomobject]@{DestinationPrefix=$DestinationPrefix;NextHop='10.20.1.2';RouteMetric=99})
}
function Remove-NetRoute { param([Parameter(ValueFromPipeline=$true)]$InputObject,[switch]$Confirm); process { $global:hkuRouteDeletes += $InputObject } }
try {
    $owned = @(Get-HKUOwnedProcess $client $routeScript 'HKU-Test')
    if ($owned.Count -ne 1 -or $owned[0].ProcessId -ne 123) { throw 'Foreign process matched.' }
    $stale = $owned[0].PSObject.Copy()
    $stale.CreationDate = 'old'
    $rejected = $false
    try { Stop-HKUOwnedProcess $stale } catch { $rejected = $true }
    if (-not $rejected -or $global:hkuStopped.Count) { throw 'PID reuse was not rejected.' }
    Stop-HKUOwnedProcess $owned[0]
    if ($global:hkuStopped.Count -ne 1 -or $global:hkuStopped[0] -ne 123 -or $global:hkuMockProcesses.Count -ne 2) { throw 'Stop affected foreign processes.' }
    if (@(Get-HKUOwnedProcess $client $routeScript 'HKU-Test').Count) { throw 'Stopped process still matched.' }
    Stop-HKUOwnedProcess $owned[0]
    if ($global:hkuStopped.Count -ne 1) { throw 'Repeated stop was not harmless.' }
    $state = [pscustomobject]@{adapter='HKU-Test';index=88;address='10.20.1.2'}
    $global:hkuAdapterIndex = 89
    Remove-HKUStaticRoutes $state @($static)
    if ($global:hkuRouteDeletes.Count) { throw 'Reused adapter routes deleted.' }
    $global:hkuAdapterIndex = 88
    Remove-HKUStaticRoutes $state @($static)
    if ($global:hkuRouteDeletes.Count -ne 1 -or $global:hkuRouteDeletes[0].NextHop -ne $static.NextHop -or $global:hkuRouteDeletes[0].RouteMetric -ne $static.RouteMetric) { throw 'Foreign routes deleted.' }
    Write-Output 'Mock process ownership, PID reuse, repeated disconnect and route identity checks passed. No real processes or routes changed.'
} finally { Remove-Variable hkuMockProcesses,hkuStopped,hkuAdapterIndex,hkuRouteDeletes -Scope Global -ErrorAction SilentlyContinue }
