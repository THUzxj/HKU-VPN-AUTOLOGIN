# HKU VPN Auto Login（Windows）

使用 OpenConnect 连接 HKU VPN，从 KeePassXC 加密数据库读取用户名、密码和 TOTP，并在微软 MFA 提示出现时自动提交验证码。通过指定 IPv4 地址或网段实现分流，普通 Internet 与系统 DNS 保持现有出口。

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
6. 保持连接窗口打开。断开时先按 `Ctrl+C` 退出 OpenConnect，再关闭代理。

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
| `routes` | 必填、非空的 IPv4/CIDR 列表，例如 `10.20.30.40/32` 或 `10.20.0.0/16` |

模板中的 `192.0.2.10/32` 是文档示例地址，不能当成实际校园服务器使用。请填写自己要访问的服务器真实 IPv4 地址；不要复制其他人的私人配置。IP 不写掩码时等同 `/32`，网段地址会规范化并去重。拒绝 `/0`、空列表和明显无效的地址，避免无意接管整个 Internet。

需要批量配置时，复制模板到自己的文件后运行：

```powershell
.\Setup.ps1 -ConfigFile .\my-config.json
```

setup 可重复运行，不覆盖数据库，也不会把旧的明文 `credentials.json` 迁移或复制进项目。手工修改 `.local/config.json` 后，Connect 会重新校验参数并生成路由脚本。重新运行交互式 setup 时，已有配置作为默认值。

## Clash 与分流

连接链路是：应用 → OpenConnect 隧道 → Clash 香港节点 → HKU VPN 网关 → 校园目标。Clash 提供 VPN 的底层传输，OpenConnect 只为 `routes` 中指定的目标安装 VPN 路由。

可选示例 `examples/clash-script.js` 会为默认的三个 HKU 网关添加 `HK APP` 香港节点组和域名规则。将它加入 Clash Verge 的脚本配置并在组内选定可用香港节点。自定义网关时同步调整对应的规则。

此项目**没有实现按 `.hk` 后缀进入 VPN**。普通网站和未列出的校园 IP 继续走已有系统/Clash 规则；不会安装 VPN 默认路由或替换系统 DNS。

Clash TUN 的 Fake-IP 可能把校园域名解析为 `198.18.x.x`，它与真实 IP 的 VPN 路由不同。SSH 可以使用真实 IP（必要时设置 `HostKeyAlias` 维持原来的主机密钥身份），并在 Clash 中为这个 IP 添加优先 `DIRECT` 规则，使 Windows 的 VPN 路由生效：

```yaml
rules:
  - IP-CIDR,10.20.30.40/32,DIRECT,no-resolve
  # 后面保留自己的规则
```

`DIRECT` 表示 Clash 不另用代理转发；实际出口由 Windows 路由决定。用真实目标地址替换例子。本脚本不会自动修改 SSH 或 Clash 配置，也不能保证校园网关允许访问所有公共网站。

## 故障排查

- **数据库/条目读不到**：确认完整路径、主密码、密钥文件；确认数据库已保存，条目名称与分组路径一致。详细 CLI 错误不直接打印，避免意外暴露条目内容。
- **用户名/密码为空**：填标准字段，不要只在备注或自定义属性中保存。当前 Windows CLI 密码输入支持可打印 ASCII；其他字符会在发送前报错。
- **自动 MFA 失败**：确认微软注册已经完成，电脑时间准确，条目生成六位验证码。脚本只自动提交一次；获取失败或再次询问时可手动输入，输入不回显。
- **TLS 提前失败**：先确认代理监听端口、节点和网关可用。默认 TLS 1.2 是 v9.12 的兼容设置，不是关闭证书校验；不会忽略服务器证书错误。
- **网卡已有/另一个 OpenConnect 在运行**：先退出之前的连接。程序不会擅自删除网卡或强制关闭其他 VPN。
- **SSH 连接到 `198.18.x.x`**：检查 Fake-IP 和 Clash 规则，确认命中真实 IP 的路由。
- **默认 Internet 是否被接管**：连接后用 `Get-NetRoute` / `Find-NetRoute -RemoteIPAddress <目标IP>` 检查。关闭窗口或强制杀进程可能留下路由，优先用 `Ctrl+C` 清理。
- **下载校验失败**：不执行或提取该文件。核对来源，重新下载；不要删除脚本里的签名/hash 校验来绕过问题。

默认关闭 DTLS 和 VPN IPv6，使用 TLS 经 HTTP 代理。这是已采用的兼容路径，不保证最佳吞吐量或跨境质量；TLS 1.2 兼容问题参考 [OpenConnect 更新记录](https://www.infradead.org/openconnect/changelog.html)。

## 测试与分享

测试不会连接 VPN，不读取真实账户。需要已安装 KeePassXC；模拟数据库、下载包和配置全部放在 `.local/`。

```powershell
.\tests\Test-Config.ps1
.\tests\Test-KeePass.ps1
.\tests\Test-MFA.ps1
```

`Test-KeePass` 使用公开 RFC 测试密钥创建临时数据库，验证用户名、密码、TOTP 和错误主密码拒绝；`Test-MFA` 模拟分段提示和验证码提交。

完整离线 setup 测试会用模拟配置覆盖 `.local/config.json`，只应在测试副本中执行，不要在已配置的日常项目上运行：

```powershell
.\tests\Test-Setup.ps1 -RuntimeArchive C:\path\to\openconnect-gui-1.6.2-win64.exe
```

`Setup.ps1` 的 `-RuntimeArchive` 可复用相同的官方安装包，仍校验签名和 hash；`-SkipInstall` 禁止 winget 安装；`-SkipCredentialCheck` 仅用于暂存参数/开发测试，会明确提示尚未验证凭据。日常使用不应跳过凭据检查。

发布/发给别人时运行 `Export-Source.ps1` 生成源码 ZIP。它按白名单只打包脚本、文档、模板、测试和上游路由源码，不包含 `.local/`、运行库、数据库或本机配置。不要直接压缩配置过的整个项目目录。项目未自动创建远程仓库或上传任何文件。

Git 默认忽略所有本机 JSON 配置，仅允许公开模板 `examples/config.example.json`，同时忽略数据库、密钥、环境文件、下载包、运行库和日志。不要使用 `git add -f` 强制提交这些文件。

当前验证覆盖本机 Windows 上的模拟登录、KeePassXC CLI、路由生成与离线 setup。首次下载/winget 安装需要接收者本机验证；新项目的真实 HKU VPN 登录也需要实测。

## 许可证

源码按 GPL-2.0 发布。上游 Windows 路由脚本保留原始版权说明，第三方来源见 `THIRD_PARTY_NOTICES.md`。项目源码包不包含第三方二进制。
