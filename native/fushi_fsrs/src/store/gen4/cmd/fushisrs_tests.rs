//! `.fushisrs` 导出 / 导入命令（G11-3，`cmd/fushisrs.rs`）的端到端测试：一律经 C ABI（`ffsrs_store_open_mode` /
//! `ffsrs_store_sync2`，装置在 `dispatch_tests.rs`）。
//!
//! - 导出 → 导入到空库：真相层（导出流逐项，去掉导入方自己的原生日志）、派生表逐行（操作主键换成「设备:seq」）、设备公钥
//!   相同；需确认 → 确认后绑定；重复导入什么都不改（幂等）。
//! - 导入到已有库：同一个集合照常并入；另一个集合先回 `needsConfirm`、什么都不写，确认后并入；裸流（不带清单）不认领。
//! - 缺口 G-12：协议 3 设备（承袭日志）的公钥随清单的 `peers` 到导入方，不带清单就没有。
//! - 本机身份分叉（拷过的数据目录各自写过）：导入先换身份，两边的写入都在。
//! - 第 1 版（协议 3 的 `FSRS2EXP`，即 v1 `.fushisrs` 里的 `ops.bin` 与协议 3 `export` 命令的输出）：与直接迁移同一台设备的
//!   库逐行相同（卡片、复习日志条数与内容）；另一个集合的第 1 版拒绝、什么都不写。
//! - 旧版本互拒：协议 3 的导入（已发布二进制的读者）拒收新流，库一字不变。
//! - 坏文件、清单与流头不符：明确报错，一条不落。
//! - 大文件：按文件流式读，读窗口有上界（不随文件变大）。
//! - 别名类：双盐场景导出后在另一个集合里认领并入，按任何一份成员点名都是整个类的回答。
//! - 查询计划：导出清单的 `peers` 语句按主键找。

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::ptr::null_mut;

use rusqlite::{Connection, OpenFlags};
use serde_json::{Value, json};

use super::dispatch_tests::{T1, call, cfg, g4req, migrated, open};
use super::fushisrs::PEERS_SQL;
use super::tests_class;
use crate::gen4::export::{Export4Reader, ExportItem};
use crate::gen4::op::tests::id;
use crate::store::ffi::{SrsCoreHandle, ffsrs_store_close, ffsrs_store_sync2};
use crate::store::gen4::files::{GEN4_FILE, OpenMode};
use crate::store::gen4::kernel::G4Core;
use crate::store::gen4::schema::DERIVED_TABLES;
use crate::store::gen4::truth::Truth;
use crate::store::sync2::collection_of;
use crate::store::sync2::tests::{P, edit, tempdir};
use crate::sync2::id::Id;

const Q: &str = "0193a1b2-0000-7000-8000-00000000cafe";
const N1: &str = super::tests::N1;

fn take_error(err: *mut std::ffi::c_char) -> String {
    if err.is_null() {
        return String::new();
    }
    let s = unsafe { std::ffi::CStr::from_ptr(err) }
        .to_string_lossy()
        .into_owned();
    crate::ffsrs_free_string(err);
    s
}

/// 发一条带原始字节块的命令（[call] 的字节块只装 `apply` 的 JSON 输入项）。回包只取 JSON。
fn call_blob(h: *mut SrsCoreHandle, req: &Value, blob: &[u8]) -> Result<Value, String> {
    let text = req.to_string();
    let mut blobs = Vec::new();
    blobs.extend_from_slice(&1u32.to_le_bytes());
    blobs.extend_from_slice(&(blob.len() as u32).to_le_bytes());
    blobs.extend_from_slice(blob);
    let (mut out, mut out_len, mut err) = (null_mut(), 0usize, null_mut());
    let rc = ffsrs_store_sync2(
        h,
        text.as_ptr(),
        text.len(),
        blobs.as_ptr(),
        blobs.len(),
        &mut out,
        &mut out_len,
        &mut err,
    );
    if rc != 0 {
        return Err(take_error(err));
    }
    let b = unsafe { std::slice::from_raw_parts(out, out_len) }.to_vec();
    crate::ffsrs_free_bytes(out, out_len);
    let n = u32::from_le_bytes(b[0..4].try_into().unwrap()) as usize;
    Ok(serde_json::from_slice(&b[4..4 + n]).unwrap())
}

pub(super) fn as_profile(profile: &str, op: &str, extra: Value) -> Value {
    let mut req = g4req(op, T1, extra);
    req["profile"] = json!(profile);
    req
}

pub(super) fn try_g4(
    h: *mut SrsCoreHandle,
    profile: &str,
    op: &str,
    extra: Value,
) -> Result<Value, String> {
    call(h, &as_profile(profile, op, extra), None)
        .map(|r| r.0)
        .map_err(|(_, e)| e)
}

/// 导出到 [dir] 下的 `ops.bin`：回包（清单里归内核的部分）与文件路径。
fn export_to(h: *mut SrsCoreHandle, profile: &str, dir: &Path) -> (Value, PathBuf) {
    let path = dir.join(format!("ops-{}.bin", Id::random().text()));
    let v = try_g4(
        h,
        profile,
        "export",
        json!({"path": path.to_str().unwrap()}),
    )
    .unwrap_or_else(|e| panic!("export: {e}"));
    assert!(path.exists());
    (v, path)
}

/// 导出回包 → 清单（Dart 写进 manifest.json 的那几项）。
fn manifest(exp: &Value) -> Value {
    json!({"collection": exp["collection"], "dir": exp["dir"], "salts": exp["salts"], "peers": exp["peers"]})
}

fn import_path(
    h: *mut SrsCoreHandle,
    profile: &str,
    path: &Path,
    extra: Value,
) -> Result<Value, String> {
    let mut x = json!({"path": path.to_str().unwrap()});
    for (k, v) in extra.as_object().cloned().unwrap_or_default() {
        x[k.as_str()] = v;
    }
    try_g4(h, profile, "import", x)
}

