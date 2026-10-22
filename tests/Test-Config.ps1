$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
. (Join-Path $root 'lib\Config.ps1')
$config = Get-Content (Join-Path $root 'examples\config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Test-HKUConfig $config $root
if ('--reconnect-timeout=3600' -notin @(Get-HKUClientArguments $config)) { throw 'Configured reconnect timeout was not passed to OpenConnect' }
foreach ($value in @(0,1441,1.5,'60',$true,$null)) {
    $config.vpn.reconnectTimeoutMinutes=$value; $rejected=$false
    try { Test-HKUConfig $config $root } catch { $rejected=$true }
    if (-not $rejected) { throw 'Invalid reconnect wait accepted' }
}
$config.vpn.PSObject.Properties.Remove('reconnectTimeoutMinutes')
Test-HKUConfig $config $root
if ('--reconnect-timeout=300' -notin @(Get-HKUClientArguments $config)) { throw 'Legacy reconnect timeout default changed' }
$config.vpn | Add-Member -NotePropertyName reconnectTimeoutMinutes -NotePropertyValue 1440
Test-HKUConfig $config $root
if ('--reconnect-timeout=86400' -notin @(Get-HKUClientArguments $config)) { throw 'Reconnect timeout upper boundary conversion failed' }
$route = ConvertTo-HKURoute '10.20.30.47/24'
if ($route.cidr -ne '10.20.30.0/24' -or $route.mask -ne '255.255.255.0') { throw 'CIDR normalization failed' }
foreach ($invalid in @('0.0.0.0/0', '10.0.0.1/33', '999.1.1.1/32', 'hku.hk', '127.0.0.1/32', '224.0.0.1/32')) {
    $rejected = $false
    try { [void](ConvertTo-HKURoute $invalid) } catch { $rejected = $true }
    if (-not $rejected) { throw "Invalid route accepted: $invalid" }
}
$work = Join-Path $root '.local\tests'
New-Item -ItemType Directory -Path $work -Force | Out-Null
$config.routes = @('10.20.30.47/24','192.0.2.10/32','192.0.2.10/32')
$scriptPath = Join-Path $work 'mock-route.js'
New-HKURoutingScript $config $root $scriptPath
$script = Get-Content -LiteralPath $scriptPath -Raw
if ($script -notmatch 'CISCO_SPLIT_INC"\) = "2"' -or $script -notmatch '10\.20\.30\.0' -or $script -notmatch 'INTERNAL_IP4_DNS"\) = ""') { throw 'Split route generation failed' }
$config.routes = @()
Test-HKUConfig $config $root
New-HKURoutingScript $config $root $scriptPath
if ((Get-Content $scriptPath -Raw) -notmatch 'CISCO_SPLIT_INC"\) = "0"') { throw 'Empty target list must use zero split routes' }
$config.routes = @('192.0.2.10/32')
$config.keepass | Add-Member -NotePropertyName password -NotePropertyValue 'mock-secret'
$rejected = $false
try { Test-HKUConfig $config $root } catch { $rejected = $true }
if (-not $rejected) { throw 'Plaintext credential configuration was accepted' }
Write-Output 'Config validation, CIDR normalization, duplicate handling and split routing generation OK. No network routes changed.'
