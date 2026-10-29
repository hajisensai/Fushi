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

/// IP 地址是否落在本机 / 局域网段（宿主在 DNS 解析后同样要用这条判据，见 Dart 侧）。
pub fn check_ip(ip: IpAddr) -> Result<(), String> {
    let private = match ip {
        IpAddr::V4(v4) => is_private_v4(v4),
        IpAddr::V6(v6) => {
            v6.is_loopback()
                || v6.is_unspecified()
                || (v6.segments()[0] & 0xfe00) == 0xfc00
                || (v6.segments()[0] & 0xffc0) == 0xfe80
                || v6.to_ipv4_mapped().is_some_and(is_private_v4)
                || v6 == Ipv6Addr::LOCALHOST
        }
    };
    if private {
        Err(format!("不允许访问本机 / 局域网地址 {ip}"))
    } else {
        Ok(())
    }
}

fn is_private_v4(v4: Ipv4Addr) -> bool {
    v4.is_loopback()
        || v4.is_private()
        || v4.is_link_local()
        || v4.is_unspecified()
        || v4.is_broadcast()
        || v4.octets()[0] == 0
        || (v4.octets()[0] == 100 && (v4.octets()[1] & 0xc0) == 64)
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
        assert!(check_ip("1.1.1.1".parse().unwrap()).is_ok());
        assert!(check_ip("2606:4700::1111".parse().unwrap()).is_ok());
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
