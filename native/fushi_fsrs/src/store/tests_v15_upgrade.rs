//! 生成器源码在 tests/fixtures/srs_v15_generator.rs.txt（放进 989d9c5130 的 store/sync2/ 下跑）。
//!
//! 真实 v15 库升级（v16 快照外置 + v17 ID 编码）的对拍：tests/fixtures/srs_v15.db.zst 与 srs_v15_vectors.json.zst 由 #2651
//! 头（schema v15，989d9c5130）的实现生成——两台设备、两个同步位置，UUID 与非 UUID 的 ID 混合，含并发修改。升级后逐表
//! 逐行与旧实现导出的内容相同（ID 列解码回文本比），摘要相同，升级后的库照常作答、同步。
use std::collections::BTreeMap;
use std::io::Read;

use serde_json::{json, Value};

use super::sync2::tests::{review, tempdir, Bucket, Device, DAY, P};
use crate::store::SrsCore;

fn unzstd(name: &str) -> Vec<u8> {
    let path = format!("{}/tests/fixtures/{name}", env!("CARGO_MANIFEST_DIR"));
    let file = std::fs::File::open(&path).unwrap();
    let mut out = Vec::new();
    ruzstd::decoding::StreamingDecoder::new(file).unwrap().read_to_end(&mut out).unwrap();
    out
}

/// 与生成端同形的逐表导出：值渲染成 `类型首字母:值`，BLOB 是 `b:十六进制`；ID 列先解码回文本；行排序后比。
fn dump(d: &Device) -> Value {
    let id_cols: BTreeMap<&str, &[&str]> = crate::store::ids::COLUMNS.iter().copied().collect();
    let tables = d.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name");
    let mut out = serde_json::Map::new();
    for t in tables.iter().skip(1) {
        let name = t[0].as_str();
        let cols = d.rows(&format!("SELECT name FROM pragma_table_xinfo('{name}') ORDER BY cid"));
        let cols: Vec<String> = cols.iter().skip(1).map(|r| r[0].clone()).collect();
        let ids = id_cols.get(name).copied().unwrap_or(&[]);
        let sel: Vec<String> = cols
            .iter()
            .map(|c| {
                let v = if ids.contains(&c.as_str()) { format!("srs_idt(\"{c}\")") } else { format!("\"{c}\"") };
                format!("CASE typeof({v}) WHEN 'blob' THEN 'b:' || hex({v}) WHEN 'null' THEN 'n' ELSE substr(typeof({v}), 1, 1) || ':' || {v} END")
            })
            .collect();
        let rows = d.rows(&format!("SELECT {} FROM \"{name}\" -- ids:text", sel.join(", ")));
        let mut rows: Vec<Vec<String>> = rows.into_iter().skip(1).collect();
        if name == "sync2_ops" {
            expand_payloads(d, &cols, &mut rows);
        }
        rows.sort();
        out.insert(name.to_owned(), json!({"cols": cols, "rows": rows}));
    }
    Value::Object(out)
}

/// v16 起日志操作的配置快照按引用存（`sc` / `sc_at` 指向 `sync2_snapshots`）：比之前先拼回原文，载荷应与 v15 逐字节相同。
fn expand_payloads(d: &Device, cols: &[String], rows: &mut [Vec<String>]) {
    let at = |c: &str| cols.iter().position(|x| x == c).unwrap();
    let (dev, seq, payload) = (at("device"), at("seq"), at("payload"));
    let w = d.core.writer().unwrap();
    let mut full: BTreeMap<(Vec<u8>, i64), Vec<u8>> = BTreeMap::new();
    let mut st = w.prepare("SELECT device, seq, payload, sc, sc_at FROM sync2_ops").unwrap();
    let mut q = st.query([]).unwrap();
    while let Some(r) = q.next().unwrap() {
        let p = super::sync2::snapshots::unpack_payload(&w, r.get(2).unwrap(), r.get(3).unwrap(), r.get(4).unwrap()).unwrap();
        full.insert((r.get(0).unwrap(), r.get(1).unwrap()), p);
    }
    let hex = |b: &[u8]| b.iter().map(|x| format!("{x:02X}")).collect::<String>();
    for r in rows.iter_mut() {
        let device = (0..r[dev].len() / 2 - 1).map(|i| u8::from_str_radix(&r[dev][2 + 2 * i..4 + 2 * i], 16).unwrap()).collect::<Vec<u8>>();
        let s: i64 = r[seq][2..].parse().unwrap();
        r[payload] = format!("b:{}", hex(&full[&(device, s)]));
    }
}

