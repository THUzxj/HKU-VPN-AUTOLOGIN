// Optional Clash Verge/Mihomo merge script for the default HKU gateways.
// This selects a Hong Kong proxy for the VPN transport, not for all .hk sites.
function main(config) {
  const name = "HK APP";
  const groups = Array.isArray(config["proxy-groups"]) ? config["proxy-groups"] : [];
  config["proxy-groups"] = [{
    name: name, type: "select", "include-all": true, "exclude-type": "direct",
    filter: "(?i)(🇭🇰|香港|港|HK|Hong[ -]?Kong)"
  }, ...groups.filter(group => !group || group.name !== name)];
  const gateways = ["vpn2fa.hku.hk", "vpn2fa-a.hku.hk", "vpn2fa-b.hku.hk"];
  const rules = Array.isArray(config.rules) ? config.rules : [];
  config.rules = [
    ...gateways.map(host => `DOMAIN,${host},${name}`),
    ...rules.filter(rule => typeof rule !== "string" ||
      !gateways.some(host => rule.startsWith(`DOMAIN,${host},`)))
  ];
  return config;
}
