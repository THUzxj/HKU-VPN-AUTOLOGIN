# GitHub Actions 自动构建与发布

工作流位于 `.github/workflows/release.yml`，仓库根目录必须包含该文件、GUI 源码和打包脚本。先将本次修改提交并推送到 GitHub；本地创建文件不会自动启用远端工作流。

## 发布版本

在包含需要发布的完整源码的提交上创建并推送版本标签：

```powershell
git tag v0.1.0-beta.1
git push origin v0.1.0-beta.1
```

`v*` 标签触发 Windows x64 构建，先运行核心、IPC、无窗口 GUI、模拟路由与清理测试，再生成自包含运行包和源码包。运行包再次验证 EXE 启动、自带 .NET 及隐私边界。通过后生成 SHA-256 文件，并创建对应 GitHub Release、上传附件。标签包含 `-` 时标记为预发布，例如 `v0.1.0-beta.1`；`v0.1.0` 为正式发布。

三个附件是 `hku-vpn-windows-x64.zip`、`hku-vpn-autologin-source.zip` 和 `SHA256SUMS.txt`。普通用户下载运行包。发布说明来自 `docs/RELEASE-NOTES.md`，发布新版本前更新此文件。

首次创建 Release 时先创建草稿并附上产物，再公开发布。若同名 Release 已存在，重跑会替换同名附件，保留既有发布说明及草稿/预发布状态；已启用不可变 Release 的仓库无法覆盖已发布附件，应使用新版本标签。不要移动已经发布的标签。

## 只构建、不发布

打开仓库 Actions → Windows release → Run workflow，选择分支执行。手动运行只生成 Actions 的 `windows-release-assets` 下载产物，不创建或修改 Release。产物保留 14 天。

工作流使用 GitHub 自带 `GITHUB_TOKEN`，无需配置个人访问令牌或 VPN/KeePass 凭据。构建任务仅需读取仓库，发布任务声明 `contents: write`；仓库或组织策略必须允许 GitHub Actions 及该写权限。构建需要访问 NuGet 和固定版本 Avalonia 许可文件，不依赖本机 Clash 代理。

GitHub Actions 的真实运行仍需推送工作流后验证。离线和演示测试通过不代表真实 VPN 登录、校园 DNS 或新机器 Setup 已验证。
