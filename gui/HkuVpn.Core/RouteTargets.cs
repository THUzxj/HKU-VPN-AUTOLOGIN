namespace HkuVpn.Core;

public enum RouteKind { Fixed, Domain }

public static class RouteTargets
{
    public static VpnConfig Change(VpnConfig current, RouteKind kind, string? original, string? value)
    {
        string Normalize(string text) => kind == RouteKind.Fixed ? VpnConfig.NormalizeRoute(text.Trim()) : VpnConfig.NormalizeDomain(text);
        var updated = current.Clone();
        var targets = (kind == RouteKind.Fixed ? updated.Routes : updated.Domains).Select(Normalize).ToList();
        var old = original == null ? null : Normalize(original);
        var next = value == null ? null : Normalize(value);
        if (old == null && next == null) throw new InvalidDataException("请输入路由目标。");
        if (old != null && !targets.Contains(old)) throw new InvalidDataException("原路由已不存在，请刷新列表。");
        if (next != null && next != old && targets.Contains(next)) throw new InvalidDataException("目标已存在，请编辑现有路由。");
        if (old != null) targets.Remove(old);
        if (next != null) targets.Add(next);
        if (kind == RouteKind.Fixed) updated.Routes = targets.ToArray(); else updated.Domains = targets.ToArray();
        updated.Validate(); return updated;
    }
}