/// 新代库文件的只读连接。
pub(super) fn reader(dir: &Path) -> Connection {
    Connection::open_with_flags(
        dir.join(GEN4_FILE),
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .unwrap()
}

pub(super) fn col_in(c: &Connection, profile: &str) -> i64 {
    Truth::new(c).binding_of(profile).unwrap().unwrap().col
}

/// 本机身份的设备 ID（`identity` 已建过）。
pub(super) fn self_device(h: *mut SrsCoreHandle, profile: &str) -> Id {
    let v = try_g4(h, profile, "identity", json!({})).unwrap();
    Id::parse(v["device"].as_str().unwrap()).unwrap()
}

/// 派生表逐行：操作主键 `k` 换成「设备:seq」（设备下标是各库的落库顺序），去掉 `col`；`k` 属于 [skip] 里设备的行不算
/// （导入方 / 导出方各自的本机原生日志）。
pub(super) fn derived(dir: &Path, profile: &str, skip: &[Id]) -> Vec<String> {
    let c = reader(dir);
    let t = Truth::new(&c);
    let col = col_in(&c, profile);
    let mut out = Vec::new();
    for table in DERIVED_TABLES {
        let mut stmt = c
            .prepare(&format!("SELECT * FROM {table} WHERE col = ?1"))
            .unwrap();
        let names: Vec<String> = stmt.column_names().iter().map(|s| s.to_string()).collect();
        let mut q = stmt.query([col]).unwrap();
        let mut lines = Vec::new();
        'row: while let Some(r) = q.next().unwrap() {
            let mut cells = Vec::new();
            for (i, name) in names.iter().enumerate() {
                let v = r.get::<_, rusqlite::types::Value>(i).unwrap();
                match (name.as_str(), v) {
                    ("col", _) => {}
                    ("k", rusqlite::types::Value::Integer(k)) => {
                        let o = t.id_of_key(k).unwrap();
                        if skip.contains(&o.device) {
                            continue 'row;
                        }
                        cells.push(format!("k={}:{}", o.device, o.seq));
                    }
                    (_, v) => cells.push(format!("{v:?}")),
                }
            }
            lines.push(format!("{table} {}", cells.join(" | ")));
        }
        lines.sort();
        out.extend(lines);
    }
    out
}

/// 导出流逐项（[skip] 里设备的原生日志整条不算；流头不算）。
fn stream(bytes: &[u8], skip: &[Id]) -> Vec<String> {
    let (mut r, _) = Export4Reader::open(bytes).unwrap();
    let mut out = Vec::new();
    let mut skipping = false;
    while let Some(it) = r.next_item().unwrap() {
        match &it {
            ExportItem::NativeLog { device, .. } => skipping = skip.contains(device),
            ExportItem::HeritageLog { .. } => skipping = false,
            _ => {}
        }
        if !skipping {
            out.push(format!("{it:?}"));
        }
    }
    out
}

pub(super) fn export_bytes(h: *mut SrsCoreHandle, profile: &str) -> Vec<u8> {
    let (_, files) = call(h, &as_profile(profile, "export", json!({})), None).unwrap();
    assert_eq!(files.len(), 1);
    assert_eq!(files[0].0, "ops.bin");
    files[0].1.clone()
}

/// `peers` 逐行（设备、公钥、名字）。
pub(super) fn peer_lines(dir: &Path, profile: &str) -> BTreeSet<String> {
    let c = reader(dir);
    let col = col_in(&c, profile);
    let mut stmt = c
        .prepare("SELECT hex(device), hex(public), name FROM peers WHERE col = ?1")
        .unwrap();
    let lines = stmt
        .query_map([col], |r| {
            Ok(format!(
                "{} {} {:?}",
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, Option<String>>(2)?
            ))
        })
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    lines
}

fn hex_upper(id: &Id) -> String {
    id.0.iter().map(|b| format!("{b:02X}")).collect()
}

/// 一条笔记的修改历史里出现过的值。
fn values_of(h: *mut SrsCoreHandle, profile: &str, note: &str) -> BTreeSet<String> {
    let v = try_g4(
        h,
        profile,
        "history",
        json!({"kind": "note", "entity": note}),
    )
    .unwrap();
    v.as_array()
        .unwrap()
        .iter()
        .filter_map(|e| e.get("value").map(|x| x.to_string()))
        .collect()
}

fn apply_edit(h: *mut SrsCoreHandle, profile: &str, note: &str, key: &str, v: Value) {
    let items = vec![json!({"e": edit("note", note, key, v), "note": note})];
    let mut req = g4req("apply", T1, json!({}));
    req["profile"] = json!(profile);
    let (r, _) = call(h, &req, Some(&items)).unwrap_or_else(|(_, e)| panic!("apply: {e}"));
    assert_eq!(r["landed"], json!([true]), "{r}");
}

/// 全新库：经 `identity` 建出 [profile] 的集合（`collection_of(uid)`，目录名 = uid）与本机身份，配好缓存。
pub(super) fn fresh(tag: &str, profile: &str) -> (tempdir::Dir, *mut SrsCoreHandle) {
    let dir = tempdir::new(tag);
    let h = open(&dir.0, 0).unwrap();
    try_g4(h, profile, "identity", json!({})).unwrap();
    try_g4(h, profile, "cache_config_set", json!({"caches": cfg()})).unwrap();
    (dir, h)
}

// ---------------------------------------------------------------------- 往返

