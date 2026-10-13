param([string]$Destination = (Join-Path $PSScriptRoot 'HKU-VPN.exe'))
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'Windows .NET Framework C# compiler is required to build the launcher.' }
$source = Join-Path $PSScriptRoot 'gui\Launcher\Launcher.cs'
& $compiler /nologo /target:winexe /optimize+ /debug- /reference:System.Windows.Forms.dll "/out:$Destination" $source
if ($LASTEXITCODE -ne 0) { throw 'EXE launcher build failed.' }
Write-Output "EXE launcher ready: $Destination"
