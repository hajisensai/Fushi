//! BUG-3959：合成写入者 `sync2:`（标签 OR-Set 的投影行）不进任何因果上下文；v19 迁移去掉存量里的它们，
//! 胜负不变、与新代码重新投影逐字节相同、摘要一致。

use std::sync::Arc;

use serde_json::{json, Value};

use super::tests::{edit, projection, Bucket, Device, P};
use crate::sync2::hlc::Hlc;
use crate::sync2::id::{Id, Key};
use crate::sync2::op::{EditBody, EntKind, LegacyStamp, Op};
use crate::sync2::vv::OpId;
use crate::sync2::vv::Vv;

const T0: i64 = 1_700_000_000_000;

fn count(d: &Device, sql: &str) -> i64 {
    d.rows(sql)[1][0].parse().unwrap()
}

/// 投影行与 `sync2_legacy` 里还带合成写入者的条数。
fn synthetic_in_ctx(d: &Device) -> (i64, i64) {
    (
        count(d, "SELECT COUNT(*) FROM srs_field_edits WHERE instr(json_extract(json, '$.ctx'), '\"sync2:') > 0"),
        count(d, "SELECT COUNT(*) FROM sync2_legacy WHERE instr(ctx, '\"sync2:') > 0"),
    )
}

fn stamped(x: Value) -> Value {
    json!({"e": {"t": "edit", "x": x}, "stamped": true})
}

fn apply_stamped(d: &Device, now: i64, events: Vec<Value>) {
    d.core.sync2_apply_local(P, now, &Value::Array(events).to_string()).unwrap();
}

/// 每个实体的寄存器裁决（registers.rs `registers_report`），按 (种类, 实体) 排好。
fn verdicts(d: &Device) -> Vec<(String, String, Value)> {
    let rows = d.rows(
        "SELECT entity_kind, srs_idt(entity_id) AS e, json FROM srs_field_edits ORDER BY entity_kind, srs_idt(entity_id), srs_idt(id)",
    );
    let mut out: Vec<(String, String, Value)> = Vec::new();
    let mut i = 1;
    while i < rows.len() {
        let (k, e) = (rows[i][0].clone(), rows[i][1].clone());
        let mut group: Vec<String> = Vec::new();
        while i < rows.len() && rows[i][0] == k && rows[i][1] == e {
            group.push(rows[i][2].clone());
            i += 1;
        }
        let items: Vec<crate::registers::StoredEdit<'_>> = group.iter().map(|j| (j.as_str(), None, None)).collect();
        out.push((k, e, crate::registers::registers_report(&items).unwrap()));
    }
    out
}

/// 往每条非合成修改记录的 ctx 里塞进合成写入者（修复前的投影就长这样：本机 legacy 闭包里一条笔记一项）。
fn inject_synthetic_ctx(d: &Device, notes: &[&str]) {
    let w = d.core.writer().unwrap();
    let rows: Vec<(String, String)> = w
        .prepare("SELECT srs_idt(id), json FROM srs_field_edits WHERE writer_id NOT LIKE 'sync2:%'")
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .map(Result::unwrap)
        .collect();
    for (id, text) in rows {
        let mut v: Value = serde_json::from_str(&text).unwrap();
        for n in notes {
            v["ctx"]["vv"][format!("sync2:tags:{n}")] = json!(1);
        }
        v["ctx"]["cloud"] = json!({"sync2:tags:Nz": [3]});
        w.execute(
            "UPDATE srs_field_edits SET jslim = srs_edit_pack(?2, id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq) WHERE id = srs_id(?1)",
            rusqlite::params![id, super::canonical(&v)],
        )
        .unwrap();
    }
}

