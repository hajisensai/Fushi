//! fushi_web_core：Brave `adblock` crate（adblock-rust，MPL-2.0）上的薄 C ABI，给 Dart FFI
//! （`packages/fushi_web_core`，纯 Dart）用。app 内所有网页浏览场景（InAppWebView）共用一个引擎。
//!
//! 约定（与 native/fushi_p2p 一致）：
//! - 符号前缀 `fwc_`；永不 panic 过 FFI 边界（每个导出函数都包 `catch_unwind`，`panic = "unwind"`）。
//! - 返回的 `char*` 一律由调用方用 `fwc_string_free` 释放（`fwc_version` 是静态串除外）；
//!   返回的字节缓冲用 `fwc_bytes_free(ptr, len)` 释放。
//! - 创建 / 反序列化失败返回 NULL，原因用 `fwc_last_error()` 取（线程局部）。
//! - 引擎是 `Send + Sync`（关掉了 adblock 的 `single-thread` 特性，正则缓存走 Mutex），
//!   Dart 侧 isolate 换 OS 线程调用也安全；`fwc_engine_free` 之后句柄不可再用。
//! - 复杂返回值是 JSON；热路径 `fwc_engine_check` 只返回整数码，不分配。

use std::cell::RefCell;
use std::collections::HashSet;
use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

use adblock::lists::{FilterSet, ParseOptions};
use adblock::request::Request;
use adblock::resources::Resource;
use adblock::Engine;
use serde_json::{json, Value};

/// `fwc_engine_check` 返回码：没有任何规则命中（放行）。
pub const FWC_ALLOW: i32 = 0;
/// 命中拦截规则且没有被例外规则抵消（拦截）。
pub const FWC_BLOCK: i32 = 1;
/// 拦截，且规则带 `$redirect`：应以替身资源（`fwc_engine_check_json` 的 `redirect`）应答。
pub const FWC_REDIRECT: i32 = 2;
/// 命中拦截规则但被 `@@` 例外规则抵消（放行）。
pub const FWC_EXCEPTION: i32 = 3;
/// 参数无效（NULL / 非 UTF-8 / URL 解析失败）：调用方按放行处理。
pub const FWC_ERROR: i32 = -1;

thread_local! {
    static LAST_ERROR: RefCell<Option<String>> = const { RefCell::new(None) };
}

fn set_last_error(msg: String) {
    LAST_ERROR.with(|e| *e.borrow_mut() = Some(msg));
}

fn clear_last_error() {
    LAST_ERROR.with(|e| *e.borrow_mut() = None);
}

fn panic_message(p: Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = p.downcast_ref::<&str>() {
        format!("panic: {s}")
    } else if let Some(s) = p.downcast_ref::<String>() {
        format!("panic: {s}")
    } else {
        "panic".to_string()
    }
}

fn into_c_string(s: String) -> *mut c_char {
    // 内嵌 NUL 不可能出现在 JSON / CSS 选择器里；真出现就去掉而不是丢整串。
    match CString::new(s) {
        Ok(c) => c.into_raw(),
        Err(e) => {
            let mut bytes = e.into_vec();
            bytes.retain(|b| *b != 0);
            CString::new(bytes)
                .map(CString::into_raw)
                .unwrap_or(std::ptr::null_mut())
        }
    }
}

fn json_out(v: Value) -> *mut c_char {
    into_c_string(v.to_string())
}

fn json_err(msg: String) -> *mut c_char {
    json_out(json!({ "ok": false, "error": msg }))
}

/// 把 `f` 的结果 JSON 化；panic 与 Err 都落成 `{"ok":false,"error":...}`。
fn guard_json(f: impl FnOnce() -> Result<Value, String>) -> *mut c_char {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(v)) => json_out(v),
        Ok(Err(e)) => json_err(e),
        Err(p) => json_err(panic_message(p)),
    }
}

unsafe fn req_str<'a>(p: *const c_char, name: &str) -> Result<&'a str, String> {
    if p.is_null() {
        return Err(format!("{name} is NULL"));
    }
    CStr::from_ptr(p)
        .to_str()
        .map_err(|_| format!("{name} is not valid UTF-8"))
}

