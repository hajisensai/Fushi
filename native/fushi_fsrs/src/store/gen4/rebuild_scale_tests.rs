//! 重建（[Index::rebuild_all]）随库规模的耗时（BUG-5137：迁移第 7/10 步在 683 万条操作、几乎每个日志 ID 都有两份
//! 操作的库上要 1537 秒，单条耗时随规模翻倍）。默认不跑（`#[ignore]`）；跑法：
//!
//! ```text
//! FUSHI_REBUILD_SCALE=2000,4000,8000,16000 cargo test --profile quick --lib rebuild_scale -- --ignored --nocapture
//! ```
//!
//! 合成库（文件库，连接配置与迁移相同：`schema::open`，页缓存 16 MiB）：一个牌组、一个笔记类型（一个字段、一个
//! 模板），每条笔记一条定义、一条带旧戳的字段修改，每张卡 [LOGS] 个日志 ID、每个 ID 在两台旧设备上各一份（资料库
//! 并入留下的副本形态，`log_ix` 里每个 ID 两行）。打出每档的总耗时、每条操作的微秒数与各阶段
//! （[Index::rebuild_stages]）。

use std::time::Instant;

use serde_json::json;

use super::cache::CFG_KEY;
use super::derive::tests::{op, stamp};
use super::derive::{Index, body_of};
use super::schema::open;
use super::truth::Truth;
use super::truth::tests::bound;
use crate::gen4::heritage::HeritageSlot;
use crate::gen4::op::tests::{id, native_edit};
use crate::gen4::op::{Body4, Edit4, Log4};
use crate::gen4::translate::T_VERSION;
use crate::store::sync2::config::default_deck_id;
use crate::store::sync2::tests::P;
use crate::sync2::id::{Id, Key};
use crate::sync2::op::{EntKind, Intent};

/// 每张卡的日志 ID 数。
const LOGS: usize = 5;
const NT: u8 = 0x7a;
const FA: u8 = 0x41;
const T1: u8 = 0x51;
/// 两台旧设备：A 写全部，B 带每条日志的第二份。
const A: u8 = 0xd1;
const B: u8 = 0xd2;
const T0: i64 = 1_700_000_000_000;

fn key(tag: u8, i: usize) -> Key {
    let mut b = [tag; 16];
    b[8..].copy_from_slice(&(i as u64).to_be_bytes());
    Key::Uuid(Id(b))
}

fn log(lid: &Key, card: &Key, at: i64) -> Body4 {
    Body4::Log(Log4 {
        id: lid.clone(),
        card: card.clone(),
        note: None,
        kind: "review".into(),
        rating: Some(3),
        revokes: None,
        at,
        ts: 1,
        origin: "fushi".into(),
        rtype: "review".into(),
        dur: 1000,
        params: None,
        alg: None,
        utc_off: 0,
        rollover: 4,
        anki_id: None,
        fv: 1,
        intent: Intent::Answer,
        res: Some(
            json!({"queue": "review", "dueDay": 20_000, "ivl": 1, "step": 0, "reps": 1, "lapses": 0,
                   "scheduler": "fushi", "lastReviewedAt": at})
            .to_string(),
        ),
        extra: "{}".into(),
        hlc: None,
        server_time: None,
    })
}

