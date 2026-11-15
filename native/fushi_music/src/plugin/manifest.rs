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
    "lyricsSearch",
    "lyricsFetch",
    "playlistEdit",
    "radio",
    "artistSimilar",
    "collect",
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

/// 插件种类（清单 `kind`）。缺省为 `music`：旧清单不带这个字段，一律按音乐插件对待。
/// 两种插件共用同一个沙箱引擎，但词汇（能力 / 权限）与宿主各自独立，互不可装
/// （docs/specs/2026-11-10-tracking-plugins.md）。
pub const KIND_MUSIC: &str = "music";
pub const KIND_TRACKING: &str = "tracking";

/// 追踪插件的已知能力名（`kind: "tracking"`）。
pub const KNOWN_TRACKING_CAPABILITIES: &[&str] = &[
    "login",
    "account",
    "trackingEntry",
    "trackingSubject",
    "trackingSearch",
    "trackingLookup",
    "trackingList",
];

/// 追踪插件必须声明的能力。
pub const REQUIRED_TRACKING_CAPABILITIES: &[&str] =
    &["login", "account", "trackingEntry", "trackingSubject"];

/// 追踪插件的已知权限名（不含 `webAuth` / `insecureHttp`）。
pub const KNOWN_TRACKING_PERMISSIONS: &[&str] = &["network", "storage", "credentials"];

/// 追踪插件必须声明的权限。
pub const REQUIRED_TRACKING_PERMISSIONS: &[&str] = &["network", "credentials"];

/// 追踪插件 `tracking.kinds` / `tracking.defaultKinds` 的已知值。
pub const KNOWN_TRACKING_KINDS: &[&str] = &["anime", "manga", "novel", "game"];

/// 追踪插件 `tracking.modes` 的已知值。
pub const KNOWN_TRACKING_MODES: &[&str] = &["episode", "chapter", "volume", "status"];

/// 追踪插件 `tracking.siteId` 不可使用的保留 id（宿主自己的 id 空间：MyAnimeList）。
/// `bangumi` 不在这里：随 app 内置的 Bangumi 插件要用它，由宿主按内置包摘要钉死
/// （docs/specs/2026-11-11-bangumi-bundled-plugin.md §3），其他包认领它一律不注册。
pub const RESERVED_TRACKING_SITE_IDS: &[&str] = &["mal"];

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct NetworkGrant {
    #[serde(default)]
    pub domains: Vec<String>,
    #[serde(default)]
    pub methods: Vec<String>,
}

/// 追踪插件的站点描述（清单 `tracking`，只在 `kind: "tracking"` 时出现）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TrackingSpec {
    pub site_id: String,
    pub site_host: String,
    pub kinds: Vec<String>,
    #[serde(default)]
    pub default_kinds: Vec<String>,
    pub modes: Vec<String>,
    pub requests_per_minute: u32,
    /// 条目网页地址模板（可选）：`https://`，含 `{id}`，可含 `{kind}`；主机须是 siteHost 或其子域。
    /// 也可按种类给（`{"anime": "...", "manga": "..."}`），没列的种类没有网页地址。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subject_url: Option<SubjectUrl>,
}

/// `tracking.subjectUrl` 的两种写法：一条模板，或按种类各一条（键须在 tracking.kinds 里）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum SubjectUrl {
    One(String),
    PerKind(std::collections::BTreeMap<String, String>),
}

