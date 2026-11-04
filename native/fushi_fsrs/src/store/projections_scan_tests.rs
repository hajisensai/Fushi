//! 整 profile 日志扫描（RWKV 回放 / 优化器训练集 / RWKV 逐卡）的回归向量与内存基准。
//!
//! 合成 profile：UUID 卡 / 日志 ID、几台设备的 HLC、学习序列 → 复习、手动重置、撤销、Anki 导入（墙钟、ankiId）、
//! 服务器时刻（部分被钳位）、血统里的前身卡、列卡之后才出现的「漏卡」，九成按生产写法瘦存（`srs_log_pack`），
//! 一成存原文；行的插入顺序按时间但成批乱序（同步晚到）。
//!
//! 向量：改动扫描实现（2026-11-03，扫描时就解析成紧凑结构、不留 JSON 原文）之前用旧实现跑出的输出摘要
//! （长度 + FNV-1a 64），新实现必须逐字节相同。基准（`#[ignore]`）：35 万条日志上 `rwkv_replay` 的峰值堆内存与耗时，
//! 计数分配器只在本测试二进制里装。

use rusqlite::types::Value;

use super::projections::RwkvRange;
use super::sync2::mem_bench::measure;
use super::SrsCore;
use crate::projection::{Alg, Day};

/// 确定性伪随机（splitmix64）。
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }

    fn uuid(&mut self) -> String {
        let a = self.next();
        let b = self.next();
        format!(
            "{:08x}-{:04x}-4{:03x}-8{:03x}-{:012x}",
            a >> 32,
            (a >> 16) & 0xffff,
            a & 0xfff,
            b >> 52,
            b & 0xffff_ffff_ffff
        )
    }
}

const DAY_MS: i64 = 86_400_000;
const T0: i64 = 1_700_000_000_000;

/// 合成 profile 的调用方输入：每份历史的血统（第一张是卡自己）与数字 id。
struct Synth {
    groups: Vec<Vec<String>>,
    ids: Vec<i64>,
    /// 插入的日志行数（= 最大 rowid）。
    rows: i64,
}

/// 一条待插入的日志：(时刻, 列, JSON 原文, 服务器时刻)。
struct Pending {
    at: i64,
    id: String,
    card: String,
    kind: &'static str,
    rating: Option<i64>,
    rtype: &'static str,
    origin: &'static str,
    dur: i64,
    json: String,
    server_time: Option<i64>,
}

fn result_json(rng: &mut Rng, queue: &str, reps: i64, at: i64) -> serde_json::Value {
    let s = 0.5 + (rng.below(40_000) as f64) / 100.0;
    let d = 1.0 + (rng.below(900) as f64) / 100.0;
    serde_json::json!({
        "queue": queue,
        "dueDay": 19_700 + rng.below(400) as i64,
        "ivl": rng.below(200) as i64,
        "reps": reps,
        "lapses": rng.below(4) as i64,
        "lastReviewedAt": at,
        "mem": {"s": s, "d": d},
        "ease": 2500,
        "scheduler": "fsrs7",
    })
}

