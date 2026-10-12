function Get-HKUOwnedProcess {
    param([string]$Client, [string]$RouteScript, [string]$AdapterName)
    $scriptArgument = '"--script"\s+"' + [regex]::Escape($RouteScript) + '"(?:\s|$)'
    $interfaceArgument = '"--interface=' + [regex]::Escape($AdapterName) + '"(?:\s|$)'
    Get-CimInstance Win32_Process -Filter "Name = 'openconnect.exe'" | Where-Object {
        $_.ExecutablePath -and [string]::Equals($_.ExecutablePath, $Client, [StringComparison]::OrdinalIgnoreCase) -and
        $_.CommandLine -match $scriptArgument -and $_.CommandLine -match $interfaceArgument
    }
}

function Stop-HKUOwnedProcess {
    param($Process)
    # Recheck creation time and command line to protect against PID reuse.
    $current = Get-CimInstance Win32_Process -Filter ('ProcessId = ' + $Process.ProcessId)
    if (-not $current) { return }
    if ($current.CreationDate -ne $Process.CreationDate -or $current.ExecutablePath -ne $Process.ExecutablePath -or
        $current.CommandLine -ne $Process.CommandLine) { throw 'VPN process identity changed; retry disconnect.' }
    Stop-Process -Id $Process.ProcessId -Force -ErrorAction Stop
    $remaining = Get-Process -Id $Process.ProcessId -ErrorAction SilentlyContinue
    if ($remaining) {
        try { $remaining.WaitForExit(10000) | Out-Null } finally { $remaining.Dispose() }
    }
    $current = Get-CimInstance Win32_Process -Filter ('ProcessId = ' + $Process.ProcessId)
    if ($current -and $current.CreationDate -eq $Process.CreationDate) { throw 'VPN process did not stop; route cleanup aborted.' }
}

function Remove-HKUStaticRoutes {
    param($State, [object[]]$Routes)
    $adapter = Get-NetAdapter -Name $State.adapter -ErrorAction SilentlyContinue
    if (-not $adapter -or $adapter.InterfaceIndex -ne $State.index) { return }
    if (-not (Get-NetIPAddress -InterfaceIndex $State.index -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $State.address })) { return }
    foreach ($saved in $Routes) {
        $matches = @(Get-NetRoute -PolicyStore ActiveStore -InterfaceIndex $State.index -DestinationPrefix $saved.DestinationPrefix -ErrorAction SilentlyContinue |
            Where-Object { $_.NextHop -eq $saved.NextHop -and $_.RouteMetric -eq $saved.RouteMetric })
        foreach ($route in $matches) { $route | Remove-NetRoute -Confirm:$false -ErrorAction Stop }
    }
}
