param([string]$Destination = (Join-Path (Split-Path $PSScriptRoot) 'hku-vpn-autologin-source.zip'))
$ErrorActionPreference = 'Stop'
# Allowlist avoids copying .local, database files, downloaded executables or caches.
$files = @('README.md','AGENTS.md','LICENSE','THIRD_PARTY_NOTICES.md','.gitignore','.gitattributes','Setup.cmd','Setup.ps1',
    'Connect.cmd','Connect.ps1','Disconnect.cmd','Disconnect.ps1','Run.cmd','Gui.cmd','Start-Gui.ps1','Build-Gui.ps1','Build-Launcher.ps1','Package-Gui.ps1','Export-Source.ps1','DomainRoutes.ps1','Add-Domain.ps1','.github','lib','vendor','examples','tests','docs')
$stage = Join-Path $PSScriptRoot ('.local\export-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
foreach ($file in $files) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $stage -Recurse }
# GUI source only: never include generated binaries, PDBs, obj metadata or local paths.
$guiRoot = Join-Path $PSScriptRoot 'gui'
Get-ChildItem -LiteralPath $guiRoot -File -Recurse | Where-Object {
    $_.FullName -notmatch '[\\/](bin|obj|\.avalonia-build-tasks)[\\/]' -and $_.Extension -in @('.cs','.csproj','.props','.axaml','.targets')
} | ForEach-Object {
    $relative = $_.FullName.Substring($guiRoot.Length).TrimStart([char[]]'\/')
    $target = Join-Path (Join-Path $stage 'gui') $relative
    New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
    Copy-Item -LiteralPath $_.FullName -Destination $target
}
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $Destination -Force
Write-Output "Source-only archive created: $Destination"
