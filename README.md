# HKU VPN Auto Login（Windows）

使用 OpenConnect 连接 HKU VPN，从 KeePassXC 加密数据库读取用户名、密码和 TOTP，并在微软 MFA 提示出现时自动提交验证码。通过指定 IPv4 地址、网段或完整域名解析出的 IP 实现分流，普通 Internet 与系统 DNS 保持现有出口。

日常操作、双击断开、路由清理范围与故障处理见 [操作说明](docs/OPERATIONS.md)。

每次运行仍需确认 Windows 管理员提权，并输入一次 KeePassXC 数据库主密码。主密码、VPN 密码、TOTP 密钥和验证码不会写入项目配置，也不会放入进程命令行。用户名会作为 OpenConnect 的 `--user` 参数传入。

这是独立客户端脚本，不是 HKU ITS 官方软件。当前版本针对 HKU 的 XML 登录表单与 `Enter Your Microsoft verification code` / `Response:` 提示，不是通用 Cisco VPN 自动登录工具。

## 环境与自动安装

- Windows 10/11 x64；不支持 ARM64 或 32 位系统。
- 需要可用的 `winget`（Windows 的 App Installer 提供），首次安装软件可能出现 UAC 提示。
- setup 自动检查并安装缺少的 PowerShell 7、KeePassXC 和 7-Zip；已安装的软件不主动升级。
- setup 下载固定版本 OpenConnect GUI 1.6.2 安装包，校验固定 SHA-256 与 Authenticode 发布者签名，再用 7-Zip 提取 CLI v9.12、Wintun 和 DLL 到 `.local/runtime/`。不安装或启动 OpenConnect GUI。
- 已配置 Clash/其他 HTTP 代理时，连接前先启动它。脚本不安装代理客户端，也不提供香港节点。