/// 迁移来的库（原生日志 + 协议 3 设备的承袭日志 + 清除骨架）导出 → 导入到一个**没有任何绑定**的空库：没确认时回
/// `needsConfirm`、什么都不建；确认后绑定（`bound`，带 `bindingChanged`），真相层、派生表、设备公钥与导出方相同（导入方
/// 自己建身份写的那条 `Salts` 除外）；同一份再导一遍什么都不改、修订号不动。
#[test]
fn export_then_import_into_an_empty_library_is_identical_and_idempotent() {
    let m = migrated();
    let work = tempdir::new("g113rt");
    let src_dev = self_device(m.h, P);
    let (exp, path) = export_to(m.h, P, &work.0);
    assert_eq!(exp["collection"], json!(collection_of(P).text()), "{exp}");
    assert_eq!(exp["dir"], json!(P));
    assert!(
        exp["salts"].as_array().unwrap().contains(&json!(P)),
        "{exp}"
    );
    assert!(
        exp["counts"]["heritageLogs"].as_u64().unwrap() >= 2,
        "{exp}"
    );
    // 文件与回包里的字节相同（导出是确定的）。
    assert_eq!(std::fs::read(&path).unwrap(), export_bytes(m.h, P));

    let dst = tempdir::new("g113empty");
    let h = open(&dst.0, 0).unwrap();
    let man = manifest(&exp);
    let ask = import_path(h, P, &path, json!({"manifest": man})).unwrap();
    assert_eq!(ask["outcome"], json!("needsConfirm"), "{ask}");
    assert_eq!(ask["collection"], exp["collection"]);
    assert!(ask.get("bindingChanged").is_none());
    let e = try_g4(h, P, "binding_get", json!({})).unwrap_err();
    assert!(e.contains("has no collection"), "{e}");

    let got = import_path(h, P, &path, json!({"manifest": man, "confirmed": true})).unwrap();
    assert_eq!(got["format"], json!(2), "{got}");
    assert_eq!(got["outcome"], json!("bound"), "{got}");
    assert_eq!(got["bindingChanged"], json!({"profile": P}));
    assert!(got["applied"].as_u64().unwrap() > 0, "{got}");
    assert_eq!(got["unchanged"], json!(false));
    assert_eq!(got["rotated"], Value::Null);
    assert!(got["localRevision"].as_i64().unwrap() > 0, "{got}");
    let dst_dev = self_device(h, P);
    assert_ne!(dst_dev, src_dev);

    // 真相层：导出流逐项相同（导入方自己的原生日志除外）。
    assert_eq!(
        stream(&export_bytes(h, P), &[dst_dev]),
        stream(&export_bytes(m.h, P), &[])
    );
    // 派生表逐行相同（两边各自本机原生日志的行除外：导出方的那条已作为别的设备的原生日志进了导入方，所以只扣导入方的）。
    try_g4(h, P, "cache_config_set", json!({"caches": cfg()})).unwrap();
    assert_eq!(derived(&dst.0, P, &[dst_dev]), derived(&m.dir.0, P, &[]));
    // 设备公钥：导出方的全部（含它自己的本机身份）都到了；多出来的只有导入方自己的本机身份。
    let (src_peers, dst_peers) = (peer_lines(&m.dir.0, P), peer_lines(&dst.0, P));
    assert!(
        src_peers.is_subset(&dst_peers),
        "{src_peers:?} {dst_peers:?}"
    );
    assert!(
        src_peers
            .iter()
            .any(|p| p.starts_with(&hex_upper(&src_dev)))
    );
    let extra: Vec<&String> = dst_peers.difference(&src_peers).collect();
    assert_eq!(extra.len(), 1, "{extra:?}");
    assert!(extra[0].starts_with(&hex_upper(&dst_dev)), "{extra:?}");

    // 再导一遍：什么都不改，修订号不动。
    let again = import_path(h, P, &path, json!({"manifest": man})).unwrap();
    assert_eq!(again["outcome"], json!("same"), "{again}");
    assert_eq!(again["applied"], json!(0));
    assert_eq!(again["unchanged"], json!(true));
    assert_eq!(again["localRevision"], got["localRevision"]);
    assert!(again.get("bindingChanged").is_none());
    assert_eq!(derived(&dst.0, P, &[dst_dev]), derived(&m.dir.0, P, &[]));
    // 字节块来源与文件来源同一个结果。
    let blob = std::fs::read(&path).unwrap();
    let mut req = as_profile(P, "import", json!({"manifest": man}));
    req["now"] = json!(T1);
    let by_blob = call_blob(h, &req, &blob).unwrap();
    assert_eq!(by_blob["unchanged"], json!(true), "{by_blob}");
    ffsrs_store_close(h);
}

// ---------------------------------------------------------------------- 已有库

/// 同一个集合（同一个 uid 的全新库，`identity` 建的是 `collection_of(uid)`）：直接并入，结论 `same`；缺口 G-12：
/// 不带清单的裸流进不来协议 3 设备的公钥（流里承袭日志没有），带清单就有；导出方本机的写入与导入方的写入都在。
#[test]
fn importing_into_the_same_collection_merges_and_carries_heritage_keys() {
    let m = migrated();
    let work = tempdir::new("g113same");
    let (exp, path) = export_to(m.h, P, &work.0);
    let src_peers = peer_lines(&m.dir.0, P);
    assert!(!src_peers.is_empty());

    // 裸流（不带清单）：不认领，照常并入；承袭日志设备的公钥没有。
    let (bare_dir, bare) = fresh("g113bare", P);
    let got = import_path(bare, P, &path, json!({})).unwrap();
    assert_eq!(got["outcome"], json!("stream"), "{got}");
    let bare_peers = peer_lines(&bare_dir.0, P);
    assert!(
        src_peers.iter().any(|p| !bare_peers.contains(p)),
        "{src_peers:?} {bare_peers:?}"
    );
    ffsrs_store_close(bare);

    let (dir, h) = fresh("g113same2", P);
    apply_edit(h, P, N1, "f/fa", json!("導入前"));
    // 承袭日志设备的公钥本机还没有：先问（`reason: identity`），确认后照常并入。
    let ask = import_path(h, P, &path, json!({"manifest": manifest(&exp)})).unwrap();
    assert_eq!(ask["reason"], json!("identity"), "{ask}");
    let got = import_path(
        h,
        P,
        &path,
        json!({"manifest": manifest(&exp), "confirmed": true}),
    )
    .unwrap();
    assert_eq!(got["outcome"], json!("same"), "{got}");
    assert!(got.get("bindingChanged").is_none(), "{got}");
    assert!(
        got["peers"].as_u64().unwrap() >= src_peers.len() as u64,
        "{got}"
    );
    assert!(src_peers.is_subset(&peer_lines(&dir.0, P)));
    let vals = values_of(h, P, N1);
    assert!(vals.contains("\"導入前\""), "{vals:?}");
    assert!(
        values_of(m.h, P, N1).is_subset(&vals),
        "{vals:?} {:?}",
        values_of(m.h, P, N1)
    );
    ffsrs_store_close(h);
}

