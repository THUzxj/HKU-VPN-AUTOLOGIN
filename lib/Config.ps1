function Resolve-HKUPath {
    param([string]$Path, [string]$ProjectRoot)
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $ProjectRoot $Path))
}

function ConvertTo-HKURoute {
    param([string]$Value)
    if ($Value -notmatch '^(\d{1,3}(?:\.\d{1,3}){3})(?:/(\d{1,2}))?$') { throw "Invalid IPv4 route: $Value" }
    $octets = @($Matches[1].Split('.') | ForEach-Object { [int]$_ })
    $prefix = 32
    if ($Matches[2]) { $prefix = [int]$Matches[2] }
    if ($prefix -lt 1 -or $prefix -gt 32 -or ($octets | Where-Object { $_ -gt 255 }).Count) { throw "Invalid IPv4 route: $Value" }
    $mask = @()
    $network = @()
    for ($i = 0; $i -lt 4; $i++) {
        $bits = [Math]::Min(8, [Math]::Max(0, $prefix - 8 * $i))
        $byte = 256 - [int][Math]::Pow(2, 8 - $bits)
        $mask += $byte
        $network += ($octets[$i] -band $byte)
    }
    if ($network[0] -eq 127 -or $network[0] -ge 224 -or ($network -join '.') -eq '0.0.0.0') { throw "Unsupported route: $Value" }
    [pscustomobject]@{ address = $network -join '.'; mask = $mask -join '.'; prefix = $prefix; cidr = ($network -join '.') + '/' + $prefix }
}

function Test-HKUConfig {
    param($Config, [string]$ProjectRoot)
    $allowed = @{
        root = @('schemaVersion','runtimePath','keepass','vpn','routes')
        keepass = @('cli','database','entry','credentialsEntry','keyFile','enabled')
        vpn = @('gateways','proxy','adapterName','mtu','tls12','userAgent')
    }
    foreach ($section in @('root','keepass','vpn')) {
        $value = $(if ($section -eq 'root') { $Config } else { $Config.$section })
        foreach ($property in $value.PSObject.Properties.Name) {
            if ($property -notin $allowed[$section]) { throw "Unknown config field in $section. Use only the fields from config.example.json; do not store passwords or TOTP secrets here." }
        }
    }
    if ($Config.schemaVersion -ne 1) { throw 'Unsupported config schemaVersion.' }
    if (-not $Config.keepass.database -or -not $Config.keepass.entry) { throw 'KeePassXC database and entry are required.' }
    if ($Config.keepass.enabled -isnot [bool] -or $Config.vpn.tls12 -isnot [bool]) { throw 'keepass.enabled and vpn.tls12 must be JSON booleans.' }
    if (-not $Config.runtimePath) { throw 'runtimePath is required.' }
    if (-not $Config.vpn.gateways -or @($Config.vpn.gateways).Count -lt 1) { throw 'At least one VPN gateway is required.' }
    foreach ($gateway in $Config.vpn.gateways) {
        $uri = $null
        if (-not [Uri]::TryCreate($gateway, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'VPN gateway must be an HTTPS URL without credentials, query or fragment.' }
    }
    if ($Config.vpn.proxy) {
        $proxy = $null
        if (-not [Uri]::TryCreate($Config.vpn.proxy, [UriKind]::Absolute, [ref]$proxy) -or $proxy.Scheme -ne 'http' -or $proxy.UserInfo -or $proxy.Query -or $proxy.Fragment -or $proxy.AbsolutePath -ne '/') { throw 'Proxy must be an HTTP URL without embedded credentials.' }
    }
    if ($Config.vpn.adapterName -notmatch '^[A-Za-z0-9_-]{1,64}$' -or $Config.vpn.adapterName -match '^(Mihomo|Clash|WLAN|Ethernet)$') { throw 'Use a dedicated VPN adapter name containing letters, digits, hyphens or underscores.' }
    if ($Config.vpn.mtu -lt 576 -or $Config.vpn.mtu -gt 1500) { throw 'MTU must be between 576 and 1500.' }
    if (-not $Config.vpn.userAgent -or $Config.vpn.userAgent -match '[\r\n]') { throw 'A single-line VPN User-Agent is required.' }
    if (-not $Config.routes -or @($Config.routes).Count -lt 1) { throw 'At least one explicit IPv4 route is required; empty routes are not allowed.' }
    foreach ($route in $Config.routes) { [void](ConvertTo-HKURoute $route) }
    [void](Resolve-HKUPath $Config.runtimePath $ProjectRoot)
}

function New-HKURoutingScript {
    param($Config, [string]$ProjectRoot, [string]$Destination)
    Test-HKUConfig $Config $ProjectRoot
    $routes = @($Config.routes | ForEach-Object { ConvertTo-HKURoute $_ } | Sort-Object cidr -Unique)
    $lines = @('// Generated local split routes. Upstream script below is unmodified.',
        'var routeShell = WScript.CreateObject("WScript.Shell");',
        'var routeEnv = routeShell.Environment("Process");',
        ('routeEnv("CISCO_SPLIT_INC") = "' + $routes.Count + '";'))
    for ($i = 0; $i -lt $routes.Count; $i++) {
        $lines += 'routeEnv("CISCO_SPLIT_INC_' + $i + '_ADDR") = "' + $routes[$i].address + '";'
        $lines += 'routeEnv("CISCO_SPLIT_INC_' + $i + '_MASK") = "' + $routes[$i].mask + '";'
        $lines += 'routeEnv("CISCO_SPLIT_INC_' + $i + '_MASKLEN") = "' + $routes[$i].prefix + '";'
    }
    $lines += @('routeEnv("CISCO_SPLIT_EXC") = "0";', 'routeEnv("CISCO_IPV6_SPLIT_INC") = "0";',
        'routeEnv("INTERNAL_IP4_DNS") = "";', 'routeEnv("INTERNAL_IP4_NBNS") = "";',
        'routeEnv("INTERNAL_IP6_ADDRESS") = "";', 'routeEnv("INTERNAL_IP6_NETMASK") = "";')
    $upstream = Get-Content -LiteralPath (Join-Path $ProjectRoot 'vendor\vpnc-script-win.js') -Raw -Encoding UTF8
    [IO.File]::WriteAllText($Destination, (($lines -join "`r`n") + "`r`n" + $upstream), (New-Object Text.UTF8Encoding($false)))
}

function Get-HKUClientArguments {
    param($Config)
    $arguments = @('--protocol=anyconnect', '--os=win', ('--useragent=' + $Config.vpn.userAgent), '--no-dtls')
    if ($Config.vpn.proxy) { $arguments += '--proxy=' + $Config.vpn.proxy } else { $arguments += '--no-proxy' }
    if ($Config.vpn.tls12 -eq $true) { $arguments += '--gnutls-priority=NORMAL:-VERS-ALL:+VERS-TLS1.2' }
    return $arguments
}
