function Invoke-HKUClient {
    param([string]$Client, [string[]]$ClientArguments, [string]$Password,
        [scriptblock]$TotpProvider)

    # Windows argv quoting, including paths with spaces and trailing backslashes.
    $quoted = foreach ($argument in $ClientArguments) {
        '"' + [regex]::Replace([regex]::Replace($argument, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
    }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Client
    $start.Arguments = $quoted -join ' '
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    # The bundled Windows build reads piped input with fgetws in the C locale.
    # Reject non-ASCII passwords in the caller rather than silently changing them.
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    $inputWriter = $null
    $line = New-Object Text.StringBuilder
    try {
        [void]$process.Start()
        # ProcessStartInfo.StandardInputEncoding is unavailable on .NET Framework
        # (Windows PowerShell 5.1). Write ASCII directly to the stdin pipe instead.
        $inputWriter = New-Object IO.StreamWriter($process.StandardInput.BaseStream, (New-Object Text.ASCIIEncoding))
        $inputWriter.WriteLine($Password)
        $inputWriter.Flush()
        $Password = $null
        $streams = foreach ($reader in @($process.StandardOutput, $process.StandardError)) {
            $buffer = New-Object char[] 1024
            [pscustomobject]@{ reader = $reader; buffer = $buffer; task = $reader.ReadAsync($buffer, 0, $buffer.Length) }
        }
        $recentOutput = ''
        $challengeSeen = $false
        $automaticAttempted = $false
        # Read both output streams asynchronously: prompts do not always end in a newline.
        # Ctrl+C still reaches the child process through the shared console.
        while (-not $process.HasExited -or ($streams | Where-Object { $null -ne $_.task })) {
            foreach ($stream in $streams) {
                if ($null -eq $stream.task -or -not $stream.task.IsCompleted) { continue }
                $count = $stream.task.GetAwaiter().GetResult()
                if ($count -eq 0) { $stream.task = $null; continue }
                $chunk = -join $stream.buffer[0..($count - 1)]
                [Console]::Write($chunk)
                $recentOutput += $chunk
                if ($recentOutput.Length -gt 4096) { $recentOutput = $recentOutput.Substring($recentOutput.Length - 4096) }
                if ($recentOutput -match 'Enter Your Microsoft verification code') { $challengeSeen = $true }
                $stream.task = $stream.reader.ReadAsync($stream.buffer, 0, $stream.buffer.Length)
                if ($TotpProvider -and $challengeSeen -and -not $automaticAttempted -and
                    $recentOutput -match 'Response:\s*$' -and -not $process.HasExited) {
                    $automaticAttempted = $true
                    try {
                        $code = & $TotpProvider
                        if ($code -notmatch '^\d{6}$') { throw 'Invalid TOTP output.' }
                        $inputWriter.WriteLine($code)
                        $inputWriter.Flush()
                        $code = $null
                        [void]$line.Clear()
                        [Console]::WriteLine()
                        Write-Host 'MFA code submitted from KeePassXC (code hidden).'
                    } catch {
                        Write-Host 'Automatic MFA failed. Enter the code manually at the Response prompt.'
                    }
                }
            }
            if (-not $process.HasExited -and -not [Console]::IsInputRedirected -and [Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq [ConsoleKey]::Enter) {
                    $inputWriter.WriteLine($line.ToString())
                    $inputWriter.Flush()
                    [void]$line.Clear()
                    [Console]::WriteLine()
                } elseif ($key.Key -eq [ConsoleKey]::Backspace) {
                    if ($line.Length -gt 0) { $line.Length-- }
                } elseif ([int]$key.KeyChar -ge 32 -and [int]$key.KeyChar -le 126) {
                    [void]$line.Append($key.KeyChar)
                }
            } else { Start-Sleep -Milliseconds 50 }
        }
        $process.WaitForExit()
        return $process.ExitCode
    } finally {
        [void]$line.Clear()
        if ($inputWriter) { $inputWriter.Dispose() }
        $process.Dispose()
    }
}