/// 另一个集合（另一个 uid 的库）：没确认回 `needsConfirm`、库一字不变；确认后并入（`joined`），导出方的数据在，本机的也在；
/// 再导一遍是 `alreadyJoined` / `same`，什么都不改。
#[test]
fn a_foreign_collection_needs_confirmation_then_joins() {
    let m = migrated();
    let work = tempdir::new("g113foreign");
    let (exp, path) = export_to(m.h, P, &work.0);
    let (dir, h) = fresh("g113q", Q);
    apply_edit(h, Q, N1, "f/fa", json!("本機"));
    let before = export_bytes(h, Q);
    let man = manifest(&exp);
    let ask = import_path(h, Q, &path, json!({"manifest": man})).unwrap();
    assert_eq!(ask["outcome"], json!("needsConfirm"), "{ask}");
    assert_eq!(ask["dir"], json!(P));
    assert_eq!(export_bytes(h, Q), before);
    assert!(values_of(h, Q, N1).contains("\"本機\""));

    let got = import_path(h, Q, &path, json!({"manifest": man, "confirmed": true})).unwrap();
    assert_eq!(got["outcome"], json!("joined"), "{got}");
    assert!(got["applied"].as_u64().unwrap() > 0, "{got}");
    // 目录名小的一方是并入的目标：P、Q 都是 uid，比字节决定谁改绑；改绑了就有 bindingChanged。
    let rebound = P < Q;
    assert_eq!(got.get("bindingChanged").is_some(), rebound, "{got}");
    let info = try_g4(h, Q, "collection_info", json!({})).unwrap();
    let salts: BTreeSet<String> = info["salts"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s.as_str().unwrap().to_owned())
        .collect();
    assert!(salts.contains(P) && salts.contains(Q), "{info}");
    // 两边的数据都在：导出方的修改历史全在，本机的也在。
    let vals = values_of(h, Q, N1);
    assert!(vals.contains("\"本機\""), "{vals:?}");
    assert!(values_of(m.h, P, N1).is_subset(&vals), "{vals:?}");
    let again = import_path(h, Q, &path, json!({"manifest": man})).unwrap();
    assert!(
        matches!(again["outcome"].as_str(), Some("alreadyJoined" | "same")),
        "{again}"
    );
    assert_eq!(again["unchanged"], json!(true), "{again}");
    let _ = dir;
    ffsrs_store_close(h);
}

/// 清单与流头不符、坏文件、不是导出流：明确报错，一条不落。
#[test]
fn bad_files_and_lying_manifests_are_refused_and_nothing_lands() {
    let m = migrated();
    let work = tempdir::new("g113bad");
    let (exp, path) = export_to(m.h, P, &work.0);
    let (dir, h) = fresh("g113badq", P);
    let before = export_bytes(h, P);
    let mut lie = manifest(&exp);
    lie["collection"] = json!(id(0x99).text());
    let e = import_path(h, P, &path, json!({"manifest": lie, "confirmed": true})).unwrap_err();
    assert!(e.contains("manifest names collection"), "{e}");
    let bytes = std::fs::read(&path).unwrap();
    let cut = work.0.join("cut.bin");
    std::fs::write(&cut, &bytes[..bytes.len() * 2 / 3]).unwrap();
    let e = import_path(h, P, &cut, json!({"manifest": manifest(&exp)})).unwrap_err();
    assert!(e.contains("gen4 import"), "{e}");
    let junk = work.0.join("junk.bin");
    std::fs::write(&junk, b"PK\x03\x04 not an ops stream").unwrap();
    let e = import_path(h, P, &junk, json!({})).unwrap_err();
    assert!(e.contains("not a Fushi SRS export"), "{e}");
    let e = import_path(h, P, &work.0.join("missing.bin"), json!({})).unwrap_err();
    assert!(e.contains("cannot open"), "{e}");
    assert_eq!(export_bytes(h, P), before);
    let _ = dir;
    ffsrs_store_close(h);
}

// ---------------------------------------------------------------------- 本机身份分叉

