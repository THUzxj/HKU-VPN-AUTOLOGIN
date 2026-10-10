function ConvertTo-HKUArguments {
    param([string[]]$Values)
    ($Values | ForEach-Object {
        '"' + [regex]::Replace([regex]::Replace($_, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
    }) -join ' '
}

function Invoke-HKUKeepassShow {
    param($Settings, [Security.SecureString]$DatabasePassword, [string[]]$ShowOptions, [string]$Entry)
    if (-not $Entry) { $Entry = [string]$Settings.entry }
    $arguments = @('show', '--quiet') + $ShowOptions
    if ($Settings.keyFile) { $arguments += @('--key-file', [string]$Settings.keyFile) }
    $arguments += @([string]$Settings.database, $Entry)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = [string]$Settings.cli
    $start.Arguments = ConvertTo-HKUArguments $arguments
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    $pointer = [IntPtr]::Zero
    $writer = $null
    try {
        [void]$process.Start()
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $writer = New-Object IO.StreamWriter($process.StandardInput.BaseStream, (New-Object Text.UTF8Encoding($false)))
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($DatabasePassword)
        $writer.WriteLine([Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer))
        $writer.Flush()
        $writer.Close()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill()
            throw 'KeePassXC CLI timed out.'
        }
        $result = $outputTask.GetAwaiter().GetResult().TrimEnd([char[]]"`r`n")
        [void]$errorTask.GetAwaiter().GetResult()
        # Do not print CLI errors: they can include sensitive entry information.
        if ($process.ExitCode -ne 0) {
            throw 'Unable to read the KeePassXC entry. Check the database password, entry path and key file.'
        }
        return $result
    } finally {
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        if ($writer) { $writer.Dispose() }
        $process.Dispose()
    }
}

function Get-HKUTotp {
    param($Settings, [Security.SecureString]$DatabasePassword)
    $code = Invoke-HKUKeepassShow -Settings $Settings -DatabasePassword $DatabasePassword -ShowOptions @('--totp')
    if ($code -notmatch '^\d{6}$') { throw 'The configured entry must provide a six-digit TOTP.' }
    return $code
}

function Get-HKUCredentials {
    param($Settings, [Security.SecureString]$DatabasePassword)
    $entry = [string]$Settings.credentialsEntry
    if (-not $entry) { $entry = [string]$Settings.entry }
    $username = Invoke-HKUKeepassShow -Settings $Settings -DatabasePassword $DatabasePassword -Entry $entry -ShowOptions @('--attributes', 'UserName')
    $password = Invoke-HKUKeepassShow -Settings $Settings -DatabasePassword $DatabasePassword -Entry $entry -ShowOptions @('--attributes', 'Password')
    if ([string]::IsNullOrWhiteSpace($username) -or [string]::IsNullOrEmpty($password)) {
        throw 'Fill the User name and Password fields in the configured KeePassXC entry, save the database, then reconnect.'
    }
    if ($username -match '[\r\n]' -or $password -match '[^\x20-\x7E]') {
        throw 'This Windows OpenConnect build requires a single-line username and a printable ASCII password.'
    }
    return [pscustomobject]@{ username = $username; password = $password }
}
