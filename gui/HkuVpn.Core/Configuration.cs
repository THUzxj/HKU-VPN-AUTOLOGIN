using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace HkuVpn.Core;

public sealed class VpnConfig
{
    public int SchemaVersion { get; set; } = 1;
    public string RuntimePath { get; set; } = ".local/runtime";
    public KeepassConfig Keepass { get; set; } = new();
    public GatewayConfig Vpn { get; set; } = new();
    public string[] Routes { get; set; } = [];
    public string[] Domains { get; set; } = [];
    public string[] DnsServers { get; set; } = [];
    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true,
        WriteIndented = true, UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };
    public static VpnConfig Load(string path) => JsonSerializer.Deserialize<VpnConfig>(File.ReadAllText(path), Json)
        ?? throw new InvalidDataException("配置为空。");
    public void Validate()
    {
        if (SchemaVersion != 1 || Keepass is null || Vpn is null || Routes is null || Domains is null || DnsServers is null)
            throw new InvalidDataException("配置结构不完整或版本不支持。");
        if (string.IsNullOrWhiteSpace(RuntimePath) || string.IsNullOrWhiteSpace(Keepass.Cli) ||
            string.IsNullOrWhiteSpace(Keepass.Database) || string.IsNullOrWhiteSpace(Keepass.Entry))
            throw new InvalidDataException("请填写运行库、KeePassXC CLI、数据库和 TOTP 条目路径。");
        if (Vpn.Gateways is null || Vpn.Gateways.Length == 0) throw new InvalidDataException("至少填写一个 VPN 网关。");
        foreach (var gateway in Vpn.Gateways)
            if (!Uri.TryCreate(gateway, UriKind.Absolute, out var uri) || uri.Scheme != "https" ||
                uri.UserInfo.Length != 0 || uri.Query.Length != 0 || uri.Fragment.Length != 0)
                throw new InvalidDataException("网关必须是无凭据、查询参数或片段的 HTTPS URL。");
        if (Vpn.Proxy.Length > 0 && (!Uri.TryCreate(Vpn.Proxy, UriKind.Absolute, out var proxy) ||
            proxy.Scheme != "http" || proxy.UserInfo.Length != 0 || proxy.AbsolutePath != "/" || proxy.Query.Length != 0 || proxy.Fragment.Length != 0))
            throw new InvalidDataException("代理应为不含凭据的 HTTP URL；直连时留空。");
        if (!Regex.IsMatch(Vpn.AdapterName, "^[A-Za-z0-9_-]{1,64}$") ||
            Regex.IsMatch(Vpn.AdapterName, "^(Mihomo|Clash|WLAN|Ethernet)$", RegexOptions.IgnoreCase))
            throw new InvalidDataException("请使用专用网卡名称，仅含字母、数字、下划线或连字符。");
        if (Vpn.Mtu is < 576 or > 1500) throw new InvalidDataException("MTU 应为 576–1500。");
        if (string.IsNullOrWhiteSpace(Vpn.UserAgent) || Vpn.UserAgent.IndexOfAny(['\r', '\n']) >= 0)
            throw new InvalidDataException("User-Agent 必须为非空单行。");
        Routes = Routes.Select(NormalizeRoute).Distinct().ToArray();
        Domains = Domains.Select(NormalizeDomain).Distinct().ToArray();
        foreach (var domain in Domains)
            if (Vpn.Gateways.Any(g => new Uri(g).Host.Equals(domain, StringComparison.OrdinalIgnoreCase)))
                throw new InvalidDataException("不能把 VPN 网关自身加入目标域名。");
        foreach (var dns in DnsServers) _ = NormalizeRoute(dns + "/32");
    }
    public static string NormalizeDomain(string value)
    {
        var name = value.Trim().TrimEnd('.').ToLowerInvariant();
        if (name.Length > 253 || !Regex.IsMatch(name, @"^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$"))
            throw new InvalidDataException("请输入精确 ASCII 域名，不含 URL、通配符或端口；国际化域名使用 punycode。");
        return name;
    }
    public static string NormalizeRoute(string value)
    {
        var match = Regex.Match(value, @"^(\d{1,3}(?:\.\d{1,3}){3})(?:/(\d{1,2}))?$");
        if (!match.Success) throw new InvalidDataException("无效 IPv4/CIDR。");
        var octets = match.Groups[1].Value.Split('.').Select(int.Parse).ToArray();
        var bits = match.Groups[2].Success ? int.Parse(match.Groups[2].Value) : 32;
        if (bits is < 1 or > 32 || octets.Any(o => o > 255)) throw new InvalidDataException("无效 IPv4/CIDR；不允许默认路由。");
        for (var i = 0; i < 4; i++) octets[i] &= 256 - (int)Math.Pow(2, 8 - Math.Clamp(bits - i * 8, 0, 8));
        if (octets[0] == 127 || octets[0] >= 224 || octets.All(o => o == 0)) throw new InvalidDataException("不支持此路由地址。");
        return string.Join('.', octets) + "/" + bits;
    }
    public void Save(string path)
    {
        Validate(); Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temp, JsonSerializer.Serialize(this, Json), new UTF8Encoding(false));
            File.Move(temp, path, true);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
    public VpnConfig Clone() => JsonSerializer.Deserialize<VpnConfig>(JsonSerializer.Serialize(this, Json), Json)!;
    public static string Resolve(string root, string path) => Path.GetFullPath(Path.IsPathRooted(path) ? path : Path.Combine(root, path));
}
public sealed class KeepassConfig
{
    public string Cli { get; set; } = "";
    public string Database { get; set; } = "";
    public string Entry { get; set; } = "HKU MFA";
    public string CredentialsEntry { get; set; } = "";
    public string KeyFile { get; set; } = "";
    public bool Enabled { get; set; } = true;
}
public sealed class GatewayConfig
{
    public string[] Gateways { get; set; } = ["https://vpn2fa-b.hku.hk", "https://vpn2fa-a.hku.hk"];
    public string Proxy { get; set; } = "";
    public string AdapterName { get; set; } = "HKU-OpenConnect";
    public int Mtu { get; set; } = 1200;
    public bool Tls12 { get; set; } = true;
    public string UserAgent { get; set; } = "AnyConnect Windows 5.1.12.146";
}