/// 数据目录被拷过、两边各写了一条：把拷贝那边的导出导回来，先换身份（旧身份冻结在共同前缀），两边的写入都在；再导一遍
/// 什么都不改、不再换身份。
#[test]
fn importing_a_clone_of_this_install_rotates_the_identity_first() {
    let (a_dir, a) = fresh("g113fork", P);
    apply_edit(a, P, N1, "f/fa", json!("共通"));
    ffsrs_store_close(a);
    let b_dir = tempdir::new("g113clone");
    for e in std::fs::read_dir(&a_dir.0).unwrap() {
        let e = e.unwrap();
        if e.file_type().unwrap().is_file() {
            std::fs::copy(e.path(), b_dir.0.join(e.file_name())).unwrap();
        }
    }
    let a = open(&a_dir.0, 0).unwrap();
    let b = open(&b_dir.0, 0).unwrap();
    let old = self_device(a, P);
    assert_eq!(self_device(b, P), old);
    apply_edit(a, P, N1, "f/fa", json!("A側"));
    apply_edit(b, P, N1, "f/fb", json!("B側"));
    let work = tempdir::new("g113forkx");
    let (exp, path) = export_to(b, P, &work.0);
    let got = import_path(a, P, &path, json!({"manifest": manifest(&exp)})).unwrap();
    let rot = &got["rotated"];
    assert_eq!(rot["previous"], json!(old.text()), "{got}");
    assert_eq!(rot["keep"], json!(2), "{got}");
    assert_eq!(rot["moved"], json!(1), "{got}");
    let new = self_device(a, P);
    assert_ne!(new, old);
    let vals = values_of(a, P, N1);
    for v in ["\"共通\"", "\"A側\"", "\"B側\""] {
        assert!(vals.contains(v), "{v}: {vals:?}");
    }
    let again = import_path(a, P, &path, json!({"manifest": manifest(&exp)})).unwrap();
    assert_eq!(again["rotated"], Value::Null, "{again}");
    assert_eq!(again["unchanged"], json!(true), "{again}");
    assert_eq!(self_device(a, P), new);
    // 本机日志是导出方日志的前缀（导回自己更早的导出）：不换身份。
    let (exp_a, path_a) = export_to(a, P, &work.0);
    apply_edit(a, P, N1, "f/fa", json!("その後"));
    let back = import_path(a, P, &path_a, json!({"manifest": manifest(&exp_a)})).unwrap();
    assert_eq!(back["rotated"], Value::Null, "{back}");
    assert_eq!(self_device(a, P), new);
    ffsrs_store_close(a);
    ffsrs_store_close(b);
}

// ---------------------------------------------------------------------- 第 1 版与旧版本互拒

/// 第 1 版（协议 3 `export` 的输出 = v1 `.fushisrs` 里的 `ops.bin`）导入到同一个 uid 的全新库：卡片、复习日志、修改与直接
/// 迁移同一台设备的库逐行相同（两边各自本机原生日志的行除外）；字节块与文件两种来源；再导一遍什么都不改；另一个集合
/// （另一个 uid 的库）拒绝、一条不落。
#[test]
fn a_version_1_file_lands_exactly_like_the_migration() {
    let m = migrated();
    let v1 = m.d.core.sync2_export(P).unwrap();
    let mig_dev = self_device(m.h, P);
    let (dir, h) = fresh("g113v1", P);
    let me = self_device(h, P);
    let mut req = as_profile(P, "import", json!({}));
    req["now"] = json!(T1);
    let got = call_blob(h, &req, &v1).unwrap();
    assert_eq!(got["format"], json!(1), "{got}");
    assert_eq!(got["outcome"], json!("legacy"));
    assert!(got["applied"].as_u64().unwrap() > 0, "{got}");
    assert_eq!(derived(&dir.0, P, &[me]), derived(&m.dir.0, P, &[mig_dev]));
    // 卡片与复习日志的条数也逐项比一遍（派生表里的这两张）。
    let count = |d: &Path, table: &str| -> i64 {
        let c = reader(d);
        let col = col_in(&c, P);
        c.query_row(
            &format!("SELECT COUNT(*) FROM {table} WHERE col = ?1"),
            [col],
            |r| r.get(0),
        )
        .unwrap()
    };
    for table in DERIVED_TABLES {
        if table.contains("card") || table.contains("log") {
            assert_eq!(count(&dir.0, table), count(&m.dir.0, table), "{table}");
        }
    }
    let work = tempdir::new("g113v1f");
    let file = work.0.join("v1.bin");
    std::fs::write(&file, &v1).unwrap();
    let again = import_path(h, P, &file, json!({})).unwrap();
    assert_eq!(again["unchanged"], json!(true), "{again}");
    assert_eq!(derived(&dir.0, P, &[me]), derived(&m.dir.0, P, &[mig_dev]));

    let (_qdir, q) = fresh("g113v1q", Q);
    let before = export_bytes(q, Q);
    let e = import_path(q, Q, &file, json!({})).unwrap_err();
    assert!(e.contains("another collection"), "{e}");
    assert_eq!(export_bytes(q, Q), before);
    ffsrs_store_close(q);
    ffsrs_store_close(h);
}

/// 旧版本互拒（规划 §6）：已发布二进制的导入（协议 3 `sync2_import`，冻结在树里）面对新流在魔数处就拒绝，库一字不变；
/// 新代的导出流也没有协议 3 读者认得的魔数。
#[test]
fn old_binaries_refuse_the_new_stream_and_change_nothing() {
    let m = migrated();
    let g4 = export_bytes(m.h, P);
    let before = m.d.core.sync2_export(P).unwrap();
    let e = m.d.core.sync2_import(P, &g4, T1).unwrap_err();
    assert!(e.contains("not a .fushisrs file"), "{e}");
    assert_eq!(m.d.core.sync2_export(P).unwrap(), before);
}

// ---------------------------------------------------------------------- 大文件

