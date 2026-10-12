# 连接、域名路由与断开操作

本文适用于当前项目的 `Connect.cmd`、`Add-Domain.ps1`、`DomainRoutes.ps1` 和 `Disconnect.cmd`。首次安装和 KeePassXC 配置见 [README](../README.md)。请在同一个项目目录中连接、修改域名和断开；不要用另一份项目的断开脚本处理当前连接。

## 日常连接

1. 如果 `.local/config.json` 的 `vpn.proxy` 配置了代理，先启动代理并确认其端口可用；直连配置可跳过。
2. 断开之前的 Cisco/OpenConnect VPN，再双击 `Connect.cmd`。
3. 接受管理员权限提示，在连接窗口输入 KeePassXC 数据库主密码。
4. 等待 OpenConnect 完成登录和隧道配置，保持连接窗口打开。
5. 配置了 `domains` 时，再查看 `.local/domain-status.txt`，确认域名解析和路由添加成功。

连接脚本的用户名、密码和 TOTP 来自 KeePassXC；断开脚本不需要数据库主密码，也不会再次登录 VPN。

域名解析在隧道就绪后由后台脚本执行。因此，看到 VPN 已连接，只能确认隧道状态，不能据此判断域名路由已经成功。

## 配置域名路由

`.local/config.json` 可以同时保留固定 IPv4/CIDR 和完整域名。以下只是相关字段片段，不是完整配置文件：

```json
"routes": ["192.0.2.10/32"],
"domains": ["server.example.hk"],
"dnsServers": []
```

请将示例地址和域名换成自己的目标。`dnsServers` 为空时，脚本使用 VPN 下发的 IPv4 DNS；指定值时，应填写可通过校园 VPN 访问的真实 DNS 地址。

脚本先为 DNS 地址添加 VPN 主机路由，再向该 DNS 查询域名的 A 记录，随后把所有返回的 IPv4 地址加入 VPN 路由。DNS 路由在本次连接期间保留，以便后续刷新；系统默认路由和全局 DNS 配置不改变。

在项目目录打开管理员 PowerShell，新增一个或多个域名：

```powershell
.\Add-Domain.ps1 -Name server.example.hk
.\Add-Domain.ps1 -Name server.example.hk,another.example.hk
```

存在有效连接会话时立即解析并更新；没有会话时仅保存配置，下次连接时应用。只保存、不立即更新：

```powershell
.\Add-Domain.ps1 -Name server.example.hk -NoRefresh
```

重新解析配置中的全部域名：

```powershell
.\DomainRoutes.ps1
```

删除域名时，手动从 `.local/config.json` 的 `domains` 列表移除，再运行刷新命令；固定 `routes` 的修改在下次连接时应用。所有查询成功后才清理不再需要的动态路由，查询失败时保留已有路由。

目前支持精确域名和 IPv4，不支持 `*.hk`、按 `.hk` 后缀匹配、AAAA/IPv6 或自动 TTL 定时刷新。IP 改变后应手动刷新或重连。一个 IP 上其他网站的流量也可能命中相同的 VPN 路由。

### Clash 或浏览器 DNS 的配合

本脚本获得的真实 IP 必须与应用实际访问的 IP 一致。Clash Fake-IP、其他 DNS 或浏览器 DoH 可能让应用获得不同地址。

