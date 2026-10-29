//! 网络授权：插件只能访问清单 `network.domains` 声明过的主机（默认拒绝）。
//!
//! 规则形态：`api.example.com`（只匹配这个主机）或 `*.example.com`（只匹配它的子域，不含
//! 裸域本身）。一律按小写比较。拒绝 IP 字面量里的回环 / 私网 / 链路本地地址与 `localhost`，
//! 无论规则怎么写——插件不该摸到用户的局域网。

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

use crate::plugin::manifest::Manifest;

/// 校验一条域名规则本身是否合法（清单解析时调用）。
pub fn validate_domain_rule(rule: &str) -> Result<(), String> {
    let host = rule.strip_prefix("*.").unwrap_or(rule);
    let ok = !host.is_empty()
        && host.len() <= 253
        && host.contains('.')
        && host.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && label
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        });
    if ok {
        Ok(())
    } else {
        Err(format!("域名规则不合法：{rule:?}（小写主机名，或 *.主机名）"))
    }
}

/// 一次访问的用途：决定允许哪些 scheme / 方法。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Purpose {
    /// 插件发起的 `fushi.http.request`（含每一跳重定向）。
    Request,
    /// 插件交给宿主去播放 / 显示的地址（音频流、封面）。
    Media,
}

#[derive(Clone, Debug)]
pub struct Policy {
    rules: Vec<String>,
    methods: Vec<String>,
    insecure_http: bool,
}

impl Policy {
    pub fn from_manifest(m: &Manifest) -> Policy {
        Policy {
            rules: m.network.domains.clone(),
            methods: if m.network.methods.is_empty() {
                vec!["GET".into()]
            } else {
                m.network.methods.clone()
            },
            insecure_http: m.has_permission("insecureHttp"),
        }
    }

    pub fn check_method(&self, method: &str) -> Result<(), String> {
        if self.methods.iter().any(|m| m == method) {
            Ok(())
        } else {
            Err(format!("插件没有声明 HTTP 方法 {method}"))
        }
    }

    /// 核对一个 URL；通过时返回规范化后的字符串。
    pub fn check_url(&self, raw: &str, _purpose: Purpose) -> Result<String, String> {
        let url = url::Url::parse(raw).map_err(|e| format!("URL 不合法：{e}"))?;
        match url.scheme() {
            "https" => {}
            "http" if self.insecure_http => {}
            "http" => return Err("插件没有 insecureHttp 权限，只能访问 https".into()),
            s => return Err(format!("不允许的 scheme {s:?}")),
        }
        if !url.username().is_empty() || url.password().is_some() {
            return Err("URL 不得带用户名 / 密码".into());
        }
        let host = match url.host() {
            Some(url::Host::Domain(d)) => d.to_ascii_lowercase(),
            Some(url::Host::Ipv4(ip)) => {
                check_ip(IpAddr::V4(ip))?;
                return Err(format!("不允许直接访问 IP 地址 {ip}"));
            }
            Some(url::Host::Ipv6(ip)) => {
                check_ip(IpAddr::V6(ip))?;
                return Err(format!("不允许直接访问 IP 地址 {ip}"));
            }
            None => return Err("URL 缺主机".into()),
        };
        if host == "localhost" || host.ends_with(".localhost") {
            return Err("不允许访问 localhost".into());
        }
        if !self.rules.iter().any(|r| rule_matches(r, &host)) {
            return Err(format!("主机 {host} 不在插件声明的网络授权内"));
        }
        Ok(url.to_string())
    }
}

fn rule_matches(rule: &str, host: &str) -> bool {
    match rule.strip_prefix("*.") {
        Some(suffix) => host.len() > suffix.len() + 1
            && host.ends_with(suffix)
            && host.as_bytes()[host.len() - suffix.len() - 1] == b'.',
        None => rule == host,
    }
}

/// IP 地址是否落在本机 / 局域网 / 保留段（宿主在 DNS 解析后用同一判据，见 Dart 侧
/// `isMusicPluginPrivateAddress`）。内嵌 IPv4 的 IPv6 形态（IPv4-mapped、IPv4-compatible、
/// NAT64 `64:ff9b::/96`、6to4 `2002::/16`）按内嵌地址判；本地 NAT64 前缀 `64:ff9b:1::/48` 整段拒绝。
///
/// 这里只核对 URL 里的 IP 字面量，所以额外拒绝 `198.18.0.0/15`（基准测试段，fake-ip 代理的
/// 假地址池）；Dart 侧核对的是 DNS 解析结果，那一段在 fake-ip 下是所有公网域名的解析值，不拦。
pub fn check_ip(ip: IpAddr) -> Result<(), String> {
    let private = match ip {
        IpAddr::V4(v4) => is_private_v4(v4) || (v4.octets()[0] == 198 && (v4.octets()[1] & 0xfe) == 18),
        IpAddr::V6(v6) => is_private_v6(v6),
    };
    if private {
        Err(format!("不允许访问本机 / 局域网地址 {ip}"))
    } else {
        Ok(())
    }
}

