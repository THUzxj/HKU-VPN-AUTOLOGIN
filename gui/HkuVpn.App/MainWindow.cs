using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using Avalonia.VisualTree;
using HkuVpn.Core;
using HkuVpn.Platform.Windows;

namespace HkuVpn.App;

public sealed class MainWindow : Window
{
    private readonly string root;
    private readonly bool demo;
    private readonly IVpnBackend backend;
    private readonly string configPath;
    private VpnConfig config;
    private readonly TabControl tabs = new();
    private readonly TextBlock stateLabel = new() { Text = "就绪", FontSize = 16, FontWeight = FontWeight.SemiBold };
    private readonly TextBlock notice = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock domainStatus = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock dependencyStatus = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock elapsed = new();
    private readonly TextBox logs = new() { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 200, MaxHeight = 350 };
    private readonly TextBox cli = Field(), database = Field(), entry = Field(), credentialsEntry = Field(), keyFile = Field(), gateways = Field(true), proxy = Field(), adapter = Field(), mtu = Field(), runtime = Field(), agent = Field(), fixedRoutes = Field(true), domains = Field(true), dns = Field(true), archive = Field();
    private readonly TextBox routeInput = new() { Name = "RouteTargetInput", MinWidth = 250, Watermark = "IPv4/CIDR 或完整域名" };
    private readonly TextBox routeSearch = new() { Name = "RouteSearchInput", MinWidth = 300, Watermark = "搜索目标、IP、来源或状态" };
    private readonly ComboBox routeKind = new() { Name = "RouteKindInput", ItemsSource = new[] { "IPv4 / CIDR", "域名" }, SelectedIndex = 0, MinWidth = 130 };
    private readonly TextBlock editingLabel = new() { Text = "添加新路由", TextWrapping = TextWrapping.Wrap };
    private readonly List<RouteRow> allRouteRows = [];
    private RouteRow? editingRoute;
    private Button? saveRoute;
    private bool CanManageRoutes => !busy && !disconnecting && (!active || tunnelConnected);
    private readonly CheckBox automaticMfa = new() { Content = "自动提交 KeePassXC TOTP" }, tls12 = new() { Content = "TLS 1.2 兼容模式" };
    private readonly ObservableCollection<RouteRow> routeRows = [];
    private readonly ObservableCollection<DiagnosticRow> diagnosticRows = [];
    private readonly List<string> logBuffer = [];
    private readonly Button connect = new() { Content = "连接 VPN" }, disconnect = new() { Content = "断开 / 恢复清理" };
    private readonly List<Control> edits = [];
    private readonly DispatcherTimer clock = new() { Interval = TimeSpan.FromSeconds(1) };
    private FileSystemWatcher? watcher;
    private CancellationTokenSource? debounce;
    private int runningOperations;
    private bool busy => runningOperations > 0;
    private bool active, tunnelConnected, exitRequested, closeApproved, disconnecting;
    private DateTimeOffset? connectedAt;
    private TrayIcon? tray;
    private Task? connectionTask;
    private Window? secretDialog;