官方手动安装入口：[PowerShell](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-windows)、[KeePassXC](https://keepassxc.org/download/)、[7-Zip](https://www.7-zip.org/)、[OpenConnect](https://gui.openconnect-vpn.net/download/)。没有 winget 时，先安装前三项，再运行 setup。

## 快速开始

1. 下载项目并解压到自己的文件夹。
2. 双击 `Setup.cmd`。脚本先准备依赖，再打开 KeePassXC，等待你创建数据库、完成下面的账户配置并填写参数。
3. 输入 `.kdbx` 路径、条目路径、代理地址和要进入 VPN 的目标 IPv4/CIDR。setup 会在本机提示输入数据库主密码，验证条目可读，再生成 `.local/config.json` 和路由脚本。setup 不尝试登录 VPN，也不添加系统路由。
4. 先启动 Clash（如果使用代理），断开已有的 Cisco VPN，再双击 `Connect.cmd`。
5. 确认管理员提权，在启动窗口输入数据库主密码。TLS 检查成功后，用户名、VPN 密码和 MFA 会自动输入。
6. 保持连接窗口打开。断开时按 `Ctrl+C`，或双击 `Disconnect.cmd`，完成后再关闭代理。

如果第一步下载需要代理，可在 PowerShell 中运行：

```powershell
.\Setup.ps1 -DownloadProxy http://127.0.0.1:7890
```

批处理启动器优先选择已安装的 PowerShell 7，找不到时使用 Windows PowerShell 5.1。提权后的连接窗口使用同一个 PowerShell 可执行文件。

## 配置微软 TOTP

1. 使用 HKU 账号登录 [微软安全信息](https://mysignins.microsoft.com/security-info)。
2. 选择“添加登录方式”→“Microsoft Authenticator”→“我想使用其他身份验证器应用”。是否开放此选项由学校策略决定。
3. 到二维码页面后，选择“无法扫描图像/二维码”，查看手动设置用的密钥。这里需要的是长期密钥，不是手机当前的六位验证码。
4. 将密钥按下一节写入 KeePassXC；用它生成的验证码回到微软页面完成注册。
5. 保留原有手机验证方式，先确认这个新增验证器能够用于 HKU VPN。

本工具支持六位标准 TOTP。手机推送确认、数字匹配、短信和语音验证码不能通过这套 TOTP 流程自动处理。不要上传二维码、密钥、数据库或主密码来诊断问题。

## 配置 KeePassXC

1. 打开 KeePassXC，创建或打开数据库，设置自己的数据库主密码并保存 `.kdbx` 文件。
2. 新建条目，例如 `HKU MFA`。在标准“用户名”字段填写 HKU 邮箱，在标准“密码”字段填写 Portal PIN/密码，不要填数据库主密码。
3. 保存条目，右键条目 → **TOTP → 设置 TOTP**，将微软页面的长期密钥填入“密钥”。一般使用 6 位、30 秒、SHA-1；注册页面指定其他参数时以页面为准。
4. 右键条目 → **TOTP → 显示/复制 TOTP**，将验证码填回微软页面完成验证。保存数据库。
5. setup 中填写 `.kdbx` 的完整路径和条目的完整路径。条目在数据库根目录时填 `HKU MFA`；位于 `HKU` 分组时填 `HKU/HKU MFA`。

用户名/密码与 TOTP 可以放在同一条目；也可以分开放，在 `credentialsEntry` 中指定凭据条目，在 `entry` 中指定 TOTP 条目。数据库使用密钥文件时，填写 `keyFile` 的完整路径；只用主密码时留空。

CLI 会独立解锁数据库，不能直接复用 KeePassXC 界面中的解锁状态。每次连接只输入一次数据库主密码，脚本随后通过标准输入交给 CLI。当前脚本不支持 YubiKey 数据库解锁或无主密码数据库。将主密码、VPN 密码和 TOTP 放在同一台 PC 会集中账户风险，请保留恢复方式并保护数据库。

参考：[KeePassXC 入门指南](https://keepassxc.org/docs/KeePassXC_GettingStarted)、[CLI 说明](https://github.com/keepassxreboot/keepassxc/blob/develop/docs/man/keepassxc-cli.1.adoc)、[微软 OATH 支持](https://learn.microsoft.com/entra/identity/authentication/concept-authentication-oath-tokens)。

## 必要参数

setup 生成的配置位于 `.local/config.json`，仓库模板在 `examples/config.example.json`。

| 参数 | 含义 |
|---|---|
| `keepass.cli` | `keepassxc-cli.exe` 的完整路径，setup 自动检测 |
| `keepass.database` | `.kdbx` 完整路径 |
| `keepass.entry` | TOTP 条目完整路径 |
| `keepass.credentialsEntry` | 用户名/密码条目路径；未填写时使用 `entry` |
| `keepass.keyFile` | 数据库密钥文件路径，可留空 |
| `keepass.enabled` | `true` 自动提交 TOTP；`false` 手动输入 MFA，用户名/密码仍自动读取 |
| `vpn.gateways` | HTTPS 网关列表，默认先 B 后 A；每个最多做两次无凭据握手检查 |
| `vpn.proxy` | HTTP 代理 URL，默认 `http://127.0.0.1:7890`；空字符串为直连 |
| `vpn.adapterName` | 专用 Wintun 网卡名，默认 `HKU-OpenConnect` |
| `vpn.mtu` | 请求的 MTU，默认 1200；服务器可能覆盖 |
| `vpn.tls12` | 默认 `true`，限制 TLS 1.2，适用于固定的 v9.12 GnuTLS 构建 |
| `vpn.userAgent` | 默认使用兼容 HKU XML 表单的 AnyConnect Windows 标识 |
| `runtimePath` | OpenConnect 和 DLL 目录，默认项目内 `.local/runtime` |
| `routes` | 固定 IPv4/CIDR 列表，例如 `10.20.30.40/32` 或 `10.20.0.0/16`；与 `domains` 至少填写一项 |
| `domains` | 精确域名列表，经 VPN DNS 解析后添加 IPv4 路由，可省略 |
| `dnsServers` | 用于域名查询的校园 IPv4 DNS；空列表使用 VPN 下发值 |

模板中的 `192.0.2.10/32` 是文档示例地址，不能当成实际校园服务器使用。请填写自己要访问的服务器真实 IPv4 地址或完整域名；不要复制其他人的私人配置。IP 不写掩码时等同 `/32`，网段地址会规范化并去重。拒绝 `/0`、无任何目标的配置和明显无效的地址，避免无意接管整个 Internet。

需要批量配置时，复制模板到自己的文件后运行：

```powershell
.\Setup.ps1 -ConfigFile .\my-config.json
```

setup 可重复运行，不覆盖数据库，也不会把旧的明文 `credentials.json` 迁移或复制进项目。手工修改 `.local/config.json` 后，Connect 会重新校验参数并生成路由脚本。重新运行交互式 setup 时，已有配置作为默认值。

## Clash 与分流

使用 Clash 代理时，目标连接链路是：应用 → OpenConnect 隧道 → Clash 香港节点 → HKU VPN 网关 → 校园目标。Clash 提供 VPN 的底层传输，OpenConnect 为 `routes` 中指定的目标及 `domains` 解析出的 IP 安装 VPN 路由；域名查询需要的校园 DNS 也会有专用路由。

可选示例 `examples/clash-script.js` 会为默认的三个 HKU 网关添加 `HK APP` 香港节点组和域名规则。将它加入 Clash Verge 的脚本配置并在组内选定可用香港节点。自定义网关时同步调整对应的规则。

此项目支持指定完整域名解析成 IPv4 路由，但**没有实现按 `.hk` 后缀匹配所有网站**。普通网站和未列出的校园 IP 继续走已有系统/Clash 规则；不会安装 VPN 默认路由或替换系统 DNS。

## 域名动态路由

可以同时配置固定 IP 路由和完整域名，例如在 `.local/config.json` 添加：

```json
"routes": [],
"domains": ["server.example.hk"],
"dnsServers": []
```

`domains` 是精确域名列表，不接受 URL、通配符或 `.hk` 后缀规则。`dnsServers` 留空时使用 VPN 下发的 IPv4 DNS；也可指定校园 DNS 的 IPv4 地址。至少需要一个固定路由或域名。旧配置不添加新字段仍可使用。

基础隧道就绪后，后台脚本为校园 DNS 添加 VPN `/32` 路由，再显式向它查询每个域名的 A 记录，把全部返回 IP 加入 VPN。本次生成的路由只保存到 ActiveStore，正常断开时清理；全局 DNS 不改变。DNS 的临时路由保留到断开，供后续刷新使用。

查看 `.local/domain-status.txt` 判断解析是否成功；`.local/domain-session.json` 记录本次接口、解析结果和脚本创建的路由，不记录认证数据。VPN 连上并不代表所有域名均解析成功，HKU DNS 的可达性仍需本机实测。

连接期间新增域名，在**管理员 PowerShell**中运行：

```powershell
.\Add-Domain.ps1 -Name server.example.hk
# 同时新增多个
.\Add-Domain.ps1 -Name server.example.hk,another.example.hk
# 只保存配置，等下次连接再应用
.\Add-Domain.ps1 -Name server.example.hk -NoRefresh
```

重新解析所有配置域名：` .\DomainRoutes.ps1 `。脚本在所有解析成功后清理已失效的旧路由；查询失败时保留原有路由并报告失败。当前没有自动 TTL 定时刷新，IP 变化后应手动刷新或重连。不支持 AAAA/IPv6 路由。

正常断开会移除本次脚本创建的 DNS/目标路由。也可双击 `Disconnect.cmd`，接受 Windows 管理员权限提示：它只结束程序路径、路由脚本路径、网卡参数都匹配当前项目的 OpenConnect 进程，再清理本次会话的 DNS/域名路由及固定 VPN 路由。Clash、Cisco、其他项目的 VPN 和登录窗口不会被结束。此脚本强制停止本地隧道；需要正常向网关注销时优先使用连接窗口的 `Ctrl+C`。

重复双击断开脚本可用于重试清理。脚本验证接口名、地址、索引，并核对路由前缀、下一跳和 metric；未找到可验证的会话记录时，不会猜测并删除网卡路由。强制结束进程后也可在管理员窗口运行 ` .\DomainRoutes.ps1 -Cleanup `，仅清理记录的 DNS/域名路由。清理不能恢复被其他工具独立修改的网络状态。

**应用的 DNS 也必须配合**：仅让本脚本查询校园 DNS，不会改变浏览器/SSH 的解析结果。Clash 用户需让目标域名避开 Fake-IP、使用同一校园 DNS，并用精确域名 `DIRECT` 规则将目标交给系统路由；校园 DNS 本身也应避开代理转发。浏览器自带 DoH 同样可能返回不同地址。需要按自己的 Clash DNS 设置调整，脚本不自动写入 Clash、hosts 或全局 DNS。若不配置域名解析，可直接使用脚本解析出的真实 IP。

共享 IP 上的其他网站也可能经过 VPN。这是 IP 路由的行为，不是严格的按域名隔离。VPN 网关自身不能加入域名目标列表，以免形成连接循环。

Clash TUN 的 Fake-IP 可能把校园域名解析为 `198.18.x.x`，它与真实 IP 的 VPN 路由不同。SSH 可以使用真实 IP（必要时设置 `HostKeyAlias` 维持原来的主机密钥身份），并在 Clash 中为这个 IP 添加优先 `DIRECT` 规则，使 Windows 的 VPN 路由生效：

```yaml
rules:
  - IP-CIDR,10.20.30.40/32,DIRECT,no-resolve
  # 后面保留自己的规则
```

`DIRECT` 表示 Clash 不另用代理转发；实际出口由 Windows 路由决定。用真实目标地址替换例子。本脚本不会自动修改 SSH 或 Clash 配置，也不能保证校园网关允许访问所有公共网站。

## 更多文档

- [故障排查](docs/TROUBLESHOOTING.md)
- [测试说明](docs/TESTING.md)
- [连接、域名路由与断开操作](docs/OPERATIONS.md)

## 许可证

源码按 GPL-2.0 发布。上游 Windows 路由脚本保留原始版权说明，第三方来源见 `THIRD_PARTY_NOTICES.md`。项目源码包不包含第三方二进制。