unsafe fn opt_str<'a>(p: *const c_char) -> Result<Option<&'a str>, String> {
    if p.is_null() {
        return Ok(None);
    }
    CStr::from_ptr(p)
        .to_str()
        .map(Some)
        .map_err(|_| "argument is not valid UTF-8".to_string())
}

unsafe fn engine_ref<'a>(e: *const Engine) -> Result<&'a Engine, String> {
    e.as_ref().ok_or_else(|| "null engine handle".to_string())
}

unsafe fn list_texts(texts: *const *const c_char, count: usize) -> Result<Vec<String>, String> {
    if count == 0 {
        return Ok(Vec::new());
    }
    if texts.is_null() {
        return Err("filter list array is NULL".into());
    }
    let mut out = Vec::with_capacity(count);
    for i in 0..count {
        let p = *texts.add(i);
        out.push(req_str(p, "filter list text")?.to_owned());
    }
    Ok(out)
}

fn filter_set_from(texts: Vec<String>, debug: bool) -> FilterSet {
    let mut set = FilterSet::new(debug);
    for text in texts {
        set.add_filter_list(text, ParseOptions::default());
    }
    set
}

// ---------------------------------------------------------------------------------------------
// 纯 Rust 核心（单测直接打这一层；C ABI 只做参数转换与 panic 隔离）
// ---------------------------------------------------------------------------------------------

/// 一次请求检查的完整结论（`fwc_engine_check_json` 的载荷）。
pub fn check_result(
    engine: &Engine,
    url: &str,
    source_url: &str,
    request_type: &str,
) -> Result<Value, String> {
    let source = if source_url.is_empty() {
        url
    } else {
        source_url
    };
    let request =
        Request::new(url, source, request_type, "get").map_err(|e| format!("bad request: {e}"))?;
    let r = engine.check_network_request(&request);
    let code = classify(
        r.should_block(),
        r.redirect.is_some(),
        r.filter.is_some(),
        r.exception.is_some(),
    );
    Ok(json!({
        "ok": true,
        "code": code,
        "blocked": r.should_block(),
        "matched": r.filter.is_some(),
        "exception": r.exception.is_some(),
        "important": r.important,
        "redirect": r.redirect,
        "rewrittenUrl": r.rewritten_url,
        "filter": r.filter.map(|f| f.to_string()),
        "exceptionFilter": r.exception.map(|f| f.to_string()),
    }))
}

fn classify(blocked: bool, redirect: bool, matched: bool, excepted: bool) -> i32 {
    if blocked {
        if redirect {
            FWC_REDIRECT
        } else {
            FWC_BLOCK
        }
    } else if matched && excepted {
        FWC_EXCEPTION
    } else {
        FWC_ALLOW
    }
}

/// 热路径整数码。
pub fn check_code(engine: &Engine, url: &str, source_url: &str, request_type: &str) -> i32 {
    let source = if source_url.is_empty() {
        url
    } else {
        source_url
    };
    match Request::new(url, source, request_type, "get") {
        Ok(request) => {
            let r = engine.check_network_request(&request);
            classify(
                r.should_block(),
                r.redirect.is_some(),
                r.filter.is_some(),
                r.exception.is_some(),
            )
        }
        Err(_) => FWC_ERROR,
    }
}

fn sorted(set: HashSet<String>) -> Vec<String> {
    let mut v: Vec<String> = set.into_iter().collect();
    v.sort();
    v
}

/// 页面级 cosmetic 资源：站点专属 hide 选择器 + 注入脚本 + 例外集 + generichide 标志。
pub fn cosmetic_result(engine: &Engine, url: &str) -> Value {
    let r = engine.url_cosmetic_resources(url);
    json!({
        "ok": true,
        "hideSelectors": sorted(r.hide_selectors),
        "proceduralActions": sorted(r.procedural_actions),
        "exceptions": sorted(r.exceptions),
        "injectedScript": r.injected_script,
        "generichide": r.generichide,
    })
}

