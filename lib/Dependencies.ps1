function Find-HKUExecutable {
    param([string]$Name, [string[]]$Candidates)
    foreach ($candidate in $Candidates) { if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate } }
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Install-HKUWingetPackage {
    param([string]$Id)
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) { throw "winget is unavailable. Install App Installer, or install $Id manually using the README links." }
    Write-Host "Installing $Id with winget..."
    & $winget.Source install --exact --id $Id --source winget --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "winget could not install $Id. Install it manually, then rerun setup." }
}

function Initialize-HKUDependencies {
    param($Config, [string]$ProjectRoot, [switch]$SkipInstall, [string]$RuntimeArchive)
    if (-not [Environment]::Is64BitOperatingSystem -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne 'X64') {
        throw 'This runtime is for Windows x64. Windows ARM64 and 32-bit systems are not supported.'
    }
    $pwsh = Find-HKUExecutable 'pwsh.exe' @("$env:ProgramFiles\PowerShell\7\pwsh.exe")
    if (-not $pwsh -and -not $SkipInstall) { Install-HKUWingetPackage 'Microsoft.PowerShell' }
    if (-not (Test-Path -LiteralPath $Config.keepass.cli)) {
        if ($SkipInstall) { throw 'KeePassXC CLI missing. Install KeePassXC or correct keepass.cli.' }
        Install-HKUWingetPackage 'KeePassXCTeam.KeePassXC'
        $found = Find-HKUExecutable 'keepassxc-cli.exe' @("$env:ProgramFiles\KeePassXC\keepassxc-cli.exe")
        if (-not $found) { throw 'KeePassXC installed but its CLI was not found.' }
        $Config.keepass.cli = $found
    }
    $runtime = Resolve-HKUPath $Config.runtimePath $ProjectRoot
    $client = Join-Path $runtime 'openconnect.exe'
    if (-not (Test-Path -LiteralPath $client)) {
        $sevenZip = Find-HKUExecutable '7z.exe' @("$env:ProgramFiles\7-Zip\7z.exe")
        if (-not $sevenZip) {
            if ($SkipInstall) { throw '7-Zip missing. Install 7zip.7zip to extract the OpenConnect package.' }
            Install-HKUWingetPackage '7zip.7zip'
            $sevenZip = Find-HKUExecutable '7z.exe' @("$env:ProgramFiles\7-Zip\7z.exe")
            if (-not $sevenZip) { throw '7-Zip was not found after installation.' }
        }
        $cache = Join-Path $ProjectRoot '.local\downloads'
        New-Item -ItemType Directory -Path $cache -Force | Out-Null
        $archive = $RuntimeArchive
        if (-not $archive) {
            $archive = Join-Path $cache 'openconnect-gui-1.6.2-win64.exe'
            if (-not (Test-Path -LiteralPath $archive)) {
                $downloadArgs = @{ Uri = 'https://www.infradead.org/openconnect-gui/download/openconnect-gui-1.6.2-win64.exe'; OutFile = $archive; UseBasicParsing = $true }
                if ($Config.vpn.proxy) { $downloadArgs.Proxy = $Config.vpn.proxy }
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Write-Host 'Downloading the pinned, signed OpenConnect GUI package (CLI v9.12)...'
                Invoke-WebRequest @downloadArgs
            }
        }
        $expected = 'DE08D8968E40E219932D01025521F879178EC99246802DB488C0FDAC9FCEF11A'
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expected) { throw 'OpenConnect download SHA-256 mismatch. The file will not be extracted or executed.' }
        $signature = Get-AuthenticodeSignature -LiteralPath $archive
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Nikolaos Mavrogiannopoulos') { throw 'OpenConnect installer signature validation failed.' }
        $stage = Join-Path $cache ('extracted-' + [Guid]::NewGuid().ToString('N'))
        & $sevenZip x $archive ('-o' + $stage) '-y' 'openconnect.exe' '*.dll' 'LICENSE.txt' | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $stage 'openconnect.exe'))) { throw 'OpenConnect CLI extraction failed.' }
        New-Item -ItemType Directory -Path $runtime -Force | Out-Null
        Get-ChildItem -LiteralPath $stage -File | Where-Object { $_.Extension -in @('.dll','.exe') -or $_.Name -eq 'LICENSE.txt' } | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $runtime -Force
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $runtime 'wintun.dll'))) { throw 'wintun.dll is missing next to openconnect.exe.' }
    $savedPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 turns native stderr warnings into ErrorRecords.
        $ErrorActionPreference = 'Continue'
        $version = (& $client --version 2>&1 | Out-String)
        $versionExitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    if ($versionExitCode -ne 0 -or $version -notmatch 'OpenConnect version') { throw 'OpenConnect CLI did not run. Check its DLLs and runtime architecture.' }
    if ($Config.vpn.tls12 -eq $true -and $version -notmatch 'GnuTLS') { throw 'TLS 1.2 priority workaround requires a GnuTLS OpenConnect build; disable vpn.tls12 for an OpenSSL build.' }
    & $Config.keepass.cli --version
    if ($LASTEXITCODE -ne 0) { throw 'KeePassXC CLI failed to run.' }
    Write-Host 'OpenConnect, Wintun and KeePassXC dependencies OK.'
}
