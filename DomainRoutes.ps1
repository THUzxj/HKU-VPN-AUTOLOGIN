param([switch]$FromHook, [switch]$Cleanup)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Config.ps1')
$local = Join-Path $PSScriptRoot '.local'
$statePath = Join-Path $local 'domain-session.json'
$statusPath = Join-Path $local 'domain-status.txt'
$cancelPath = Join-Path $local 'domain-cancel.flag'
$lock = $null
$state = $null
function Save-DomainState { $script:state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding UTF8 }
function Test-DomainInterface {
    $adapter = Get-NetAdapter -Name $state.adapter -ErrorAction SilentlyContinue
    if (-not $adapter -or $adapter.InterfaceIndex -ne $state.index) { return $false }
    return [bool](Get-NetIPAddress -InterfaceIndex $state.index -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $state.address })
}
function Remove-OwnedRoute {
    param($Owned)
    $routesToRemove = @(Get-NetRoute -PolicyStore ActiveStore -InterfaceIndex $state.index -DestinationPrefix $Owned.prefix -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -eq $Owned.nextHop -and $_.RouteMetric -eq $Owned.metric })
    foreach ($route in $routesToRemove) { $route | Remove-NetRoute -Confirm:$false -ErrorAction Stop }
}
function Add-DomainRoute {
    param([string]$IP)
    if (Test-Path -LiteralPath $cancelPath) { throw 'Domain refresh cancelled for disconnect.' }
    [void](ConvertTo-HKURoute ($IP + '/32'))
    if ($IP -in $state.protected) { throw 'A DNS answer conflicts with the VPN transport address.' }
    $prefix = $IP + '/32'
    $existing = @(Get-NetRoute -PolicyStore ActiveStore -DestinationPrefix $prefix -ErrorAction SilentlyContinue)
    if ($existing.Count) {
        if ($existing | Where-Object { $_.InterfaceIndex -ne $state.index }) { throw "Existing host route conflicts with VPN route: $prefix" }
        return
    }
    New-NetRoute -DestinationPrefix $prefix -InterfaceIndex $state.index -NextHop $state.address -RouteMetric 5 -PolicyStore ActiveStore | Out-Null
    $state.owned = @($state.owned) + @([pscustomobject]@{prefix=$prefix; nextHop=$state.address; metric=5})
    Save-DomainState
}
try {
    New-Item -ItemType Directory -Path $local -Force | Out-Null
    if ($Cleanup -or ($FromHook -and $env:reason -eq 'disconnect')) { Set-Content -LiteralPath $cancelPath -Value 'Disconnect requested' }
    # Serialize refresh, add-domain and disconnect operations. Never share VPN secrets.
    for ($attempt = 0; $attempt -lt 100 -and -not $lock; $attempt++) {
        try { $lock = [IO.File]::Open((Join-Path $local 'domain-routes.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch { Start-Sleep -Milliseconds 100 }
    }
    if (-not $lock) { throw 'Domain routes are busy. Retry after the current DNS query completes.' }
    if (Test-Path -LiteralPath $statePath) { $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json }
    if ($Cleanup -or ($FromHook -and $env:reason -eq 'disconnect')) {
        if ($state -and (Test-DomainInterface)) { foreach ($owned in $state.owned) { Remove-OwnedRoute $owned } }
        if ($state) { Remove-Item -LiteralPath $statePath }
        Remove-Item -LiteralPath $cancelPath -ErrorAction SilentlyContinue
        Set-Content -LiteralPath $statusPath -Value 'Domain session cleaned up.' -Encoding UTF8
        return
    }
    $config = Get-Content -LiteralPath (Join-Path $local 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-HKUConfig $config $PSScriptRoot
    if ($FromHook -and $env:reason -eq 'connect') {
        if ($state) { throw 'Previous domain session exists. Run DomainRoutes.ps1 -Cleanup before reconnecting.' }
        $dns = @($config.dnsServers)
        if (-not $dns.Count) { $dns = @($env:HKU_DNS_SERVERS -split '\s+' | Where-Object { $_ }) }
        $state = [pscustomobject]@{index=[int]$env:TUNIDX; adapter=$config.vpn.adapterName; address=$env:INTERNAL_IP4_ADDRESS; dns=$dns; protected=@($env:VPNGATEWAY); owned=@(); resolved=@(); static=@($config.routes | ForEach-Object { (ConvertTo-HKURoute $_).cidr })}
        if (-not (Test-DomainInterface)) { throw 'VPN adapter identity/address could not be verified.' }
        Save-DomainState
    }
    if (-not $state -or -not (Test-DomainInterface)) { throw 'No active verified VPN domain session. Connect the VPN first.' }
    $names = @($config.domains | ForEach-Object { ConvertTo-HKUDomain $_ } | Sort-Object -Unique)
    $desired = @()
    $answers = @()
    if ($names.Count) {
        if (-not $state.dns.Count) { throw 'VPN did not supply IPv4 DNS servers. Configure dnsServers explicitly.' }
        foreach ($dns in $state.dns) { Add-DomainRoute $dns; $desired += $dns + '/32' }
        foreach ($name in $names) {
            if (Test-Path -LiteralPath $cancelPath) { throw 'Domain refresh cancelled for disconnect.' }
            if ($name -in @($config.vpn.gateways | ForEach-Object { ([Uri]$_).Host })) { throw 'VPN gateway domains must not be routed back into the VPN.' }
            $records = @()
            foreach ($dns in $state.dns) {
                if (Test-Path -LiteralPath $cancelPath) { throw 'Domain refresh cancelled for disconnect.' }
                try {
                    $records = @(Resolve-DnsName -Name ($name + '.') -Server $dns -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop | Where-Object { $_.IPAddress })
                    if ($records.Count) { break }
                } catch { $records = @() }
            }
            if (-not $records.Count) { throw "VPN DNS lookup failed: $name. Existing domain routes were retained." }
            foreach ($record in $records) {
                [void](ConvertTo-HKURoute ($record.IPAddress + '/32'))
                $desired += $record.IPAddress + '/32'
                $answers += [pscustomobject]@{domain=$name; ip=$record.IPAddress; ttl=$record.TTL}
            }
        }
        foreach ($address in @($answers.ip | Sort-Object -Unique)) { Add-DomainRoute $address }
    }
    # Remove only routes created by this session, after all lookups succeed.
    $retain = @()
    foreach ($owned in $state.owned) {
        if ($owned.prefix -in $desired) { $retain += $owned } else { Remove-OwnedRoute $owned }
    }
    $state.owned = $retain
    $state.resolved = $answers
    Save-DomainState
    $summary = @('Domain route refresh OK. Global DNS unchanged.') + @($answers | ForEach-Object { $_.domain + ' -> ' + $_.ip + ' (TTL ' + $_.ttl + ')' })
    $summary | Set-Content -LiteralPath $statusPath -Encoding UTF8
    if (-not $FromHook) { $summary | Write-Output }
} catch {
    $_.Exception.Message | Set-Content -LiteralPath $statusPath -Encoding UTF8
    if (-not $FromHook) { Write-Error $_.Exception.Message -ErrorAction Continue }
    exit 1
} finally { if ($lock) { $lock.Dispose() } }