/// 外来的已盖戳记录（profile 并入 / 备份合并 / 旧 `.fushisrs`）带着合成写入者：合成标签行照样落、标签照样并入；
/// 但它们的 dot 与 ctx 里的合成项不进 `sync2_legacy`、不进新操作的载荷、不进任何投影行；之后本机写的修改 ctx
/// 只有真实写入者。
#[test]
fn stamped_and_local_edits_never_carry_synthetic_writers() {
    let a = Device::new("syn-a");
    apply_stamped(
        &a,
        T0,
        vec![
            stamped(json!({"id": "x", "p": P, "k": "note", "e": "N1", "f": "tags", "w": "sync2:tags:N1", "s": 1,
                "ctx": {"vv": {}}, "v": ["t1"], "hlc": format!("{T0}:0:old"), "ts": "wall"})),
            stamped(json!({"id": "x", "p": P, "k": "note", "e": "N1", "f": "f/x", "w": "old", "s": 3,
                "ctx": {"vv": {"old": 2, "sync2:tags:N2": 1}, "cloud": {"sync2:tags:N3": [1]}}, "v": "o",
                "hlc": format!("{T0}:1:old"), "ts": "wall"})),
        ],
    );
    a.apply(T0 + 10, vec![edit("note", "N1", "f/y", json!("v"))]);
    assert_eq!(synthetic_in_ctx(&a), (0, 0));
    // 真实旧写入者的闭包照旧进本机新修改的 ctx。
    let ctx: Value = serde_json::from_str(
        &a.rows("SELECT json_extract(json, '$.ctx') FROM srs_field_edits WHERE field_key = 'f/y'")[1][0],
    )
    .unwrap();
    assert_eq!(ctx["vv"]["old"], json!(3), "{ctx}");
    assert!(!ctx.to_string().contains("sync2:"), "{ctx}");
    // 新包的操作载荷里也没有 ctx 里的合成项（合成标签行自己的写入者名还在：它是那条记录的身份）。
    assert_eq!(count(&a, "SELECT COUNT(*) FROM sync2_ops WHERE instr(payload, CAST('sync2:tags:N2' AS BLOB)) > 0"), 0);
    assert_eq!(count(&a, "SELECT COUNT(*) FROM sync2_ops WHERE instr(payload, CAST('sync2:tags:N3' AS BLOB)) > 0"), 0);
    let tags = a.rows("SELECT json_extract(json, '$.v') FROM srs_field_edits WHERE field_key = 'tags'");
    assert_eq!(tags[1][0], "[\"t1\"]");
}

