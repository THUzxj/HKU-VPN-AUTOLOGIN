param([string]$Destination = (Join-Path (Split-Path $PSScriptRoot) 'hku-vpn-autologin-source.zip'))
$ErrorActionPreference = 'Stop'
# Allowlist avoids copying .local, database files, downloaded executables or caches.
$files = @('README.md','LICENSE','THIRD_PARTY_NOTICES.md','.gitignore','.gitattributes','Setup.cmd','Setup.ps1',
    'Connect.cmd','Connect.ps1','Run.cmd','Export-Source.ps1','lib','vendor','examples','tests')
$stage = Join-Path $PSScriptRoot ('.local\export-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
foreach ($file in $files) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $stage -Recurse }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $Destination -Force
Write-Output "Source-only archive created: $Destination"
