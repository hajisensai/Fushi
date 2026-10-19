//! 网页广告 / 跟踪拦截的「胖核心」：订阅状态、列表缓存（ETag / Last-Modified / 过期判定）、
//! 引擎编译与序列化缓存、白名单全部由这里持有并落盘；Dart 只做两件事——按 [`AdblockCore::begin_sync`]
//! 给的清单联网取字节（必须走 app 的全局代理），以及渲染 [`AdblockCore::snapshot`]。
//!
//! 磁盘布局（`dir` 由 Dart 传入）：
//! - `state.json`：订阅集、总开关、白名单原文、每份列表的缓存元数据；
//! - `lists/<id>.txt`：列表原始字节（下载原样落盘）；
//! - `engine/<key>.dat`：序列化引擎；`engine/<key>.cb.json`：WebKit 内容拦截规则（只在需要的平台生成）。
//!   `key` 由本库版本 + 每份在用列表的 id / 长度 / 内容哈希算出，任一变化即换键重编，旧件随即清掉。

pub mod allowlist;
pub mod catalog;
pub mod content_blocking;
pub mod ffi;

use std::collections::{BTreeMap, VecDeque};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, RwLock};
use std::time::{SystemTime, UNIX_EPOCH};

use adblock::lists::{FilterSet, ParseOptions};
use adblock::request::Request;
use adblock::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// 列表距上次成功核对超过这么久才联网（毫秒）。
pub const MAX_AGE_MS: i64 = 4 * 24 * 60 * 60 * 1000;

/// `check` 返回码：放行（没命中 / 总开关关 / 白名单 / 引擎未就绪 / 被 `@@` 例外抵消）。
pub const CHECK_ALLOW: i32 = 0;
/// 拦截。
pub const CHECK_BLOCK: i32 = 1;
/// 命中拦截规则但被 `@@` 例外规则抵消（放行；单独给出只为统计 / 调试）。
pub const CHECK_EXCEPTION: i32 = 3;
/// 参数无效（URL 解析失败等）：按放行处理。
pub const CHECK_ERROR: i32 = -1;