使用 Clash 时，需要按自己的配置让目标域名返回真实 IP、使用一致的校园 DNS，并通过目标的 `DIRECT` 规则交给 Windows 路由；校园 DNS 查询本身也应避免被代理转发。具体说明见 [README 的域名动态路由部分](../README.md#域名动态路由)。脚本不会自动修改 Clash、浏览器 DNS 或 hosts。

## 断开连接

| 操作 | 行为 | 适用场景 |
|---|---|---|
| 连接窗口按 `Ctrl+C` | 请求 OpenConnect 正常退出，由其执行断开钩子 | 日常断开，优先使用 |
| 双击 `Disconnect.cmd` | 结束匹配当前项目的 OpenConnect，并执行本地路由清理 | 希望双击断开，或连接窗口无法正常操作 |
| `DomainRoutes.ps1 -Cleanup` | 仅清理记录的 DNS/域名路由，不停止 VPN 进程、不清理固定路由 | 已确认 VPN 停止后的专项清理 |

### 双击断开

1. 双击与当前连接同目录的 `Disconnect.cmd`。
2. 接受 Windows 管理员权限提示；拒绝提权将无法执行清理。
3. 等待断开脚本完成，查看是否有错误或警告。
4. 完成后再关闭代理。原来的连接窗口可能仍然打开，可查看退出信息后手动关闭。

在已有管理员 PowerShell 中，也可以运行：

```powershell
.\Disconnect.ps1
```

此方式强制停止本地 OpenConnect 进程，不能保证向远端网关完成正常注销。如果需要正常退出流程，使用连接窗口的 `Ctrl+C`。

### 进程与路由的清理范围

脚本只匹配同时满足以下条件的 OpenConnect 进程：可执行文件路径与当前配置的运行库一致、命令行指定当前项目的 `.local/vpnc-route.js`、网卡名与当前配置一致。停止前再次核对进程创建时间、程序路径和命令行，防止 PID 被其他进程重用。

路由清理依赖 `.local/domain-session.json` 中的会话信息。固定路由使用连接时记录的前缀；旧会话没有此前缀记录时使用当前配置。脚本核对网卡名、接口索引和 VPN 内部 IPv4 地址，并按前缀、下一跳及 metric 匹配待删除路由。DNS/域名路由只删除会话记录中由脚本创建的条目。

如果 Wintun 网卡随进程退出而消失，脚本会跳过该网卡的显式路由删除；如果接口无法验证，也不会猜测路由归属。脚本不会删除网卡、重置系统网络、恢复其他工具修改的 DNS，也不会结束 Clash、Cisco 或其他项目的 VPN 进程。

断开脚本不会删除 `.local/config.json`、域名配置、KeePassXC 数据库或运行库。完成清理后，本次域名会话记录和取消标记会移除，状态文件保留。

## 查看状态与排查

| 文件/信息 | 用途 |
|---|---|
| 连接窗口输出 | TLS、认证、隧道建立和 OpenConnect 退出信息 |
| `.local/domain-status.txt` | 最近一次域名解析、刷新或清理结果 |
| `.local/domain-session.json` | 本次接口、固定路由前缀、DNS、解析结果和动态路由记录 |
| `.local/domain-cancel.flag` | 断开请求标记，后台解析会在检查点停止；不是连接状态证明 |
| `.local/domain-routes.lock` | 串行化刷新和清理；文件存在本身不代表操作仍在运行 |

这些文件不保存认证密码或 TOTP，但会话和配置可能包含私人域名、地址和本机路径，不应作为公开诊断资料上传。

### 断开提示路由忙或清理失败

正在执行的 DNS 查询可能需要先结束。等待当前查询返回后再次双击 `Disconnect.cmd`；如果进程已经停止，再次执行仍可用于清理遗留会话。不要靠手动删除会话记录或锁文件绕过失败，否则可能丢失路由归属信息。

### 提示没有匹配会话记录

脚本会保留无法验证的网卡路由。检查是否从同一项目连接和断开，以及连接期间是否修改了 `runtimePath` 或 `vpn.adapterName`。这些参数会影响进程匹配，建议断开后再修改。出现成功文字同时伴随此警告时，不能据此认定所有遗留路由均已删除。

### 提示 VPN 仍在运行或进程身份改变

脚本中止后续清理，避免破坏仍在使用的隧道。检查连接窗口，尝试 `Ctrl+C`，或再次运行断开脚本。不要用批量结束所有 `openconnect.exe` 的命令代替项目进程筛选。

### 配置文件缺失或无效

断开脚本需要当前项目的有效配置来确认进程归属。保留原配置，修正报错字段后重试；仍可在原连接窗口使用 `Ctrl+C`。不要在 VPN 运行期间移动整个项目或删除 `.local/`。

### 只清理 DNS/域名路由

先确认 VPN 已停止，再在管理员 PowerShell 中执行：

```powershell
.\DomainRoutes.ps1 -Cleanup
```

这个命令不会停止 OpenConnect。如果隧道仍在运行，目标访问可能因路由被移除而中断。

### 检查实际路由

以下命令只读取当前状态，使用自己目标的真实 IP 替换示例：

```powershell
Get-NetAdapter -Name HKU-OpenConnect -ErrorAction SilentlyContinue
Find-NetRoute -RemoteIPAddress 192.0.2.10
Get-Content .\.local\domain-status.txt
```

自定义网卡名时替换第一条命令中的名称。断开后网卡可能已经不存在；目标可能回到原有出口，也可能因只允许校园网访问而无法连接。单独看到状态文件中的成功文字不能证明实时网络通畅。

## 验证范围

`tests/Test-Disconnect.ps1` 使用模拟对象验证项目进程筛选、PID 重用拒绝、重复停止和路由归属检查，不会停止真实进程或修改真实路由。`tests/Test-Domains.ps1` 验证 DNS 路由建立、多 IP 添加、刷新、失败保留、冲突保护和清理，只应在尚未配置的测试副本运行。

上述检查已在 Windows PowerShell 5.1 和 PowerShell 7 环境中执行；它们不证明真实 HKU DNS 可达、管理员提示体验或强制断开后的实际网络恢复，这些仍需在自己的连接中验证。