fn edit(kind: EntKind, entity: Key, k: &str, value: serde_json::Value, s: Option<i64>) -> Body4 {
    Body4::Edit(Edit4 {
        kind,
        entity,
        key: k.to_owned(),
        value: value.to_string(),
        stamp: s.map(|seq| stamp("w-old", seq, r#"{"vv":{}}"#, 1_000 + seq)),
        ..native_edit()
    })
}

/// 灌一个 [notes] 条笔记的库，返回 (集合, 操作条数)。
fn build(t: &Truth<'_>, notes: usize) -> (i64, u64) {
    let col = bound(t);
    let deck = Key::Uuid(Id::parse(&default_deck_id(P)).expect("deck id"));
    let nt = Key::Uuid(id(NT));
    let mut a: Vec<Body4> = vec![
        Body4::Entity {
            kind: EntKind::Deck,
            id: deck,
            data: json!({"createdAt": 1, "builtin": "default"}).to_string(),
        },
        Body4::Entity {
            kind: EntKind::NoteType,
            id: nt.clone(),
            data: json!({"createdAt": 1, "ntKind": "standard"}).to_string(),
        },
        edit(
            EntKind::NoteType,
            nt.clone(),
            &format!("fieldDef/{}", id(FA).text()),
            json!({"name": "E", "ord": 0}),
            None,
        ),
        edit(
            EntKind::NoteType,
            nt,
            &format!("tmplDef/{}", id(T1).text()),
            json!({"name": "A", "ord": 0, "front": "{{E}}"}),
            None,
        ),
    ];
    let mut b: Vec<Body4> = Vec::new();
    for i in 0..notes {
        let note = key(0x3a, i);
        a.push(Body4::Entity {
            kind: EntKind::Note,
            id: note.clone(),
            data: json!({"createdAt": 1, "guid": format!("g{i}"), "noteTypeId": id(NT).text()})
                .to_string(),
        });
        a.push(edit(
            EntKind::Note,
            note.clone(),
            &format!("f/{}", id(FA).text()),
            // 字段正文像真实笔记一样有几百字节（够长才压缩，`pack::ZSTD_MIN`）。
            json!(format!("<div>語{i}：{}</div>", "例文の本文。".repeat(30))),
            Some(i as i64 + 1),
        ));
        let card =
            Key::of(&crate::registers::card_id(&note.text(), &id(T1).text(), 0).expect("card id"));
        for j in 0..LOGS {
            let lid = key(0x1a, i * LOGS + j);
            let at = T0 + (j as i64) * 86_400_000 + i as i64;
            a.push(log(&lid, &card, at));
            b.push(log(&lid, &card, at));
        }
    }
    let n = (a.len() + b.len()) as u64;
    for (dev, bodies) in [(A, a), (B, b)] {
        for (chunk_no, chunk) in bodies.chunks(20_000).enumerate() {
            t.tx(|t| {
                for (j, body) in chunk.iter().enumerate() {
                    let seq = (chunk_no * 20_000 + j) as u64 + 1;
                    let o = op(dev, seq, T0 + seq as i64, &[], body);
                    let fp: [u8; 8] = seq.to_le_bytes();
                    t.put_heritage(col, &id(0xc0), &HeritageSlot::op(fp, o), T_VERSION)?;
                }
                Ok(())
            })
            .unwrap();
        }
    }
    let cfg = json!({"defaultDeck": default_deck_id(P)}).to_string();
    t.tx(|t| t.set_derive_cfg(col, CFG_KEY, Some(&cfg)))
        .unwrap();
    (col, n)
}

#[test]
#[ignore = "benchmark: run with --ignored --nocapture"]
fn rebuild_scale_duplicated_logs() {
    let scales: Vec<usize> = std::env::var("FUSHI_REBUILD_SCALE")
        .unwrap_or_else(|_| "2000,4000,8000".to_owned())
        .split(',')
        .map(|s| s.trim().parse().expect("scale"))
        .collect();
    let dir = std::env::temp_dir().join(format!("fushi-rebuild-scale-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    for notes in scales {
        let path = dir.join(format!("scale-{notes}.db"));
        let _ = std::fs::remove_file(&path);
        let conn = open(&path).unwrap();
        // A/B：`FUSHI_REBUILD_CACHE_KIB` 改页缓存（只量测用，迁移连接固定 16 MiB）。
        if let Ok(kib) = std::env::var("FUSHI_REBUILD_CACHE_KIB") {
            conn.execute_batch(&format!("PRAGMA cache_size = -{kib}"))
                .unwrap();
        }
        let t = Truth::new(&conn);
        let built = Instant::now();
        let (col, ops) = build(&t, notes);
        let built = built.elapsed().as_secs_f64();
        let started = Instant::now();
        let (settled, stages) = t
            .tx(|t| {
                let mut ix = Index::new(t, col);
                let s = ix.rebuild_all()?;
                Ok((s, std::mem::take(&mut ix.rebuild_stages)))
            })
            .unwrap();
        let secs = started.elapsed().as_secs_f64();
        // 派生层读修改操作的两种读法（BUG-5137 第 7 步「派生层只要头部」）：整条（`entry_by_key` + `body_of`）对
        // 只解头部（`Truth::edit_read`），走同一批 `reg_ix` 行。
        let ks: Vec<i64> = conn
            .prepare("SELECT k FROM reg_ix WHERE col = ?1")
            .unwrap()
            .query_map([col], |r| r.get(0))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        let at = Instant::now();
        for &k in &ks {
            let e = t.entry_by_key(k).unwrap().unwrap();
            assert!(matches!(body_of(&e), Some(Body4::Edit(_))));
        }
        let whole = at.elapsed().as_secs_f64();
        let at = Instant::now();
        for &k in &ks {
            assert!(t.edit_read(k, false).unwrap().is_some());
        }
        let head = at.elapsed().as_secs_f64();
        eprintln!(
            "[rebuild_scale] edits {}: whole decode {whole:.2}s, head only {head:.2}s",
            ks.len()
        );
        let stages: Vec<String> = stages
            .iter()
            .map(|(n, s)| format!("{n} {:.2}", s))
            .collect();
        eprintln!(
            "[rebuild_scale] notes {notes} ops {ops} build {built:.1}s rebuild {secs:.2}s = {:.1} us/op; logs {} cacheCards {} | {}",
            secs * 1e6 / ops as f64,
            settled.logs,
            settled.cache_cards,
            stages.join(", ")
        );
        drop(t);
        drop(conn);
        let _ = std::fs::remove_file(&path);
    }
    let _ = std::fs::remove_dir_all(&dir);
}
