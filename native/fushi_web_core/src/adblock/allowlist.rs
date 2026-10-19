//! 白名单站点：解析用户输入的原文，按主机名（含子域名）匹配。

/// 解析白名单原文：逗号 / 分号 / 空白 / 全角逗号 / 顿号分隔；容忍用户粘整条 URL、`*.` / `.`
/// 前缀与端口；统一小写，去重保序。
pub fn parse(raw: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for token in raw.split(|c: char| c.is_whitespace() || matches!(c, ',' | ';' | '，' | '、')) {
        let mut t = token.trim().to_lowercase();
        if t.is_empty() {
            continue;
        }
        if t.contains("://") {
            t = url_host(&t).unwrap_or_default();
        }
        if let Some(slash) = t.find('/') {
            t.truncate(slash);
        }
        if let Some(colon) = t.find(':') {
            t.truncate(colon);
        }
        loop {
            if let Some(rest) = t.strip_prefix("*.") {
                t = rest.to_string();
            } else if let Some(rest) = t.strip_prefix('.') {
                t = rest.to_string();
            } else {
                break;
            }
        }
        if !t.is_empty() && !out.contains(&t) {
            out.push(t);
        }
    }
    out
}

/// `host` 是否命中白名单（精确或其子域名）。
pub fn matches(host: &str, allowlist: &[String]) -> bool {
    if host.is_empty() || allowlist.is_empty() {
        return false;
    }
    let h = host.to_ascii_lowercase();
    allowlist.iter().any(|entry| {
        h == *entry
            || (h.len() > entry.len()
                && h.ends_with(entry.as_str())
                && h.as_bytes()[h.len() - entry.len() - 1] == b'.')
    })
}

/// 从绝对 URL 取主机名（小写；去 userinfo 与端口；IPv6 字面量去方括号）。取不到返回 None。
pub fn url_host(url: &str) -> Option<String> {
    let after = &url[url.find("://")? + 3..];
    let end = after.find(['/', '?', '#']).unwrap_or(after.len());
    let mut authority = &after[..end];
    if let Some(at) = authority.rfind('@') {
        authority = &authority[at + 1..];
    }
    let host = if let Some(rest) = authority.strip_prefix('[') {
        &rest[..rest.find(']')?]
    } else {
        authority.split(':').next().unwrap_or("")
    };
    if host.is_empty() {
        None
    } else {
        Some(host.to_ascii_lowercase())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_tolerantly() {
        assert_eq!(
            parse("Example.com, *.foo.org;https://Bar.net/x?y  .baz.io:8080，qux.jp、a.b/c"),
            vec![
                "example.com",
                "foo.org",
                "bar.net",
                "baz.io",
                "qux.jp",
                "a.b"
            ]
        );
        assert!(parse("  , ;").is_empty());
        assert_eq!(parse("a.com a.com"), vec!["a.com"]);
    }

    #[test]
    fn matches_exact_and_subdomains_only() {
        let list = parse("news.test");
        assert!(matches("news.test", &list));
        assert!(matches("m.news.test", &list));
        assert!(matches("M.NEWS.TEST", &list));
        assert!(!matches("badnews.test", &list));
        assert!(!matches("", &list));
    }

    #[test]
    fn host_extraction() {
        assert_eq!(
            url_host("https://u:p@Ex.com:8443/a?b#c").as_deref(),
            Some("ex.com")
        );
        assert_eq!(url_host("http://[::1]:80/").as_deref(), Some("::1"));
        assert_eq!(url_host("about:blank"), None);
    }
}
