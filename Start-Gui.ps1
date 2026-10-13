param([switch]$Demo)
$ErrorActionPreference = 'Stop'
$executable = Join-Path $PSScriptRoot '.local\gui\HkuVpn.exe'
if (-not (Test-Path -LiteralPath $executable)) { throw 'Build the GUI first: .\Build-Gui.ps1 (requires .NET 10 SDK). See docs/GUI.md.' }
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not (Test-Path -LiteralPath (Join-Path (Split-Path $executable) 'coreclr.dll'))) {
    $hasRuntime = $dotnet -and (& $dotnet.Source --list-runtimes | Where-Object { $_ -match '^Microsoft.NETCore.App 10\.' })
    if (-not $hasRuntime) {
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if (-not $winget) { throw 'Install .NET 10 x64 Runtime first, or use a self-contained GUI build.' }
        & $winget.Source install --exact --id Microsoft.DotNet.Runtime.10 --source winget --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { throw '.NET Runtime installation failed.' }
    }
}
$arguments = '--root "' + $PSScriptRoot + '"' + $(if ($Demo) { ' --demo' } else { '' })
Start-Process -FilePath $executable -ArgumentList $arguments