fn default_kind() -> String {
    KIND_MUSIC.to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Manifest {
    pub schema: u32,
    /// 插件种类：缺省 `music`。序列化（交给 Dart 的摘要）时总是带上。
    #[serde(default = "default_kind")]
    pub kind: String,
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
    /// 追踪插件的站点描述；音乐插件不得带。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tracking: Option<TrackingSpec>,
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
        match self.kind.as_str() {
            KIND_MUSIC => self.validate_music()?,
            KIND_TRACKING => self.validate_tracking()?,
            other => {
                return Err(format!(
                    "未知插件种类 {other:?}（只允许 {KIND_MUSIC} / {KIND_TRACKING}）"
                ));
            }
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

    /// network 权限与网络授权的一致性（两种插件共用）。
    fn check_network_permissions(&self) -> Result<(), String> {
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
        Ok(())
    }

    /// 音乐插件（`kind` 缺省或 `music`）的词汇与能力依赖规则。
    fn validate_music(&self) -> Result<(), String> {
        if self.tracking.is_some() {
            return Err("音乐插件不能声明 tracking（只有 kind 为 tracking 的插件可以）".into());
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
        self.check_network_permissions()?;
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
        if has_cap("playlistEdit") && !(has_cap("account") && has_cap("playlist")) {
            return Err(
                "playlistEdit 能力需要同时声明 login / account 与 playlist（编辑的是登录账号的歌单）"
                    .into(),
            );
        }
        if has_cap("radio") && !has_cap("stream") {
            return Err("radio 能力需要同时声明 stream（电台给出的曲目必须能播放）".into());
        }
        if has_cap("artistSimilar") && !has_cap("artist") {
            return Err("artistSimilar 能力需要同时声明 artist".into());
        }
        if has_cap("collect") && !has_cap("account") {
            return Err("collect 能力需要同时声明 login / account（收藏属于登录账号）".into());
        }
        if has_cap("lyricsSearch") != has_cap("lyricsFetch") {
            return Err("lyricsSearch 与 lyricsFetch 能力必须同时声明".into());
        }
        Ok(())
    }

    /// 追踪插件（`kind: "tracking"`）的规则（docs/specs/2026-11-10-tracking-plugins.md §2）。
    fn validate_tracking(&self) -> Result<(), String> {
        check_known("能力", &self.capabilities, KNOWN_TRACKING_CAPABILITIES)?;
        for c in REQUIRED_TRACKING_CAPABILITIES {
            if !self.capabilities.iter().any(|x| x == c) {
                return Err(format!(
                    "追踪插件必须声明能力 {c}（login / account / trackingEntry / trackingSubject 缺一不可）"
                ));
            }
        }
        check_known("权限", &self.permissions, KNOWN_TRACKING_PERMISSIONS)?;
        for p in REQUIRED_TRACKING_PERMISSIONS {
            if !self.has_permission(p) {
                return Err(format!("追踪插件必须声明权限 {p}"));
            }
        }
        self.check_network_permissions()?;
        if !self.search_types.is_empty() {
            return Err("追踪插件不能声明 searchTypes".into());
        }
        let t = self
            .tracking
            .as_ref()
            .ok_or("追踪插件缺少 tracking 站点描述")?;
        if !valid_site_id(&t.site_id) {
            return Err(format!(
                "tracking.siteId 不合法：{:?}（只允许 a-z0-9，2–32 字符）",
                t.site_id
            ));
        }
        if RESERVED_TRACKING_SITE_IDS.contains(&t.site_id.as_str()) {
            return Err(format!("tracking.siteId 是保留 id：{:?}", t.site_id));
        }
        if t.site_host.starts_with("*.") {
            return Err(format!("tracking.siteHost 不能带通配符：{:?}", t.site_host));
        }
        crate::plugin::policy::validate_domain_rule(&t.site_host)
            .map_err(|_| format!("tracking.siteHost 不是主机名：{:?}", t.site_host))?;
        check_known("tracking.kinds 取值", &t.kinds, KNOWN_TRACKING_KINDS)?;
        if t.kinds.is_empty() {
            return Err("tracking.kinds 不能为空".into());
        }
        let kinds: Vec<&str> = t.kinds.iter().map(String::as_str).collect();
        check_known("tracking.defaultKinds 取值", &t.default_kinds, &kinds)
            .map_err(|e| format!("{e}（defaultKinds 必须是 kinds 的子集）"))?;
        check_known("tracking.modes 取值", &t.modes, KNOWN_TRACKING_MODES)?;
        if t.modes.is_empty() {
            return Err("tracking.modes 不能为空".into());
        }
        let has_game = t.kinds.iter().any(|k| k == "game");
        let has_status = t.modes.iter().any(|m| m == "status");
        if has_game != has_status {
            return Err("tracking.kinds 的 game 与 tracking.modes 的 status 必须同时声明".into());
        }
        match &t.subject_url {
            None => {}
            Some(SubjectUrl::One(url)) => check_subject_url(url, &t.site_host)?,
            Some(SubjectUrl::PerKind(map)) => {
                if map.is_empty() {
                    return Err("tracking.subjectUrl 按种类写时不能为空".into());
                }
                for (kind, url) in map {
                    if !t.kinds.iter().any(|k| k == kind) {
                        return Err(format!(
                            "tracking.subjectUrl 的种类 {kind:?} 不在 tracking.kinds 里"
                        ));
                    }
                    check_subject_url(url, &t.site_host)?;
                }
            }
        }
        if !(1..=600).contains(&t.requests_per_minute) {
            return Err(format!(
                "tracking.requestsPerMinute 必须在 1–600 之间（当前 {}）",
                t.requests_per_minute
            ));
        }
        Ok(())
    }
}

/// `tracking.subjectUrl`：`https://<主机>/…`，主机是 siteHost 或其子域，带 `{id}`，占位符只有
/// `{id}` / `{kind}`，不超过 300 字节。
fn check_subject_url(url: &str, site_host: &str) -> Result<(), String> {
    let bad = |why: &str| Err(format!("tracking.subjectUrl 不合法（{why}）：{url:?}"));
    if url.len() > 300 {
        return bad("超过 300 字节");
    }
    let Some(rest) = url.strip_prefix("https://") else {
        return bad("必须以 https:// 开头");
    };
    let host = rest.split(['/', '?', '#']).next().unwrap_or("");
    if host != site_host && !host.ends_with(&format!(".{site_host}")) {
        return bad("主机必须是 siteHost 或其子域");
    }
    if !url.contains("{id}") {
        return bad("缺少 {id}");
    }
    let stripped = url.replace("{id}", "").replace("{kind}", "");
    if stripped.contains('{') || stripped.contains('}') || host.contains('{') {
        return bad("只允许 {id} / {kind} 占位符，且不能出现在主机里");
    }
    if url.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return bad("含空白或控制字符");
    }
    Ok(())
}

/// 追踪站点 id：`[a-z0-9]{2,32}`（作为关联表里的 provider 落库）。
fn valid_site_id(id: &str) -> bool {
    (2..=32).contains(&id.len())
        && id
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
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
        for bad in [
            "foo.", "foo..bar", ".foo", "-foo", "foo-", "foo_", "a", "Foo",
        ] {
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
        // 编辑歌单 / 电台 / 相似艺人 / 收藏：各自的依赖缺一不可。
        for (caps, why) in [
            (
                serde_json::json!(["search", "login", "account", "playlistEdit"]),
                "playlistEdit 需要 playlist",
            ),
            (
                serde_json::json!(["search", "playlist", "playlistEdit"]),
                "playlistEdit 需要 account",
            ),
            (serde_json::json!(["search", "radio"]), "radio 需要 stream"),
            (
                serde_json::json!(["search", "artistSimilar"]),
                "artistSimilar 需要 artist",
            ),
            (
                serde_json::json!(["search", "collect"]),
                "collect 需要 account",
            ),
        ] {
            j["capabilities"] = caps;
            assert!(Manifest::parse(j.to_string().as_bytes()).is_err(), "{why}");
        }
        j["capabilities"] = serde_json::json!([
            "search",
            "login",
            "account",
            "playlist",
            "playlistEdit",
            "stream",
            "radio",
            "artist",
            "artistSimilar",
            "collect"
        ]);
        assert!(
            Manifest::parse(j.to_string().as_bytes()).is_ok(),
            "新能力随依赖声明"
        );
        // 歌词插件：lyricsSearch / lyricsFetch 成对声明，可以只声明这两个。
        for caps in [
            serde_json::json!(["lyricsSearch"]),
            serde_json::json!(["lyricsFetch"]),
            serde_json::json!(["search", "lyricsSearch"]),
        ] {
            j["capabilities"] = caps.clone();
            j["searchTypes"] = serde_json::json!(["song"]);
            assert!(
                Manifest::parse(j.to_string().as_bytes()).is_err(),
                "lyricsSearch / lyricsFetch 必须成对: {caps}"
            );
        }
        j["capabilities"] = serde_json::json!(["lyricsSearch", "lyricsFetch"]);
        j["searchTypes"] = serde_json::json!([]);
        assert!(
            Manifest::parse(j.to_string().as_bytes()).is_ok(),
            "纯歌词插件只声明这两个能力"
        );
        j["capabilities"] = serde_json::json!(["search", "lyricsSearch", "lyricsFetch"]);
        j["searchTypes"] = serde_json::json!(["song"]);
        assert!(
            Manifest::parse(j.to_string().as_bytes()).is_ok(),
            "歌词能力可与其他能力共存"
        );
        let mut j = base();
        j["unknownField"] = serde_json::json!(1);
        assert!(Manifest::parse(j.to_string().as_bytes()).is_err());
    }

    fn tracking_base() -> serde_json::Value {
        serde_json::json!({
            "schema": 1, "kind": "tracking", "id": "moe.example.tracking.site", "name": "Example",
            "version": "0.1.0", "api": 1, "entry": "main.js",
            "capabilities": ["login", "account", "trackingEntry", "trackingSubject", "trackingSearch", "trackingLookup"],
            "permissions": ["network", "credentials"],
            "network": {"domains": ["api.example.org"], "methods": ["GET", "POST"]},
            "tracking": {
                "siteId": "example", "siteHost": "example.org",
                "kinds": ["anime", "manga", "novel"], "defaultKinds": ["anime"],
                "modes": ["episode", "chapter", "volume"], "requestsPerMinute": 30
            }
        })
    }

    fn parse(j: &serde_json::Value) -> Result<Manifest, String> {
        Manifest::parse(j.to_string().as_bytes())
    }

    #[test]
    fn old_manifest_without_kind_is_music() {
        let m = parse(&base()).unwrap();
        assert_eq!(m.kind, KIND_MUSIC);
        assert!(m.tracking.is_none());
        // 交给 Dart 的序列化总带 kind，不带 tracking。
        let s = serde_json::to_value(&m).unwrap();
        assert_eq!(s["kind"], "music");
        assert!(s.get("tracking").is_none());
        let mut j = base();
        j["kind"] = serde_json::json!("music");
        assert_eq!(parse(&j).unwrap().kind, KIND_MUSIC);
    }

    #[test]
    fn unknown_kind_is_rejected() {
        for k in ["video", "", "Music", "TRACKING"] {
            let mut j = base();
            j["kind"] = serde_json::json!(k);
            assert!(parse(&j).is_err(), "{k}");
        }
        let mut j = base();
        j["kind"] = serde_json::json!(1);
        assert!(parse(&j).is_err());
    }

    #[test]
    fn music_manifest_with_tracking_is_rejected() {
        let mut j = base();
        j["tracking"] = tracking_base()["tracking"].clone();
        let e = parse(&j).unwrap_err();
        assert!(e.contains("tracking"), "{e}");
        j["kind"] = serde_json::json!("music");
        assert!(parse(&j).is_err());
    }

    #[test]
    fn accepts_valid_tracking() {
        let m = parse(&tracking_base()).unwrap();
        assert_eq!(m.kind, KIND_TRACKING);
        let t = m.tracking.as_ref().unwrap();
        assert_eq!(t.site_id, "example");
        assert_eq!(t.requests_per_minute, 30);
        let s = serde_json::to_value(&m).unwrap();
        assert_eq!(s["kind"], "tracking");
        assert_eq!(s["tracking"]["siteHost"], "example.org");
        assert_eq!(s["tracking"]["defaultKinds"], serde_json::json!(["anime"]));

        // 最小合法：只带四个必需能力、defaultKinds 缺省 / 为空、storage 可选、边界值。
        let mut j = tracking_base();
        j["capabilities"] =
            serde_json::json!(["login", "account", "trackingEntry", "trackingSubject"]);
        j["permissions"] = serde_json::json!(["network", "storage", "credentials"]);
        j["searchTypes"] = serde_json::json!([]);
        j["tracking"]
            .as_object_mut()
            .unwrap()
            .remove("defaultKinds");
        j["tracking"]["kinds"] = serde_json::json!(["manga"]);
        j["tracking"]["modes"] = serde_json::json!(["chapter"]);
        j["tracking"]["siteId"] = serde_json::json!("a1");
        j["tracking"]["siteHost"] = serde_json::json!("sub.example-site.co.jp");
        for rpm in [1, 600] {
            j["tracking"]["requestsPerMinute"] = serde_json::json!(rpm);
            let m = parse(&j).unwrap();
            assert!(m.tracking.unwrap().default_kinds.is_empty());
        }
        j["tracking"]["defaultKinds"] = serde_json::json!([]);
        assert!(parse(&j).is_ok());
        j["tracking"]["siteId"] = serde_json::json!("a".repeat(32));
        assert!(parse(&j).is_ok());
    }

    /// 保留的站点 id 被拒绝，普通 id 照常通过。
    #[test]
    fn tracking_reserved_site_ids_rejected() {
        let mut j = tracking_base();
        j["tracking"]["siteId"] = serde_json::json!("mal");
        let err = parse(&j).unwrap_err();
        assert!(err.contains("保留"), "{err}");
        // bangumi 由宿主按内置包摘要钉死，引擎不拒。
        for id in ["anilist", "bangumi"] {
            let mut j = tracking_base();
            j["tracking"]["siteId"] = serde_json::json!(id);
            assert!(parse(&j).is_ok(), "{id}");
        }
    }

    /// 可选扩展：game + status、trackingList、subjectUrl（docs/specs/2026-11-11-bangumi-bundled-plugin.md §2）。
    #[test]
    fn tracking_optional_extensions() {
        let mut j = tracking_base();
        j["capabilities"] = serde_json::json!([
            "login",
            "account",
            "trackingEntry",
            "trackingSubject",
            "trackingList"
        ]);
        j["tracking"]["kinds"] = serde_json::json!(["anime", "game"]);
        j["tracking"]["modes"] = serde_json::json!(["episode", "status"]);
        j["tracking"]["subjectUrl"] = serde_json::json!("https://example.org/subject/{id}");
        let m = parse(&j).unwrap();
        let s = serde_json::to_value(&m).unwrap();
        assert_eq!(s["tracking"]["subjectUrl"], "https://example.org/subject/{id}");
        j["tracking"]["subjectUrl"] = serde_json::json!("https://www.example.org/{kind}/{id}");
        assert!(parse(&j).is_ok());
        // 不带 subjectUrl 时序列化里也没有。
        let plain = serde_json::to_value(parse(&tracking_base()).unwrap()).unwrap();
        assert!(plain["tracking"].get("subjectUrl").is_none());
        // 按种类写：原样往返。
        let per_kind = serde_json::json!({
            "anime": "https://example.org/anime/{id}",
            "game": "https://www.example.org/{kind}/{id}"
        });
        j["tracking"]["subjectUrl"] = per_kind.clone();
        let s = serde_json::to_value(parse(&j).unwrap()).unwrap();
        assert_eq!(s["tracking"]["subjectUrl"], per_kind);

        for (kinds, modes) in [
            (serde_json::json!(["anime", "game"]), serde_json::json!(["episode"])),
            (serde_json::json!(["anime"]), serde_json::json!(["episode", "status"])),
        ] {
            let mut j = tracking_base();
            j["tracking"]["kinds"] = kinds;
            j["tracking"]["modes"] = modes;
            let e = parse(&j).unwrap_err();
            assert!(e.contains("game"), "{e}");
        }
        for url in [
            "http://example.org/subject/{id}",
            "https://evil.org/subject/{id}",
            "https://example.org.evil.org/{id}",
            "https://example.org/subject/",
            "https://example.org/{name}/{id}",
            "https://example.org/ {id}",
        ] {
            let mut j = tracking_base();
            j["tracking"]["subjectUrl"] = serde_json::json!(url);
            let e = parse(&j).unwrap_err();
            assert!(e.contains("subjectUrl"), "{url}: {e}");
            // 按种类写时每条模板同一规则。
            j["tracking"]["subjectUrl"] = serde_json::json!({ "anime": url });
            let e = parse(&j).unwrap_err();
            assert!(e.contains("subjectUrl"), "{url}: {e}");
        }
        for bad in [
            serde_json::json!({}),
            serde_json::json!({ "game": "https://example.org/game/{id}" }),
            serde_json::json!({ "music": "https://example.org/music/{id}" }),
            serde_json::json!({ "anime": 1 }),
            serde_json::json!(["https://example.org/{id}"]),
        ] {
            let mut j = tracking_base();
            j["tracking"]["subjectUrl"] = bad.clone();
            assert!(parse(&j).is_err(), "{bad}");
        }
    }

    /// 每条追踪规则各一个失败用例。
    #[test]
    fn tracking_rules_each_reject() {
        type Mutate = fn(&mut serde_json::Value);
        let cases: &[(&str, Mutate)] = &[
            ("音乐能力", |j| {
                j["capabilities"] = serde_json::json!([
                    "login",
                    "account",
                    "trackingEntry",
                    "trackingSubject",
                    "search"
                ])
            }),
            ("未知能力", |j| {
                j["capabilities"] = serde_json::json!([
                    "login",
                    "account",
                    "trackingEntry",
                    "trackingSubject",
                    "teleport"
                ])
            }),
            ("重复能力", |j| {
                j["capabilities"] = serde_json::json!([
                    "login",
                    "account",
                    "trackingEntry",
                    "trackingSubject",
                    "login"
                ])
            }),
            ("缺 login", |j| {
                j["capabilities"] =
                    serde_json::json!(["account", "trackingEntry", "trackingSubject"])
            }),
            ("缺 account", |j| {
                j["capabilities"] = serde_json::json!(["login", "trackingEntry", "trackingSubject"])
            }),
            ("缺 trackingEntry", |j| {
                j["capabilities"] = serde_json::json!(["login", "account", "trackingSubject"])
            }),
            ("缺 trackingSubject", |j| {
                j["capabilities"] = serde_json::json!(["login", "account", "trackingEntry"])
            }),
            ("缺 network 权限", |j| {
                j["permissions"] = serde_json::json!(["credentials"]);
                j["network"] = serde_json::json!({});
            }),
            ("缺 credentials 权限", |j| {
                j["permissions"] = serde_json::json!(["network"])
            }),
            ("webAuth", |j| {
                j["permissions"] = serde_json::json!(["network", "credentials", "webAuth"])
            }),
            ("insecureHttp", |j| {
                j["permissions"] = serde_json::json!(["network", "credentials", "insecureHttp"])
            }),
            ("重复权限", |j| {
                j["permissions"] = serde_json::json!(["network", "credentials", "network"])
            }),
            ("network 权限无域名", |j| {
                j["network"] = serde_json::json!({})
            }),
            ("searchTypes 非空", |j| {
                j["searchTypes"] = serde_json::json!(["song"])
            }),
            ("缺 tracking", |j| {
                j.as_object_mut().unwrap().remove("tracking");
            }),
            ("tracking 未知字段", |j| {
                j["tracking"]["extra"] = serde_json::json!(1)
            }),
            ("tracking 缺 siteId", |j| {
                j["tracking"].as_object_mut().unwrap().remove("siteId");
            }),
            ("siteId 过短", |j| {
                j["tracking"]["siteId"] = serde_json::json!("a")
            }),
            ("siteId 过长", |j| {
                j["tracking"]["siteId"] = serde_json::json!("a".repeat(33))
            }),
            ("siteId 大写", |j| {
                j["tracking"]["siteId"] = serde_json::json!("Example")
            }),
            ("siteId 带符号", |j| {
                j["tracking"]["siteId"] = serde_json::json!("ex-ample")
            }),
            ("siteHost 通配符", |j| {
                j["tracking"]["siteHost"] = serde_json::json!("*.example.org")
            }),
            ("siteHost 带 scheme", |j| {
                j["tracking"]["siteHost"] = serde_json::json!("https://example.org")
            }),
            ("siteHost 带路径", |j| {
                j["tracking"]["siteHost"] = serde_json::json!("example.org/x")
            }),
            ("siteHost 无点", |j| {
                j["tracking"]["siteHost"] = serde_json::json!("localhost")
            }),
            ("siteHost 大写", |j| {
                j["tracking"]["siteHost"] = serde_json::json!("Example.org")
            }),
            ("kinds 为空", |j| {
                j["tracking"]["kinds"] = serde_json::json!([]);
                j["tracking"]["defaultKinds"] = serde_json::json!([]);
            }),
            ("kinds 未知", |j| {
                j["tracking"]["kinds"] = serde_json::json!(["anime", "music"])
            }),
            ("kinds 重复", |j| {
                j["tracking"]["kinds"] = serde_json::json!(["anime", "anime"])
            }),
            ("defaultKinds 不在 kinds 里", |j| {
                j["tracking"]["kinds"] = serde_json::json!(["manga"]);
                j["tracking"]["defaultKinds"] = serde_json::json!(["anime"]);
            }),
            ("defaultKinds 重复", |j| {
                j["tracking"]["defaultKinds"] = serde_json::json!(["anime", "anime"])
            }),
            ("modes 为空", |j| {
                j["tracking"]["modes"] = serde_json::json!([])
            }),
            ("modes 未知", |j| {
                j["tracking"]["modes"] = serde_json::json!(["page"])
            }),
            ("modes 重复", |j| {
                j["tracking"]["modes"] = serde_json::json!(["episode", "episode"])
            }),
            ("requestsPerMinute 为 0", |j| {
                j["tracking"]["requestsPerMinute"] = serde_json::json!(0)
            }),
            ("requestsPerMinute 超过 600", |j| {
                j["tracking"]["requestsPerMinute"] = serde_json::json!(601)
            }),
            ("requestsPerMinute 缺失", |j| {
                j["tracking"]
                    .as_object_mut()
                    .unwrap()
                    .remove("requestsPerMinute");
            }),
            ("requestsPerMinute 负数", |j| {
                j["tracking"]["requestsPerMinute"] = serde_json::json!(-1)
            }),
        ];
        assert!(parse(&tracking_base()).is_ok());
        for (why, mutate) in cases {
            let mut j = tracking_base();
            mutate(&mut j);
            assert!(parse(&j).is_err(), "{why} should fail: {j}");
        }
    }
}