/// 内存上界：一份明文上 MB 的导出，按文件读（与导入命令同一个来源）时读窗口不随文件变大；导入命令按路径读完整份。
#[test]
fn a_large_file_is_read_with_a_bounded_window() {
    let (src_dir, src) = fresh("g113big", P);
    let mut seed = 0x9e37_79b9_7f4a_7c15u64;
    let mut items = Vec::new();
    for i in 0..1500 {
        let mut s = String::with_capacity(800);
        for _ in 0..800 {
            seed = seed
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            s.push(char::from(b'a' + (seed >> 59) as u8 % 26));
        }
        items.push(json!({"e": edit("note", N1, &format!("f/x{i}"), json!(s)), "note": N1}));
    }
    let (r, _) = call(src, &g4req("apply", T1, json!({})), Some(&items)).unwrap();
    assert_eq!(r["landed"].as_array().unwrap().len(), 1500);
    let work = tempdir::new("g113bigx");
    let (exp, path) = export_to(src, P, &work.0);
    let file_len = std::fs::metadata(&path).unwrap().len() as usize;
    let plain = zstd::stream::decode_all(std::fs::File::open(&path).unwrap()).unwrap();
    assert!(plain.len() > 1 << 20, "{}", plain.len());
    assert!(file_len > 512 << 10, "{file_len}");
    let f = std::io::BufReader::new(std::fs::File::open(&path).unwrap());
    let (mut rd, _) = Export4Reader::open_reader(f).unwrap();
    let mut widest = rd.window_capacity();
    while rd.next_item().unwrap().is_some() {
        widest = widest.max(rd.window_capacity());
    }
    assert!(widest <= 256 << 10, "window {widest}");
    assert!(widest < file_len, "window {widest} file {file_len}");

    let (dst_dir, dst) = fresh("g113bigd", P);
    // 命令层的读法（复核：之前只量了读者，命令改成整份读进内存也测不出）：导入命令对这个文件的每一次读都是有界的一块，
    // 合起来至少读完整份（嗅探、读头、分叉检查、落库各开一遍）。整份读进内存（`fs::read`）不经 FileSource，记录为零。
    super::fushisrs::meter::take();
    let got = import_path(
        dst,
        P,
        &path,
        json!({"manifest": manifest(&exp), "confirmed": true}),
    )
    .unwrap();
    let reads = super::fushisrs::meter::take();
    assert!(reads.bytes >= file_len as u64, "{reads:?} file {file_len}");
    assert!(reads.calls > 4, "{reads:?}");
    assert!(reads.widest <= 256 << 10, "{reads:?}");
    assert!(reads.widest < file_len, "{reads:?} file {file_len}");
    assert!(got["applied"].as_u64().unwrap() >= 1500, "{got}");
    let me = self_device(dst, P);
    let src_me = self_device(src, P);
    assert_eq!(
        stream(&export_bytes(dst, P), &[me]),
        stream(&export_bytes(src, P), &[])
    );
    let _ = (src_me, src_dir, dst_dir);
    ffsrs_store_close(src);
    ffsrs_store_close(dst);
}

// ---------------------------------------------------------------------- 别名类

/// 双盐场景（`tests_class.rs`）的库导出、在另一个集合的库里确认认领：导入方按任何一份成员点名都是整个类的回答（修改
/// 历史），与导出方相同。
#[test]
fn alias_classes_survive_an_export_and_a_foreign_import() {
    let src_dir = tempdir::new("g113alias");
    let w = {
        let c = G4Core::open(&src_dir.0, OpenMode::Primary).unwrap();
        // 目录名比导入方 Q 小：导入方的空集合按 D27 的方向换绑（G9-5 第二轮复核：只在这个方向上换绑）。
        let col = c.write(|t| t.bind(P, &id(0xc0), "0-dir")).unwrap();
        let w = c.write(|t| Ok(tests_class::land(t, col))).unwrap();
        c.close();
        w
    };
    let src = open(&src_dir.0, 0).unwrap();
    let work = tempdir::new("g113aliasx");
    let (exp, path) = export_to(src, P, &work.0);
    let (_dst_dir, dst) = fresh("g113aliasd", Q);
    let got = import_path(
        dst,
        Q,
        &path,
        json!({"manifest": manifest(&exp), "confirmed": true}),
    )
    .unwrap();
    // 导入方 Q 刚打开、集合里只有本机身份写的 Salts、目录名（Q）比导出方大：确认后丢掉空集合、直接绑到导出方的集合
    // （G9-5「空集合可换绑」）。
    assert_eq!(got["outcome"], json!("bound"), "{got}");
    let hist = |h: *mut SrsCoreHandle, profile: &str, e: &Id| -> Vec<String> {
        let v = try_g4(
            h,
            profile,
            "history",
            json!({"kind": "note", "entity": e.text()}),
        )
        .unwrap();
        let mut out: Vec<String> = v
            .as_array()
            .unwrap()
            .iter()
            .map(|e| {
                format!(
                    "{}={}",
                    e["key"],
                    e.get("value").cloned().unwrap_or(Value::Null)
                )
            })
            .collect();
        out.sort();
        out
    };
    let canon = hist(src, P, &w.c_note);
    assert!(!canon.is_empty());
    for e in [&w.c_note, &w.note[0], &w.note[1]] {
        assert_eq!(hist(dst, Q, e), canon, "{e}");
    }
    let ids = try_g4(
        dst,
        Q,
        "canonical_ids",
        json!({"ids": [w.note[0].text(), w.note[1].text(), w.card[1].text()]}),
    )
    .unwrap();
    assert_eq!(
        ids["ids"],
        json!([w.c_note.text(), w.c_note.text(), w.c_card.text()]),
        "{ids}"
    );
    ffsrs_store_close(src);
    ffsrs_store_close(dst);
}

// ---------------------------------------------------------------------- 查询计划

/// 导出清单的 `peers` 语句按主键前缀找、不排序（主键已按设备排）。
#[test]
fn the_peers_statement_uses_the_primary_key() {
    let m = migrated();
    let c = reader(&m.dir.0);
    let plan: Vec<String> = c
        .prepare(&format!("EXPLAIN QUERY PLAN {PEERS_SQL}"))
        .unwrap()
        .query_map([1], |r| r.get::<_, String>(3))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    assert!(plan.iter().all(|p| p.starts_with("SEARCH")), "{plan:?}");
}

// ---------------------------------------------------------------------- 复核补的几条

