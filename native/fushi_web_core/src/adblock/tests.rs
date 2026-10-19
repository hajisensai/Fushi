use std::cell::Cell;
use std::path::PathBuf;

use serde_json::Value;

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

thread_local! {
    static NOW: Cell<i64> = const { Cell::new(1_700_000_000_000) };
}

fn test_clock() -> i64 {
    NOW.with(Cell::get)
}

fn advance(ms: i64) {
    NOW.with(|n| n.set(n.get() + ms));
}

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let p = std::env::temp_dir().join(format!(
            "fwc_adblock_{tag}_{}_{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = fs::remove_dir_all(&p);
        fs::create_dir_all(&p).unwrap();
        TempDir(p)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn open(dir: &TempDir) -> AdblockCore {
    AdblockCore::open_with_clock(dir.0.clone(), false, test_clock)
}

/// 只订阅 easylist，并用 `body` 跑完一次同步。
fn sync_with(core: &AdblockCore, body: &str) -> Value {
    for l in catalog::CATALOG {
        core.set_list_enabled(l.id, l.id == "easylist");
    }
    let plan = core.begin_sync(false);
    assert_eq!(plan["run"], true, "{plan}");
    for item in plan["fetch"].as_array().unwrap() {
        core.ingest(
            item["id"].as_str().unwrap(),
            200,
            body.as_bytes(),
            Some("\"e1\""),
            None,
            None,
        )
        .unwrap();
    }
    core.finish_sync()
}

const PAGE: &str = "https://news.test/";
const SCRIPT: u8 = 3;
const IMAGE: u8 = 4;

#[test]
fn defaults_subscribe_whole_catalog_and_are_enabled() {
    let dir = TempDir::new("defaults");
    let core = open(&dir);
    let s = core.snapshot();
    assert_eq!(s["enabled"], true);
    assert_eq!(s["status"], "idle");
    assert_eq!(s["lists"].as_array().unwrap().len(), catalog::CATALOG.len());
    assert!(s["lists"]
        .as_array()
        .unwrap()
        .iter()
        .all(|l| l["enabled"] == true));
    // 引擎没就绪：一律放行。
    assert_eq!(
        core.check("https://ads.example.com/x.js", PAGE, PAGE, SCRIPT),
        CHECK_ALLOW
    );
}

#[test]
fn network_rules_behave_like_upstream() {
    let dir = TempDir::new("rules");
    let core = open(&dir);
    let s = sync_with(&core, LIST);
    assert_eq!(s["status"], "ready", "{s}");
    assert_eq!(s["fromCache"], false);
    assert!(s["ruleCount"].as_u64().unwrap() >= 9);
    let c = |u: &str, src: &str, t: u8| core.check(u, src, PAGE, t);
    assert_eq!(c("https://ads.example.com/x.js", PAGE, SCRIPT), CHECK_BLOCK);
    assert_eq!(c("https://ok.example.com/x.js", PAGE, SCRIPT), CHECK_ALLOW);
    // $third-party
    assert_eq!(
        c("https://tracker.example.net/p.gif", PAGE, IMAGE),
        CHECK_BLOCK
    );
    assert_eq!(
        c(
            "https://tracker.example.net/p.gif",
            "https://tracker.example.net/",
            IMAGE
        ),
        CHECK_ALLOW
    );
    // $image 类型限定
    assert_eq!(
        c(
            "https://site.test/banner/a.png",
            "https://site.test/",
            IMAGE
        ),
        CHECK_BLOCK
    );
    assert_eq!(
        c(
            "https://site.test/banner/a.js",
            "https://site.test/",
            SCRIPT
        ),
        CHECK_ALLOW
    );
    // @@ 例外
    assert_eq!(
        c("https://ads.example.com/allowed/a.js", PAGE, SCRIPT),
        CHECK_EXCEPTION
    );
    // 没加载 redirect 资源：退化为拦截
    assert_eq!(
        c("https://cdn.example.org/ad.js", PAGE, SCRIPT),
        CHECK_BLOCK
    );
    // 空 source = 同源
    assert_eq!(
        core.check("https://ads.example.com/x.js", "", "", SCRIPT),
        CHECK_BLOCK
    );
    assert_eq!(c("not a url", "", SCRIPT), CHECK_ERROR);
}

#[test]
fn switch_and_allowlist_apply_on_the_next_request() {
    let dir = TempDir::new("switch");
    let core = open(&dir);
    sync_with(&core, LIST);
    let ad = || core.check("https://ads.example.com/x.js", PAGE, PAGE, SCRIPT);
    assert_eq!(ad(), CHECK_BLOCK);
    let s = core.set_allowlist(" https://NEWS.test/path , foo.org ");
    assert_eq!(
        s["allowlistHosts"],
        serde_json::json!(["news.test", "foo.org"])
    );
    assert_eq!(ad(), CHECK_ALLOW);
    // 子域名页面同样放行；别的站照拦。
    assert_eq!(
        core.check(
            "https://ads.example.com/x.js",
            "",
            "https://m.news.test/a",
            SCRIPT
        ),
        CHECK_ALLOW
    );
    assert_eq!(
        core.check(
            "https://ads.example.com/x.js",
            "",
            "https://other.test/",
            SCRIPT
        ),
        CHECK_BLOCK
    );
    core.set_allowlist("");
    core.set_enabled(false);
    assert_eq!(ad(), CHECK_ALLOW);
    assert_eq!(
        core.begin_sync(false)["run"],
        false,
        "disabled: nothing to sync"
    );
    core.set_enabled(true);
    assert_eq!(ad(), CHECK_BLOCK);
}

#[test]
fn state_persists_and_engine_reloads_from_disk_cache() {
    let dir = TempDir::new("persist");
    {
        let core = open(&dir);
        sync_with(&core, LIST);
        core.set_allowlist("keep.test");
    }
    let core = open(&dir);
    let s = core.snapshot();
    assert_eq!(s["allowlist"], "keep.test");
    assert_eq!(s["status"], "idle", "engine is not loaded until a sync");
    let plan = core.begin_sync(false);
    assert_eq!(plan["run"], true);
    assert!(
        plan["fetch"].as_array().unwrap().is_empty(),
        "fresh cache: no network: {plan}"
    );
    let s = core.finish_sync();
    assert_eq!(s["status"], "ready");
    assert_eq!(s["fromCache"], true, "deserialized, not recompiled");
    assert_eq!(
        core.check("https://ads.example.com/x.js", PAGE, PAGE, SCRIPT),
        CHECK_BLOCK
    );
    // 引擎就绪且缓存新鲜：不再需要同步。
    assert_eq!(core.begin_sync(false)["run"], false);
}

#[test]
fn stale_lists_send_conditional_headers_and_304_renews() {
    let dir = TempDir::new("stale");
    let core = open(&dir);
    sync_with(&core, LIST);
    advance(MAX_AGE_MS - 1);
    assert_eq!(core.begin_sync(false)["run"], false, "not stale yet");
    advance(1);
    let plan = core.begin_sync(false);
    let item = &plan["fetch"][0];
    assert_eq!(item["id"], "easylist");
    assert_eq!(item["etag"], "\"e1\"");
    core.ingest("easylist", 304, &[], None, None, None).unwrap();
    let s = core.finish_sync();
    let l = &s["lists"][0];
    assert_eq!(l["lastResult"], "notModified");
    assert_eq!(l["stale"], false);
    assert_eq!(s["lastSyncOk"], true);
}

#[test]
fn offline_keeps_stale_cache_and_reports_missing_without_cache() {
    let dir = TempDir::new("offline");
    let core = open(&dir);
    sync_with(&core, LIST);
    // 再订阅一份从没下载过的。
    core.set_list_enabled("easyprivacy", true);
    let s = core.begin_sync(true);
    assert_eq!(s["fetch"].as_array().unwrap().len(), 2);
    core.ingest("easylist", 0, &[], None, None, Some("connection refused"))
        .unwrap();
    core.ingest("easyprivacy", 503, &[], None, None, None)
        .unwrap();
    let s = core.finish_sync();
    let by_id = |id: &str| {
        s["lists"]
            .as_array()
            .unwrap()
            .iter()
            .find(|l| l["id"] == id)
            .unwrap()
            .clone()
    };
    assert_eq!(by_id("easylist")["lastResult"], "staleCache");
    assert_eq!(by_id("easylist")["lastError"], "connection refused");
    assert_eq!(by_id("easyprivacy")["lastResult"], "missing");
    assert_eq!(by_id("easyprivacy")["lastError"], "HTTP 503");
    assert_eq!(s["status"], "ready", "old cache still compiles");
    assert_eq!(s["lastSyncOk"], false, "forced update fetched nothing new");
    assert_eq!(
        core.check("https://ads.example.com/x.js", PAGE, PAGE, SCRIPT),
        CHECK_BLOCK
    );
}

#[test]
fn first_install_offline_fails_then_recovers() {
    let dir = TempDir::new("first");
    let core = open(&dir);
    for l in catalog::CATALOG {
        core.set_list_enabled(l.id, l.id == "easylist");
    }
    core.begin_sync(false);
    core.ingest("easylist", 0, &[], None, None, Some("offline"))
        .unwrap();
    let s = core.finish_sync();
    assert_eq!(s["status"], "failed");
    assert_eq!(s["lastSyncOk"], false);
    let plan = core.begin_sync(false);
    assert_eq!(plan["run"], true, "missing cache is always stale");
    core.ingest("easylist", 200, LIST.as_bytes(), None, None, None)
        .unwrap();
    assert_eq!(core.finish_sync()["status"], "ready");
}

#[test]
fn html_portal_page_is_rejected() {
    let dir = TempDir::new("html");
    let core = open(&dir);
    for l in catalog::CATALOG {
        core.set_list_enabled(l.id, l.id == "easylist");
    }
    core.begin_sync(false);
    core.ingest(
        "easylist",
        200,
        b"  <!DOCTYPE html><html>captive portal</html>",
        None,
        None,
        None,
    )
    .unwrap();
    let s = core.finish_sync();
    assert_eq!(s["lists"][0]["lastResult"], "missing");
    assert_eq!(s["lists"][0]["lastError"], "response is not a filter list");
    assert_eq!(s["status"], "failed");
}

#[test]
fn unsubscribing_evicts_cache_and_rebuilds() {
    let dir = TempDir::new("evict");
    let core = open(&dir);
    sync_with(&core, LIST);
    assert!(dir.0.join("lists/easylist.txt").is_file());
    core.set_list_enabled("easylist", false);
    assert!(!dir.0.join("lists/easylist.txt").exists());
    let plan = core.begin_sync(false);
    assert_eq!(plan["run"], true, "engine must be dropped: {plan}");
    let s = core.finish_sync();
    assert_eq!(s["status"], "idle");
    assert_eq!(s["ruleCount"], 0);
    assert_eq!(
        core.check("https://ads.example.com/x.js", PAGE, PAGE, SCRIPT),
        CHECK_ALLOW
    );
    // 未知 id 忽略。
    let s = core.set_list_enabled("nope", true);
    assert!(s["lists"]
        .as_array()
        .unwrap()
        .iter()
        .all(|l| l["id"] != "nope"));
}

#[test]
fn ingest_outside_a_sync_is_rejected() {
    let dir = TempDir::new("ingest");
    let core = open(&dir);
    assert!(core
        .ingest("easylist", 200, LIST.as_bytes(), None, None, None)
        .is_err());
}

#[test]
fn cosmetic_payload_and_generic_minus_exceptions() {
    let dir = TempDir::new("cosmetic");
    let core = open(&dir);
    sync_with(&core, LIST);
    let raw = core.cosmetic("https://example.com/page", "https://example.com/page");
    let v: Value = serde_json::from_slice(&raw).unwrap();
    let hide: Vec<String> = serde_json::from_value(v["hideSelectors"].clone()).unwrap();
    assert!(hide.contains(&".ad-banner".to_string()) && hide.contains(&"#sponsor".to_string()));
    assert_eq!(v["generichide"], false);
    // example.com 例外了 .generic-ad；别的站照常。
    let on_example = core.generic("https://example.com/page", "", "generic-ad\nfoo", "");
    assert_eq!(on_example, b"[]");
    let on_other = core.generic("https://other.test/", "", "generic-ad\nfoo", "");
    assert_eq!(on_other, br#"[".generic-ad"]"#);
    // 白名单 / 关闭：空载荷。
    core.set_allowlist("example.com");
    assert!(core
        .cosmetic("https://example.com/page", "https://example.com/")
        .is_empty());
    core.set_allowlist("");
    core.set_enabled(false);
    assert!(core
        .generic("https://other.test/", "", "generic-ad", "")
        .is_empty());
}

#[test]
fn content_blockers_only_when_requested() {
    let dir = TempDir::new("cb");
    let core = AdblockCore::open_with_clock(dir.0.clone(), true, test_clock);
    sync_with(&core, LIST);
    let raw = core.content_blockers();
    let rules: Vec<Value> = serde_json::from_slice(&raw).unwrap();
    assert!(rules.iter().any(|r| r["action"]["type"] == "block"));
    assert!(rules
        .iter()
        .all(|r| r["action"]["type"] != "css-display-none"));

    let dir2 = TempDir::new("nocb");
    let core2 = open(&dir2);
    sync_with(&core2, LIST);
    assert!(core2.content_blockers().is_empty());
}

#[test]
fn c_abi_roundtrip() {
    let dir = TempDir::new("cabi");
    let d = dir.0.to_string_lossy().into_owned();
    unsafe {
        let core = ffi::fwc_adblock_open(d.as_ptr(), d.len(), 0);
        assert!(!core.is_null());
        let mut len = 0usize;
        let id = "easyprivacy";
        for l in catalog::CATALOG {
            let p = ffi::fwc_adblock_set_list_enabled(
                core,
                l.id.as_ptr(),
                l.id.len(),
                u8::from(l.id == id),
                &mut len,
            );
            crate::fwc_bytes_free(p, len);
        }
        let p = ffi::fwc_adblock_begin_sync(core, 0, &mut len);
        let plan: Value = serde_json::from_slice(std::slice::from_raw_parts(p, len)).unwrap();
        crate::fwc_bytes_free(p, len);
        assert_eq!(plan["fetch"][0]["id"], id);
        let rc = ffi::fwc_adblock_ingest(
            core,
            id.as_ptr(),
            id.len(),
            200,
            LIST.as_ptr(),
            LIST.len(),
            std::ptr::null(),
            0,
            std::ptr::null(),
            0,
            std::ptr::null(),
            0,
        );
        assert_eq!(rc, 0);
        let p = ffi::fwc_adblock_finish_sync(core, &mut len);
        let snap: Value = serde_json::from_slice(std::slice::from_raw_parts(p, len)).unwrap();
        crate::fwc_bytes_free(p, len);
        assert_eq!(snap["status"], "ready");
        let url = "https://ads.example.com/x.js";
        assert_eq!(
            ffi::fwc_adblock_check(
                core,
                url.as_ptr(),
                url.len(),
                PAGE.as_ptr(),
                PAGE.len(),
                PAGE.as_ptr(),
                PAGE.len(),
                SCRIPT
            ),
            CHECK_BLOCK
        );
        assert_eq!(
            ffi::fwc_adblock_check(
                std::ptr::null(),
                url.as_ptr(),
                url.len(),
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                SCRIPT
            ),
            CHECK_ERROR
        );
        let bad = [0xffu8, 0xfe];
        assert_eq!(
            ffi::fwc_adblock_check(
                core,
                bad.as_ptr(),
                bad.len(),
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                SCRIPT
            ),
            CHECK_ERROR
        );
        let p = ffi::fwc_adblock_catalog(&mut len);
        let cat: Value = serde_json::from_slice(std::slice::from_raw_parts(p, len)).unwrap();
        crate::fwc_bytes_free(p, len);
        assert_eq!(cat.as_array().unwrap().len(), catalog::CATALOG.len());
        assert_eq!(cat[0]["host"], "easylist.to");
        // 未就绪 / 空 href 的 cosmetic：长度 0、NULL。
        let p = ffi::fwc_adblock_cosmetic(core, std::ptr::null(), 0, std::ptr::null(), 0, &mut len);
        assert!(p.is_null() && len == 0);
        ffi::fwc_adblock_close(core);
        assert!(ffi::fwc_adblock_open(std::ptr::null(), 0, 0).is_null());
        let err = crate::fwc_last_error();
        assert!(!err.is_null());
        crate::fwc_string_free(err);
    }
}
