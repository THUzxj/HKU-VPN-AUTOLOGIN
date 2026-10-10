param([string]$ConfigFile, [string]$RuntimeArchive, [string]$DownloadProxy, [switch]$SkipInstall, [switch]$SkipCredentialCheck)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Config.ps1')
. (Join-Path $PSScriptRoot 'lib\Dependencies.ps1')
. (Join-Path $PSScriptRoot 'lib\KeePass.ps1')
function Read-SetupValue {
    param([string]$Prompt, [string]$Default)
    $answer = Read-Host ($Prompt + $(if ($Default) { " [$Default]" } else { '' }))
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim().Trim('"')
}
Write-Host 'HKU VPN Auto Login setup: paths and connection parameters only; passwords are never saved here.'
if ($ConfigFile) {
    $config = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    # Bootstrap software before asking users to create their KeePassXC database.
    $bootstrap = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'examples\config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $bootstrap.vpn.proxy = $DownloadProxy
    Initialize-HKUDependencies -Config $bootstrap -ProjectRoot $PSScriptRoot -SkipInstall:$SkipInstall -RuntimeArchive $RuntimeArchive
    Write-Host 'Dependencies ready. Create/open your KeePassXC database and configure the HKU entries as described in README.md.'
    $keepassGui = Join-Path (Split-Path $bootstrap.keepass.cli) 'KeePassXC.exe'
    if (Test-Path -LiteralPath $keepassGui) { Start-Process -FilePath $keepassGui }
    $existing = Join-Path $PSScriptRoot '.local\config.json'
    if (Test-Path -LiteralPath $existing) { $config = Get-Content -LiteralPath $existing -Raw -Encoding UTF8 | ConvertFrom-Json }
    else { $config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'examples\config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json; $config.keepass.database = ''; $config.routes = @() }
    $detectedCli = Find-HKUExecutable 'keepassxc-cli.exe' @("$env:ProgramFiles\KeePassXC\keepassxc-cli.exe")
    $config.keepass.cli = Read-SetupValue 'KeePassXC CLI path (installed automatically if missing)' $(if ($detectedCli) { $detectedCli } else { "$env:ProgramFiles\KeePassXC\keepassxc-cli.exe" })
    do {
        $config.keepass.database = Read-SetupValue 'Create/save the database first, then enter its .kdbx path' $config.keepass.database
        $databaseExists = $config.keepass.database -and (Test-Path -LiteralPath $config.keepass.database -PathType Leaf)
        if (-not $databaseExists) { Write-Host 'The database file does not exist yet. Create/save it in KeePassXC, then enter its path.' }
    } until ($databaseExists)
    $config.keepass.entry = Read-SetupValue 'TOTP entry path' $config.keepass.entry
    $config.keepass.credentialsEntry = Read-SetupValue 'Username/password entry path' $config.keepass.credentialsEntry
    $config.keepass.keyFile = Read-SetupValue 'Key file path (empty if none)' $config.keepass.keyFile
    $config.vpn.gateways = @((Read-SetupValue 'HTTPS VPN gateways, comma separated' ($config.vpn.gateways -join ',')) -split ',' | ForEach-Object { $_.Trim() })
    $proxy = Read-SetupValue 'HTTP proxy URL; type none for a direct VPN connection' $config.vpn.proxy
    $config.vpn.proxy = $(if ($proxy -eq 'none') { '' } else { $proxy })
    $config.vpn.adapterName = Read-SetupValue 'Dedicated VPN adapter name' $config.vpn.adapterName
    $config.vpn.mtu = [int](Read-SetupValue 'Requested MTU' ([string]$config.vpn.mtu))
    $config.routes = @((Read-SetupValue 'VPN target IPv4/CIDRs, comma separated (required; not domain names)' ($config.routes -join ',')) -split ',' | ForEach-Object { $_.Trim() })
    $config.keepass.enabled = (Read-SetupValue 'Automatic MFA? y/n' $(if ($config.keepass.enabled) { 'y' } else { 'n' })) -ne 'n'
}
$config.keepass.database = Resolve-HKUPath $config.keepass.database $PSScriptRoot
if ($config.keepass.keyFile) { $config.keepass.keyFile = Resolve-HKUPath $config.keepass.keyFile $PSScriptRoot }
$config.keepass.cli = Resolve-HKUPath $config.keepass.cli $PSScriptRoot
Test-HKUConfig $config $PSScriptRoot
if (-not (Test-Path -LiteralPath $config.keepass.database -PathType Leaf)) { throw 'Database does not exist. Create/save it in KeePassXC first; follow the README.' }
if ($config.keepass.keyFile -and -not (Test-Path -LiteralPath $config.keepass.keyFile -PathType Leaf)) { throw 'Configured key file is missing.' }
Initialize-HKUDependencies -Config $config -ProjectRoot $PSScriptRoot -SkipInstall:$SkipInstall -RuntimeArchive $RuntimeArchive
if (-not $SkipCredentialCheck) {
    $master = Read-Host 'KeePassXC database master password (local check only; not saved)' -AsSecureString
    try {
        $credentials = Get-HKUCredentials $config.keepass $master
        $credentials = $null
        if ($config.keepass.enabled) { $code = Get-HKUTotp $config.keepass $master; $code = $null }
        Write-Host 'KeePassXC entry access OK. No VPN authentication was attempted.'
    } finally { $master.Dispose() }
} else { Write-Host 'Credential validation skipped. Actual entry access must be verified before use.' }
$local = Join-Path $PSScriptRoot '.local'
New-Item -ItemType Directory -Path $local -Force | Out-Null
$routePath = Join-Path $local 'vpnc-route.js'
New-HKURoutingScript $config $PSScriptRoot $routePath
$configPath = Join-Path $local 'config.json'
$config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding UTF8
Write-Host "Setup complete: $configPath"
Write-Host 'Start your configured proxy first, then run Connect.cmd. Keep the VPN window open; Ctrl+C disconnects.'