    public MainWindow(string root, bool demo, IVpnBackend? suppliedBackend = null)
    {
        this.root = root; this.demo = demo; configPath = Path.Combine(root, ".local", "config.json");
        backend = suppliedBackend ?? (demo ? new DemoBackend() : new WindowsBackend(root));
        Title = "HKU VPN" + (demo ? " · 演示模式" : ""); Width = 1100; Height = 820; MinWidth = 820; MinHeight = 640;
        Background = Brush.Parse("#F3F6FA");
        config = demo ? DemoConfig() : LoadConfig();
        var heading = new StackPanel { Spacing = 5, Children = { new TextBlock { Text = "HKU VPN", FontSize = 28, FontWeight = FontWeight.Bold },
            new TextBlock { Text = demo ? "演示模式 · 不读取私人配置、不连接网络、不修改路由" : "OpenConnect · KeePassXC · 按目标分流", Foreground = Brush.Parse("#52647A") } } };
        var header = new DockPanel(); DockPanel.SetDock(stateLabel, Dock.Right); header.Children.Add(stateLabel); header.Children.Add(heading);
        tabs.Items.Add(new TabItem { Header = "Setup", Content = SetupPage() });
        tabs.Items.Add(new TabItem { Header = "连接与路由", Content = ConnectionPage() });
        tabs.Items.Add(new TabItem { Header = "配置", Content = ConfigPage() });
        tabs.Items.Add(new TabItem { Header = "诊断", Content = DiagnosticsPage() });
        var outer = new Grid { RowDefinitions = new RowDefinitions("Auto,*,Auto"), Margin = new Thickness(24), RowSpacing = 18 };
        outer.Children.Add(header); Grid.SetRow(tabs, 1); outer.Children.Add(tabs); Grid.SetRow(notice, 2); outer.Children.Add(notice); Content = outer;
        Populate(config); tabs.SelectedIndex = !demo && !File.Exists(configPath) ? 0 : 1;
        backend.RequestSecret = RequestSecretAsync;
        backend.Event += e => Dispatcher.UIThread.Post(() => HandleEvent(e));
        clock.Tick += (_, _) => { if (IsVisible && connectedAt != null) elapsed.Text = "已连接 " + (DateTimeOffset.Now - connectedAt.Value).ToString(@"hh\:mm\:ss"); };
        Closing += OnClosing;
        Opened += async (_, _) => { SetupTray(); CheckDependencies(); if (File.Exists(configPath) && !demo) StartWatcher(); else ShowConfiguredRoutes(); await Task.CompletedTask; };
        UpdateButtons();
    }
    private static VpnConfig DemoConfig() => new() { Keepass = new() { Cli = "keepassxc-cli", Database = "example.kdbx" }, Routes = ["192.0.2.10/32"], Domains = ["server.example.hk"] };
    private VpnConfig LoadConfig()
    {
        try { if (File.Exists(configPath)) { var value = VpnConfig.Load(configPath); value.Validate(); return value; } } catch { notice.Text = "已有配置无法读取或无效，请在配置页检查；未覆盖文件。"; }
        var defaults = new VpnConfig();
        if (OperatingSystem.IsWindows()) defaults.Keepass.Cli = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "KeePassXC", "keepassxc-cli.exe");
        return defaults;
    }
    private static TextBox Field(bool multi = false) => new() { AcceptsReturn = multi, MinHeight = multi ? 65 : 34, TextWrapping = TextWrapping.Wrap, HorizontalAlignment = HorizontalAlignment.Stretch };
    private static StackPanel Stack(params Control[] controls) => new StackPanel { Spacing = 12 }.With(controls);
    private static TextBlock Text(string value) => new() { Text = value, TextWrapping = TextWrapping.Wrap };
    private static Control Page(Control content) => new ScrollViewer { Content = new Border { Padding = new Thickness(18), Background = Brushes.White, CornerRadius = new CornerRadius(8), Child = content } };
    private Button ActionButton(string label, Func<Task> action)
    {
        var button = new Button { Content = label }; button.Click += async (_, _) => await ExecuteAsync(action); return button;
    }
    private static WrapPanel Actions(params Control[] controls) { var panel = new WrapPanel { Orientation = Orientation.Horizontal }; foreach (var c in controls) { c.Margin = new Thickness(0, 0, 10, 8); panel.Children.Add(c); } return panel; }
    private Control SetupPage() => Page(Stack(
        Text("首次配置：检查依赖 → 安装缺失软件 → 配置数据库与目标 → 本地验证 → 保存。"),
        Actions(ActionButton("检查依赖", () => { CheckDependencies(); return Task.CompletedTask; }), ActionButton("安装 / 修复依赖", InstallAsync)), dependencyStatus,
        Text("可选：已下载的 OpenConnect 1.6.2 安装包；仍校验签名和 hash。"), Actions(archive, ActionButton("选择安装包", () => PickAsync(archive))),
        Text("在 KeePassXC 标准字段填写用户名、Portal 密码，并配置六位 TOTP。微软注册请在浏览器完成。"),
        Actions(ActionButton("打开 KeePassXC", OpenKeepassAsync), ActionButton("填写配置与路由", () => { tabs.SelectedIndex = 2; return Task.CompletedTask; })),
        Actions(ActionButton("本地验证条目并保存", VerifyAndSaveAsync)),
        Text("验证只读取本机数据库，不登录 VPN。密码与验证码不写入配置。")));
    private Control ConnectionPage()
    {
        connect.Click += async (_, _) => await BeginConnectAsync();
        disconnect.Click += async (_, _) => await ExecuteAsync(DisconnectAsync, allowDuringConnection: true);
        var list = new ItemsControl { ItemsSource = routeRows, ItemTemplate = new FuncDataTemplate<RouteRow>((row, _) =>
        {
            var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("75,2*,2*,110,2*,130"), Margin = new Thickness(0, 8) };
            var values = new[] { row!.Source, row.Target, row.Prefix, row.Status, row.Detail };
            for (var i = 0; i < values.Length; i++) { var cell = Text(values[i]); cell.Margin = new Thickness(5, 0); Grid.SetColumn(cell, i); grid.Children.Add(cell); }
            var actions = row.Source is "固定" or "域名"
                ? Actions(RouteAction("编辑", () => { EditRoute(row); return Task.CompletedTask; }), RouteAction("删除", () => DeleteRouteAsync(row)))
                : (Control)Text(row.Source == "VPN DNS" ? "自动维护" : "刷新以同步");
            Grid.SetColumn(actions, 5); grid.Children.Add(actions);
            return grid;
        }) };
        var header = new Grid { ColumnDefinitions = new ColumnDefinitions("75,2*,2*,110,2*,130") };
        var names = new[] { "来源", "目标", "真实 IP / 前缀", "路由状态", "详情", "操作" };
        for (var i = 0; i < names.Length; i++) { var label = Text(names[i]); label.FontWeight = FontWeight.SemiBold; Grid.SetColumn(label, i); header.Children.Add(label); }
        saveRoute = RouteAction("保存修改", SaveRouteEditAsync); saveRoute.Name = "SaveRouteEdit";
        var add = RouteAction("添加路由", AddRouteAsync); add.Name = "AddRoute";
        routeSearch.TextChanged += (_, _) => FilterRoutes();
        return Page(Stack(Actions(connect, disconnect, elapsed), Text("隧道状态与路由状态分别核对；不会接管默认路由或全局 DNS。"),
            Actions(ActionButton("检查当前路由", SnapshotAsync), ActionButton("刷新 / 应用全部路由", RefreshAsync)),
            editingLabel, Actions(routeKind, routeInput, add, saveRoute, RouteAction("取消编辑", () => { CancelRouteEdit(); return Task.CompletedTask; })),
            Text("IP 可输入单个 IPv4 或 CIDR；域名输入完整名称。已连接时立即同步，未连接时保存到下次连接。"),
            Actions(routeSearch, ActionButton("清除搜索", () => { routeSearch.Text = ""; return Task.CompletedTask; })), header, list, domainStatus,
            Text("域名目标需要应用 DNS 与真实 IP 一致；Clash Fake-IP / 浏览器 DoH 可能导致地址不匹配。")));
    }
    private Control ConfigPage()
    {
        var form = new Grid { ColumnDefinitions = new ColumnDefinitions("180,*"), RowSpacing = 10, ColumnSpacing = 10 };
        void Add(string label, Control field, bool picker = false)
        {
            var row = form.RowDefinitions.Count; form.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
            var caption = Text(label); caption.VerticalAlignment = VerticalAlignment.Center; Grid.SetRow(caption, row); form.Children.Add(caption);
            Control editor = field;
            if (picker && field is TextBox box) { var panel = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 8 }; panel.Children.Add(box); var button = ActionButton("选择", () => PickAsync(box)); Grid.SetColumn(button, 1); panel.Children.Add(button); editor = panel; edits.Add(button); }
            Grid.SetColumn(editor, 1); Grid.SetRow(editor, row); form.Children.Add(editor); edits.Add(field);
        }
        Add("KeePassXC CLI", cli, true); Add("数据库 .kdbx", database, true); Add("TOTP 条目路径", entry); Add("凭据条目路径", credentialsEntry); Add("密钥文件（可选）", keyFile, true);
        Add("自动 MFA", automaticMfa); Add("HTTPS 网关（每行一项）", gateways); Add("HTTP 代理（空为直连）", proxy);
        Add("固定 IPv4/CIDR", fixedRoutes); Add("精确域名", domains); Add("校园 IPv4 DNS（可空）", dns);
        var advanced = new Expander { Header = "高级配置", Content = Stack(Text("网卡名"), adapter, Text("运行库目录"), runtime, Text("MTU"), mtu, tls12, Text("User-Agent"), agent) };
        edits.AddRange([adapter, runtime, mtu, tls12, agent]);
        return Page(Stack(form, advanced, Actions(ActionButton("校验并保存配置", SaveAsync), ActionButton("验证凭据并保存", VerifyAndSaveAsync)),
            Text("连接期间本页锁定；IP/CIDR 与域名可在连接页修改并立即同步。不保存主密码、VPN 密码或 TOTP 密钥。")));
    }
    private Control DiagnosticsPage()
    {
        var checks = new ItemsControl { ItemsSource = diagnosticRows, ItemTemplate = new FuncDataTemplate<DiagnosticRow>((row, _) =>
            Text((row!.Success ? "✓ " : "! ") + row.Name + "：" + row.Detail)) };
        return Page(Stack(Text("默认只读，不提交账号或 MFA。网络检查仅在点击后执行。"),
            Actions(ActionButton("本机依赖与配置检查", () => DiagnoseAsync(false)), ActionButton("网络 / 网关检查", () => DiagnoseAsync(true)), ActionButton("导出脱敏报告", ExportDiagnosticsAsync)),
            checks, Text("操作日志（不展示原始认证输出）"), logs, ActionButton("清空日志", () => { logBuffer.Clear(); logs.Text = ""; return Task.CompletedTask; })));
    }
    private void Populate(VpnConfig value)
    {
        cli.Text = value.Keepass.Cli; database.Text = value.Keepass.Database; entry.Text = value.Keepass.Entry; credentialsEntry.Text = value.Keepass.CredentialsEntry; keyFile.Text = value.Keepass.KeyFile;
        automaticMfa.IsChecked = value.Keepass.Enabled; gateways.Text = string.Join('\n', value.Vpn.Gateways); proxy.Text = value.Vpn.Proxy;
        adapter.Text = value.Vpn.AdapterName; mtu.Text = value.Vpn.Mtu.ToString(); runtime.Text = value.RuntimePath; tls12.IsChecked = value.Vpn.Tls12; agent.Text = value.Vpn.UserAgent;
        fixedRoutes.Text = string.Join('\n', value.Routes); domains.Text = string.Join('\n', value.Domains); dns.Text = string.Join('\n', value.DnsServers);
    }
    private VpnConfig Draft() => new()
    {
        RuntimePath = runtime.Text?.Trim() ?? "", Keepass = new() { Cli = cli.Text?.Trim() ?? "", Database = database.Text?.Trim() ?? "", Entry = entry.Text?.Trim() ?? "", CredentialsEntry = credentialsEntry.Text?.Trim() ?? "", KeyFile = keyFile.Text?.Trim() ?? "", Enabled = automaticMfa.IsChecked == true },
        Vpn = new() { Gateways = Split(gateways.Text), Proxy = proxy.Text?.Trim() ?? "", AdapterName = adapter.Text?.Trim() ?? "", Mtu = int.TryParse(mtu.Text, out var size) ? size : 0, Tls12 = tls12.IsChecked == true, UserAgent = agent.Text?.Trim() ?? "" },
        Routes = Split(fixedRoutes.Text), Domains = Split(domains.Text), DnsServers = Split(dns.Text)
    };
    private static string[] Split(string? text) => (text ?? "").Split(['\n', '\r', ','], StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
    private async Task SaveAsync()
    {
        if (active) throw new InvalidOperationException("连接中不能保存完整配置；请先断开。");
        var draft = Draft(); draft.Validate(); if (!demo) draft.Save(configPath); else _ = await backend.InvokeAsync("targets", draft); config = draft; Populate(config); StartWatcher(); ShowConfiguredRoutes(); Note("配置已校验并保存；尚未验证凭据。");
    }
    private async Task VerifyAndSaveAsync()
    {
        if (active) throw new InvalidOperationException("请先断开再验证并保存配置。");
        var draft = Draft(); draft.Validate();
        if (!demo)
        {
            var master = await RequestSecretAsync("master"); if (master is null) return;
            try
            {
                var settings = draft.Clone().Keepass; settings.Cli = VpnConfig.Resolve(root, settings.Cli); settings.Database = VpnConfig.Resolve(root, settings.Database);
                if (settings.KeyFile.Length > 0) settings.KeyFile = VpnConfig.Resolve(root, settings.KeyFile);
                _ = await KeepassReader.CredentialsAsync(settings, master, CancellationToken.None);
                if (settings.Enabled) _ = await KeepassReader.TotpAsync(settings, master, CancellationToken.None);
            }
            finally { master = null; }
        }
        await SaveAsync(); Note(demo ? "演示：配置已验证（模拟）。" : "凭据已在本机验证，配置已保存；未登录 VPN。");
    }
    private async Task InstallAsync()
    {
        if (active) throw new InvalidOperationException("连接中不能安装依赖。");
        Note("正在安装 / 检查依赖，可能需要数分钟；下载包仍执行 hash 与签名校验。");
        var result = await backend.InvokeAsync("install", new { config = Draft(), archive = archive.Text?.Trim() ?? "" });
        if (!demo) { var updated = result.Deserialize<VpnConfig>(VpnConfig.Json)!; cli.Text = updated.Keepass.Cli; }
        CheckDependencies(); Note("依赖准备完成，请填写配置并验证条目。");
    }
    private async Task BeginConnectAsync()
    {
        if (busy || active) return;
        try
        {
            if (!demo) { config = VpnConfig.Load(configPath); config.Validate(); }
            active = true; SetState("preparing"); UpdateButtons();
            connectionTask = backend.InvokeAsync("connect"); await connectionTask;
        }
        catch (Exception error) { Note(SafeLog.Redact(error.Message)); }
        finally { active = false; connectedAt = null; clock.Stop(); UpdateButtons(); if (!exitRequested) await ExecuteAsync(SnapshotAsync); }
    }
    private async Task DisconnectAsync()
    {
        if (disconnecting) return;
        disconnecting = true;
        try {
        Note("正在停止本项目隧道并清理路由…");
        await backend.InvokeAsync("disconnect"); active = false; SetState("ready"); await SnapshotAsync(); Note("断开与清理操作完成。请核对路由状态与警告。");
        } finally { disconnecting = false; }
    }
    private async Task SnapshotAsync()
    {
        if (!demo && !File.Exists(configPath)) { ShowConfiguredRoutes(); return; }
        ApplySnapshot(await backend.InvokeAsync("snapshot"));
    }
    private async Task RefreshAsync() {
        if (active && !tunnelConnected) throw new InvalidOperationException("隧道尚未建立，请等待认证完成后刷新。");
        var snapshot = await backend.InvokeAsync("refresh"); ApplySnapshot(snapshot);
        if (!snapshot.TryGetProperty("refreshFailed", out var failure) || !failure.GetBoolean()) Note("全部路由已同步，请核对每条路由和域名状态。");
    }
    private Button RouteAction(string label, Func<Task> action)
    {
        var button = ActionButton(label, action); button.Classes.Add("route-action"); button.IsEnabled = CanManageRoutes; return button;
    }
    private void EditRoute(RouteRow row)
    {
        if (active && !tunnelConnected || disconnecting) throw new InvalidOperationException("请等待认证或断开完成后编辑路由。");
        editingRoute = row; routeKind.SelectedIndex = row.Source == "固定" ? 0 : 1;
        routeKind.IsEnabled = false; routeInput.Text = row.Target; editingLabel.Text = "编辑：" + row.Target;
        if (saveRoute != null) saveRoute.IsEnabled = true;
    }
    private void CancelRouteEdit()
    { editingRoute = null; routeInput.Text = ""; editingLabel.Text = "添加新路由"; routeKind.IsEnabled = CanManageRoutes; if (saveRoute != null) saveRoute.IsEnabled = false; }
    private Task AddRouteAsync() => ChangeRouteAsync(routeKind.SelectedIndex == 0 ? RouteKind.Fixed : RouteKind.Domain, null, routeInput.Text);
    private Task SaveRouteEditAsync() => editingRoute == null ? Task.CompletedTask : ChangeRouteAsync(editingRoute.Source == "固定" ? RouteKind.Fixed : RouteKind.Domain, editingRoute.Target, routeInput.Text);
    private Task DeleteRouteAsync(RouteRow row) => ChangeRouteAsync(row.Source == "固定" ? RouteKind.Fixed : RouteKind.Domain, row.Target, null);
    private async Task ChangeRouteAsync(RouteKind kind, string? original, string? value)
    {
        if (active && !tunnelConnected) throw new InvalidOperationException("认证期间不能修改目标，请等待连接完成或先断开。");
        var current = demo || !File.Exists(configPath) ? config : VpnConfig.Load(configPath);
        var updated = RouteTargets.Change(current, kind, original, value);
        if (!demo) updated.Save(configPath); else _ = await backend.InvokeAsync("targets", updated);
        config = updated; fixedRoutes.Text = string.Join('\n', config.Routes); domains.Text = string.Join('\n', config.Domains); CancelRouteEdit();
        if (active) await RefreshAsync(); else { ShowConfiguredRoutes(); Note("路由配置已保存，下次连接应用。"); }
    }
    private void SetRouteRows(IEnumerable<RouteRow> rows)
    { allRouteRows.Clear(); allRouteRows.AddRange(rows); FilterRoutes(); }
    private void FilterRoutes()
    {
        var term = routeSearch.Text?.Trim() ?? ""; routeRows.Clear();
        foreach (var row in allRouteRows.Where(r => term.Length == 0 || string.Join(' ', r.Source, r.Target, r.Prefix, r.Status, r.Detail).Contains(term, StringComparison.OrdinalIgnoreCase))) routeRows.Add(row);
    }
    private void ApplySnapshot(JsonElement data)
    {
        var snapshot = data.Deserialize<BackendSnapshot>(new JsonSerializerOptions { PropertyNameCaseInsensitive = true })!;
        SetRouteRows(snapshot.Routes);
        domainStatus.Text = snapshot.DomainStatus;
        if (data.TryGetProperty("refreshFailed", out var failed) && failed.GetBoolean()) Note("配置已保存，但路由同步失败；原有路由已保留，请检查 DNS、目标和路由冲突后重试刷新。");
        if (snapshot.RecoveryNeeded) SetState("recovery");
    }
    private void ShowConfiguredRoutes()
    {
        SetRouteRows(config.Routes.Select(r => new RouteRow("固定", r, r, "未应用", "下次连接生效"))
            .Concat(config.Domains.Select(d => new RouteRow("域名", d, "", "未应用", "连接后经 VPN DNS 解析"))));
    }
    private void HandleEvent(BackendEvent e)
    {
        if (e.Name == "state") SetState(e.Data.GetString() ?? "failed");
        else if (e.Name == "snapshot") ApplySnapshot(e.Data);
        else if (e.Name == "closeInput") secretDialog?.Close(null);
        else if (e.Name == "offline") { secretDialog?.Close(null); active = false; clock.Stop(); SetState("recovery"); UpdateButtons(); }
    }
    private void SetState(string state)
    {
        tunnelConnected = state == "connected";
        stateLabel.Text = state switch { "ready" => "未连接", "preparing" => "准备连接", "authenticating" => "正在认证", "mfa" => "等待 MFA", "connected" => "VPN 已连接", "recovery" => "需要检查 / 恢复", _ => "连接失败" };
        if (state == "connected") { connectedAt = DateTimeOffset.Now; clock.Start(); }
        if (state == "ready") { connectedAt = null; elapsed.Text = ""; clock.Stop(); }
        Note(stateLabel.Text); UpdateButtons();
    }
    private void UpdateButtons()
    {
        connect.IsEnabled = !busy && !active && backend.Supported; disconnect.IsEnabled = !disconnecting && backend.Supported;
        foreach (var edit in edits) edit.IsEnabled = !busy && !active;
        routeInput.IsEnabled = CanManageRoutes; routeKind.IsEnabled = CanManageRoutes && editingRoute == null;
        foreach (var action in this.GetVisualDescendants().OfType<Button>().Where(b => b.Classes.Contains("route-action"))) action.IsEnabled = CanManageRoutes;
        if (saveRoute != null) saveRoute.IsEnabled = CanManageRoutes && editingRoute != null;
    }
    private async Task ExecuteAsync(Func<Task> action, bool allowDuringConnection = false)
    {
        if (busy && !allowDuringConnection) return; runningOperations++; UpdateButtons();
        try { await action(); }
        catch (Exception error) { Note(SafeLog.Redact(error.Message)); }
        finally { runningOperations--; UpdateButtons(); }
    }
    private void Note(string message)
    {
        var safe = SafeLog.Redact(message); notice.Text = safe; logBuffer.Add(DateTimeOffset.Now.ToString("HH:mm:ss") + "  " + safe);
        while (logBuffer.Count > 200) logBuffer.RemoveAt(0); logs.Text = string.Join('\n', logBuffer);
    }
    private async Task<string?> RequestSecretAsync(string type)
    {
        if (!Dispatcher.UIThread.CheckAccess()) return await Dispatcher.UIThread.InvokeAsync(() => RequestSecretAsync(type));
        var input = new TextBox { PasswordChar = '●', MinWidth = 310, Watermark = type == "master" ? "KeePassXC 数据库主密码" : "六位 Microsoft 验证码" };
        var dialog = new Window { Title = type == "master" ? "解锁数据库" : "输入 MFA", Width = 420, Height = 210, CanResize = false, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        secretDialog = dialog;
        var submit = new Button { Content = "继续", IsDefault = true }; var cancel = new Button { Content = "取消", IsCancel = true };
        submit.Click += (_, _) => { var value = input.Text; input.Text = ""; dialog.Close(value); };
        cancel.Click += (_, _) => { input.Text = ""; dialog.Close(null); };
        dialog.Content = new StackPanel { Margin = new Thickness(24), Spacing = 14, Children = { Text("仅用于本次操作，不保存。"), input, Actions(submit, cancel) } };
        dialog.Opened += (_, _) => input.Focus();
        try { var result = await dialog.ShowDialog<string?>(this); input.Text = ""; return result; }
        finally { input.Text = ""; if (ReferenceEquals(secretDialog, dialog)) secretDialog = null; }
    }
    private async Task PickAsync(TextBox field)
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions { AllowMultiple = false });
        var path = files.FirstOrDefault()?.TryGetLocalPath(); if (path != null) field.Text = path;
    }
    private Task OpenKeepassAsync()
    {
        if (demo) { Note("演示模式不会启动外部软件。"); return Task.CompletedTask; }
        var path = Path.Combine(Path.GetDirectoryName(VpnConfig.Resolve(root, cli.Text ?? ""))!, OperatingSystem.IsWindows() ? "KeePassXC.exe" : "keepassxc");
        if (!File.Exists(path)) throw new InvalidOperationException("未找到 KeePassXC，请先安装或填写 CLI 路径。");
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); return Task.CompletedTask;
    }
    private void CheckDependencies()
    {
        if (demo) { dependencyStatus.Text = "演示依赖：模拟可用。"; return; }
        var checks = new[] { ("KeePassXC CLI", VpnConfig.Resolve(root, cli.Text ?? "")), ("数据库", VpnConfig.Resolve(root, database.Text ?? "")),
            ("OpenConnect", Path.Combine(VpnConfig.Resolve(root, runtime.Text ?? ""), "openconnect.exe")), ("Wintun", Path.Combine(VpnConfig.Resolve(root, runtime.Text ?? ""), "wintun.dll")) };
        dependencyStatus.Text = string.Join('\n', checks.Select(c => (File.Exists(c.Item2) ? "✓ " : "! ") + c.Item1 + (File.Exists(c.Item2) ? " 已找到" : " 缺失")));
    }
    private async Task DiagnoseAsync(bool network)
    {
        var draft = Draft(); draft.Validate(); var result = await backend.InvokeAsync("diagnose", new { config = draft, network });
        diagnosticRows.Clear(); foreach (var row in result.Deserialize<DiagnosticRow[]>(new JsonSerializerOptions { PropertyNameCaseInsensitive = true })!) diagnosticRows.Add(row);
        Note("诊断完成；未提交 VPN 凭据，未修改路由。");
    }
    private async Task ExportDiagnosticsAsync()
    {
        var file = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions { SuggestedFileName = "hku-vpn-diagnostics.txt", DefaultExtension = "txt" });
        if (file == null) return;
        await using var output = await file.OpenWriteAsync(); using var writer = new StreamWriter(output);
        await writer.WriteAsync(SafeLog.Redact(string.Join('\n', diagnosticRows.Select(r => r.Name + "：" + r.Detail)) + "\n\n" + string.Join('\n', logBuffer)));
        Note("已导出脱敏报告，不含配置或会话文件。");
    }
    private void StartWatcher()
    {
        if (demo || watcher != null) return;
        var local = Path.Combine(root, ".local"); if (!Directory.Exists(local)) return;
        watcher = new FileSystemWatcher(local) { NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName, EnableRaisingEvents = true };
        void Changed(object? sender, FileSystemEventArgs e)
        {
            if (e.Name is not ("domain-session.json" or "domain-status.txt")) return;
            Dispatcher.UIThread.Post(async () =>
            {
                debounce?.Cancel(); debounce?.Dispose(); debounce = new CancellationTokenSource(); var ct = debounce.Token;
                try { await Task.Delay(600, ct); if (active && !busy && !exitRequested) await ExecuteAsync(SnapshotAsync); } catch (OperationCanceledException) { }
            });
        }
        watcher.Changed += Changed; watcher.Created += Changed; watcher.Deleted += Changed;
    }
    private void SetupTray()
    {
        if (!OperatingSystem.IsWindows() || demo) return;
        var menu = new NativeMenu(); var show = new NativeMenuItem("打开 HKU VPN"); show.Click += (_, _) => { Show(); Activate(); };
        var stop = new NativeMenuItem("断开 VPN"); stop.Click += async (_, _) => await ExecuteAsync(DisconnectAsync, allowDuringConnection: true);
        var quit = new NativeMenuItem("退出并清理"); quit.Click += async (_, _) => await ExitAsync(); menu.Items.Add(show); menu.Items.Add(stop); menu.Items.Add(quit);
        // Icon is generated locally; no external asset is required.
        using var bitmap = new Avalonia.Media.Imaging.WriteableBitmap(new PixelSize(32, 32), new Vector(96, 96), Avalonia.Platform.PixelFormat.Bgra8888, Avalonia.Platform.AlphaFormat.Opaque);
        using (var locked = bitmap.Lock()) { var pixels = Enumerable.Repeat(unchecked((int)0xFF2667A8), 32 * 32).ToArray(); System.Runtime.InteropServices.Marshal.Copy(pixels, 0, locked.Address, pixels.Length); }
        using var bytes = new MemoryStream(); bitmap.Save(bytes); bytes.Position = 0;
        tray = new TrayIcon { Icon = new WindowIcon(bytes), ToolTipText = "HKU VPN · 双击打开", Menu = menu, IsVisible = true };
        tray.Clicked += (_, _) => { Show(); Activate(); };
    }
    private void OnClosing(object? sender, WindowClosingEventArgs e)
    {
        if (closeApproved) return;
        e.Cancel = true;
        if (active && tray != null) { Note("窗口已隐藏到托盘，VPN 仍在连接。退出请使用托盘菜单。 "); Hide(); }
        else _ = ExitAsync();
    }
    private async Task ExitAsync()
    {
        if (exitRequested || busy) { Note("请等待当前操作完成后退出。"); return; }
        exitRequested = true;
        try
        {
            if (active) await DisconnectAsync();
            await backend.DisposeAsync(); watcher?.Dispose(); debounce?.Cancel(); clock.Stop(); tray?.Dispose(); closeApproved = true; Close();
        }
        catch (Exception error) { exitRequested = false; Show(); Note("退出清理失败，请重试断开：" + SafeLog.Redact(error.Message)); }
    }
    public int PageCount => tabs.Items.Count;
    public int RouteCount => routeRows.Count;
}
internal static class PanelExtensions
{
    public static StackPanel With(this StackPanel panel, IEnumerable<Control> children) { foreach (var child in children) panel.Children.Add(child); return panel; }
}
