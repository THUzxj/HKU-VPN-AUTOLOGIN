param([string]$Destination = (Join-Path (Split-Path $PSScriptRoot) 'hku-vpn-windows-x64.zip'), [switch]$NoBuild)
$ErrorActionPreference = 'Stop'
$published = Join-Path $PSScriptRoot '.local\gui-package'
if (-not $NoBuild) {
    $project = Join-Path $PSScriptRoot 'gui\HkuVpn.App\HkuVpn.App.csproj'
    # Rebuild avoids reusing assemblies with private absolute PDB paths.
    & dotnet build $project -t:Rebuild -c Release -r win-x64 --self-contained true -p:DebugType=None -p:DebugSymbols=false "-p:PathMap=$PSScriptRoot=/_/" -p:NuGetAudit=false
    if ($LASTEXITCODE -ne 0) { throw 'Release rebuild failed.' }
    & dotnet publish $project -c Release -r win-x64 --self-contained true --no-build --no-restore -p:DebugType=None -p:DebugSymbols=false "-p:PathMap=$PSScriptRoot=/_/" -o $published
    if ($LASTEXITCODE -ne 0) { throw 'Self-contained GUI publish failed.' }
}
if (-not (Test-Path -LiteralPath (Join-Path $published 'coreclr.dll'))) { throw 'A self-contained build is required. Run Package-Gui.ps1 without -NoBuild first.' }
$stage = Join-Path $PSScriptRoot ('.local\package-' + [Guid]::NewGuid().ToString('N'))
$sourceZip = $stage + '.zip'
& (Join-Path $PSScriptRoot 'Export-Source.ps1') -Destination $sourceZip
Expand-Archive -LiteralPath $sourceZip -DestinationPath $stage
$guiDestination = Join-Path $stage '.local\gui'
New-Item -ItemType Directory -Path $guiDestination -Force | Out-Null
Copy-Item -Path (Join-Path $published '*') -Destination $guiDestination -Recurse -Force
Get-ChildItem -LiteralPath $guiDestination -Filter '*.pdb' -File | Remove-Item
& (Join-Path $PSScriptRoot 'Build-Launcher.ps1') -Destination (Join-Path $stage 'HKU-VPN.exe')
# Explicit .NET ZIP enumeration includes .local (Compress-Archive can skip hidden files).
Add-Type -AssemblyName System.IO.Compression.FileSystem
$noticeRoot = Join-Path $stage 'third-party-licenses'
New-Item -ItemType Directory -Path $noticeRoot -Force | Out-Null
$assets = Get-Content (Join-Path $PSScriptRoot 'gui\HkuVpn.App\obj\project.assets.json') -Raw | ConvertFrom-Json
$packageRoots = @($assets.packageFolders.PSObject.Properties.Name)
# Retain full license/notice texts included by NuGet packages, without local metadata.
foreach ($package in $assets.libraries.PSObject.Properties) {
    if ($package.Value.type -ne 'package') { continue }
    foreach ($packageRoot in $packageRoots) {
        $packagePath = Join-Path $packageRoot $package.Value.path
        $nupkg = Get-ChildItem -LiteralPath $packagePath -Filter '*.nupkg' -File | Select-Object -First 1
        if (-not $nupkg) { continue }
        $reader = [IO.Compression.ZipFile]::OpenRead($nupkg.FullName)
        try {
            foreach ($entry in $reader.Entries | Where-Object { $_.Name -match '(?i)(license|licence|notices)' }) {
                $name = ($package.Name -replace '[/\\]','-') + '-' + $entry.Name
                $target = Join-Path $noticeRoot $name
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
            }
        } finally { $reader.Dispose() }
    }
}
$runtimeVersion = (Get-Content (Join-Path $published 'HkuVpn.runtimeconfig.json') -Raw | ConvertFrom-Json).runtimeOptions.includedFrameworks | Where-Object name -eq 'Microsoft.NETCore.App' | Select-Object -ExpandProperty version
foreach ($packageRoot in $packageRoots) {
    $runtimePackage = Join-Path $packageRoot ('microsoft.netcore.app.runtime.win-x64\' + $runtimeVersion)
    foreach ($name in @('LICENSE.TXT','THIRD-PARTY-NOTICES.TXT')) {
        Copy-Item -LiteralPath (Join-Path $runtimePackage $name) -Destination (Join-Path $noticeRoot ('dotnet-' + $name)) -ErrorAction Stop
    }
    break
}
# Avalonia's package declares MIT but omits its full copyright/license text.
$avalonia = Join-Path $noticeRoot 'Avalonia-LICENSE.md'
Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/AvaloniaUI/Avalonia/627ae9ef921621e27e7aa58df2796fbadb50af88/licence.md' -OutFile $avalonia
if ((Get-Content -LiteralPath $avalonia -Raw) -notmatch 'Permission is hereby granted') { throw 'Invalid Avalonia license download.' }
foreach ($file in Get-ChildItem -LiteralPath $guiDestination -File | Where-Object { $_.Name -match '^HkuVpn.*\.(dll|exe)$' }) {
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    foreach ($encoding in @([Text.Encoding]::UTF8, [Text.Encoding]::Unicode)) {
        $binaryText = $encoding.GetString($bytes)
        if ($binaryText.Contains($PSScriptRoot) -or ($env:USERPROFILE -and $binaryText.Contains($env:USERPROFILE))) {
            throw 'Private build path found in GUI assembly. Rebuild with Package-Gui.ps1 without -NoBuild.'
        }
    }
}
if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination }
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $Destination)
Remove-Item -LiteralPath $sourceZip
Write-Output "Windows x64 portable package ready: $Destination"