/// 通用（generic）hide 选择器：页面上出现的 class / id 命中的通用规则，扣掉例外。
pub fn generic_selectors(
    engine: &Engine,
    classes: &[String],
    ids: &[String],
    exceptions: &[String],
) -> Vec<String> {
    let exceptions: HashSet<String> = exceptions.iter().cloned().collect();
    let mut v = engine.hidden_class_id_selectors(classes, ids, &exceptions);
    v.sort();
    v.dedup();
    v
}

/// 过滤列表 → Apple WKContentRuleList JSON（`[{"trigger":...,"action":...}, ...]`）。
/// 给不能逐请求拦截的平台（iOS / macOS WKWebView）当 contentBlockers 用。
pub fn content_blocking_rules(texts: Vec<String>) -> Result<Value, String> {
    let set = filter_set_from(texts, true);
    let (mut rules, used) = set
        .into_content_blocking()
        .map_err(|_| "content blocking conversion failed".to_string())?;
    if !rules.is_empty() {
        // ABP 语义：顶层文档请求默认不拦；内容拦截格式表达不了，按上游建议追加这条例外。
        rules.push(adblock::content_blocking::ignore_previous_fp_documents());
    }
    let rules_json = serde_json::to_value(&rules).map_err(|e| e.to_string())?;
    Ok(json!({ "ok": true, "rules": rules_json, "convertedFilterCount": used.len() }))
}

fn parse_string_array(p: *const c_char, name: &str) -> Result<Vec<String>, String> {
    let s = unsafe { opt_str(p)? };
    match s {
        None | Some("") => Ok(Vec::new()),
        Some(s) => serde_json::from_str::<Vec<String>>(s).map_err(|e| format!("{name}: {e}")),
    }
}

// ---------------------------------------------------------------------------------------------
// C ABI
// ---------------------------------------------------------------------------------------------

/// 库版本（静态字符串，不要 free）。
#[no_mangle]
pub extern "C" fn fwc_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
}

/// 释放本库返回的任意 `char*`。NULL 为 no-op。
///
/// # Safety
/// `s` 必须是本库返回、尚未释放的指针。
#[no_mangle]
pub unsafe extern "C" fn fwc_string_free(s: *mut c_char) {
    if !s.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(CString::from_raw(s))));
    }
}

/// 释放 `fwc_engine_serialize` 返回的缓冲。NULL 为 no-op。
///
/// # Safety
/// `ptr` / `len` 必须原样来自 `fwc_engine_serialize`。
#[no_mangle]
pub unsafe extern "C" fn fwc_bytes_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| {
            drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)));
        }));
    }
}

/// 本线程最近一次创建 / 反序列化失败的原因；无则 NULL。调用方 free。
#[no_mangle]
pub extern "C" fn fwc_last_error() -> *mut c_char {
    catch_unwind(|| LAST_ERROR.with(|e| e.borrow().clone()))
        .ok()
        .flatten()
        .map(into_c_string)
        .unwrap_or(std::ptr::null_mut())
}

/// 从 `count` 份过滤列表文本（ABP / uBO 语法，UTF-8）编译引擎。失败返回 NULL。
/// 编译大列表（EasyList 级）要几百毫秒，Dart 侧放后台 isolate，结果用 serialize 落盘缓存。
///
/// # Safety
/// `texts` 指向 `count` 个以 NUL 结尾的 UTF-8 字符串。
#[no_mangle]
pub unsafe extern "C" fn fwc_engine_create(
    texts: *const *const c_char,
    count: usize,
) -> *mut Engine {
    clear_last_error();
    let r = catch_unwind(AssertUnwindSafe(|| -> Result<Engine, String> {
        let texts = list_texts(texts, count)?;
        Ok(Engine::new_with_filter_set(filter_set_from(texts, false)))
    }));
    match r {
        Ok(Ok(e)) => Box::into_raw(Box::new(e)),
        Ok(Err(msg)) => {
            set_last_error(msg);
            std::ptr::null_mut()
        }
        Err(p) => {
            set_last_error(panic_message(p));
            std::ptr::null_mut()
        }
    }
}