/// 造 `cards` 份历史、共约 `target` 条日志（另加几张漏卡），按时间成批乱序插入。
fn synth(c: &SrsCore, cards: usize, target: usize, seed: u64) -> Synth {
    let mut rng = Rng(seed);
    let writers: Vec<String> = (0..4).map(|_| rng.uuid()).collect();
    let mut pending: Vec<Pending> = Vec::with_capacity(target + 64);
    let mut groups: Vec<Vec<String>> = Vec::with_capacity(cards);
    let per = (target / cards).max(2) as i64;
    // 一张卡的一串日志（学习 → 复习，夹着重置 / 撤销 / 导入）。
    let card_logs = |rng: &mut Rng, card: &str, start: i64, n: i64, pending: &mut Vec<Pending>| {
        let mut at = start;
        let mut reps = 0;
        let mut last_id: Option<String> = None;
        let mut learning = true;
        for k in 0..n {
            at += if learning { 60_000 + rng.below(600_000) as i64 } else { DAY_MS * (1 + rng.below(20) as i64) };
            let id = rng.uuid();
            let writer = &writers[rng.below(writers.len() as u64) as usize];
            let roll = rng.below(100);
            let wall = rng.below(10) == 0;
            let mut m = serde_json::Map::new();
            let (kind, rtype, origin, rating): (&'static str, &'static str, &'static str, Option<i64>);
            if roll < 3 && k > 0 {
                // 手动重置：新卡、reps 归零；之后重新学习。
                kind = "manual";
                rtype = "manual";
                origin = "fushi";
                rating = None;
                reps = 0;
                learning = true;
                m.insert("res".into(), result_json(rng, "new", 0, at));
            } else if roll < 6 && last_id.is_some() {
                kind = "undo";
                rtype = "manual";
                origin = "fushi";
                rating = None;
                m.insert("revokes".into(), serde_json::json!(last_id.clone().unwrap()));
            } else if roll < 8 {
                kind = "suspend";
                rtype = "manual";
                origin = "fushi";
                rating = None;
            } else {
                kind = "review";
                let r = 1 + rng.below(4) as i64;
                rating = Some(r);
                rtype = if learning {
                    "learn"
                } else if r == 1 {
                    "relearn"
                } else {
                    "review"
                };
                origin = if roll < 14 { "anki" } else { "fushi" };
                reps += 1;
                if learning && reps >= 2 {
                    learning = false;
                }
                let q = if learning { "learning" } else { "review" };
                m.insert("res".into(), result_json(rng, q, reps, at));
                if origin == "anki" {
                    m.insert("ankiId".into(), serde_json::json!(at + rng.below(3) as i64));
                }
                if rng.below(3) == 0 {
                    m.insert("alg".into(), serde_json::json!(["fsrs7", "fsrs6", "rwkv"][rng.below(3) as usize]));
                }
                if rng.below(50) == 0 {
                    m.insert("memAlg".into(), serde_json::json!("fsrs6"));
                }
            }
            let dur = if kind == "review" { 800 + rng.below(20_000) as i64 } else { 0 };
            m.insert("id".into(), serde_json::json!(id));
            m.insert("p".into(), serde_json::json!("p"));
            m.insert("card".into(), serde_json::json!(card));
            m.insert("kind".into(), serde_json::json!(kind));
            if let Some(r) = rating {
                m.insert("rating".into(), serde_json::json!(r));
            }
            m.insert("hlc".into(), serde_json::json!(format!("{}:{}:{}", at, rng.below(3), writer)));
            m.insert("at".into(), serde_json::json!(at));
            m.insert("ts".into(), serde_json::json!(if wall { "wall" } else { "anchored" }));
            m.insert("origin".into(), serde_json::json!(origin));
            m.insert("rtype".into(), serde_json::json!(rtype));
            if dur != 0 {
                m.insert("dur".into(), serde_json::json!(dur));
            }
            m.insert("params".into(), serde_json::json!("p:0123456789abcdef"));
            m.insert("utcOff".into(), serde_json::json!(540));
            m.insert("rollover".into(), serde_json::json!(4));
            m.insert("fv".into(), serde_json::json!(2));
            let server_time = match rng.below(10) {
                0..=3 => None,
                4 => Some(at - DAY_MS * 3),
                _ => Some(at + rng.below(5_000) as i64),
            };
            if kind == "review" {
                last_id = Some(id.clone());
            }
            pending.push(Pending {
                at,
                id,
                card: card.to_owned(),
                kind,
                rating,
                rtype,
                origin,
                dur,
                json: serde_json::to_string(&serde_json::Value::Object(m)).unwrap(),
                server_time,
            });
        }
    };
    for g in 0..cards {
        let card = rng.uuid();
        let start = T0 + rng.below(400) as i64 * DAY_MS;
        let n = (per / 2 + rng.below(per as u64) as i64).max(1);
        let mut lineage = vec![card.clone()];
        if g % 20 == 7 {
            // 前身卡（换笔记类型留下的旧卡）：历史在它身上开头。
            let pred = rng.uuid();
            card_logs(&mut rng, &pred, start - 30 * DAY_MS, 3, &mut pending);
            lineage.push(pred);
        }
        card_logs(&mut rng, &card, start, n, &mut pending);
        groups.push(lineage);
    }
    // 漏卡：不在任何血统里。
    for _ in 0..5 {
        let stray = rng.uuid();
        card_logs(&mut rng, &stray, T0 + 500 * DAY_MS, 2, &mut pending);
    }
    pending.sort_by_key(|p| p.at);
    // 成批乱序：每 64 条里随机打乱（同步晚到的批次）。
    for chunk in pending.chunks_mut(64) {
        for i in (1..chunk.len()).rev() {
            let j = rng.below(i as u64 + 1) as usize;
            chunk.swap(i, j);
        }
    }
    c.exec("BEGIN", &[], false).unwrap();
    for (k, p) in pending.iter().enumerate() {
        let jslim = if k % 10 == 3 {
            "?10".to_owned()
        } else {
            "srs_log_pack(?10, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)".to_owned()
        };
        c.exec(
            &format!(
                "INSERT INTO srs_review_logs (id, profile_uid, card_id, kind, rating, occurred_at, review_type, origin, duration_ms, jslim) \
                 VALUES (srs_id(?1), srs_id(?2), srs_id(?3), ?4, ?5, ?6, ?7, ?8, ?9, {jslim})"
            ),
            &[
                Value::Text(p.id.clone()),
                Value::Text("p".into()),
                Value::Text(p.card.clone()),
                Value::Text(p.kind.into()),
                p.rating.map_or(Value::Null, Value::Integer),
                Value::Integer(p.at),
                Value::Text(p.rtype.into()),
                Value::Text(p.origin.into()),
                Value::Integer(p.dur),
                Value::Text(p.json.clone()),
            ],
            false,
        )
        .unwrap();
        if let Some(st) = p.server_time {
            c.exec(
                "INSERT INTO srs_event_local (event_id, profile_uid, server_time) VALUES (srs_id(?1), srs_id(?2), ?3)",
                &[Value::Text(p.id.clone()), Value::Text("p".into()), Value::Integer(st)],
                false,
            )
            .unwrap();
        }
    }
    c.exec("COMMIT", &[], false).unwrap();
    let ids: Vec<i64> = (0..groups.len() * 4).map(|i| 1000 + i as i64).collect();
    Synth { groups, ids, rows: pending.len() as i64 }
}

fn core(name: &str) -> SrsCore {
    let dir = std::env::temp_dir().join(format!("ffsrs_scan_{name}_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let p = dir.join("srs.db");
    for ext in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{ext}", p.display()));
    }
    let c = SrsCore::open(&p).unwrap();
    c.legacy_mark_none().unwrap();
    c
}

/// 输出摘要：长度 + FNV-1a 64。
fn digest(b: &[u8]) -> (usize, u64) {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for &x in b {
        h ^= x as u64;
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    (b.len(), h)
}

const D: Day = Day { utc_offset_min: 540, rollover_hour: 4 };

/// 一组调用的输出摘要（顺序固定，见 [SCAN_VECTORS]）。
fn scan_outputs(c: &SrsCore, s: &Synth) -> Vec<(usize, u64)> {
    let n = s.rows;
    let since = n / 2;
    let mut out = Vec::new();
    let replay = |since: i64, range: RwkvRange| digest(&c.rwkv_replay("p", &s.groups, &s.ids, &D, since, range).unwrap());
    out.push(replay(since, RwkvRange::default()));
    out.push(replay(n, RwkvRange::default()));
    for base in [n * 9 / 10, n * 99 / 100, n - 3] {
        out.push(replay(base, RwkvRange { rebase_since: Some(base), rows_from: None }));
        out.push(replay(base, RwkvRange { rebase_since: Some(base), rows_from: Some(T0 + 200 * DAY_MS) }));
    }
    out.push(replay(n, RwkvRange { rebase_since: Some(n), rows_from: None }));
    // 只给部分卡（其余都成了漏卡）。
    let half: Vec<Vec<String>> = s.groups[..s.groups.len() / 2].to_vec();
    out.push(digest(&c.rwkv_replay("p", &half, &s.ids[..half.len() * 4], &D, 0, RwkvRange::default()).unwrap()));
    let card_ids: Vec<i64> = (0..s.groups.len() as i64).collect();
    out.push(digest(&c.optimizer_items(&s.groups, &card_ids, Alg::Fsrs7, &D).unwrap()));
    out.push(digest(&c.optimizer_items(&s.groups, &card_ids, Alg::Fsrs6, &D).unwrap()));
    let some = &s.groups[..s.groups.len().min(300)];
    out.push(digest(&c.rwkv_cards(some, &s.ids[..some.len() * 4], &D).unwrap()));
    out
}

/// 旧实现（扫描时留 JSON 原文）跑出的摘要。
const SCAN_VECTORS: &[(usize, u64)] = &[
    (567236, 18229953843773811911),
    (567036, 7094045539091026492),
    (269444, 16195887277329384220),
    (358436, 2415489732893743140),
    (126012, 5967832298583993582),
    (358236, 16071242567022168792),
    (3804, 2450468029866312275),
    (358236, 9082045737538904433),
    (60, 16813038352655682568),
    (292508, 5307347981762726681),
    (138400, 7977254060440931981),
    (138400, 5687057432165487693),
    (363972, 1559909685104941592),
];

#[test]
fn scan_outputs_match_the_vectors_recorded_from_the_json_holding_implementation() {
    let c = core("vectors");
    let s = synth(&c, 600, 9_000, 0x5eed_2026_1103);
    // 九成按生产写法瘦存、一成原文：两条解析路径都走到（页首行是列名）。
    let count = |sql: &str| -> i64 {
        match &super::rows::decode(&c.exec(sql, &[], true).unwrap()).unwrap().1[1][0] {
            Value::Integer(n) => *n,
            v => panic!("{v:?}"),
        }
    };
    let slim = count("SELECT count(*) FROM srs_review_logs WHERE substr(jslim, 1, 1) = '~'");
    assert_eq!(count("SELECT count(*) FROM srs_review_logs"), s.rows);
    assert!(slim > s.rows * 8 / 10 && slim < s.rows, "slim {slim} of {}", s.rows);
    let got = scan_outputs(&c, &s);
    assert_eq!(got, SCAN_VECTORS);
}

/// 基准：`cargo test --release --lib rwkv_replay_bench -- --ignored --nocapture --test-threads=1`。
#[test]
#[ignore]
fn rwkv_replay_bench() {
    let logs: usize = std::env::var("FFSRS_BENCH_LOGS").ok().and_then(|v| v.parse().ok()).unwrap_or(350_000);
    let c = core("bench");
    let t = std::time::Instant::now();
    let s = synth(&c, logs / 10, logs, 0xbe4c_2026);
    eprintln!("synth: {} rows, {} groups in {:?}", s.rows, s.groups.len(), t.elapsed());
    for (label, range, since) in [
        ("full", RwkvRange::default(), s.rows),
        ("rebase", RwkvRange { rebase_since: Some(s.rows - 50), rows_from: None }, s.rows - 50),
    ] {
        for _ in 0..3 {
            let (out, m) = measure(|| c.rwkv_replay("p", &s.groups, &s.ids, &D, since, range).unwrap());
            println!(
                "BENCH rwkv_replay {label:<7} rust_peak={:>6.1}MiB sqlite_peak={:>5.1}MiB {}ms output={:.1}MiB",
                m.rust_peak, m.sqlite_peak, m.ms, out.len() as f64 / 1048576.0
            );
        }
    }
    let card_ids: Vec<i64> = (0..s.groups.len() as i64).collect();
    let (_, m) = measure(|| c.optimizer_items(&s.groups, &card_ids, Alg::Fsrs7, &D).unwrap());
    println!("BENCH optimizer_items rust_peak={:>6.1}MiB sqlite_peak={:>5.1}MiB {}ms", m.rust_peak, m.sqlite_peak, m.ms);
}