/// 旧表与新表共有的列上逐行比较。
fn diff_rows(table: &str, old: &Value, new: &Value) -> Option<String> {
    let oc: Vec<&str> = old["cols"].as_array().unwrap().iter().map(|c| c.as_str().unwrap()).collect();
    let nc: Vec<&str> = new["cols"].as_array().unwrap().iter().map(|c| c.as_str().unwrap()).collect();
    let common: Vec<&str> = oc.iter().copied().filter(|c| nc.contains(c)).collect();
    let pick = |rows: &Value, cols: &[&str]| -> Vec<Vec<String>> {
        let idx: Vec<usize> = common.iter().map(|c| cols.iter().position(|x| x == c).unwrap()).collect();
        let mut out: Vec<Vec<String>> = rows
            .as_array()
            .unwrap()
            .iter()
            .map(|r| idx.iter().map(|&i| r[i].as_str().unwrap().to_owned()).collect())
            .collect();
        out.sort();
        out
    };
    let a = pick(&old["rows"], &oc);
    let b = pick(&new["rows"], &nc);
    let only_old: Vec<&Vec<String>> = a.iter().filter(|r| !b.contains(r)).collect();
    let only_new: Vec<&Vec<String>> = b.iter().filter(|r| !a.contains(r)).collect();
    if only_old.is_empty() && only_new.is_empty() {
        return None;
    }
    Some(format!("{table} {common:?}
  old only: {:?}
  new only: {:?}", &only_old[..only_old.len().min(3)], &only_new[..only_new.len().min(3)]))
}

/// develop@6486c650c5（schema v8）`transport.rs` 的 `digest` 原样搬来（只把 ID 列换成解码后的文本）：16 桶按 ID
/// 首字节分、桶内按 ID 文本顺序逐行哈希，根 = 16 个桶哈希顺序拼接再 BLAKE3。
fn legacy_v8_digest(d: &Device, profile: &str) -> String {
    let w = d.core.writer().unwrap();
    let mut buckets: Vec<blake3::Hasher> = (0..16).map(|_| blake3::Hasher::new()).collect();
    for (table, body, tag) in
        [("srs_entities", "kind || payload_json", b'e'), ("srs_field_edits", "json", b'f'), ("srs_review_logs", "json", b'l')]
    {
        let mut stmt = w
            .prepare(&format!(
                "SELECT srs_idt(id) AS i, {body} FROM {table} WHERE profile_uid = srs_id(?1) ORDER BY i"
            ))
            .unwrap();
        let mut q = stmt.query([profile]).unwrap();
        while let Some(r) = q.next().unwrap() {
            let id: String = r.get(0).unwrap();
            let body: String = r.get(1).unwrap();
            let h = &mut buckets[id.as_bytes().first().map_or(0, |c| (*c as usize) % 16)];
            h.update(&[tag]);
            h.update(&(id.len() as u64).to_le_bytes());
            h.update(id.as_bytes());
            h.update(&(body.len() as u64).to_le_bytes());
            h.update(body.as_bytes());
        }
    }
    let mut root = blake3::Hasher::new();
    for h in buckets {
        root.update(h.finalize().as_bytes());
    }
    root.finalize().to_hex().to_string()
}

#[test]
fn a_real_v15_database_upgrades_row_for_row() {
    upgrades_row_for_row("v15");
}

/// 真实 v8 库（develop@6486c650c5，schema v8 的实现生成；生成器 tests/fixtures/srs_v8_generator.rs.txt）一路升到当前
/// 版本（v9 … v18 的每一步：队列索引、寄存器重建、v12 性能、v13 Anki 数字 ID、v14 摘要桶重建、v15、v16 快照外置、
/// v17 ID 编码、v18 瘦 JSON）：旧表逐表逐行无损、摘要逐位相同、升级后与新设备同步收到的日志与旧实现相同。
#[test]
fn a_real_v8_database_upgrades_row_for_row() {
    upgrades_row_for_row("v8");
}

/// [ver] 的夹具 `srs_<ver>.db.zst` / `srs_<ver>_vectors.json.zst` 升到当前版本后与旧实现导出的逐项比。
fn upgrades_row_for_row(ver: &str) {
    let dir = tempdir::new(&format!("{ver}-up"));
    let path = dir.0.join("srs.db");
    std::fs::write(&path, unzstd(&format!("srs_{ver}.db.zst"))).unwrap();
    let vectors: Value = serde_json::from_slice(&unzstd(&format!("srs_{ver}_vectors.json.zst"))).unwrap();
    let a = Device { core: SrsCore::open(&path).unwrap(), _dir: tempdir::new("unused") };
    assert_eq!(a.rows("SELECT value FROM srs_meta WHERE key = 'schema'")[1][0], crate::store::schema::SCHEMA_VERSION.to_string());

    // ID 已编码：每张表的 UUID 都成了 16 字节 BLOB，非 UUID 的旧 ID 还是文本。
    let blobs: i64 = a.rows("SELECT COUNT(*) FROM srs_review_logs WHERE typeof(id) = 'blob'")[1][0].parse().unwrap();
    let texts: i64 = a.rows("SELECT COUNT(*) FROM srs_review_logs WHERE typeof(id) = 'text'")[1][0].parse().unwrap();
    assert!(blobs > 0 && texts > 0, "blobs={blobs} texts={texts}");

    let old = vectors["tables"].as_object().unwrap();
    let new = dump(&a);
    let mut diffs = Vec::new();
    // srs_meta 里只有版本号变、多一条一次性整理的记录（store/compact.rs），别的键值不变。
    let meta = |t: &Value| -> Value {
        let rows: Vec<&Value> =
            t["rows"].as_array().unwrap().iter().filter(|r| !["t:schema", "t:compact_last"].contains(&r[0].as_str().unwrap())).collect();
        json!({"cols": t["cols"], "rows": rows})
    };
    for (table, o) in old {
        let n = new.get(table).unwrap_or_else(|| panic!("table {table} gone after upgrade"));
        let (o, n) = if table == "srs_meta" { (&meta(o), &meta(n)) } else { (o, n) };
        diffs.extend(diff_rows(table, o, n));
    }
    assert!(diffs.is_empty(), "{}", diffs.join("
"));
    let got = a.core.sync2_digest(P).unwrap();
    if ver == "v8" {
        // v12 把摘要换成按 blake3(id) 分 4096 桶的可增减和（sync2/digest.rs 文件头：「与旧格式不能比」，域分隔
        // `fushi-srs-digest-v2`），v8 夹具里记的是旧算法（16 桶、按 ID 首字节、顺序哈希）的根，新旧根逐位不同是设计
        // 使然。所以分两步钉死：① 用旧算法对升级后的数据重算，必须与 v8 实现当时算出的根逐位相同——摘要的全部输入
        // （实体 `kind || payload_json`、修改记录 `json`、日志 `json`，按 ID 文本）无损；② 升级后由触发器维护的桶表
        // 求出的根等于对同样数据从头扫描算的根——v14 的桶表全量重建没有漏行或多算。版本向量部分逐字相同。
        assert_eq!(legacy_v8_digest(&a, P), vectors["digest"]["digest"].as_str().unwrap());
        let w = a.core.writer().unwrap();
        assert_eq!(got["digest"].as_str().unwrap(), super::sync2::digest::root_by_scan(&w, P).unwrap());
        drop(w);
        assert_eq!(got["vv"], vectors["digest"]["vv"]);
    } else {
        // 摘要逐位相同。
        assert_eq!(got, vectors["digest"]);
    }

    // 升级后与一台新设备在新位置同步：新设备收到的复习日志与旧实现（生成夹具时同样的操作）逐条相同。
    let t = 1_700_000_000_000 + 20 * DAY;
    let mut bucket = Bucket::default();
    let c = Device::new(&format!("{ver}-fresh"));
    for _ in 0..2 {
        a.sync(&mut bucket, "fresh", t);
        c.sync(&mut bucket, "fresh", t);
    }
    let got = c.rows("SELECT srs_idt(id) AS id, json FROM srs_review_logs ORDER BY srs_idt(id)");
    assert_eq!(json!(got[1..]), json!(vectors["fresh_logs"].as_array().unwrap()[1..]));

    // 升级后照常作答：新日志按 BLOB 存，读回来是原文本。
    let card = "0193a1b2-0004-7000-8000-000000000001";
    let log = "0193a1b2-0005-7000-8000-00000000ffff";
    a.apply(t + DAY, vec![review(log, card, t + DAY, 3, "review")]);
    let got = a.rows(&format!("SELECT typeof(id), srs_idt(card_id) FROM srs_review_logs WHERE id = srs_id('{log}')"));
    assert_eq!(got[1], vec!["blob".to_owned(), card.to_owned()]);
}