/// 从 `fwc_engine_serialize` 的产物恢复引擎（格式版本不符 / 数据损坏 → NULL）。
///
/// # Safety
/// `data` 指向 `len` 个可读字节。
#[no_mangle]
pub unsafe extern "C" fn fwc_engine_deserialize(data: *const u8, len: usize) -> *mut Engine {
    clear_last_error();
    let r = catch_unwind(AssertUnwindSafe(|| -> Result<Engine, String> {
        if data.is_null() || len == 0 {
            return Err("serialized engine is empty".into());
        }
        let bytes = std::slice::from_raw_parts(data, len);
        let mut engine = Engine::default();
        engine
            .deserialize(bytes)
            .map_err(|e| format!("deserialize failed: {e:?}"))?;
        Ok(engine)
    }));
    match r {
        Ok(Ok(e)) => Box::into_raw(Box::new(e)),
        Ok(Err(msg)) => {
            set_last_error(msg);
            std::ptr::null_mut()
        }
        Err(p) => {
            set_last_error(panic_message(p));
            std::ptr::null_mut()
        }
    }
}

/// 序列化引擎；`*out_len` 写入长度。失败返回 NULL。结果用 `fwc_bytes_free(ptr, len)` 释放。
///
/// # Safety
/// `e` 是有效引擎句柄，`out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn fwc_engine_serialize(e: *const Engine, out_len: *mut usize) -> *mut u8 {
    if out_len.is_null() {
        return std::ptr::null_mut();
    }
    *out_len = 0;
    let r = catch_unwind(AssertUnwindSafe(|| -> Result<Vec<u8>, String> {
        Ok(engine_ref(e)?.serialize())
    }));
    match r {
        Ok(Ok(bytes)) => {
            let boxed = bytes.into_boxed_slice();
            *out_len = boxed.len();
            Box::into_raw(boxed) as *mut u8
        }
        _ => std::ptr::null_mut(),
    }
}

/// 释放引擎。NULL 为 no-op。
///
/// # Safety
/// `e` 必须是本库返回、尚未释放的引擎句柄。
#[no_mangle]
pub unsafe extern "C" fn fwc_engine_free(e: *mut Engine) {
    if !e.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(e))));
    }
}

/// 加载 `$redirect` 替身 / `##+js()` scriptlet 资源（uBO `resources` 的 adblock-rust JSON 形态：
/// `[{"name":..,"aliases":[..],"kind":{"mime":..}|"template",..,"content":"<base64>"}]`）。
/// 返回 `{"ok":true,"count":N}`；没加载资源时 redirect 规则只会退化为普通拦截、scriptlet 为空。
///
/// # Safety
/// `e` 是有效引擎句柄，`resources_json` 是 NUL 结尾 UTF-8。
#[no_mangle]
pub unsafe extern "C" fn fwc_engine_use_resources(
    e: *mut Engine,
    resources_json: *const c_char,
) -> *mut c_char {
    guard_json(|| {
        let engine = e.as_mut().ok_or_else(|| "null engine handle".to_string())?;
        let text = req_str(resources_json, "resources_json")?;
        let resources: Vec<Resource> =
            serde_json::from_str(text).map_err(|e| format!("resources_json: {e}"))?;
        let count = resources.len();
        engine.use_resources(resources);
        Ok(json!({ "ok": true, "count": count }))
    })
}

/// 热路径：检查一个子资源请求。返回 `FWC_ALLOW` / `FWC_BLOCK` / `FWC_REDIRECT` /
/// `FWC_EXCEPTION` / `FWC_ERROR`。`source_url` NULL 或空 = 与 `url` 同源（第一方）。
/// `request_type` 用 adblock 的资源类型名：`document` / `subdocument` / `script` / `image` /
/// `stylesheet` / `xmlhttprequest` / `font` / `media` / `websocket` / `ping` / `other` 等。
///
/// # Safety
/// 字符串参数为 NUL 结尾 UTF-8（`source_url` 可为 NULL）。
#[no_mangle]
pub unsafe extern "C" fn fwc_engine_check(
    e: *const Engine,
    url: *const c_char,
    source_url: *const c_char,
    request_type: *const c_char,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| -> i32 {
        let Ok(engine) = engine_ref(e) else {
            return FWC_ERROR;
        };
        let Ok(url) = req_str(url, "url") else {
            return FWC_ERROR;
        };
        let Ok(source) = opt_str(source_url) else {
            return FWC_ERROR;
        };
        let request_type = match opt_str(request_type) {
            Ok(Some(t)) if !t.is_empty() => t,
            Ok(_) => "other",
            Err(_) => return FWC_ERROR,
        };
        check_code(engine, url, source.unwrap_or(""), request_type)
    }))
    .unwrap_or(FWC_ERROR)
}

