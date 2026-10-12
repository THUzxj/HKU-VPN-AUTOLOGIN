param([Parameter(Mandatory=$true)][string[]]$Name, [switch]$NoRefresh)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Config.ps1')
$path = Join-Path $PSScriptRoot '.local\config.json'
$config = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
$names = @($Name | ForEach-Object { ConvertTo-HKUDomain $_ })
if (-not $config.PSObject.Properties['domains']) { $config | Add-Member -NotePropertyName domains -NotePropertyValue @() }
$config.domains = @(@($config.domains) + $names | Sort-Object -Unique)
Test-HKUConfig $config $PSScriptRoot
$config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
Write-Output 'Domains saved in local configuration.'
if (-not $NoRefresh -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot '.local\domain-session.json'))) {
    & (Join-Path $PSScriptRoot 'DomainRoutes.ps1')
} else { Write-Output 'New domains will be resolved on the next VPN connection.' }
