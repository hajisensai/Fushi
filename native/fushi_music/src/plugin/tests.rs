//! 运行时端到端：打包 → 安装 → 建实例 → 步进驱动（含宿主调用往返）。

use std::fs;
use std::path::PathBuf;

use serde_json::{json, Value};

use super::package::tests::{build_zip, manifest_with, Sign};
use super::package::{install_zip, inspect_zip, load_dir};
use super::runtime::Instance;

fn temp_root(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("fmp-rt-{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&d);
    d
}

fn open(tag: &str, manifest: &str, files: &[(&str, &str)], budget: u64) -> Result<Instance, String> {
    let mut all: Vec<(&str, &[u8])> = vec![("manifest.json", manifest.as_bytes())];
    for (p, s) in files {
        all.push((p, s.as_bytes()));
    }
    let zip = build_zip(&all, Sign::None, None);
    let digest = inspect_zip(&zip)?.digest;
    let root = temp_root(tag);
    install_zip(&zip, &root, &digest)?;
    let pkg = load_dir(&root.join("moe.test"))?;
    Instance::open(pkg, budget)
}

fn step(inst: &mut Instance, ops: Value) -> Value {
    inst.step(ops.to_string().as_bytes())
}

#[test]
fn invoke_with_http_roundtrip() {
    let m = manifest_with(&["search", "lyrics"], &["network"], &["api.example.com"]);
    let js = r#"
        const util = require('./lib/util');
        module.exports = {
          async search(args) {
            const r = await fushi.http.request({ url: 'https://api.example.com/s?q=' + encodeURIComponent(args.query), responseType: 'json' });
            console.log('status', r.status);
            return { items: r.json.items.map(util.upper), page: args.page };
          },
          async lyrics() { return { md5: fushi.encoding.hexEncode(fushi.crypto.md5('abc')) }; },
        };
    "#;
    let util = "exports.upper = function (s) { return String(s).toUpperCase(); };";
    let mut inst = open("http", &m, &[("main.js", js), ("lib/util.js", util)], 2000).unwrap();

    let out = step(&mut inst, json!([{ "op": "invoke", "inv": 1, "method": "search", "args": { "query": "夜曲", "page": 2 } }]));
    assert_eq!(out["settled"], json!([]), "{out}");
    let call = &out["calls"][0];
    assert_eq!(call["op"], "http");
    assert_eq!(call["args"]["method"], "GET");
    assert!(call["args"]["url"].as_str().unwrap().starts_with("https://api.example.com/s?q=%E5%A4%9C"));
    let body = data_encoding::BASE64.encode(br#"{"items":["a","b"]}"#);
    let out = step(&mut inst, json!([{ "op": "complete", "call": call["id"], "ok": true,
        "value": { "status": 200, "url": "https://api.example.com/s", "headers": {}, "bodyBase64": body } }]));
    assert_eq!(out["settled"][0], json!({ "inv": 1, "ok": true, "value": { "items": ["A", "B"], "page": 2 } }), "{out}");
    assert_eq!(out["logs"][0]["message"], "status 200");

    let out = step(&mut inst, json!([{ "op": "invoke", "inv": 2, "method": "lyrics", "args": {} }]));
    assert_eq!(out["settled"][0]["value"]["md5"], "900150983cd24fb0d6963f7d28e17f72");
}

#[test]
fn policy_violations_reject_inside_js() {
    let m = manifest_with(&["search"], &["network"], &["api.example.com"]);
    let js = r#"
        module.exports = { async search(a) {
          const out = [];
          for (const u of ['https://evil.com/', 'http://api.example.com/', 'https://127.0.0.1/']) {
            try { await fushi.http.request({ url: u }); out.push('allowed'); } catch (e) { out.push('denied'); }
          }
          try { await fushi.http.request({ url: 'https://api.example.com/', method: 'DELETE' }); } catch (e) { out.push('method'); }
          try { await fushi.storage.get('k'); } catch (e) { out.push('storage'); }
          return out;
        } };
    "#;
    let mut inst = open("policy", &m, &[("main.js", js)], 2000).unwrap();
    let out = step(&mut inst, json!([{ "op": "invoke", "inv": 7, "method": "search", "args": {} }]));
    assert_eq!(out["calls"], json!([]), "越权请求不得到达宿主：{out}");
    assert_eq!(
        out["settled"][0]["value"],
        json!(["denied", "denied", "denied", "method", "storage"])
    );
}

#[test]
fn errors_budget_and_undeclared() {
    let m = manifest_with(&["search", "lyrics"], &[], &[]);
    let js = r#"
        module.exports = {
          search() { throw new TypeError('boom'); },
          lyrics() { for (;;) {} },
          secret() { return 1; },
        };
    "#;
    let mut inst = open("err", &m, &[("main.js", js)], 300).unwrap();
    let out = step(&mut inst, json!([
        { "op": "invoke", "inv": 1, "method": "search", "args": {} },
        { "op": "invoke", "inv": 2, "method": "secret", "args": {} },
    ]));
    let settled = out["settled"].as_array().unwrap();
    let by_inv = |i: u64| settled.iter().find(|s| s["inv"] == i).unwrap().clone();
    assert!(by_inv(1)["error"].as_str().unwrap().contains("TypeError: boom"));
    assert!(by_inv(2)["error"].as_str().unwrap().contains("没有声明能力"));
    let out = step(&mut inst, json!([{ "op": "invoke", "inv": 3, "method": "lyrics", "args": {} }]));
    assert!(out["fatal"].as_str().unwrap().contains("CPU"), "{out}");
    // 作废后的实例只回 fatal。
    let out = step(&mut inst, json!([]));
    assert!(out["fatal"].is_string());
}

#[test]
fn missing_capability_export_and_escape() {
    let m = manifest_with(&["search", "lyrics"], &[], &[]);
    let err = open("missing", &m, &[("main.js", "module.exports = { search() {} };")], 2000)
        .err()
        .unwrap();
    assert!(err.contains("lyrics"), "{err}");
    let m = manifest_with(&["lyrics"], &[], &[]);
    let err = open("escape", &m, &[("main.js", "require('../outside'); module.exports = { lyrics() {} };")], 2000)
        .err()
        .unwrap();
    assert!(err.contains("越出"), "{err}");
    // 原生桥不暴露给插件。
    let js = "module.exports = { lyrics() { return [typeof __n, typeof globalThis.__n]; } };";
    let mut inst = open("hidden", &m, &[("main.js", js)], 2000).unwrap();
    let out = step(&mut inst, json!([{ "op": "invoke", "inv": 1, "method": "lyrics" }]));
    assert_eq!(out["settled"][0]["value"], json!(["undefined", "undefined"]));
}

#[test]
fn credentials_gate_and_set_cookies() {
    let m = serde_json::json!({
        "schema": 1, "id": "moe.test", "name": "Test", "version": "0.1.0", "api": 1,
        "entry": "main.js", "capabilities": ["login", "account"],
        "permissions": ["network", "credentials"],
        "network": {"domains": ["api.example.com"], "methods": ["GET"]}
    })
    .to_string();
    let js = r#"
        module.exports = {
          async login() {
            const r = await fushi.http.request({ url: 'https://api.example.com/login' });
            await fushi.credentials.set('cookie', r.setCookies.join('|'));
            return { state: 'done', cookies: r.setCookies.length };
          },
          async account() { return { loggedIn: !!(await fushi.credentials.get('cookie')) }; },
        };
    "#;
    let mut inst = open("cred", &m, &[("main.js", js)], 2000).unwrap();
    let out = step(&mut inst, json!([{ "op": "invoke", "inv": 1, "method": "login", "args": {} }]));
    let c = &out["calls"][0];
    let out = step(&mut inst, json!([{ "op": "complete", "call": c["id"], "ok": true,
        "value": { "status": 200, "url": "https://api.example.com/login", "headers": {},
                   "setCookies": ["MUSIC_U=a; Expires=Wed, 01 Jan 2031 00:00:00 GMT", "__csrf=b"], "bodyBase64": "" } }]));
    let c = &out["calls"][0];
    assert_eq!(c["op"], "credentials.set");
    assert_eq!(c["args"]["value"], "MUSIC_U=a; Expires=Wed, 01 Jan 2031 00:00:00 GMT|__csrf=b");
    let out = step(&mut inst, json!([{ "op": "complete", "call": c["id"], "ok": true, "value": null }]));
    assert_eq!(out["settled"][0]["value"], json!({ "state": "done", "cookies": 2 }));

    // 没有 credentials 权限的清单不能声明 login。
    let bad = m.replace("\"network\",\"credentials\"", "\"network\"");
    assert_ne!(bad, m);
    assert!(super::manifest::Manifest::parse(bad.as_bytes()).is_err());
}

#[test]
fn storage_roundtrip_and_host_error() {
    let m = manifest_with(&["lyrics"], &["storage"], &[]);
    let js = r#"
        module.exports = { async lyrics() {
          await fushi.storage.set('token', 'abc');
          const v = await fushi.storage.get('token');
          try { await fushi.storage.get('missing'); } catch (e) { return [v, String(e.message)]; }
        } };
    "#;
    let mut inst = open("storage", &m, &[("main.js", js)], 2000).unwrap();
    let out = step(&mut inst, json!([{ "op": "invoke", "inv": 1, "method": "lyrics" }]));
    let c = &out["calls"][0];
    assert_eq!(c["op"], "storage.set");
    let out = step(&mut inst, json!([{ "op": "complete", "call": c["id"], "ok": true, "value": null }]));
    let c = &out["calls"][0];
    assert_eq!(c["op"], "storage.get");
    let out = step(&mut inst, json!([{ "op": "complete", "call": c["id"], "ok": true, "value": "abc" }]));
    let c = &out["calls"][0];
    let out = step(&mut inst, json!([{ "op": "complete", "call": c["id"], "ok": false, "error": "disk on fire" }]));
    assert_eq!(out["settled"][0]["value"], json!(["abc", "disk on fire"]));
}

/// 插件改写 `JSON.stringify` 往宿主调用参数里塞 `plugin` / `op`，宿主拿到的参数里也只能有
/// 核对过的 key / value（否则 Dart 宿主展开参数时会以别的插件名义读写凭据 / 存储）。
#[test]
fn host_call_args_are_normalized_not_forwarded() {
    let m = serde_json::json!({
        "schema": 1, "id": "moe.test", "name": "Test", "version": "0.1.0", "api": 1,
        "entry": "main.js", "capabilities": ["login", "account"],
        "permissions": ["network", "credentials", "storage"],
        "network": {"domains": ["api.example.com"], "methods": ["GET"]}
    })
    .to_string();
    let js = r#"
        const orig = JSON.stringify;
        JSON.stringify = function (v) {
          if (v && typeof v === 'object' && 'key' in v) {
            v = Object.assign({}, v, { plugin: 'moe.victim', op: 'clear' });
          }
          return orig(v);
        };
        module.exports = {
          async login() { return await fushi.credentials.get('cookie'); },
          async account() { return await fushi.storage.set('k', 'v'); },
        };
    "#;
    let mut inst = open("normalize", &m, &[("main.js", js)], 2000).unwrap();
    let out = step(&mut inst, json!([{ "op": "invoke", "inv": 1, "method": "login", "args": {} }]));
    let c = &out["calls"][0];
    assert_eq!(c["op"], "credentials.get");
    assert_eq!(c["args"], json!({ "key": "cookie" }), "{out}");
    let out = step(&mut inst, json!([{ "op": "invoke", "inv": 2, "method": "account", "args": {} }]));
    let c = &out["calls"][0];
    assert_eq!(c["op"], "storage.set");
    assert_eq!(c["args"], json!({ "key": "k", "value": "v" }), "{out}");
}

/// 模块顶层排的微任务也在 CPU 预算内：死循环不能让 open 永不返回。
#[test]
fn boot_microtask_respects_budget() {
    let m = manifest_with(&["lyrics"], &[], &[]);
    let js = r#"
        Promise.resolve().then(function () { for (;;) {} });
        module.exports = { async lyrics() { return 1; } };
    "#;
    let r = open("bootloop", &m, &[("main.js", js)], 200);
    let err = r.err().expect("boot 微任务死循环必须超预算失败");
    assert!(err.contains("预算"), "{err}");
}