/// 同 `fwc_engine_check`，但返回完整 JSON：
/// `{"ok":true,"code":N,"blocked":b,"matched":b,"exception":b,"important":b,
///   "redirect":"data:..."|null,"rewrittenUrl":".."|null,"filter":..,"exceptionFilter":..}`。
///
/// # Safety
/// 同 `fwc_engine_check`。
#[no_mangle]
pub unsafe extern "C" fn fwc_engine_check_json(
    e: *const Engine,
    url: *const c_char,
    source_url: *const c_char,
    request_type: *const c_char,
) -> *mut c_char {
    guard_json(|| {
        let engine = engine_ref(e)?;
        let url = req_str(url, "url")?;
        let source = opt_str(source_url)?.unwrap_or("");
        let request_type = match opt_str(request_type)? {
            Some(t) if !t.is_empty() => t,
            _ => "other",
        };
        check_result(engine, url, source, request_type)
    })
}

/// 页面级 cosmetic 资源 JSON：
/// `{"ok":true,"hideSelectors":[..],"proceduralActions":[..],"exceptions":[..],
///   "injectedScript":"..","generichide":b}`。
///
/// # Safety
/// `e` 有效，`url` 为 NUL 结尾 UTF-8。
#[no_mangle]
pub unsafe extern "C" fn fwc_engine_cosmetic(e: *const Engine, url: *const c_char) -> *mut c_char {
    guard_json(|| {
        let engine = engine_ref(e)?;
        let url = req_str(url, "url")?;
        Ok(cosmetic_result(engine, url))
    })
}

/// 通用 hide 选择器（按需取）：`classes_json` / `ids_json` / `exceptions_json` 都是字符串数组
/// JSON（NULL 视为空数组；exceptions 原样取自 `fwc_engine_cosmetic` 的 `exceptions`）。
/// 返回 `{"ok":true,"selectors":[..]}`。页面 `generichide` 为真时调用方不应再取。
///
/// # Safety
/// `e` 有效，字符串参数为 NUL 结尾 UTF-8 或 NULL。
#[no_mangle]
pub unsafe extern "C" fn fwc_engine_generic_selectors(
    e: *const Engine,
    classes_json: *const c_char,
    ids_json: *const c_char,
    exceptions_json: *const c_char,
) -> *mut c_char {
    guard_json(|| {
        let engine = engine_ref(e)?;
        let classes = parse_string_array(classes_json, "classes_json")?;
        let ids = parse_string_array(ids_json, "ids_json")?;
        let exceptions = parse_string_array(exceptions_json, "exceptions_json")?;
        Ok(
            json!({ "ok": true, "selectors": generic_selectors(engine, &classes, &ids, &exceptions) }),
        )
    })
}