/// 请求类型码 → adblock-rust 的资源类型名（与 Dart `AdblockRequestType.code` 一一对应）。
pub fn request_type_name(code: u8) -> &'static str {
    match code {
        1 => "document",
        2 => "subdocument",
        3 => "script",
        4 => "image",
        5 => "stylesheet",
        6 => "xmlhttprequest",
        7 => "font",
        8 => "media",
        9 => "websocket",
        10 => "ping",
        _ => "other",
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ListResult {
    /// 缓存未过期，直接用。
    Cache,
    /// 下载了新内容。
    Downloaded,
    /// 服务器回 304，缓存续期。
    NotModified,
    /// 联网失败，退回过期缓存。
    StaleCache,
    /// 联网失败且没有缓存：本次缺席。
    Missing,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ListMeta {
    /// 最近一次**成功核对**（200 新内容或 304 未变）的时刻；过期判断以它为准。
    fetched_at: Option<i64>,
    /// 最近一次尝试联网的时刻（成功失败都算）。
    checked_at: Option<i64>,
    byte_length: u64,
    rule_count: u64,
    content_hash: Option<String>,
    etag: Option<String>,
    last_modified: Option<String>,
    last_result: Option<ListResult>,
    last_error: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Persisted {
    #[serde(default = "default_true")]
    enabled: bool,
    #[serde(default = "catalog::default_selection")]
    selected: Vec<String>,
    #[serde(default)]
    allowlist: String,
    #[serde(default)]
    lists: BTreeMap<String, ListMeta>,
}

fn default_true() -> bool {
    true
}

impl Default for Persisted {
    fn default() -> Self {
        Self {
            enabled: true,
            selected: catalog::default_selection(),
            allowlist: String::new(),
            lists: BTreeMap::new(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum EngineStatus {
    Idle,
    Loading,
    Ready,
    Failed,
}

impl EngineStatus {
    fn wire(self) -> &'static str {
        match self {
            EngineStatus::Idle => "idle",
            EngineStatus::Loading => "loading",
            EngineStatus::Ready => "ready",
            EngineStatus::Failed => "failed",
        }
    }
}

struct CoreState {
    persisted: Persisted,
    status: EngineStatus,
    error: Option<String>,
    engine_key: Option<String>,
    from_cache: bool,
    built_at: Option<i64>,
    syncing: bool,
    sync_forced: bool,
    sync_planned: Vec<String>,
    last_sync_ok: Option<bool>,
}

/// 逐请求热路径读的设置（与 `CoreState.persisted` 同步更新，单独一把读写锁不和冷路径抢）。
struct HotSettings {
    enabled: bool,
    allowlist: Vec<String>,
}

struct LoadedEngine {
    engine: Engine,
}

/// 一个数据目录一个核心；全应用共用一份（引擎几 MB）。`Send + Sync`：Dart 侧把句柄地址带进
/// 后台 isolate 调慢命令（编译），主 isolate 同时可以照常 check。
pub struct AdblockCore {
    dir: PathBuf,
    want_content_blocking: bool,
    clock: fn() -> i64,
    state: Mutex<CoreState>,
    hot: RwLock<HotSettings>,
    engine: RwLock<Option<Arc<LoadedEngine>>>,
    /// href → 该页 cosmetic 例外集（generic 选择器要扣掉它们）；最多 16 条。
    exceptions: Mutex<VecDeque<(String, Vec<String>)>>,
}

fn system_clock() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// 粗判下载内容确实是过滤列表（防代理 / 门户页返回 HTML 被当规则吃进去）。
fn looks_like_filter_list(body: &[u8]) -> bool {
    let head = &body[..body.len().min(2048)];
    let text = String::from_utf8_lossy(head);
    let trimmed = text.trim_start().to_ascii_lowercase();
    if trimmed.starts_with("<!doctype") || trimmed.starts_with("<html") {
        return false;
    }
    body.iter().any(|b| !b.is_ascii_whitespace())
}

/// 规则行数：非空、非 `!` 注释、非 `[Adblock Plus x.y]` 头。
fn count_rules(body: &[u8]) -> u64 {
    body.split(|b| *b == b'\n')
        .filter(|line| {
            let line = line.trim_ascii();
            !line.is_empty() && line[0] != b'!' && line[0] != b'['
        })
        .count() as u64
}

/// FNV-1a 64（稳定、跨平台；只作缓存键，不防碰撞攻击）。
fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        hash ^= *b as u64;
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    hash
}

fn write_atomic(target: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp = target.with_extension(format!(
        "{}.tmp",
        target.extension().and_then(|e| e.to_str()).unwrap_or("")
    ));
    fs::write(&tmp, bytes)?;
    fs::rename(&tmp, target)
}

impl AdblockCore {
    /// 打开（或首次创建）`dir` 下的状态。很快：只读 `state.json`，不编译引擎。
    /// `want_content_blocking`：本平台要不要 WebKit 内容拦截规则（iOS / macOS）。
    pub fn open(dir: PathBuf, want_content_blocking: bool) -> Self {
        Self::open_with_clock(dir, want_content_blocking, system_clock)
    }

    pub fn open_with_clock(dir: PathBuf, want_content_blocking: bool, clock: fn() -> i64) -> Self {
        let persisted: Persisted = fs::read(dir.join("state.json"))
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        let hot = HotSettings {
            enabled: persisted.enabled,
            allowlist: allowlist::parse(&persisted.allowlist),
        };
        Self {
            dir,
            want_content_blocking,
            clock,
            state: Mutex::new(CoreState {
                persisted,
                status: EngineStatus::Idle,
                error: None,
                engine_key: None,
                from_cache: false,
                built_at: None,
                syncing: false,
                sync_forced: false,
                sync_planned: Vec::new(),
                last_sync_ok: None,
            }),
            hot: RwLock::new(hot),
            engine: RwLock::new(None),
            exceptions: Mutex::new(VecDeque::new()),
        }
    }

    fn lock(&self) -> MutexGuard<'_, CoreState> {
        self.state.lock().unwrap_or_else(|p| p.into_inner())
    }

    fn list_path(&self, id: &str) -> PathBuf {
        self.dir.join("lists").join(format!("{id}.txt"))
    }

    fn engine_dir(&self) -> PathBuf {
        self.dir.join("engine")
    }

    fn persist(&self, st: &CoreState) {
        if let Ok(bytes) = serde_json::to_vec_pretty(&st.persisted) {
            let _ = write_atomic(&self.dir.join("state.json"), &bytes);
        }
    }

    fn sync_hot(&self, st: &CoreState) {
        if let Ok(mut hot) = self.hot.write() {
            hot.enabled = st.persisted.enabled;
            hot.allowlist = allowlist::parse(&st.persisted.allowlist);
        }
    }

    // ------------------------------------------------------------------ 设置命令

    pub fn set_enabled(&self, enabled: bool) -> Value {
        let mut st = self.lock();
        st.persisted.enabled = enabled;
        self.persist(&st);
        self.sync_hot(&st);
        self.snapshot_locked(&st)
    }

    /// 订阅 / 取消订阅一份目录里的列表（未知 id 忽略）。取消订阅时清掉它的磁盘缓存。
    /// 只改订阅集，不联网也不重编：调用方随后发起一次同步。
    pub fn set_list_enabled(&self, id: &str, enabled: bool) -> Value {
        let mut st = self.lock();
        if catalog::find(id).is_some() {
            let currently = st.persisted.selected.iter().any(|s| s == id);
            if enabled && !currently {
                st.persisted.selected.push(id.to_string());
            } else if !enabled && currently {
                st.persisted.selected.retain(|s| s != id);
                st.persisted.lists.remove(id);
                let _ = fs::remove_file(self.list_path(id));
            }
            // 目录顺序就是编译顺序与缓存键顺序。
            let order = |s: &String| catalog::CATALOG.iter().position(|l| l.id == s);
            st.persisted.selected.sort_by_key(order);
            self.persist(&st);
        }
        self.snapshot_locked(&st)
    }

    pub fn set_allowlist(&self, raw: &str) -> Value {
        let mut st = self.lock();
        st.persisted.allowlist = raw.trim().to_string();
        self.persist(&st);
        self.sync_hot(&st);
        self.snapshot_locked(&st)
    }

    // ------------------------------------------------------------------ 同步：计划 → 取字节 → 收字节 → 收尾

    fn has_cache(&self, st: &CoreState, id: &str) -> bool {
        st.persisted
            .lists
            .get(id)
            .is_some_and(|m| m.fetched_at.is_some() && m.content_hash.is_some())
            && self.list_path(id).is_file()
    }

    fn is_stale(&self, st: &CoreState, id: &str, now: i64) -> bool {
        if !self.has_cache(st, id) {
            return true;
        }
        let fetched = st
            .persisted
            .lists
            .get(id)
            .and_then(|m| m.fetched_at)
            .unwrap_or(0);
        now - fetched >= MAX_AGE_MS
    }

    /// 现有缓存下、当前订阅集对应的引擎缓存键；一份可用列表都没有时 None。
    fn engine_key(&self, st: &CoreState) -> Option<(String, Vec<String>)> {
        let mut sb = format!("v{}", env!("CARGO_PKG_VERSION"));
        let mut present = Vec::new();
        for id in &st.persisted.selected {
            if !self.has_cache(st, id) {
                continue;
            }
            let meta = &st.persisted.lists[id];
            sb.push_str(&format!(
                "|{id}:{}:{}",
                meta.byte_length,
                meta.content_hash.as_deref().unwrap_or("")
            ));
            present.push(id.clone());
        }
        if present.is_empty() {
            None
        } else {
            Some((format!("{:016x}", fnv1a64(sb.as_bytes())), present))
        }
    }

    /// 开始一次同步。返回 `{"run":bool,"fetch":[{"id","url","etag","lastModified"}]}`：
    /// `run` 为 false 时什么也不用做（总开关关着 / 已有同步在跑 / 缓存都新鲜且引擎已是最新）；
    /// 否则逐条联网（带条件请求头），每条结果交给 [`Self::ingest`]，最后调 [`Self::finish_sync`]。
    /// `force`：「立即更新」，不看过期时间、全部订阅列表都核对一遍。
    pub fn begin_sync(&self, force: bool) -> Value {
        let now = (self.clock)();
        let mut st = self.lock();
        if !st.persisted.enabled || st.syncing {
            return json!({ "run": false, "fetch": [] });
        }
        let selected = st.persisted.selected.clone();
        let mut fetch = Vec::new();
        let mut planned = Vec::new();
        for id in &selected {
            let Some(list) = catalog::find(id) else {
                continue;
            };
            if force || self.is_stale(&st, id, now) {
                let meta = st.persisted.lists.get(id).cloned().unwrap_or_default();
                let cached = self.has_cache(&st, id);
                fetch.push(json!({
                    "id": list.id,
                    "url": list.url,
                    "etag": if cached { meta.etag } else { None },
                    "lastModified": if cached { meta.last_modified } else { None },
                }));
                planned.push(id.clone());
            } else if let Some(meta) = st.persisted.lists.get_mut(id) {
                meta.last_result = Some(ListResult::Cache);
            }
        }
        let current_key = self.engine_key(&st).map(|(k, _)| k);
        let needs_rebuild = current_key != st.engine_key
            || (current_key.is_some() && st.status != EngineStatus::Ready);
        if fetch.is_empty() && !needs_rebuild {
            if st.status != EngineStatus::Ready && current_key.is_none() {
                st.status = if selected.is_empty() {
                    EngineStatus::Idle
                } else {
                    EngineStatus::Failed
                };
            }
            return json!({ "run": false, "fetch": [] });
        }
        st.syncing = true;
        st.sync_forced = force;
        st.sync_planned = planned;
        st.status = EngineStatus::Loading;
        json!({ "run": true, "fetch": fetch })
    }

    /// 交回一份列表的联网结果。`status`：HTTP 状态码，联网失败（超时 / DNS / 代理）传 0 并在
    /// `error` 里给原因；`body` 是原始字节（不解码、不转字符串）。不在本次计划里的 id 忽略。
    pub fn ingest(
        &self,
        id: &str,
        status: i32,
        body: &[u8],
        etag: Option<&str>,
        last_modified: Option<&str>,
        error: Option<&str>,
    ) -> Result<(), String> {
        let now = (self.clock)();
        let mut st = self.lock();
        if !st.syncing || !st.sync_planned.iter().any(|p| p == id) {
            return Err(format!("{id} is not part of the current sync"));
        }
        let cached = self.has_cache(&st, id);
        let mut meta = st.persisted.lists.get(id).cloned().unwrap_or_default();
        meta.checked_at = Some(now);
        if status == 304 && cached {
            meta.fetched_at = Some(now);
            meta.last_result = Some(ListResult::NotModified);
            meta.last_error = None;
        } else if status == 200 && looks_like_filter_list(body) {
            match write_atomic(&self.list_path(id), body) {
                Ok(()) => {
                    meta.fetched_at = Some(now);
                    meta.byte_length = body.len() as u64;
                    meta.rule_count = count_rules(body);
                    meta.content_hash = Some(format!("{:016x}", fnv1a64(body)));
                    meta.etag = etag.filter(|s| !s.is_empty()).map(str::to_string);
                    meta.last_modified =
                        last_modified.filter(|s| !s.is_empty()).map(str::to_string);
                    meta.last_result = Some(ListResult::Downloaded);
                    meta.last_error = None;
                }
                Err(e) => {
                    meta.last_error = Some(format!("write failed: {e}"));
                    meta.last_result = Some(if cached {
                        ListResult::StaleCache
                    } else {
                        ListResult::Missing
                    });
                }
            }
        } else {
            let reason = match error.filter(|e| !e.is_empty()) {
                Some(e) => e.to_string(),
                None if status == 200 => "response is not a filter list".to_string(),
                None => format!("HTTP {status}"),
            };
            meta.last_error = Some(reason);
            meta.last_result = Some(if cached {
                ListResult::StaleCache
            } else {
                ListResult::Missing
            });
        }
        st.persisted.lists.insert(id.to_string(), meta);
        self.persist(&st);
        Ok(())
    }

    /// 收尾：按现有缓存把引擎调到最新（键没变什么也不做；有序列化缓存就反序列化；否则编译并
    /// 落盘）。**慢**（冷编译 ~100 ms 级）：Dart 侧在后台 isolate 调。返回最新快照。
    pub fn finish_sync(&self) -> Value {
        let (key_and_present, forced, planned) = {
            let st = self.lock();
            if !st.syncing {
                return self.snapshot_locked(&st);
            }
            (
                self.engine_key(&st),
                st.sync_forced,
                st.sync_planned.clone(),
            )
        };
        let outcome = match &key_and_present {
            None => Ok(None),
            Some((key, present)) => {
                let same = self.lock().engine_key.as_deref() == Some(key.as_str())
                    && self.engine.read().map(|e| e.is_some()).unwrap_or(false);
                if same {
                    Ok(Some((key.clone(), None)))
                } else {
                    self.load_engine_isolated(key, present)
                        .map(|r| Some((key.clone(), Some(r))))
                }
            }
        };
        let now = (self.clock)();
        let mut st = self.lock();
        match outcome {
            Ok(Some((key, loaded))) => {
                if let Some((engine, from_cache)) = loaded {
                    if let Ok(mut slot) = self.engine.write() {
                        *slot = Some(Arc::new(LoadedEngine { engine }));
                    }
                    if let Ok(mut ex) = self.exceptions.lock() {
                        ex.clear();
                    }
                    st.from_cache = from_cache;
                    st.built_at = Some(now);
                }
                st.engine_key = Some(key);
                st.status = EngineStatus::Ready;
                st.error = None;
            }
            Ok(None) => {
                // 一份可用列表都没有（离线首装 / 全部取消订阅）。
                if let Ok(mut slot) = self.engine.write() {
                    *slot = None;
                }
                st.engine_key = None;
                st.status = if st.persisted.selected.is_empty() {
                    EngineStatus::Idle
                } else {
                    EngineStatus::Failed
                };
                st.error = if st.persisted.selected.is_empty() {
                    None
                } else {
                    Some("no filter list is available".into())
                };
            }
            Err(e) => {
                // 旧引擎（若有）保留。
                let has_engine = self.engine.read().map(|e| e.is_some()).unwrap_or(false);
                st.status = if has_engine {
                    EngineStatus::Ready
                } else {
                    EngineStatus::Failed
                };
                st.error = Some(e);
            }
        }
        st.last_sync_ok = Some(if forced {
            planned.iter().any(|id| {
                matches!(
                    st.persisted.lists.get(id).and_then(|m| m.last_result),
                    Some(ListResult::Downloaded | ListResult::NotModified)
                )
            })
        } else {
            st.status == EngineStatus::Ready
        });
        st.syncing = false;
        st.sync_planned.clear();
        self.persist(&st);
        self.snapshot_locked(&st)
    }

    /// [`Self::load_engine`] 的 panic 隔离版：第三方 adblock 的反序列化 / 编译若 panic，按
    /// 普通失败（`Err`）走 [`Self::finish_sync`] 的收尾，`syncing` 照常复位——否则 FFI 边界的
    /// `catch_unwind` 虽拦住了 panic，同步状态却永远卡在「加载中」。磁盘上这把键的缓存件可能
    /// 正是 panic 的来源，一并删掉，下次冷编译而不是每次启动都复现。
    fn load_engine_isolated(
        &self,
        key: &str,
        present: &[String],
    ) -> Result<(Engine, bool), String> {
        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            self.load_engine(key, present)
        })) {
            Ok(result) => result,
            Err(_) => {
                let engine_dir = self.engine_dir();
                let _ = fs::remove_file(engine_dir.join(format!("{key}.dat")));
                let _ = fs::remove_file(engine_dir.join(format!("{key}.cb.json")));
                Err("filter engine build panicked".into())
            }
        }
    }

    /// 反序列化缓存或编译；需要时补出 WebKit 规则。返回 (引擎, 是否来自缓存)。
    fn load_engine(&self, key: &str, present: &[String]) -> Result<(Engine, bool), String> {
        let engine_dir = self.engine_dir();
        let engine_file = engine_dir.join(format!("{key}.dat"));
        let rules_file = engine_dir.join(format!("{key}.cb.json"));
        let mut texts: Option<Vec<String>> = None;
        let read_texts = || -> Result<Vec<String>, String> {
            present
                .iter()
                .map(|id| {
                    fs::read(self.list_path(id))
                        .map(|b| String::from_utf8_lossy(&b).into_owned())
                        .map_err(|e| format!("read {id}: {e}"))
                })
                .collect()
        };

        let mut from_cache = false;
        let mut engine = None;
        if let Ok(bytes) = fs::read(&engine_file) {
            let mut e = Engine::default();
            if e.deserialize(&bytes).is_ok() {
                engine = Some(e);
                from_cache = true;
            } else {
                let _ = fs::remove_file(&engine_file);
            }
        }
        let engine = match engine {
            Some(e) => e,
            None => {
                let t = read_texts()?;
                let mut set = FilterSet::new(false);
                for text in &t {
                    set.add_filter_list(text.clone(), ParseOptions::default());
                }
                let e = Engine::new_with_filter_set(set);
                write_atomic(&engine_file, &e.serialize())
                    .map_err(|err| format!("write engine cache: {err}"))?;
                texts = Some(t);
                e
            }
        };
        if self.want_content_blocking && !rules_file.is_file() {
            let t = match texts.take() {
                Some(t) => t,
                None => read_texts()?,
            };
            let rules = content_blocking::export(&t, content_blocking::MAX_CONTENT_BLOCKERS)?;
            let bytes = serde_json::to_vec(&rules).map_err(|e| e.to_string())?;
            write_atomic(&rules_file, &bytes).map_err(|err| format!("write rules: {err}"))?;
        }
        // 只留这一把键的件。
        if let Ok(entries) = fs::read_dir(&engine_dir) {
            for entry in entries.flatten() {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                if !name.starts_with(&format!("{key}.")) {
                    let _ = fs::remove_file(entry.path());
                }
            }
        }
        Ok((engine, from_cache))
    }

    // ------------------------------------------------------------------ 热路径

    fn active_engine(&self, page_url: &str) -> Option<Arc<LoadedEngine>> {
        {
            let hot = self.hot.read().ok()?;
            if !hot.enabled {
                return None;
            }
            if !hot.allowlist.is_empty() {
                if let Some(host) = allowlist::url_host(page_url) {
                    if allowlist::matches(&host, &hot.allowlist) {
                        return None;
                    }
                }
            }
        }
        self.engine.read().ok()?.clone()
    }

    /// 逐请求判定。`source_url` 空 = 与 `url` 同源；`page_url` 是顶层页面（白名单按它判）。
    pub fn check(&self, url: &str, source_url: &str, page_url: &str, request_type: u8) -> i32 {
        let Some(loaded) = self.active_engine(page_url) else {
            return CHECK_ALLOW;
        };
        let source = if source_url.is_empty() {
            url
        } else {
            source_url
        };
        match Request::new(url, source, request_type_name(request_type), "get") {
            Ok(request) => {
                let r = loaded.engine.check_network_request(&request);
                if r.should_block() {
                    // 没加载 `$redirect` 资源：redirect 规则一律退化为普通拦截。
                    CHECK_BLOCK
                } else if r.filter.is_some() && r.exception.is_some() {
                    CHECK_EXCEPTION
                } else {
                    CHECK_ALLOW
                }
            }
            Err(_) => CHECK_ERROR,
        }
    }

    fn remember_exceptions(&self, href: &str, exceptions: Vec<String>) {
        if let Ok(mut cache) = self.exceptions.lock() {
            cache.retain(|(h, _)| h != href);
            if cache.len() >= 16 {
                cache.pop_front();
            }
            cache.push_back((href.to_string(), exceptions));
        }
    }

    /// 页面级 cosmetic 资源，直接是交给页内 JS 的 JSON 载荷：
    /// `{"hideSelectors":[..],"injectedScript":"..","generichide":b}`；未激活 / 白名单返回空。
    pub fn cosmetic(&self, href: &str, page_url: &str) -> Vec<u8> {
        let Some(loaded) = self.active_engine(if page_url.is_empty() { href } else { page_url })
        else {
            return Vec::new();
        };
        let r = loaded.engine.url_cosmetic_resources(href);
        let mut hide: Vec<String> = r.hide_selectors.into_iter().collect();
        hide.sort();
        let mut exceptions: Vec<String> = r.exceptions.into_iter().collect();
        exceptions.sort();
        self.remember_exceptions(href, exceptions);
        serde_json::to_vec(&json!({
            "hideSelectors": hide,
            "injectedScript": r.injected_script,
            "generichide": r.generichide,
        }))
        .unwrap_or_default()
    }

    /// 通用（generic）hide 选择器：页面上出现的 class / id（各自换行分隔）命中的通用规则，扣掉该页
    /// 例外。返回交给页内 JS 的 JSON 数组；未激活 / 白名单返回空。
    pub fn generic(&self, href: &str, page_url: &str, classes: &str, ids: &str) -> Vec<u8> {
        let Some(loaded) = self.active_engine(if page_url.is_empty() { href } else { page_url })
        else {
            return Vec::new();
        };
        let cached = self
            .exceptions
            .lock()
            .ok()
            .and_then(|c| c.iter().find(|(h, _)| h == href).map(|(_, ex)| ex.clone()));
        let exceptions = match cached {
            Some(ex) => ex,
            None => {
                let ex: Vec<String> = loaded
                    .engine
                    .url_cosmetic_resources(href)
                    .exceptions
                    .into_iter()
                    .collect();
                self.remember_exceptions(href, ex.clone());
                ex
            }
        };
        let split = |s: &str| -> Vec<String> {
            s.split('\n')
                .filter(|t| !t.is_empty())
                .map(str::to_string)
                .collect()
        };
        let ex: std::collections::HashSet<String> = exceptions.into_iter().collect();
        let mut v = loaded
            .engine
            .hidden_class_id_selectors(split(classes), split(ids), &ex);
        v.sort();
        v.dedup();
        serde_json::to_vec(&v).unwrap_or_default()
    }

    /// 当前引擎对应的 WebKit 内容拦截规则 JSON（已筛选、已截断）；没有就空。
    pub fn content_blockers(&self) -> Vec<u8> {
        if !self.want_content_blocking {
            return Vec::new();
        }
        let key = self.lock().engine_key.clone();
        match key {
            Some(key) => {
                fs::read(self.engine_dir().join(format!("{key}.cb.json"))).unwrap_or_default()
            }
            None => Vec::new(),
        }
    }

    // ------------------------------------------------------------------ 快照

    pub fn snapshot(&self) -> Value {
        let st = self.lock();
        self.snapshot_locked(&st)
    }

    fn snapshot_locked(&self, st: &CoreState) -> Value {
        let now = (self.clock)();
        let mut rule_count = 0u64;
        let mut last_updated: Option<i64> = None;
        let lists: Vec<Value> = catalog::CATALOG
            .iter()
            .map(|l| {
                let enabled = st.persisted.selected.iter().any(|s| s == l.id);
                let meta = st.persisted.lists.get(l.id).cloned().unwrap_or_default();
                let cached = self.has_cache(st, l.id);
                if enabled && cached {
                    rule_count += meta.rule_count;
                    if let Some(at) = meta.fetched_at {
                        last_updated = Some(last_updated.map_or(at, |p| p.max(at)));
                    }
                }
                json!({
                    "id": l.id,
                    "title": l.title,
                    "url": l.url,
                    "host": allowlist::url_host(l.url),
                    "enabled": enabled,
                    "cached": cached,
                    "stale": self.is_stale(st, l.id, now),
                    "fetchedAt": meta.fetched_at,
                    "checkedAt": meta.checked_at,
                    "byteLength": meta.byte_length,
                    "ruleCount": meta.rule_count,
                    "lastResult": meta.last_result,
                    "lastError": meta.last_error,
                })
            })
            .collect();
        json!({
            "version": env!("CARGO_PKG_VERSION"),
            "enabled": st.persisted.enabled,
            "allowlist": st.persisted.allowlist,
            "allowlistHosts": allowlist::parse(&st.persisted.allowlist),
            "status": st.status.wire(),
            "error": st.error,
            "syncing": st.syncing,
            "ruleCount": if st.engine_key.is_some() { rule_count } else { 0 },
            "fromCache": st.from_cache,
            "builtAt": st.built_at,
            "lastUpdatedAt": last_updated,
            "lastSyncOk": st.last_sync_ok,
            "lists": lists,
        })
    }
}

#[cfg(test)]
mod tests;
