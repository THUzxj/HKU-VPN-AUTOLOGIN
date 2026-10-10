$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\lib\KeePass.ps1"
$testWork = Join-Path $PSScriptRoot '..\.local\tests'; New-Item -ItemType Directory -Path $testWork -Force | Out-Null; $xmlPath = Join-Path $testWork 'mock-totp.xml'
$databasePath = Join-Path $testWork ('mock-totp-' + [Guid]::NewGuid().ToString('N') + '.kdbx')
# Public RFC 6238 test key only; no user credentials are involved.
$xml = '<KeePassFile><Meta><Generator>Local test</Generator></Meta><Root><Group><Name>Mock</Name><Entry><String><Key>Title</Key><Value>HKU MFA</Value></String><String><Key>UserName</Key><Value>mock@example.test</Value></String><String><Key>Password</Key><Value> fake$&quot;\password </Value></String><String><Key>otp</Key><Value>otpauth://totp/Mock?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&amp;digits=6&amp;period=30</Value></String></Entry></Group></Root></KeePassFile>'
Set-Content -LiteralPath $xmlPath -Value $xml -Encoding UTF8
$cli = 'C:\Program Files\KeePassXC\keepassxc-cli.exe'
$start = New-Object Diagnostics.ProcessStartInfo
$start.FileName = $cli
$start.Arguments = ConvertTo-HKUArguments @('import','--quiet','--set-password',$xmlPath,$databasePath)
$start.UseShellExecute = $false
$start.RedirectStandardInput = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$child = New-Object Diagnostics.Process
$child.StartInfo = $start
try {
    [void]$child.Start()
    $outTask = $child.StandardOutput.ReadToEndAsync()
    $errTask = $child.StandardError.ReadToEndAsync()
    $child.StandardInput.WriteLine('fake-database-password')
    $child.StandardInput.WriteLine('fake-database-password')
    $child.StandardInput.Close()
    if (-not $child.WaitForExit(30000)) { $child.Kill(); throw 'Mock import timeout' }
    if ($child.ExitCode -ne 0) { throw ('Mock import failed: ' + $errTask.GetAwaiter().GetResult()) }
} finally { $child.Dispose() }
$settings = [pscustomobject]@{cli=$cli; database=$databasePath; entry='HKU MFA'; keyFile=''}
$master = ConvertTo-SecureString 'fake-database-password' -AsPlainText -Force
$wrong = ConvertTo-SecureString 'wrong-password' -AsPlainText -Force
try {
    $credentials = Get-HKUCredentials -Settings $settings -DatabasePassword $master
    if ($credentials.username -ne 'mock@example.test' -or $credentials.password -cne ' fake$"\password ') { throw 'Mock credentials did not round-trip exactly' }
    $credentials = $null
    $code = Get-HKUTotp -Settings $settings -DatabasePassword $master
    if ($code -notmatch '^\d{6}$') { throw 'Mock TOTP invalid' }
    $code = $null
    $rejected = $false
    try { [void](Get-HKUTotp -Settings $settings -DatabasePassword $wrong) } catch { $rejected = $true }
    if (-not $rejected) { throw 'Wrong database password was not rejected' }
    Write-Output 'Actual KeePassXC CLI: mock username/password, TOTP and wrong-password rejection OK. No real database opened.'
} finally { $master.Dispose(); $wrong.Dispose() }