/// 过滤列表 → Apple 内容拦截规则 JSON：`{"ok":true,"rules":[..],"convertedFilterCount":N}`。
/// 不需要引擎句柄（转换走 debug 模式的 FilterSet，与编译引擎是两条路径）。
///
/// # Safety
/// `texts` 指向 `count` 个以 NUL 结尾的 UTF-8 字符串。
#[no_mangle]
pub unsafe extern "C" fn fwc_content_blocking_rules(
    texts: *const *const c_char,
    count: usize,
) -> *mut c_char {
    guard_json(|| {
        let texts = list_texts(texts, count)?;
        content_blocking_rules(texts)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIST: &str = r#"
! Title: fushi test list
||ads.example.com^
||tracker.example.net^$third-party
/banner/*$image
@@||ads.example.com/allowed/*
||cdn.example.org/ad.js$script,redirect=noopjs
example.com##.ad-banner
example.com###sponsor
##.generic-ad
example.com#@#.generic-ad
"#;

    fn engine() -> Engine {
        Engine::new_with_filter_set(filter_set_from(vec![LIST.to_string()], false))
    }

    #[test]
    fn blocks_listed_domain() {
        let e = engine();
        assert_eq!(
            check_code(
                &e,
                "https://ads.example.com/x.js",
                "https://news.test/",
                "script"
            ),
            FWC_BLOCK
        );
        assert_eq!(
            check_code(
                &e,
                "https://ok.example.com/x.js",
                "https://news.test/",
                "script"
            ),
            FWC_ALLOW
        );
    }

    #[test]
    fn third_party_option_respected() {
        let e = engine();
        assert_eq!(
            check_code(
                &e,
                "https://tracker.example.net/p.gif",
                "https://news.test/",
                "image"
            ),
            FWC_BLOCK
        );
        // 第一方请求不受 $third-party 规则影响。
        assert_eq!(
            check_code(
                &e,
                "https://tracker.example.net/p.gif",
                "https://tracker.example.net/",
                "image"
            ),
            FWC_ALLOW
        );
    }

    #[test]
    fn request_type_option_respected() {
        let e = engine();
        assert_eq!(
            check_code(
                &e,
                "https://site.test/banner/a.png",
                "https://site.test/",
                "image"
            ),
            FWC_BLOCK
        );
        assert_eq!(
            check_code(
                &e,
                "https://site.test/banner/a.js",
                "https://site.test/",
                "script"
            ),
            FWC_ALLOW
        );
    }

    #[test]
    fn exception_rule_unblocks() {
        let e = engine();
        assert_eq!(
            check_code(
                &e,
                "https://ads.example.com/allowed/a.js",
                "https://news.test/",
                "script"
            ),
            FWC_EXCEPTION
        );
        let v = check_result(
            &e,
            "https://ads.example.com/allowed/a.js",
            "https://news.test/",
            "script",
        )
        .unwrap();
        assert_eq!(v["blocked"], false);
        assert_eq!(v["exception"], true);
        assert_eq!(v["matched"], true);
    }

    #[test]
    fn redirect_rule_without_resources_still_blocks() {
        let e = engine();
        // 没加载 noopjs 资源：redirect 规则退化为普通拦截。
        let code = check_code(
            &e,
            "https://cdn.example.org/ad.js",
            "https://news.test/",
            "script",
        );
        assert!(code == FWC_BLOCK || code == FWC_REDIRECT, "code={code}");
    }

    #[test]
    fn redirect_rule_with_resource_redirects() {
        let mut e = engine();
        let resources: Vec<Resource> = serde_json::from_value(json!([{
            "name": "noopjs",
            "aliases": ["noop.js"],
            "kind": { "mime": "application/javascript" },
            "content": "KGZ1bmN0aW9uKCkge30pKCk7"
        }]))
        .unwrap();
        e.use_resources(resources);
        assert_eq!(
            check_code(
                &e,
                "https://cdn.example.org/ad.js",
                "https://news.test/",
                "script"
            ),
            FWC_REDIRECT
        );
        let v = check_result(
            &e,
            "https://cdn.example.org/ad.js",
            "https://news.test/",
            "script",
        )
        .unwrap();
        assert!(v["redirect"]
            .as_str()
            .unwrap()
            .starts_with("data:application/javascript"));
    }

    #[test]
    fn bad_url_is_error_not_panic() {
        let e = engine();
        assert_eq!(check_code(&e, "not a url", "", "script"), FWC_ERROR);
    }

    #[test]
    fn cosmetic_site_specific_and_generic_exception() {
        let e = engine();
        let v = cosmetic_result(&e, "https://example.com/page");
        let hide: Vec<String> = serde_json::from_value(v["hideSelectors"].clone()).unwrap();
        assert!(hide.contains(&".ad-banner".to_string()), "{hide:?}");
        assert!(hide.contains(&"#sponsor".to_string()), "{hide:?}");
        let exceptions: Vec<String> = serde_json::from_value(v["exceptions"].clone()).unwrap();
        assert!(
            exceptions.contains(&".generic-ad".to_string()),
            "{exceptions:?}"
        );

        // 例外站点：generic 选择器被扣掉；其他站点：照常返回。
        let on_example = generic_selectors(&e, &["generic-ad".into()], &[], &exceptions);
        assert!(on_example.is_empty(), "{on_example:?}");
        let other = cosmetic_result(&e, "https://other.test/");
        let other_ex: Vec<String> = serde_json::from_value(other["exceptions"].clone()).unwrap();
        let on_other = generic_selectors(&e, &["generic-ad".into()], &[], &other_ex);
        assert_eq!(on_other, vec![".generic-ad".to_string()]);
        // 其他站点拿不到 example.com 专属选择器。
        let other_hide: Vec<String> =
            serde_json::from_value(other["hideSelectors"].clone()).unwrap();
        assert!(!other_hide.contains(&".ad-banner".to_string()));
    }

    #[test]
    fn serialize_roundtrip_preserves_behaviour() {
        let e = engine();
        let bytes = e.serialize();
        let mut restored = Engine::default();
        restored.deserialize(&bytes).unwrap();
        assert_eq!(
            check_code(
                &restored,
                "https://ads.example.com/x.js",
                "https://news.test/",
                "script"
            ),
            FWC_BLOCK
        );
        let v = cosmetic_result(&restored, "https://example.com/");
        assert!(v["hideSelectors"]
            .as_array()
            .unwrap()
            .iter()
            .any(|s| s == ".ad-banner"));
    }

    #[test]
    fn content_blocking_export_has_rules() {
        let v = content_blocking_rules(vec![LIST.to_string()]).unwrap();
        let rules = v["rules"].as_array().unwrap();
        assert!(!rules.is_empty());
        assert!(rules.iter().any(|r| r["action"]["type"] == "block"));
        assert!(rules
            .iter()
            .any(|r| r["action"]["type"] == "css-display-none"));
    }

    #[test]
    fn c_abi_roundtrip() {
        unsafe {
            let text = CString::new(LIST).unwrap();
            let arr = [text.as_ptr()];
            let e = fwc_engine_create(arr.as_ptr(), 1);
            assert!(!e.is_null());

            let url = CString::new("https://ads.example.com/x.js").unwrap();
            let src = CString::new("https://news.test/").unwrap();
            let ty = CString::new("script").unwrap();
            assert_eq!(
                fwc_engine_check(e, url.as_ptr(), src.as_ptr(), ty.as_ptr()),
                FWC_BLOCK
            );
            assert_eq!(
                fwc_engine_check(e, url.as_ptr(), std::ptr::null(), std::ptr::null()),
                FWC_BLOCK
            );
            assert_eq!(
                fwc_engine_check(std::ptr::null(), url.as_ptr(), src.as_ptr(), ty.as_ptr()),
                FWC_ERROR
            );

            let mut len = 0usize;
            let buf = fwc_engine_serialize(e, &mut len);
            assert!(!buf.is_null() && len > 0);
            let e2 = fwc_engine_deserialize(buf, len);
            assert!(!e2.is_null());
            fwc_bytes_free(buf, len);
            assert_eq!(
                fwc_engine_check(e2, url.as_ptr(), src.as_ptr(), ty.as_ptr()),
                FWC_BLOCK
            );

            let garbage = [1u8, 2, 3];
            let bad = fwc_engine_deserialize(garbage.as_ptr(), garbage.len());
            assert!(bad.is_null());
            let err = fwc_last_error();
            assert!(!err.is_null());
            fwc_string_free(err);

            let page = CString::new("https://example.com/").unwrap();
            let c = fwc_engine_cosmetic(e2, page.as_ptr());
            let s = CStr::from_ptr(c).to_str().unwrap().to_owned();
            fwc_string_free(c);
            let v: Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], true);

            let classes = CString::new(r#"["generic-ad"]"#).unwrap();
            let g = fwc_engine_generic_selectors(
                e2,
                classes.as_ptr(),
                std::ptr::null(),
                std::ptr::null(),
            );
            let gs = CStr::from_ptr(g).to_str().unwrap().to_owned();
            fwc_string_free(g);
            assert!(gs.contains(".generic-ad"), "{gs}");

            fwc_engine_free(e);
            fwc_engine_free(e2);
        }
    }
}
