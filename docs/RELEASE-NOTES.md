新配置默认包含 7 个 HKU IPv4 网段，以及 `hku.hk`、`hku.edu.hk`、`hku.org.hk`、`hku.global` 的 DNS 后缀分流。校园 DNS 默认使用 `147.8.235.73`、`147.8.235.74`；连接时创建 NRPT 规则，断开时清理，并为 VPN 网关保留默认 DNS 例外。IPv6 隧道仍禁用。

旧配置不会自动覆盖，请在配置页手动合并新默认项。源码用户需要先运行 `Build-Gui.ps1`，生成根目录 `HKU-VPN.exe`；更新 GUI 源码后需退出旧 GUI 并重新构建。详见 README 和 `docs/GUI.md`。

Windows x64 运行包提供 Setup、连接与路由、配置和诊断界面，支持 KeePassXC 凭据/TOTP 读取，以及固定 IPv4/CIDR、精确域名路由的增删改查。

下载 `hku-vpn-windows-x64.zip`，解压完整目录后双击 `HKU-VPN.exe`。自带 .NET 运行时；首次使用请在 Setup 页配置 VPN 依赖和 KeePassXC。保留目录结构，不能只复制启动 EXE。

`hku-vpn-autologin-source.zip` 面向开发者；`SHA256SUMS.txt` 用于核对附件 SHA-256。

运行包不包含账号、密码数据库、本机配置或日志。自动测试使用模拟认证/路由和演示模式，不执行真实 HKU 登录；实际 MFA、校园网络和新机器首次配置仍需验证。当前仅提供 Windows x64 后端，macOS 后端尚未实现。
