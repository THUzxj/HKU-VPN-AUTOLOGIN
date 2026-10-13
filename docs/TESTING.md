# 测试说明

在项目根目录的 PowerShell 中运行以下命令。测试不会连接 VPN，不读取真实账户。需要已安装 KeePassXC；模拟数据库、下载包和配置全部放在 `.local/`。

```powershell
.\tests\Test-Config.ps1
.\tests\Test-KeePass.ps1
.\tests\Test-MFA.ps1
.\tests\Test-Disconnect.ps1
# 只在尚未配置的测试副本中运行：
.\tests\Test-Domains.ps1
```

`Test-KeePass` 使用公开 RFC 测试密钥创建临时数据库，验证用户名、密码、TOTP 和错误主密码拒绝；`Test-MFA` 模拟分段提示和验证码提交。

完整离线 setup 测试会用模拟配置覆盖 `.local/config.json`，只应在测试副本中执行，不要在已配置的日常项目上运行：

```powershell
.\tests\Test-Setup.ps1 -RuntimeArchive C:\path\to\openconnect-gui-1.6.2-win64.exe
```

`Setup.ps1` 的 `-RuntimeArchive` 可复用相同的官方安装包，仍校验签名和 hash；`-SkipInstall` 禁止 winget 安装；`-SkipCredentialCheck` 仅用于暂存参数/开发测试，会明确提示尚未验证凭据。日常使用不应跳过凭据检查。

## 验证范围

当前验证覆盖本机 Windows 上的模拟登录、KeePassXC CLI、路由生成与离线 setup。首次下载/winget 安装需要在实际安装环境中验证；真实 HKU VPN 登录也需要实测。

日常安装与配置见 [README](../README.md)，功能操作见 [操作说明](OPERATIONS.md)。

## GUI 测试

安装 .NET 10 SDK 后，在项目根目录执行：

```powershell
dotnet run --project gui/HkuVpn.Tests/HkuVpn.Tests.csproj -c Release -- .
.\tests\Test-GuiBridge.ps1
```

覆盖配置保存/兼容、日志脱敏、模拟分段 MFA、手动 MFA、认证拒绝、取消、Windows 本机 IPC、演示连接生命周期、四页渲染以及模拟路由归属。不会访问真实账号或修改真实网络。测试截图和临时副本放在 `.local/`。真实 GUI 提权、校园连接和 macOS 支持不在离线测试证明范围内。