/// 修复前的版本包好、已经上传的旧操作（载荷里的旧戳带着合成写入者）：新代码投影时不收——`sync2_legacy` 与投影行
/// 都干净。直接喂投影函数（改已存操作的载荷会坏哈希链，模拟不了「对端收到的旧段」）。
#[test]
fn pre_fix_ops_with_synthetic_writers_project_without_them() {
    let a = Device::new("syn-old");
    let conn = a.core.writer().unwrap();
    let device = Id::random();
    let op = Op {
        id: OpId { device, seq: 7 },
        hlc: Hlc { wall: T0, logical: 0, device },
        deps: Arc::new(Vv::default()),
        kind: crate::sync2::op::KIND_EDIT,
        schema: 1,
        payload: Arc::from(Vec::new()),
        purged: false,
    };
    let body = |writer: &str, ctx: &str| EditBody {
        kind: EntKind::Note,
        entity: Key::of("N1"),
        key: "f/x".into(),
        value: "\"o\"".into(),
        machine: false,
        ts: 0,
        legacy: Some(LegacyStamp {
            writer: writer.into(),
            seq: 3,
            ctx_json: ctx.into(),
            hlc: format!("{T0}:0:{writer}"),
            server_time: None,
        }),
    };
    let ctx = r#"{"cloud":{"sync2:tags:N3":[1]},"vv":{"old":2,"sync2:tags:N2":1}}"#;
    let e = body("old", ctx);
    let (_, row) = super::edit_row(&conn, P, &op, &e).unwrap();
    assert_eq!(row["ctx"], json!({"vv": {"old": 2}}));
    let l = e.legacy.as_ref().unwrap();
    super::note_legacy(&conn, P, &device, 7, l).unwrap();
    let synth = body("sync2:tags:N1", r#"{"vv":{"sync2:tags:N4":1}}"#);
    super::note_legacy(&conn, P, &device, 8, synth.legacy.as_ref().unwrap()).unwrap();
    let stored: String = conn
        .query_row("SELECT ctx FROM sync2_legacy WHERE device = ?1", [device.0.to_vec()], |r| r.get(0))
        .unwrap();
    assert_eq!(stored, r#"{"vv":{"old":3}}"#);
}

/// v19 迁移：修复前的存量（每条修改记录的 ctx 带一大串合成写入者、`sync2_legacy` 也带）去掉之后——
/// (a) 每个实体每个键的胜者、未被支配者、冲突、可见败者、与删除并发的修改都不变（塞进去之前、之后、去掉之后三份相同）；
/// (b) 与从同一批操作新投影的设备逐字节相同、摘要相同；(c) 可重放；`sync2_legacy` 同样去掉。
#[test]
fn v19_strip_keeps_every_verdict_and_matches_a_fresh_projection() {
    let (a, b) = (Device::new("mig-a"), Device::new("mig-b"));
    let mut bucket = Bucket::default();
    // 并发改同一字段（冲突 + 可见败者）、删除与编辑并发、标签（合成行）、牌组字段。
    a.apply(T0, vec![edit("note", "N1", "f/x", json!("a1")), edit("note", "N2", "f/x", json!("keep"))]);
    a.apply(T0 + 1, vec![edit("note", "N1", "tags", json!(["t1", "t2"])), edit("deck", "D1", "collapsed", json!(true))]);
    a.sync(&mut bucket, "loc", T0 + 2);
    b.sync(&mut bucket, "loc", T0 + 3);
    a.apply(T0 + 4, vec![edit("note", "N1", "f/x", json!("a2")), edit("note", "N2", "deleted", json!(T0 + 4))]);
    b.apply(T0 + 5, vec![edit("note", "N1", "f/x", json!("b1")), edit("note", "N2", "f/x", json!("b-edit"))]);
    b.apply(T0 + 6, vec![edit("note", "N1", "tags", json!(["t3"]))]);
    for i in 0..3 {
        a.sync(&mut bucket, "loc", T0 + 10 + i * 2);
        b.sync(&mut bucket, "loc", T0 + 11 + i * 2);
    }
    assert_eq!(projection(&a), projection(&b), "converged before the injection");
    let clean = verdicts(&a);
    assert!(clean.iter().any(|(_, _, v)| v["regs"].as_array().unwrap().iter().any(|r| r[2] == json!(true))), "{clean:?}");

    inject_synthetic_ctx(&a, &["N1", "N2", "N3"]);
    a.core
        .writer()
        .unwrap()
        .execute(
            "INSERT OR REPLACE INTO sync2_legacy (profile_uid, device, upto, ctx) VALUES (srs_id(?1), X'00', 1, ?2)",
            rusqlite::params![P, r#"{"vv":{"old":3,"sync2:tags:N1":1}}"#],
        )
        .unwrap();
    assert!(synthetic_in_ctx(&a).0 > 0);
    assert_ne!(a.digest(), b.digest(), "the bloated projection hashes differently");
    assert_eq!(verdicts(&a), clean, "synthetic dots in ctx never decided anything");

    let (n_legacy, n_rows) = super::strip_synthetic_writers(&a.core.writer().unwrap()).unwrap();
    assert_eq!(n_legacy, 1);
    assert!(n_rows > 0);
    assert_eq!(synthetic_in_ctx(&a), (0, 0));
    assert_eq!(verdicts(&a), clean);
    assert_eq!(projection(&a), projection(&b), "stripped rows equal the fresh projection byte for byte");
    assert_eq!(a.digest(), b.digest());
    assert_eq!(super::strip_synthetic_writers(&a.core.writer().unwrap()).unwrap(), (0, 0), "replayable");

    let legacy = a.rows("SELECT ctx FROM sync2_legacy WHERE device = X'00'");
    assert_eq!(legacy[1][0], r#"{"vv":{"old":3}}"#);
}

/// 真实库副本上的 v19 实测（手动：`FUSHI_SRS_REAL_DB=<v18 库副本> cargo test --lib real_db_v19 -- --ignored --nocapture`；
/// **会把副本升到 v19**，只给副本）。全量比对每个实体的寄存器裁决（不抽样），打印迁移前后体积、耗时与新写一条的大小。
#[test]
#[ignore]
fn real_db_v19_strip_report() {
    let Ok(path) = std::env::var("FUSHI_SRS_REAL_DB") else { return };
    let path = std::path::PathBuf::from(path);
    fn raw(path: &std::path::Path) -> rusqlite::Connection {
        let c = rusqlite::Connection::open(path).unwrap();
        crate::store::ids::register(&c).unwrap();
        crate::store::slim::register(&c).unwrap();
        super::digest::register(&c).unwrap();
        c
    }
    fn one(c: &rusqlite::Connection, sql: &str) -> String {
        c.query_row(sql, [], |r| r.get::<_, rusqlite::types::Value>(0)).map(|v| format!("{v:?}")).unwrap()
    }
    // 每个实体的裁决摘要（BLAKE3(report)），按 (种类, 实体) 顺序流式算，内存只留哈希。
    fn verdict_hashes(c: &rusqlite::Connection) -> Vec<(String, [u8; 32])> {
        let mut stmt = c
            .prepare("SELECT entity_kind, srs_idt(entity_id), json FROM srs_field_edits ORDER BY entity_kind, entity_id, id")
            .unwrap();
        let mut q = stmt.query([]).unwrap();
        let mut out = Vec::new();
        let mut cur: Option<String> = None;
        let mut group: Vec<String> = Vec::new();
        let flush = |cur: &Option<String>, group: &mut Vec<String>, out: &mut Vec<(String, [u8; 32])>| {
            if let Some(k) = cur {
                let items: Vec<crate::registers::StoredEdit<'_>> = group.iter().map(|j| (j.as_str(), None, None)).collect();
                let rep = crate::registers::registers_report(&items).unwrap().to_string();
                out.push((k.clone(), *blake3::hash(rep.as_bytes()).as_bytes()));
            }
            group.clear();
        };
        while let Some(r) = q.next().unwrap() {
            let k = format!("{}/{}", r.get::<_, String>(0).unwrap(), r.get::<_, String>(1).unwrap());
            if cur.as_deref() != Some(k.as_str()) {
                flush(&cur, &mut group, &mut out);
                cur = Some(k);
            }
            group.push(r.get(2).unwrap());
        }
        flush(&cur, &mut group, &mut out);
        out
    }
    let stats = |c: &rusqlite::Connection, tag: &str| {
        eprintln!(
            "[{tag}] schema={} big(>500k) rows/bytes={} / {} | ctx-with-sync2 rows={} | legacy ctx bytes={} | all edits jslim bytes={} | file pages={} free={}",
            one(c, "SELECT value FROM srs_meta WHERE key = 'schema'"),
            one(c, "SELECT COUNT(*) FROM srs_field_edits WHERE length(jslim) > 500000"),
            one(c, "SELECT COALESCE(SUM(length(jslim)), 0) FROM srs_field_edits WHERE length(jslim) > 500000"),
            one(c, "SELECT COUNT(*) FROM srs_field_edits WHERE instr(jslim, '\"sync2:') > 0"),
            one(c, "SELECT group_concat(length(ctx)) FROM sync2_legacy"),
            one(c, "SELECT SUM(length(jslim)) FROM srs_field_edits"),
            one(c, "PRAGMA page_count"),
            one(c, "PRAGMA freelist_count"),
        );
    };
    let (before, profile) = {
        let c = raw(&path);
        stats(&c, "before");
        let p: String = c.query_row("SELECT srs_idt(profile_uid) FROM sync2_self LIMIT 1", [], |r| r.get(0)).unwrap();
        let t = std::time::Instant::now();
        let v = verdict_hashes(&c);
        eprintln!("[before] {} entities judged in {:?}", v.len(), t.elapsed());
        (v, p)
    };
    let t = std::time::Instant::now();
    let core = crate::store::SrsCore::open(&path).unwrap();
    eprintln!("[open+migrate v19] {:?}", t.elapsed());
    drop(core);
    let c = raw(&path);
    stats(&c, "after");
    let after = verdict_hashes(&c);
    assert_eq!(before.len(), after.len());
    let diff = before.iter().zip(&after).filter(|(a, b)| a != b).count();
    eprintln!("[compare] entities={} differing verdicts={diff}", before.len());
    assert_eq!(diff, 0);
    // 增量桶表与全表扫描一致（UPDATE 触发器把改写的行先减后加）。
    assert_eq!(super::digest::root(&c, &profile).unwrap(), super::digest::root_by_scan(&c, &profile).unwrap());
    eprintln!("[digest] incremental root == full scan root");
    drop(c);
    // 新写一条（牌组折叠，布尔值）：看它的 ctx 多大。
    let core = crate::store::SrsCore::open(&path).unwrap();
    let deck: String = {
        let c = raw(&path);
        c.query_row("SELECT srs_idt(id) FROM srs_entities WHERE kind = 'deck' LIMIT 1", [], |r| r.get(0)).unwrap()
    };
    let ev = json!([{"e": {"t": "edit", "x": {"id": "x", "p": profile, "k": "deck", "e": deck, "f": "collapsed", "w": "dart", "s": 1,
        "ctx": {"vv": {}}, "v": true, "hlc": "0:0:dart", "ts": "wall"}}}]);
    let t = std::time::Instant::now();
    core.sync2_apply_local(&profile, 4_102_444_800_000, &ev.to_string()).unwrap();
    eprintln!("[new write] apply {:?}", t.elapsed());
    drop(core);
    let c = raw(&path);
    eprintln!(
        "[new write] jslim bytes={} ctx={}",
        one(&c, "SELECT length(jslim) FROM srs_field_edits WHERE field_key = 'collapsed' ORDER BY rowid DESC LIMIT 1"),
        one(&c, "SELECT json_extract(json, '$.ctx') FROM srs_field_edits WHERE field_key = 'collapsed' ORDER BY rowid DESC LIMIT 1"),
    );
}
