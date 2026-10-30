//! 插件清单 `manifest.json` 的解析与校验（契约见 docs/specs/2026-10-28-music-plugins.md §2）。

use serde::{Deserialize, Serialize};

/// 宿主支持的插件 API 版本。清单 `api` 大于它的插件拒装。
pub const HOST_API_VERSION: u32 = 1;

/// 已知能力名：每个能力对应入口模块导出的同名函数。
pub const KNOWN_CAPABILITIES: &[&str] = &[
    "search",
    "album",
    "playlist",
    "artist",
    "stream",
    "lyrics",
    "login",
    "account",
    "home",
    "library",
    "artistAlbums",
    "artistMvs",
    "mvStream",
    "searchBest",
    "like",
];

/// 已知权限名。
pub const KNOWN_PERMISSIONS: &[&str] = &[
    "network",
    "storage",
    "credentials",
    "webAuth",
    "insecureHttp",
];

pub const KNOWN_SEARCH_TYPES: &[&str] = &["song", "album", "artist", "playlist"];

const KNOWN_METHODS: &[&str] = &["GET", "POST", "HEAD", "PUT", "DELETE", "PATCH"];

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct NetworkGrant {
    #[serde(default)]
    pub domains: Vec<String>,
    #[serde(default)]
    pub methods: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Manifest {
    pub schema: u32,
    pub id: String,
    pub name: String,
    pub version: String,
    pub api: u32,
    pub entry: String,
    #[serde(default)]
    pub author: Option<String>,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub homepage: Option<String>,
    #[serde(default)]
    pub capabilities: Vec<String>,
    #[serde(default)]
    pub search_types: Vec<String>,
    #[serde(default)]
    pub permissions: Vec<String>,
    #[serde(default)]
    pub network: NetworkGrant,
}

impl Manifest {
    pub fn parse(bytes: &[u8]) -> Result<Manifest, String> {
        let m: Manifest =
            serde_json::from_slice(bytes).map_err(|e| format!("manifest.json 解析失败：{e}"))?;
        m.validate()?;
        Ok(m)
    }

    pub fn has_permission(&self, p: &str) -> bool {
        self.permissions.iter().any(|x| x == p)
    }

    fn validate(&self) -> Result<(), String> {
        if self.schema != 1 {
            return Err(format!("不支持的清单 schema {}", self.schema));
        }
        if !valid_id(&self.id) {
            return Err(format!(
                "插件 id 不合法：{:?}（只允许 a-z0-9 . _ -，2–64 字符）",
                self.id
            ));
        }
        if self.name.trim().is_empty() || self.name.chars().count() > 64 {
            return Err("插件名称为空或超过 64 字符".into());
        }
        if !valid_version(&self.version) {
            return Err(format!("版本号不合法：{:?}（要求 X.Y.Z）", self.version));
        }
        if self.api == 0 || self.api > HOST_API_VERSION {
            return Err(format!(
                "插件要求 API {}，宿主只支持到 {HOST_API_VERSION}",
                self.api
            ));
        }
        crate::plugin::package::check_rel_path(&self.entry)?;
        if !self.entry.ends_with(".js") {
            return Err("entry 必须是 .js 文件".into());
        }
        check_known("能力", &self.capabilities, KNOWN_CAPABILITIES)?;
        check_known("权限", &self.permissions, KNOWN_PERMISSIONS)?;
        check_known("搜索类型", &self.search_types, KNOWN_SEARCH_TYPES)?;
        if self.capabilities.is_empty() {
            return Err("插件没有声明任何能力".into());
        }
        if self.capabilities.iter().any(|c| c == "search") && self.search_types.is_empty() {
            return Err("声明了 search 能力却没有 searchTypes".into());
        }
        let wants_network = !self.network.domains.is_empty();
        if wants_network != self.has_permission("network") {
            return Err("network 权限与 network.domains 必须同时声明".into());
        }
        if self.has_permission("insecureHttp") && !wants_network {
            return Err("insecureHttp 权限需要 network 权限".into());
        }
        if self.has_permission("webAuth") && !wants_network {
            return Err("webAuth 权限需要 network 权限（登录页必须在网络授权内）".into());
        }
        let has_cap = |c: &str| self.capabilities.iter().any(|x| x == c);
        if (has_cap("login") || has_cap("account")) && !self.has_permission("credentials") {
            return Err("login / account 能力需要 credentials 权限".into());
        }
        if has_cap("login") != has_cap("account") {
            return Err("login 与 account 能力必须同时声明".into());
        }
        if has_cap("library") && !has_cap("account") {
            return Err("library 能力需要同时声明 login / account（我的歌单属于登录账号）".into());
        }
        if (has_cap("artistAlbums") || has_cap("artistMvs")) && !has_cap("artist") {
            return Err("artistAlbums / artistMvs 能力需要同时声明 artist".into());
        }
        if has_cap("artistMvs") && !has_cap("mvStream") {
            return Err("artistMvs 能力需要同时声明 mvStream（列出的 MV 必须能播放）".into());
        }
        if has_cap("searchBest") && !has_cap("search") {
            return Err("searchBest 能力需要同时声明 search".into());
        }
        if has_cap("like") && !has_cap("account") {
            return Err("like 能力需要同时声明 login / account（喜欢的音乐属于登录账号）".into());
        }
        if self.network.domains.len() > 32 {
            return Err("network.domains 超过 32 条".into());
        }
        for d in &self.network.domains {
            crate::plugin::policy::validate_domain_rule(d)?;
        }
        for m in &self.network.methods {
            if !KNOWN_METHODS.contains(&m.as_str()) {
                return Err(format!("未知 HTTP 方法 {m:?}"));
            }
        }
        Ok(())
    }
}

fn check_known(label: &str, values: &[String], known: &[&str]) -> Result<(), String> {
    for v in values {
        if !known.contains(&v.as_str()) {
            return Err(format!("未知{label} {v:?}"));
        }
    }
    let mut sorted: Vec<&String> = values.iter().collect();
    sorted.sort();
    sorted.dedup();
    if sorted.len() != values.len() {
        return Err(format!("{label}有重复项"));
    }
    Ok(())
}

/// 插件 id：2..=64 字节，`[a-z0-9._-]`，首尾必须是字母或数字、不得有连续的点。id 直接作目录名：
/// Windows 会把结尾的点规范化掉（`foo.` ≡ `foo`），连续点在部分文件系统上也有特殊含义。
pub fn valid_id(id: &str) -> bool {
    let n = id.len();
    let alnum = |b: u8| b.is_ascii_lowercase() || b.is_ascii_digit();
    (2..=64).contains(&n)
        && id.bytes().next().is_some_and(alnum)
        && id.bytes().last().is_some_and(alnum)
        && !id.contains("..")
        && id
            .bytes()
            .all(|b| alnum(b) || b == b'.' || b == b'_' || b == b'-')
}

fn valid_version(v: &str) -> bool {
    let parts: Vec<&str> = v.split('.').collect();
    parts.len() == 3
        && parts
            .iter()
            .all(|p| !p.is_empty() && p.len() <= 6 && p.bytes().all(|b| b.is_ascii_digit()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base() -> serde_json::Value {
        serde_json::json!({
            "schema": 1, "id": "moe.example", "name": "Example", "version": "1.0.0", "api": 1,
            "entry": "main.js", "capabilities": ["search", "lyrics"], "searchTypes": ["song"],
            "permissions": ["network"], "network": {"domains": ["api.example.com", "*.cdn.example.com"], "methods": ["GET"]}
        })
    }

    #[test]
    fn accepts_valid() {
        let m = Manifest::parse(base().to_string().as_bytes()).unwrap();
        assert_eq!(m.id, "moe.example");
    }

    #[test]
    fn id_shape() {
        for ok in ["moe.test", "a1", "x-y_z.q9"] {
            assert!(valid_id(ok), "{ok}");
        }
        // 结尾的点（Windows 规范化成另一个 id 的目录）、连续点、首尾非字母数字一律拒。
        for bad in ["foo.", "foo..bar", ".foo", "-foo", "foo-", "foo_", "a", "Foo"] {
            assert!(!valid_id(bad), "{bad}");
        }
    }

    #[test]
    fn rejects_bad_fields() {
        for (k, v) in [
            ("id", serde_json::json!("Bad ID")),
            ("version", serde_json::json!("1.0")),
            ("api", serde_json::json!(99)),
            ("entry", serde_json::json!("../main.js")),
            ("capabilities", serde_json::json!(["teleport"])),
            ("permissions", serde_json::json!([])),
        ] {
            let mut j = base();
            j[k] = v;
            assert!(
                Manifest::parse(j.to_string().as_bytes()).is_err(),
                "{k} should fail"
            );
        }
        let mut j = base();
        j["capabilities"] = serde_json::json!(["search", "home", "library"]);
        assert!(
            Manifest::parse(j.to_string().as_bytes()).is_err(),
            "library 需要 account"
        );
        j["capabilities"] = serde_json::json!(["search", "home"]);
        assert!(
            Manifest::parse(j.to_string().as_bytes()).is_ok(),
            "home 单独声明可以"
        );
        j["capabilities"] = serde_json::json!(["search", "artistAlbums"]);
        assert!(
            Manifest::parse(j.to_string().as_bytes()).is_err(),
            "artistAlbums 需要 artist"
        );
        j["capabilities"] = serde_json::json!(["search", "artist", "artistMvs"]);
        assert!(
            Manifest::parse(j.to_string().as_bytes()).is_err(),
            "artistMvs 需要 mvStream"
        );
        j["capabilities"] =
            serde_json::json!(["search", "artist", "artistAlbums", "artistMvs", "mvStream"]);
        assert!(
            Manifest::parse(j.to_string().as_bytes()).is_ok(),
            "艺人分页与 MV 能力"
        );
        j["capabilities"] = serde_json::json!(["search", "mvStream"]);
        assert!(
            Manifest::parse(j.to_string().as_bytes()).is_ok(),
            "mvStream 可单独声明（曲目 mvId 用）"
        );
        j["capabilities"] = serde_json::json!(["lyrics", "searchBest"]);
        assert!(
            Manifest::parse(j.to_string().as_bytes()).is_err(),
            "searchBest 需要 search"
        );
        j["capabilities"] = serde_json::json!(["search", "searchBest"]);
        assert!(
            Manifest::parse(j.to_string().as_bytes()).is_ok(),
            "searchBest 随 search 声明"
        );
        j["capabilities"] = serde_json::json!(["search", "like"]);
        assert!(
            Manifest::parse(j.to_string().as_bytes()).is_err(),
            "like 需要 account"
        );
        j["capabilities"] = serde_json::json!(["search", "login", "account", "like"]);
        j["permissions"] = serde_json::json!(["network", "credentials"]);
        assert!(
            Manifest::parse(j.to_string().as_bytes()).is_ok(),
            "like 随登录能力声明"
        );
        let mut j = base();
        j["unknownField"] = serde_json::json!(1);
        assert!(Manifest::parse(j.to_string().as_bytes()).is_err());
    }
}