fn is_private_v6(v6: Ipv6Addr) -> bool {
    let s = v6.segments();
    let embedded = |hi: u16, lo: u16| is_private_v4(Ipv4Addr::from(((hi as u32) << 16) | lo as u32));
    if s[..6] == [0; 6] {
        // ::、::1、IPv4-compatible ::a.b.c.d
        return (s[6] == 0 && s[7] <= 1) || embedded(s[6], s[7]);
    }
    if let Some(v4) = v6.to_ipv4_mapped() {
        return is_private_v4(v4);
    }
    if s[0] == 0x64 && s[1] == 0xff9b {
        if s[2..6] == [0; 4] {
            return embedded(s[6], s[7]);
        }
        if s[2] == 1 {
            return true;
        }
    }
    if s[0] == 0x2002 {
        return embedded(s[1], s[2]);
    }
    (s[0] & 0xfe00) == 0xfc00 // ULA
        || (s[0] & 0xffc0) == 0xfe80 // 链路本地
        || (s[0] & 0xffc0) == 0xfec0 // 站点本地（已废弃）
        || (s[0] & 0xff00) == 0xff00 // 组播
}

fn is_private_v4(v4: Ipv4Addr) -> bool {
    let o = v4.octets();
    o[0] == 0
        || o[0] == 10
        || o[0] == 127
        || (o[0] == 100 && (o[1] & 0xc0) == 64)
        || (o[0] == 169 && o[1] == 254)
        || (o[0] == 172 && (o[1] & 0xf0) == 16)
        || (o[0] == 192 && o[1] == 168)
        || (o[0] == 192 && o[1] == 0 && o[2] == 0)
        || o[0] >= 224
}

#[cfg(test)]
mod tests {
    use super::*;

    fn policy(insecure: bool) -> Policy {
        Policy {
            rules: vec!["api.example.com".into(), "*.cdn.example.com".into()],
            methods: vec!["GET".into(), "POST".into()],
            insecure_http: insecure,
        }
    }

    #[test]
    fn matches_rules() {
        let p = policy(false);
        assert!(p.check_url("https://api.example.com/x?y=1", Purpose::Request).is_ok());
        assert!(p.check_url("https://API.example.com/x", Purpose::Request).is_ok());
        assert!(p.check_url("https://a.b.cdn.example.com/x", Purpose::Media).is_ok());
        assert!(p.check_url("https://cdn.example.com/x", Purpose::Media).is_err());
        assert!(p.check_url("https://evilcdn.example.com/x", Purpose::Media).is_err());
        assert!(p.check_url("https://api.example.com.evil.net/", Purpose::Request).is_err());
        assert!(p.check_url("https://other.com/", Purpose::Request).is_err());
    }

    #[test]
    fn rejects_scheme_ip_userinfo() {
        let p = policy(false);
        assert!(p.check_url("http://api.example.com/", Purpose::Request).is_err());
        assert!(policy(true).check_url("http://api.example.com/", Purpose::Request).is_ok());
        assert!(p.check_url("file:///etc/passwd", Purpose::Request).is_err());
        assert!(p.check_url("https://127.0.0.1/", Purpose::Request).is_err());
        assert!(p.check_url("https://[::1]/", Purpose::Request).is_err());
        assert!(p.check_url("https://u:p@api.example.com/", Purpose::Request).is_err());
        assert!(p.check_method("DELETE").is_err());
        assert!(p.check_method("POST").is_ok());
    }

    #[test]
    fn private_ips() {
        for ip in ["10.0.0.1", "192.168.1.1", "172.16.0.1", "169.254.1.1", "100.64.0.1", "::1", "fe80::1", "fd00::1", "::ffff:192.168.0.1"] {
            assert!(check_ip(ip.parse().unwrap()).is_err(), "{ip}");
        }
        for ip in [
            "64:ff9b::a00:1", "64:ff9b:1::1", "2002:c0a8:101::1", "::a9fe:a9fe", "192.0.0.8",
            "198.18.0.1", "198.19.255.255", "224.0.0.1", "255.255.255.255", "fec0::1", "ff02::1", "::",
        ] {
            assert!(check_ip(ip.parse().unwrap()).is_err(), "{ip}");
        }
        for ip in ["1.1.1.1", "2606:4700::1111", "64:ff9b::808:808", "2002:808:808::1", "198.20.0.1"] {
            assert!(check_ip(ip.parse().unwrap()).is_ok(), "{ip}");
        }
    }

    #[test]
    fn domain_rule_validation() {
        assert!(validate_domain_rule("*.img.example-music.com").is_ok());
        assert!(validate_domain_rule("api.example-music.com").is_ok());
        for bad in ["*", "*.com.", "Api.example-music.com", "localhost", "a..b", "*.*.x.com"] {
            assert!(validate_domain_rule(bad).is_err(), "{bad}");
        }
    }
}
