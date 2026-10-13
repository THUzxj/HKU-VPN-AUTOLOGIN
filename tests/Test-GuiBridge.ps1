$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$work = Join-Path $root ('.local\gui-bridge-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $work '.local') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'lib') -Destination $work -Recurse
$config = Get-Content (Join-Path $root 'examples\config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$config.routes = @('192.0.2.10/32'); $config.domains = @('server.example.hk')
$config | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $work '.local\config.json') -Encoding UTF8
$specialStatus = "DNS's status: `"查询完成`"`r`nC:\mock\status"
[IO.File]::WriteAllText((Join-Path $work '.local\domain-status.txt'), $specialStatus, (New-Object Text.UTF8Encoding($false)))
@{adapter='HKU-OpenConnect';index=88;address='10.20.1.2';dns=@('192.0.2.53');resolved=@(@{domain='server.example.hk';ip='192.0.2.20';ttl=300})} |
    ConvertTo-Json -Depth 8 | Set-Content (Join-Path $work '.local\domain-session.json') -Encoding UTF8
$mocks = @'
function Get-NetAdapter { param($Name,$ErrorAction); [pscustomobject]@{InterfaceIndex=88} }
function Get-NetIPAddress { param($InterfaceIndex,$AddressFamily,$ErrorAction); [pscustomobject]@{IPAddress='10.20.1.2'} }
function Get-NetRoute {
 param($PolicyStore,$InterfaceIndex,$AddressFamily,$ErrorAction)
 @([pscustomobject]@{DestinationPrefix='192.0.2.10/32';NextHop='10.20.1.2'},
   [pscustomobject]@{DestinationPrefix='192.0.2.20/32';NextHop='10.20.1.99'},
   [pscustomobject]@{DestinationPrefix='192.0.2.53/32';NextHop='0.0.0.0'})
}
'@
$bridge = Join-Path $work 'lib\GuiBridge.ps1'
$source = Get-Content -LiteralPath $bridge -Raw -Encoding UTF8
$source = $source.Replace('$inputJson = [Console]::ReadLine()', $mocks + "`n" + '$inputJson = [Console]::ReadLine()')
[IO.File]::WriteAllText($bridge,$source,(New-Object Text.UTF8Encoding($true)))
$shell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$output = & $shell -NoProfile -ExecutionPolicy Bypass -File $bridge -Operation snapshot
if ($LASTEXITCODE -ne 0) { throw 'Snapshot bridge failed' }
$line = $output | Where-Object { $_ -like 'HKU_GUI_RESULT_B64:*' } | Select-Object -Last 1
$snapshot = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($line.Substring(19))) | ConvertFrom-Json
if (-not $snapshot.connected -or $snapshot.routes.Count -ne 3) { throw 'Snapshot structure failed' }
if ($snapshot.domainStatus -ne $specialStatus) { throw 'Special characters in bridge result were corrupted' }
if (($snapshot.routes | Where-Object source -eq '域名').status -ne '未应用') { throw 'Wrong next-hop was reported as installed' }
if (($snapshot.routes | Where-Object source -eq '固定').status -ne '已安装') { throw 'Real route state missing' }
if (($snapshot.routes | Where-Object source -eq 'VPN DNS').status -ne '已安装') { throw 'DNS route state missing' }
Write-Output 'Mock GUI bridge snapshot, UTF-8 and next-hop verification passed. No real network operations.'
