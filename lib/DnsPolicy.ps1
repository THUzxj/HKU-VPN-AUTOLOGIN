function Remove-HKUDnsPolicy {
    param($State)
    if (-not $State.dnsPolicyOwner) { return }
    # The random owner is persisted before creating rules, allowing crash recovery.
    foreach ($rule in @(Get-DnsClientNrptRule -ErrorAction Stop | Where-Object { $_.Comment -eq $State.dnsPolicyOwner })) {
        Remove-DnsClientNrptRule -Name $rule.Name -Force -ErrorAction Stop
    }
}

function Sync-HKUDnsPolicy {
    param($State, $Config)
    $suffixes = @($Config.dnsSuffixes | ForEach-Object { ConvertTo-HKUDomain $_ } | Sort-Object -Unique)
    if (-not $suffixes.Count -and -not $State.dnsPolicyOwner) { return }
    if ($suffixes.Count -and -not $State.dns.Count) { throw 'Suffix DNS requires IPv4 DNS servers.' }
    $desired = @()
    foreach ($suffix in $suffixes) {
        $desired += [pscustomobject]@{names=@($suffix,('.' + $suffix)); servers=@($State.dns)}
    }
    # More-specific empty rules exempt tunnel endpoints from campus DNS.
    foreach ($hostName in @($Config.vpn.gateways | ForEach-Object { ([Uri]$_).Host } | Sort-Object -Unique)) {
        if ($suffixes | Where-Object { $hostName -eq $_ -or $hostName.EndsWith('.' + $_) }) {
            $desired += [pscustomobject]@{names=@($hostName); servers=@()}
        }
    }
    $existing = @(Get-DnsClientNrptRule -ErrorAction Stop)
    foreach ($rule in $existing) {
        if ($State.dnsPolicyOwner -and $rule.Comment -eq $State.dnsPolicyOwner) { continue }
        foreach ($target in $desired) {
            if (@($rule.Namespace | Where-Object { $_ -in $target.names }).Count) {
                throw 'An existing NRPT rule conflicts with a requested DNS namespace; no rules were replaced.'
            }
        }
    }
    Remove-HKUDnsPolicy $State
    try {
        foreach ($target in $desired) {
            $parameters = @{Namespace=$target.names; Comment=$State.dnsPolicyOwner; DisplayName='HKU VPN session DNS'; ErrorAction='Stop'}
            if ($target.servers.Count) { $parameters.NameServers = $target.servers }
            Add-DnsClientNrptRule @parameters | Out-Null
        }
    } catch {
        Remove-HKUDnsPolicy $State
        throw
    }
    Clear-DnsClientCache -ErrorAction Stop
}
