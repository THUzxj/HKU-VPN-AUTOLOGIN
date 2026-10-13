param([Parameter(Mandatory=$true)][ValidateSet('install','prepare','snapshot','refresh','disconnect','diagnose')][string]$Operation)
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$root = Split-Path $PSScriptRoot
. (Join-Path $PSScriptRoot 'Config.ps1')
. (Join-Path $PSScriptRoot 'Dependencies.ps1')
$inputJson = [Console]::ReadLine()
$request = if ($inputJson -and $inputJson -ne 'null') { $inputJson | ConvertFrom-Json } else { $null }
function Write-GuiResult($Value) {
    $json = ConvertTo-Json -InputObject $Value -Depth 12 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    # Allow an already-running older helper to disconnect during an update.
    [Console]::WriteLine('HKU_GUI_RESULT:' + $json)
    [Console]::WriteLine('HKU_GUI_RESULT_B64:' + $encoded)
}
function Read-GuiConfig {
    $config = Get-Content -LiteralPath (Join-Path $root '.local\config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-HKUConfig $config $root
    return $config
}
function Get-GuiSnapshot {
    $config = Read-GuiConfig
    $path = Join-Path $root '.local\domain-session.json'
    $state = $null
    if (Test-Path -LiteralPath $path) { try { $state = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
    $verified = $false
    if ($state) {
        $adapter = Get-NetAdapter -Name $state.adapter -ErrorAction SilentlyContinue
        $verified = $adapter -and $adapter.InterfaceIndex -eq $state.index -and
            [bool](Get-NetIPAddress -InterfaceIndex $state.index -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $state.address })
    }
    $actual = @()
    if ($verified) { $actual = @(Get-NetRoute -PolicyStore ActiveStore -InterfaceIndex $state.index -AddressFamily IPv4 -ErrorAction SilentlyContinue) }
    $rows = @()
    foreach ($route in $config.routes) {
        $prefix = (ConvertTo-HKURoute $route).cidr
        $exists = [bool]($actual | Where-Object { $_.DestinationPrefix -eq $prefix -and $_.NextHop -in @($state.address,'0.0.0.0') })
        $rows += @{source='固定';target=$route;prefix=$prefix;status=$(if ($exists) {'已安装'} else {'未应用'});detail='连接中修改后立即同步'}
    }
    foreach ($domain in $config.domains) {
        $records = @($state.resolved | Where-Object { $_.domain -eq (ConvertTo-HKUDomain $domain) })
        if (-not $records.Count) { $rows += @{source='域名';target=$domain;prefix='';status=$(if ($verified) {'待解析 / 查询失败'} else {'未应用'});detail='查看域名状态，或点击刷新'} }
        foreach ($record in $records) {
            $prefix = $record.ip + '/32'
            $exists = [bool]($actual | Where-Object { $_.DestinationPrefix -eq $prefix -and $_.NextHop -in @($state.address,'0.0.0.0') })
            $rows += @{source='域名';target=$domain;prefix=$prefix;status=$(if ($exists) {'已安装'} else {'未应用'});detail=('TTL ' + $record.ttl + '；不自动刷新')}
        }
    }
    if ($state) {
        $configuredPrefixes = @($config.routes | ForEach-Object { (ConvertTo-HKURoute $_).cidr })
        foreach ($old in @($state.static | Where-Object { $_ -notin $configuredPrefixes })) {
            if ($actual | Where-Object { $_.DestinationPrefix -eq $old -and $_.NextHop -in @($state.address,'0.0.0.0') }) {
                $rows += @{source='会话旧路由';target=$old;prefix=$old;status='仍安装';detail='配置已删除；刷新成功后清理'}
            }
        }
        foreach ($old in @($state.resolved | Where-Object { $_.domain -notin $config.domains })) {
            $prefix = $old.ip+'/32'
            if ($actual | Where-Object { $_.DestinationPrefix -eq $prefix -and $_.NextHop -in @($state.address,'0.0.0.0') }) {
                $rows += @{source='会话旧域名';target=$old.domain;prefix=$prefix;status='仍安装';detail='配置已删除；刷新成功后清理'}
            }
        }
        foreach ($dns in $state.dns) {
            $prefix = $dns + '/32'; $exists = [bool]($actual | Where-Object { $_.DestinationPrefix -eq $prefix -and $_.NextHop -in @($state.address,'0.0.0.0') })
            $rows += @{source='VPN DNS';target=$dns;prefix=$prefix;status=$(if ($exists) {'已安装'} else {'未应用'});detail='仅查询使用，未替换全局 DNS'}
        }
    }
    $status = ''
    $statusPath = Join-Path $root '.local\domain-status.txt'
    if (Test-Path -LiteralPath $statusPath) { $status = (Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8).Trim() }
    return @{connected=[bool]$verified;recoveryNeeded=[bool]($state -and -not $verified);routes=@($rows);domainStatus=$status}
}
try {
    $result = $null
    switch ($Operation) {
        'install' {
            $config = $request.config
            # Bootstrap dependencies before asking the user to create a database.
            $savedDatabase = $config.keepass.database
            $savedRoutes = $config.routes
            if (-not $config.keepass.database) { $config.keepass.database = 'pending-setup.kdbx' }
            if (-not $config.routes -and -not $config.domains) { $config.routes = @('192.0.2.10/32') }
            Test-HKUConfig $config $root
            Initialize-HKUDependencies -Config $config -ProjectRoot $root -RuntimeArchive $request.archive
            $config.keepass.database = $savedDatabase
            $config.routes = @($savedRoutes)
            $result = $config
        }
        'prepare' {
            $config = Read-GuiConfig
            if (Get-Process openconnect -ErrorAction SilentlyContinue) { throw 'Another OpenConnect is running.' }
            if (Get-NetAdapter -Name $config.vpn.adapterName -ErrorAction SilentlyContinue) { throw 'Adapter already exists.' }
            if (Test-Path -LiteralPath (Join-Path $root '.local\domain-session.json')) { throw 'Previous session requires cleanup.' }
            if (Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'Cisco' -and $_.Status -eq 'Up' }) { throw 'Cisco is connected.' }
            $runtime = Resolve-HKUPath $config.runtimePath $root
            $dll = Join-Path $runtime 'wintun.dll'
            foreach ($file in @($dll,(Join-Path $runtime 'openconnect.exe'))) { if (-not (Test-Path -LiteralPath $file)) { throw 'Missing runtime.' } }
            # Retain the existing Wintun preflight before starting OpenConnect.
            $source = @"
using System;
using System.Runtime.InteropServices;
public class HkuGuiTunProbe {
 [DllImport(@"$dll", EntryPoint="WintunCreateAdapter", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr Create(string name, string type, IntPtr guid);
 [DllImport(@"$dll", EntryPoint="WintunStartSession", SetLastError=true)] public static extern IntPtr Start(IntPtr adapter, uint capacity);
 [DllImport(@"$dll", EntryPoint="WintunEndSession")] public static extern void End(IntPtr session);
 [DllImport(@"$dll", EntryPoint="WintunCloseAdapter")] public static extern void Close(IntPtr adapter);
}
"@
            Add-Type -TypeDefinition $source
            $adapter = [HkuGuiTunProbe]::Create($config.vpn.adapterName,'OpenConnect',[IntPtr]::Zero)
            if ($adapter -eq [IntPtr]::Zero) { throw 'Wintun create failed.' }
            try {
                $session = [HkuGuiTunProbe]::Start($adapter,4194304)
                if ($session -eq [IntPtr]::Zero) { throw 'Wintun start failed.' }
                [HkuGuiTunProbe]::End($session)
            } finally { [HkuGuiTunProbe]::Close($adapter) }
            New-HKURoutingScript $config $root (Join-Path $root '.local\vpnc-route.js')
            $result = $true
        }
        'snapshot' { $result = Get-GuiSnapshot }
        'refresh' {
            $global:LASTEXITCODE = 0
            & (Join-Path $root 'DomainRoutes.ps1')
            $result = Get-GuiSnapshot
            $result['refreshFailed'] = $LASTEXITCODE -ne 0
        }
        'disconnect' {
            & (Join-Path $root 'Disconnect.ps1')
            $result = $true
        }
        'diagnose' {
            $config = $request.config
            Test-HKUConfig $config $root
            $checks = @()
            foreach ($item in @(@{name='KeePassXC CLI';path=(Resolve-HKUPath $config.keepass.cli $root)},@{name='数据库';path=(Resolve-HKUPath $config.keepass.database $root)},@{name='OpenConnect';path=(Join-Path (Resolve-HKUPath $config.runtimePath $root) 'openconnect.exe')},@{name='Wintun';path=(Join-Path (Resolve-HKUPath $config.runtimePath $root) 'wintun.dll')})) {
                $exists = Test-Path -LiteralPath $item.path -PathType Leaf
                $checks += @{name=$item.name;success=[bool]$exists;detail=$(if ($exists) {'文件存在'} else {'文件缺失，请完成 Setup'})}
            }
            if ($request.network) {
                if ($config.vpn.proxy) {
                    $proxy = [Uri]$config.vpn.proxy
                    $socket = if ($proxy.DnsSafeHost.Contains(':')) { New-Object Net.Sockets.TcpClient([Net.Sockets.AddressFamily]::InterNetworkV6) } else { New-Object Net.Sockets.TcpClient }
                    try { $task = $socket.ConnectAsync($proxy.DnsSafeHost,$proxy.Port); $ok = $task.Wait(5000) -and $socket.Connected }
                    catch { $ok = $false } finally { $socket.Dispose() }
                    $checks += @{name='代理端口';success=[bool]$ok;detail=$(if ($ok) {'TCP 可连接'} else {'TCP 无法连接'})}
                }
                foreach ($gateway in $config.vpn.gateways) {
                    try { $null = Resolve-DnsName ([Uri]$gateway).Host -DnsOnly -QuickTimeout -ErrorAction Stop; $ok = $true } catch { $ok = $false }
                    $checks += @{name='网关 DNS';success=[bool]$ok;detail=$(if ($ok) {'解析成功'} else {'解析失败'})}
                }
            }
            $result = @($checks)
        }
    }
    Write-GuiResult $result
} catch {
    # No raw exception/command output goes into IPC or diagnostic exports.
    $message = 'Windows operation failed; check configuration and privileges.'
    switch -Regex ($_.Exception.Message) {
        'SHA-256 mismatch' { $message = 'OpenConnect package hash mismatch; download again.'; break }
        'signature validation' { $message = 'OpenConnect package signature validation failed.'; break }
        'Another OpenConnect' { $message = 'Another OpenConnect process is running; disconnect it first.'; break }
        'Previous session' { $message = 'Previous VPN session exists; use disconnect/recovery first.'; break }
        'Adapter already exists' { $message = 'VPN adapter already exists; check its owner before connecting.'; break }
        'Cisco is connected' { $message = 'Disconnect Cisco VPN before connecting.'; break }
        'Missing runtime|missing|not found' { $message = 'Required runtime or dependency is missing; run Setup.'; break }
        'winget' { $message = 'Dependency installation failed; check winget or install manually.'; break }
        'Wintun' { $message = 'Wintun preflight failed; check driver and adapter state.'; break }
    }
    Write-GuiResult @{error=$message}
    exit 1
}