/// 操作本机全都已有、只带来新盐或新设备公钥的再导入也是改动：回包 `unchanged` 为 false、修订号推进（Dart 据 `unchanged`
/// 决定丢不丢缓存日志，补盐会收派生层）；真的什么都没带来时才是 `unchanged`。
#[test]
fn new_salts_or_peers_alone_are_a_change() {
    let m = migrated();
    let work = tempdir::new("g113salt");
    let (exp, path) = export_to(m.h, P, &work.0);
    let (_dir, h) = fresh("g113saltd", P);
    let man = manifest(&exp);
    let first = import_path(h, P, &path, json!({"manifest": man, "confirmed": true})).unwrap();
    assert_eq!(first["unchanged"], json!(false), "{first}");

    let mut salted = man.clone();
    salted["salts"].as_array_mut().unwrap().push(json!(Q));
    let got = import_path(h, P, &path, json!({"manifest": salted, "confirmed": true})).unwrap();
    assert_eq!(got["outcome"], json!("saltsAdded"), "{got}");
    assert_eq!(got["applied"], json!(0), "{got}");
    assert_eq!(got["unchanged"], json!(false), "{got}");
    assert!(
        got["localRevision"].as_i64().unwrap() > first["localRevision"].as_i64().unwrap(),
        "{got} {first}"
    );

    let mut peered = salted.clone();
    peered["peers"]
        .as_array_mut()
        .unwrap()
        .push(json!({"device": id(0x77).text(), "public": "ab".repeat(32)}));
    let got2 = import_path(h, P, &path, json!({"manifest": peered, "confirmed": true})).unwrap();
    assert_eq!(got2["outcome"], json!("same"), "{got2}");
    assert_eq!(got2["applied"], json!(0), "{got2}");
    assert!(got2["peers"].as_u64().unwrap() >= 1, "{got2}");
    assert_eq!(got2["unchanged"], json!(false), "{got2}");

    let again = import_path(h, P, &path, json!({"manifest": peered})).unwrap();
    assert_eq!(again["unchanged"], json!(true), "{again}");
    assert_eq!(again["localRevision"], got2["localRevision"], "{again}");
    ffsrs_store_close(h);
}

/// 预检（`preflight: true`）只判、不写：另一个集合回 `needsConfirm`；同一个集合带新盐回 `ready`、盐不留（保存点回滚）；
/// 另一个集合的第 1 版与裸流、坏文件照真导入的口径报错。每一步库都一字不变、修订号不动；预检之后真导入照常落。
#[test]
fn preflight_judges_without_writing() {
    let m = migrated();
    let work = tempdir::new("g113pre");
    let (exp, path) = export_to(m.h, P, &work.0);
    let man = manifest(&exp);
    let v1 = work.0.join("v1.bin");
    std::fs::write(&v1, m.d.core.sync2_export(P).unwrap()).unwrap();
    let pre = |h: *mut SrsCoreHandle, profile: &str, file: &Path, extra: Value| {
        let mut x = json!({"preflight": true});
        for (k, v) in extra.as_object().cloned().unwrap_or_default() {
            x[k.as_str()] = v;
        }
        import_path(h, profile, file, x)
    };

    let (_qd, q) = fresh("g113preq", Q);
    let q_before = export_bytes(q, Q);
    let got = pre(q, Q, &path, json!({"manifest": man})).unwrap();
    assert_eq!(got["outcome"], json!("needsConfirm"), "{got}");
    assert_eq!(got["preflight"], json!(true), "{got}");
    assert_eq!(got["dir"], json!(P), "{got}");
    let e = pre(q, Q, &path, json!({})).unwrap_err();
    assert!(e.contains("another collection"), "{e}");
    let e = pre(q, Q, &v1, json!({})).unwrap_err();
    assert!(e.contains("another collection"), "{e}");
    assert_eq!(export_bytes(q, Q), q_before);
    ffsrs_store_close(q);

    let (_pd, h) = fresh("g113prep", P);
    let before = export_bytes(h, P);
    let mut salted = man.clone();
    salted["salts"].as_array_mut().unwrap().push(json!(Q));
    let got = pre(h, P, &path, json!({"manifest": salted})).unwrap();
    assert_eq!(got["outcome"], json!("needsConfirm"), "{got}");
    assert_eq!(got["reason"], json!("identity"), "{got}");
    assert_eq!(got["preflight"], json!(true), "{got}");
    assert!(
        got["newSalts"].as_array().unwrap().contains(&json!(Q)),
        "{got}"
    );
    let got = pre(h, P, &path, json!({"manifest": salted, "confirmed": true})).unwrap();
    assert_eq!(
        got,
        json!({"format": 2, "outcome": "ready", "preflight": true})
    );
    let got = pre(h, P, &path, json!({})).unwrap();
    assert_eq!(got["outcome"], json!("ready"), "{got}");
    let got = pre(h, P, &v1, json!({})).unwrap();
    assert_eq!(
        got,
        json!({"format": 1, "outcome": "ready", "preflight": true})
    );
    let junk = work.0.join("junk.bin");
    std::fs::write(&junk, b"PK\x03\x04 not an ops stream").unwrap();
    let e = pre(h, P, &junk, json!({})).unwrap_err();
    assert!(e.contains("not a Fushi SRS export"), "{e}");
    assert_eq!(export_bytes(h, P), before, "the preflight wrote something");

    let got = import_path(h, P, &path, json!({"manifest": salted, "confirmed": true})).unwrap();
    assert_eq!(got["outcome"], json!("saltsAdded"), "{got}");
    assert!(got["applied"].as_u64().unwrap() > 0, "{got}");
    ffsrs_store_close(h);
}

