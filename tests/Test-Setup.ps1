param([string]$RuntimeArchive)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$work = Join-Path $root '.local\tests'
$database = Get-ChildItem -LiteralPath $work -Filter 'mock-totp-*.kdbx' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $database) { throw 'Run Test-KeePass.ps1 first to create the mock database.' }
$config = Get-Content (Join-Path $root 'examples\config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$config.keepass.database = $database.FullName
$configPath = Join-Path $work 'mock-setup.json'
$config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding UTF8
# Only the test overrides Read-Host; production setup always prompts locally.
function Read-Host {
    param([string]$Prompt, [switch]$AsSecureString)
    if (-not $AsSecureString) { throw 'Unexpected interactive test prompt' }
    return ConvertTo-SecureString 'fake-database-password' -AsPlainText -Force
}
. (Join-Path $root 'Setup.ps1') -ConfigFile $configPath -RuntimeArchive $RuntimeArchive -SkipInstall
$generated = Get-Content (Join-Path $root '.local\config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($generated.routes[0] -ne '192.0.2.10/32' -or -not (Test-Path (Join-Path $root '.local\vpnc-route.js'))) { throw 'Setup output mismatch' }
Write-Output 'Offline setup and credential validation OK with a mock database. No VPN login or system route changes.'
