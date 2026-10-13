param([string]$Archive = (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'hku-vpn-windows-x64.zip'))
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($Archive)
try {
    $bad = @($zip.Entries | Where-Object { $_.FullName -match '\.kdbx$|\.keyx$|\.pdb$|(^|[\\/])(credentials|config|domain-session)\.json$|(^|[\\/])(bin|obj)[\\/]' })
    if ($bad.Count) { throw 'Private/generated files found in portable package.' }
    foreach ($entry in $zip.Entries | Where-Object { $_.Name -match '\.(md|ps1|cs|csproj|txt|json|cmd)$' -or $_.Name -match '^HkuVpn.*\.(dll|exe)$' }) {
        $reader = New-Object IO.StreamReader($entry.Open())
        try {
            $text = $reader.ReadToEnd()
            if ($text.Contains($root) -or ($env:USERPROFILE -and $text.Contains($env:USERPROFILE))) { throw 'Private local path found in portable package.' }
        } finally { $reader.Dispose() }
    }
} finally { $zip.Dispose() }
$testRoot = Join-Path $root ('.local\EXE 启动测试 ' + [Guid]::NewGuid().ToString('N'))
[IO.Compression.ZipFile]::ExtractToDirectory($Archive, $testRoot)
$old = @{}
foreach ($key in @('DOTNET_ROOT','DOTNET_ROOT_X64','DOTNET_MULTILEVEL_LOOKUP')) { $old[$key]=[Environment]::GetEnvironmentVariable($key,'Process') }
$demo = $null
try {
    $env:DOTNET_ROOT = Join-Path $testRoot 'missing-runtime'
    $env:DOTNET_ROOT_X64 = $env:DOTNET_ROOT
    $env:DOTNET_MULTILEVEL_LOOKUP = '0'
    $launcher = Join-Path $testRoot 'HKU-VPN.exe'
    $check = Start-Process -FilePath $launcher -WorkingDirectory $env:TEMP -ArgumentList '--check-start' -WindowStyle Hidden -Wait -PassThru
    if ($check.ExitCode -ne 0) { throw 'EXE path check failed.' }
    $started = Start-Process -FilePath $launcher -WorkingDirectory $env:TEMP -ArgumentList '--demo' -WindowStyle Hidden -PassThru
    if (-not $started.WaitForExit(5000)) { throw 'Launcher did not exit after starting GUI.' }
    $expected = Join-Path $testRoot '.local\gui\HkuVpn.exe'
    for ($attempt=0; $attempt -lt 30 -and -not $demo; $attempt++) {
        Start-Sleep -Milliseconds 200
        $demo = Get-Process HkuVpn -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $expected }
    }
    if (-not $demo) { throw 'Portable demo did not start.' }
    Start-Sleep -Seconds 2
    $runtime = @($demo.Modules | Where-Object ModuleName -eq 'coreclr.dll')
    if ($runtime.Count -ne 1 -or $runtime[0].FileName -ne (Join-Path $testRoot '.local\gui\coreclr.dll')) { throw 'Bundled .NET runtime was not loaded.' }
    Write-Output 'Portable EXE path, Chinese/space directory, bundled runtime and privacy checks passed. Demo only; no VPN or credentials used.'
} finally {
    # The executable must belong to our freshly extracted, unique demo directory.
    if ($demo) { $demo | Where-Object { $_.Path -eq (Join-Path $testRoot '.local\gui\HkuVpn.exe') } | Stop-Process -Force }
    foreach ($key in $old.Keys) { [Environment]::SetEnvironmentVariable($key,$old[$key],'Process') }
}