/// 导出的临时文件是在整个目标文件名后追加 `.g4tmp`，不是替换扩展名：同目录里只差扩展名的文件不会被当成临时文件覆盖、挪走。
#[test]
fn the_export_temp_file_appends_to_the_whole_name() {
    let (_d, h) = fresh("g113tmp", P);
    let work = tempdir::new("g113tmpx");
    let neighbour = work.0.join("ops.g4tmp");
    std::fs::write(&neighbour, b"keep").unwrap();
    let target = work.0.join("ops.bin");
    try_g4(h, P, "export", json!({"path": target.to_str().unwrap()})).unwrap();
    assert_eq!(std::fs::read(&neighbour).unwrap(), b"keep");
    assert!(target.exists());
    assert!(!work.0.join("ops.bin.g4tmp").exists());
    ffsrs_store_close(h);
}

// ---------------------------------------------------------------------- 合流（W2）：刷新键与身份确认

const REFRESH_KEYS: [&str; 5] = ["content", "structure", "rwkv", "stats", "landed"];

fn refresh_keys(h: *mut SrsCoreHandle, profile: &str) -> Value {
    try_g4(h, profile, "refresh_keys", json!({})).unwrap()
}

/// 导入真改了东西之后进程内刷新键（S1c `refresh.rs`）整份作废；预检、要确认、什么都没改（`unchanged`）的导入不动。
/// 回包里不留分发器取走的内部键。
#[test]
fn an_import_that_changes_something_moves_the_refresh_keys() {
    let m = migrated();
    let work = tempdir::new("g113rk");
    let (exp, path) = export_to(m.h, P, &work.0);
    let man = manifest(&exp);
    let (_dir, h) = fresh("g113rkd", P);
    let k0 = refresh_keys(h, P);
    let pre = import_path(h, P, &path, json!({"manifest": man, "preflight": true})).unwrap();
    assert_eq!(refresh_keys(h, P), k0, "{pre}");
    let ask = import_path(h, P, &path, json!({"manifest": man})).unwrap();
    assert_eq!(ask["outcome"], json!("needsConfirm"), "{ask}");
    assert_eq!(refresh_keys(h, P), k0, "{ask}");
    let got = import_path(h, P, &path, json!({"manifest": man, "confirmed": true})).unwrap();
    assert_eq!(got["unchanged"], json!(false), "{got}");
    assert!(got.get("refreshTally").is_none(), "{got}");
    let k1 = refresh_keys(h, P);
    for k in REFRESH_KEYS {
        assert_ne!(k1[k], k0[k], "{k}: {k0} {k1}");
    }
    let again = import_path(h, P, &path, json!({"manifest": man})).unwrap();
    assert_eq!(again["unchanged"], json!(true), "{again}");
    assert_eq!(refresh_keys(h, P), k1, "{again}");
    // 裸流（不认领）再导一遍同样什么都不改：不动。
    let bare = import_path(h, P, &path, json!({})).unwrap();
    assert_eq!(bare["unchanged"], json!(true), "{bare}");
    assert_eq!(refresh_keys(h, P), k1, "{bare}");
    ffsrs_store_close(h);
}

/// 同一个集合的文件带来本机还不算数的盐或还不认识的设备公钥：没确认回 `needsConfirm`（`reason: identity`，列出
/// `newSalts` / `newPeers`）、库一字不变、修订号不动；预检同形；确认后才落（`saltsAdded`）。确认过的再导一遍不再问。
#[test]
fn new_salts_and_peers_from_a_same_collection_file_need_confirmation() {
    let m = migrated();
    let work = tempdir::new("g113idc");
    let (exp, path) = export_to(m.h, P, &work.0);
    let man = manifest(&exp);
    let (_dir, h) = fresh("g113idcd", P);
    import_path(h, P, &path, json!({"manifest": man, "confirmed": true})).unwrap();
    let base = import_path(h, P, &path, json!({"manifest": man})).unwrap();
    assert_eq!(base["unchanged"], json!(true), "{base}");

    let mut salted = man.clone();
    salted["salts"].as_array_mut().unwrap().push(json!(Q));
    let before = export_bytes(h, P);
    for preflight in [true, false] {
        let mut x = json!({"manifest": salted});
        if preflight {
            x["preflight"] = json!(true);
        }
        let ask = import_path(h, P, &path, x).unwrap();
        assert_eq!(ask["outcome"], json!("needsConfirm"), "{ask}");
        assert_eq!(ask["reason"], json!("identity"), "{ask}");
        assert_eq!(ask["newSalts"], json!([Q]), "{ask}");
        assert_eq!(ask["newPeers"], json!([]), "{ask}");
        assert_eq!(ask["dir"], json!(P), "{ask}");
    }
    assert_eq!(export_bytes(h, P), before, "an unconfirmed salt landed");
    let info = try_g4(h, P, "collection_info", json!({})).unwrap();
    assert!(
        !info["salts"].as_array().unwrap().contains(&json!(Q)),
        "{info}"
    );

    let mut peered = man.clone();
    let stranger = id(0x77).text();
    peered["peers"]
        .as_array_mut()
        .unwrap()
        .push(json!({"device": stranger, "public": "ab".repeat(32)}));
    let ask = import_path(h, P, &path, json!({"manifest": peered})).unwrap();
    assert_eq!(ask["reason"], json!("identity"), "{ask}");
    assert_eq!(ask["newSalts"], json!([]), "{ask}");
    assert_eq!(ask["newPeers"], json!([stranger]), "{ask}");
    assert!(
        !peer_lines(&_dir.0, P)
            .iter()
            .any(|l| l.contains(&hex_upper(&id(0x77))))
    );

    let got = import_path(h, P, &path, json!({"manifest": salted, "confirmed": true})).unwrap();
    assert_eq!(got["outcome"], json!("saltsAdded"), "{got}");
    let again = import_path(h, P, &path, json!({"manifest": salted})).unwrap();
    assert_eq!(again["unchanged"], json!(true), "{again}");
    ffsrs_store_close(h);
}
