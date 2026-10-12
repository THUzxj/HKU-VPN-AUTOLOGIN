$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
. (Join-Path $root 'lib\Config.ps1')
$local = Join-Path $root '.local'
if (Test-Path (Join-Path $local 'config.json')) { throw 'Run domain tests in an unconfigured test copy.' }
New-Item -ItemType Directory -Path $local -Force | Out-Null
$config = Get-Content (Join-Path $root 'examples\config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$config.routes = @()
$config.domains = @('server.example.hk')
Test-HKUConfig $config $root
foreach ($bad in @('*.hk','https://server.example.hk','server.example.hk:22','127.0.0.1')) {
    $rejected=$false
    try { [void](ConvertTo-HKUDomain $bad) } catch { $rejected=$true }
    if (-not $rejected) { throw 'Invalid domain accepted' }
}
$routeScript = Join-Path $local 'domain-test.js'
New-HKURoutingScript $config $root $routeScript
$generated = Get-Content $routeScript -Raw
if ($generated -notmatch 'CISCO_SPLIT_INC"\) = "0"' -or $generated -notmatch 'HKU_DNS_SERVERS' -or $generated -notmatch 'Run\(domainHook, 0, false\)') { throw 'Domain-only asynchronous hook generation failed' }
$global:HkuMockRoutes = New-Object 'Collections.Generic.List[object]'
$global:HkuMockAnswers = @('192.0.2.20','192.0.2.21')
function Get-NetAdapter { param($Name) [pscustomobject]@{Name='HKU-OpenConnect';InterfaceIndex=88} }
function Get-NetIPAddress { param($InterfaceIndex,$AddressFamily) [pscustomobject]@{IPAddress='10.20.1.2'} }
function Get-NetRoute {
    param($PolicyStore,$InterfaceIndex,$DestinationPrefix)
    $global:HkuMockRoutes | Where-Object { $_.DestinationPrefix -eq $DestinationPrefix -and (-not $InterfaceIndex -or $_.InterfaceIndex -eq $InterfaceIndex) }
}
function New-NetRoute {
    param($DestinationPrefix,$InterfaceIndex,$NextHop,$RouteMetric,$PolicyStore)
    $route=[pscustomobject]@{DestinationPrefix=$DestinationPrefix;InterfaceIndex=$InterfaceIndex;NextHop=$NextHop;RouteMetric=$RouteMetric}
    $global:HkuMockRoutes.Add($route)
    return $route
}
function Remove-NetRoute {
    param([Parameter(ValueFromPipeline=$true)]$InputObject,[switch]$Confirm)
    process { [void]$global:HkuMockRoutes.Remove($InputObject) }
}
function Resolve-DnsName {
    param($Name,$Server,$Type,[switch]$DnsOnly,[switch]$NoHostsFile,[switch]$QuickTimeout)
    if ($Server -ne '10.20.0.1' -or -not ($global:HkuMockRoutes | Where-Object { $_.DestinationPrefix -eq '10.20.0.1/32' })) { throw 'DNS route must exist before querying the VPN DNS' }
    $global:HkuMockAnswers | ForEach-Object { [pscustomobject]@{IPAddress=$_;TTL=300} }
}
$configPath=Join-Path $local 'config.json'
$config | ConvertTo-Json -Depth 8 | Set-Content $configPath -Encoding UTF8
$oldEnv=@{}
foreach ($key in @('reason','TUNIDX','INTERNAL_IP4_ADDRESS','HKU_DNS_SERVERS','VPNGATEWAY')) { $oldEnv[$key]=[Environment]::GetEnvironmentVariable($key,'Process') }
try {
    $env:reason='connect'; $env:TUNIDX='88'; $env:INTERNAL_IP4_ADDRESS='10.20.1.2'; $env:HKU_DNS_SERVERS='10.20.0.1'; $env:VPNGATEWAY='203.0.113.1'
    & (Join-Path $root 'DomainRoutes.ps1') -FromHook
    if ($global:HkuMockRoutes.Count -ne 3) { throw 'DNS and all A record routes were not added' }
    $global:HkuMockAnswers=@()
    & (Join-Path $root 'DomainRoutes.ps1')
    if ($LASTEXITCODE -ne 1 -or $global:HkuMockRoutes.Count -ne 3) { throw 'Lookup failure did not preserve existing routes' }
    $global:HkuMockAnswers=@('192.0.2.20','192.0.2.22')
    & (Join-Path $root 'DomainRoutes.ps1')
    if ($global:HkuMockRoutes | Where-Object { $_.DestinationPrefix -eq '192.0.2.21/32' }) { throw 'Stale route retained after successful refresh' }
    $foreign=[pscustomobject]@{DestinationPrefix='192.0.2.50/32';InterfaceIndex=7;NextHop='192.0.2.1';RouteMetric=1}
    $global:HkuMockRoutes.Add($foreign)
    $global:HkuMockAnswers=@('192.0.2.50')
    & (Join-Path $root 'DomainRoutes.ps1')
    if ($LASTEXITCODE -ne 1 -or -not $global:HkuMockRoutes.Contains($foreign)) { throw 'Conflicting external route was changed' }
    [void]$global:HkuMockRoutes.Remove($foreign)
    & (Join-Path $root 'Add-Domain.ps1') -Name another.example.hk -NoRefresh
    $updated=Get-Content $configPath -Raw | ConvertFrom-Json
    if ('another.example.hk' -notin $updated.domains) { throw 'Add-Domain did not persist the requested domain' }
    & (Join-Path $root 'DomainRoutes.ps1') -Cleanup
    if ($global:HkuMockRoutes.Count -ne 0) { throw 'Owned routes were not cleaned up' }
    Write-Output 'Mock domain bootstrap, multi-IP routing, refresh, failure retention, conflict protection and cleanup OK. No real DNS or route operations.'
} finally {
    foreach ($key in $oldEnv.Keys) { [Environment]::SetEnvironmentVariable($key,$oldEnv[$key],'Process') }
    Remove-Item -LiteralPath $configPath -ErrorAction SilentlyContinue
    Remove-Variable HkuMockRoutes,HkuMockAnswers -Scope Global -ErrorAction SilentlyContinue
}
