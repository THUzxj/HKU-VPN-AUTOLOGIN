param([switch]$SelfContained)
$ErrorActionPreference = 'Stop'
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw 'Install .NET 10 SDK to build the GUI.' }
$project = Join-Path $PSScriptRoot 'gui\HkuVpn.App\HkuVpn.App.csproj'
$destination = Join-Path $PSScriptRoot '.local\gui'
& dotnet publish $project -c Release -r win-x64 --self-contained $SelfContained.IsPresent.ToString().ToLowerInvariant() -o $destination
if ($LASTEXITCODE -ne 0) { throw 'GUI build failed.' }
& (Join-Path $PSScriptRoot 'Build-Launcher.ps1')
Write-Output "GUI ready: $destination"
