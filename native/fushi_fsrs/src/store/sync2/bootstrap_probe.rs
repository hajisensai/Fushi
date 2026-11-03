//! 新设备冷启动耗时探针（默认不跑）：批量通道设计 `docs/specs/2026-11-03-srs-sync2-bulk-bootstrap.md` 的实测依据，
//! 实现批量通道时拿它的 `probe_fold_floor` 当下限对照。
//! `SRS_BENCH_DIR=<…/v3> [SRS_BENCH_SEGS=n] [PROBE_MODE=base|lean] cargo test --release --lib probe_ -- --ignored --nocapture --test-threads=1`
//!
//! - `probe_oneshot_env`：现有逐条投递一次收完。`lean` = 同样的代码，只换执行环境：删掉摘要 / 学习 / 浏览触发器、
//!   `synchronous = OFF`、大页缓存，收完再一次性重建摘要。量「不改结构只换环境」能省多少。
//! - `probe_fold_floor`：批量通道的下限：解码验签 → 解析载荷 → 按实体分组一次 `land_stored` 折叠 → 排序后批量写
//!   操作 / 存活修改 / 复习日志进一个新库（journal off、synchronous off）。
//! - `probe_sliced`：生产形态端到端（8 MiB 一批、默认时间片、按节奏并回 WAL、收尾重放），`PROBE_MODE=seq` 关掉批量投影；
//!   末尾逐表打印行数与内容哈希，两种模式对比即真实数据上的等价回归。
//! - `probe_ops_store`：只写操作日志（`sync2_ops`）的耗时与体积。

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::Instant;

use rusqlite::{params, Connection};

use crate::sync2::op::Body;
use crate::sync2::segment;

fn files(dir: &Path, out: &mut Vec<PathBuf>) {
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        if p.is_dir() {
            files(&p, out);
        } else {
            out.push(p);
        }
    }
}

fn load(dir: &Path, max: usize) -> (Vec<Vec<u8>>, Vec<Vec<u8>>) {
    let mut all = Vec::new();
    files(&dir.join("devices"), &mut all);
    all.sort();
    let name = |p: &PathBuf| p.file_name().unwrap().to_string_lossy().into_owned();
    let heads = all.iter().filter(|p| segment::parse_head_file_name(&name(p)).is_some()).map(|p| std::fs::read(p).unwrap()).collect();
    let segs = all.iter().filter(|p| name(p).starts_with("seg-")).take(max).map(|p| std::fs::read(p).unwrap()).collect();
    (heads, segs)
}

fn ms(t: Instant) -> u128 {
    t.elapsed().as_millis()
}

fn env_usize(k: &str) -> usize {
    std::env::var(k).ok().and_then(|v| v.parse().ok()).unwrap_or(usize::MAX)
}

fn size_mb(p: &Path) -> u64 {
    std::fs::metadata(p).map(|m| m.len() >> 20).unwrap_or(0)
}

fn setup() -> (PathBuf, String, Vec<Vec<u8>>, Vec<Vec<u8>>) {
    let dir = PathBuf::from(std::env::var("SRS_BENCH_DIR").expect("SRS_BENCH_DIR"));
    let profile = dir.parent().unwrap().file_name().unwrap().to_string_lossy().into_owned();
    let (heads, segs) = load(&dir, env_usize("SRS_BENCH_SEGS"));
    let bytes: usize = segs.iter().map(Vec::len).sum();
    println!("PROBE profile={profile} heads={} segs={} bytes={}MB", heads.len(), segs.len(), bytes >> 20);
    (dir, profile, heads, segs)
}

#[test]
#[ignore]
fn probe_oneshot_env() {
    let (_dir, profile, heads, segs) = setup();
    let lean = std::env::var("PROBE_MODE").as_deref() == Ok("lean");
    let now = 1_800_000_000_000i64;
    let tmp = super::tests::tempdir::new("probe-oneshot");
    let db = tmp.0.join("srs.db");
    let core = crate::store::SrsCore::open(&db).unwrap();
    core.sync2_identity(&profile, now).unwrap();
    core.sync2_plan(&profile, &heads).unwrap();
    if lean {
        let w = core.writer().unwrap();
        let names = |sql: &str| -> Vec<String> {
            let mut s = w.prepare(sql).unwrap();
            let v = s.query_map([], |r| r.get::<_, String>(0)).unwrap().collect::<Result<Vec<_>, _>>().unwrap();
            v
        };
        let dg = names("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'sync2_dg_%'");
        let tmpt = names("SELECT name FROM sqlite_temp_master WHERE type = 'trigger'");
        for n in &dg {
            w.execute_batch(&format!("DROP TRIGGER main.{n}")).unwrap();
        }
        for n in &tmpt {
            w.execute_batch(&format!("DROP TRIGGER temp.{n}")).unwrap();
        }
        w.execute_batch("PRAGMA synchronous = OFF; PRAGMA wal_autocheckpoint = 65536; PRAGMA cache_size = -262144;").unwrap();
        println!("PROBE lean: dropped {} digest + {} temp triggers", dg.len(), tmpt.len());
    }
    let t = Instant::now();
    let r = core.sync2_ingest(&profile, &segs, None, now).unwrap();
    let ingest = ms(t);
    let v: serde_json::Value = serde_json::from_str(&r).unwrap();
    let mut digest_ms = 0;
    if lean {
        let t = Instant::now();
        super::digest::rebuild(&core.writer().unwrap()).unwrap();
        digest_ms = ms(t);
    }
    let ops: i64 = core.writer().unwrap().query_row("SELECT COUNT(*) FROM sync2_ops", [], |r| r.get(0)).unwrap();
    println!(
        "PROBE oneshot mode={} ops={ops} ingest={ingest}ms digest_rebuild={digest_ms}ms applied={} pending={} db={}MB wal={}MB",
        if lean { "lean" } else { "base" },
        v["applied"],
        v["pending"],
        size_mb(&db),
        size_mb(&tmp.0.join("srs.db-wal")),
    );
}

#[test]
#[ignore]
fn probe_fold_floor() {
    let (_dir, profile, heads, segs) = setup();
    let now = 1_800_000_000_000i64;
    let pubs: HashMap<_, _> = heads
        .iter()
        .map(|h| {
            let h = segment::Head::decode(h).unwrap();
            (h.device, h.public)
        })
        .collect();

    // 1. 验签 + 解压 + 解码 + 重算链（与收段的 prepare 同一组函数）。
    let t = Instant::now();
    let mut ops = Vec::new();
    for s in &segs {
        let hdr = segment::peek_header(s).unwrap();
        let open = segment::open_verified(s, &pubs[&hdr.device], None).unwrap();
        for op in open.verify().unwrap() {
            ops.push(op.unwrap());
        }
    }
    let decode = ms(t);

    // 2. 解析载荷。
    let t = Instant::now();
    let bodies: Vec<Body> = ops.iter().map(|op| op.body().unwrap()).collect();
    let parse = ms(t);
    let mut kinds: BTreeMap<&'static str, usize> = BTreeMap::new();
    for b in &bodies {
        let k = match b {
            Body::Entity { .. } => "entity",
            Body::Edit(e) if e.key == "tags" => "edit_tags",
            Body::Edit(_) => "edit",
            Body::Log(_) => "log",
            Body::TagAdd { .. } | Body::TagRemove { .. } | Body::TagOrder { .. } => "tag",
            Body::Media { .. } | Body::MediaAt { .. } => "media",
            _ => "other",
        };
        *kinds.entry(k).or_default() += 1;
    }
    let payload: usize = ops.iter().map(|o| o.payload.len()).sum();
    println!("PROBE ops={} payload_raw={}MB kinds={kinds:?}", ops.len(), payload >> 20);

    // 3. 投影行（生产的 edit_row / log_row，同一份 JSON）+ 按实体分组一次折叠（生产的 land_stored）。
    let tmp = super::tests::tempdir::new("probe-fold");
    let core = crate::store::SrsCore::open(&tmp.0.join("srs.db")).unwrap();
    core.sync2_identity(&profile, now).unwrap();
    let w = core.writer().unwrap();
    let t = Instant::now();
    let mut groups: HashMap<(&'static str, String), Vec<(String, Option<i64>)>> = HashMap::new();
    let mut logs: Vec<(String, String, String)> = Vec::new();
    for (op, b) in ops.iter().zip(&bodies) {
        match b {
            Body::Edit(e) if e.key != "tags" => {
                let (_id, row) = super::edit_row(&w, &profile, op, e).unwrap();
                groups
                    .entry((e.kind.wire(), e.entity.text()))
                    .or_default()
                    .push((super::canonical(&row), e.legacy.as_ref().and_then(|l| l.server_time)));
            }
            Body::Log(l) => logs.push((l.id.text(), l.card.text(), super::canonical(&super::log_row(&profile, op, l)))),
            _ => {}
        }
    }
    let rows = ms(t);
    let t = Instant::now();
    let mut kept: Vec<String> = Vec::new();
    let mut edits = 0;
    for v in groups.values() {
        let items: Vec<crate::registers::StoredEdit<'_>> = v.iter().map(|(j, s)| (j.as_str(), *s, None)).collect();
        let (landed, deleted) = crate::registers::land_stored(&items, 0).unwrap();
        let gone: HashSet<usize> = deleted.iter().flatten().copied().collect();
        for (i, l) in landed.iter().enumerate() {
            if *l && !gone.contains(&i) {
                kept.push(v[i].0.clone());
            }
        }
        edits += v.len();
    }
    let fold = ms(t);
    println!("PROBE fold: entities={} edits={edits} survivors={} logs={}", groups.len(), kept.len(), logs.len());
    drop(w);

    // 4. 批量写：一个新库、一个事务、主键有序插入、写完再建二级索引。
    let t = Instant::now();
    let db = tmp.0.join("bulk.db");
    let c = Connection::open(&db).unwrap();
    c.execute_batch(
        "PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF; PRAGMA cache_size = -262144;
         CREATE TABLE ops (device BLOB NOT NULL, seq INTEGER NOT NULL, wall INTEGER, logical INTEGER, kind INTEGER, payload BLOB, chain BLOB,
           PRIMARY KEY (device, seq)) WITHOUT ROWID;
         CREATE TABLE edits (id INTEGER PRIMARY KEY, json TEXT NOT NULL);
         CREATE TABLE logs (id TEXT PRIMARY KEY, card TEXT NOT NULL, json TEXT NOT NULL) WITHOUT ROWID;",
    )
    .unwrap();
    let tx = c.unchecked_transaction().unwrap();
    {
        let mut ins = tx.prepare("INSERT INTO ops VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)").unwrap();
        for op in &ops {
            ins.execute(params![
                op.id.device.0.to_vec(),
                op.id.seq as i64,
                op.hlc.wall,
                i64::from(op.hlc.logical),
                i64::from(op.kind),
                &op.payload[..],
                [0u8; 32].to_vec()
            ])
            .unwrap();
        }
        let mut ins = tx.prepare("INSERT INTO edits (json) VALUES (?1)").unwrap();
        for j in &kept {
            ins.execute([j]).unwrap();
        }
        logs.sort();
        let mut ins = tx.prepare("INSERT INTO logs VALUES (?1, ?2, ?3)").unwrap();
        for (id, card, j) in &logs {
            ins.execute(params![id, card, j]).unwrap();
        }
    }
    tx.execute_batch("CREATE INDEX logs_card ON logs (card);").unwrap();
    tx.commit().unwrap();
    let write = ms(t);
    println!(
        "PROBE floor total={}ms = decode {decode} + parse {parse} + rows {rows} + fold {fold} + write {write}; bulk.db={}MB",
        decode + parse + rows + fold + write,
        size_mb(&db)
    );
}

/// 操作日志写入量：全部操作只写 `sync2_ops`（真实表结构、WAL、一个事务，经 [super::insert_op]，即 v21 起的 zstd 压缩存法）。
/// 实测（683,706 条）：原样 428 MB / 36.5 s；逐条 zstd 1 档 192 MB（3 档 190 MB，只多省 1%、压缩慢三成）。
#[test]
#[ignore]
fn probe_ops_store() {
    let (_dir, profile, heads, segs) = setup();
    let now = 1_800_000_000_000i64;
    let pubs: HashMap<_, _> = heads
        .iter()
        .map(|h| {
            let h = segment::Head::decode(h).unwrap();
            (h.device, h.public)
        })
        .collect();
    let mut ops = Vec::new();
    for s in &segs {
        let hdr = segment::peek_header(s).unwrap();
        let open = segment::open_verified(s, &pubs[&hdr.device], None).unwrap();
        for op in open.verify().unwrap() {
            ops.push(op.unwrap());
        }
    }
    let tmp = super::tests::tempdir::new("probe-ops");
    let db = tmp.0.join("srs.db");
    let core = crate::store::SrsCore::open(&db).unwrap();
    core.sync2_identity(&profile, now).unwrap();
    let w = core.writer().unwrap();
    let t = Instant::now();
    w.execute_batch("BEGIN").unwrap();
    for op in &ops {
        super::insert_op(&w, &profile, op, &[0u8; 32], now).unwrap();
    }
    w.execute_batch("COMMIT").unwrap();
    let total = ms(t);
    let (raw, stored): (i64, i64) = w
        .query_row("SELECT COUNT(*), TOTAL(LENGTH(payload)) FROM sync2_ops", [], |r| Ok((r.get(0)?, r.get::<_, f64>(1)? as i64)))
        .unwrap();
    drop(w);
    println!(
        "PROBE ops_store ops={} rows={raw} total={total}ms per={:.1}us payload={}MB stored={}MB db={}MB wal={}MB",
        ops.len(),
        total as f64 * 1000.0 / ops.len() as f64,
        ops.iter().map(|o| o.payload.len()).sum::<usize>() >> 20,
        stored >> 20,
        size_mb(&db),
        size_mb(&tmp.0.join("srs.db-wal"))
    );
}

/// 生产形态的端到端：与 Dart 一样按 8 MiB 一批 `ingest_prepare`、默认时间片 `ingest_commit`、WAL 按
/// `SrsWalCheckpointPacer` 的节奏另开连接并回，最后 `ingest_finish` + `replay_pending`。`PROBE_MODE=seq` 关掉
/// 批量投影（[super::bulk::sequential]）作 A/B；末尾打印每张表的行数与无序内容哈希，两种模式逐表对比。
#[test]
#[ignore]
fn probe_sliced() {
    let (_dir, profile, heads, segs) = setup();
    let seq = std::env::var("PROBE_MODE").as_deref() == Ok("seq");
    let now = 1_800_000_000_000i64;
    let tmp = super::tests::tempdir::new("probe-sliced");
    let db = tmp.0.join("srs.db");
    let core = crate::store::SrsCore::open(&db).unwrap();
    core.sync2_identity(&profile, now).unwrap();
    let deck = super::config::default_deck_id(&profile);
    let cmd = |req: serde_json::Value, blobs: Vec<Vec<u8>>| -> serde_json::Value {
        let mut req = req;
        req["profile"] = serde_json::json!(profile);
        req["caches"] = serde_json::json!({"defaultDeck": deck});
        let mut blobs = blobs;
        let mut files = Vec::new();
        crate::store::ffi::sync2_dispatch(&core, &req, &mut blobs, &mut files).unwrap()
    };
    let run = || {
        let t0 = Instant::now();
        let (mut prepare, mut commit, mut ckpt, mut slices) = (0u128, 0u128, 0u128, 0usize);
        cmd(serde_json::json!({"op": "plan"}), heads.clone());
        cmd(serde_json::json!({"op": "ingest_begin"}), vec![]);
        let slice_ms: Option<u64> = std::env::var("PROBE_SLICE_MS").ok().and_then(|v| v.parse().ok());
        let pacer_pages: usize = std::env::var("PROBE_PACER_PAGES").ok().and_then(|v| v.parse().ok()).unwrap_or(8192);
        if let Some(mb) = std::env::var("PROBE_CACHE_MB").ok().and_then(|v| v.parse::<i64>().ok()) {
            core.writer().unwrap().execute_batch(&format!("PRAGMA cache_size = -{}", mb * 1024)).unwrap();
        }
        let mut batch: Vec<Vec<u8>> = Vec::new();
        let mut bytes = 0usize;
        // 与 Dart `SrsDbStore.sync2IngestBatch` 相同：一批 = prepare + 若干片 commit，期间写连接的自动 checkpoint
        // 阈值调到 16384 页（`bulkWrites`），WAL 按 `SrsWalCheckpointPacer` 的节奏另开连接并回，批末并回一次再恢复。
        let mut flush = |batch: Vec<Vec<u8>>| {
            let t = Instant::now();
            cmd(serde_json::json!({"op": "ingest_prepare"}), batch);
            prepare += ms(t);
            core.writer().unwrap().execute_batch("PRAGMA wal_autocheckpoint = 16384").unwrap();
            let (mut every, mut since) = (1usize, 0usize);
            loop {
                let t = Instant::now();
                let mut req = serde_json::json!({"op": "ingest_commit", "now": now});
                if let Some(s) = slice_ms {
                    req["sliceMs"] = serde_json::json!(s);
                }
                let r = cmd(req, vec![]);
                commit += ms(t);
                slices += 1;
                if r["more"] != serde_json::json!(true) {
                    break;
                }
                since += 1;
                if since >= every {
                    let t = Instant::now();
                    let log = cmd(serde_json::json!({"op": "wal_checkpoint"}), vec![])["log"].as_u64().unwrap_or(0) as usize;
                    ckpt += ms(t);
                    let per = log / since.max(1);
                    every = if per == 0 { 64 } else { (pacer_pages / per).clamp(1, 64) };
                    since = 0;
                }
            }
            let t = Instant::now();
            cmd(serde_json::json!({"op": "wal_checkpoint"}), vec![]);
            ckpt += ms(t);
            core.writer().unwrap().execute_batch("PRAGMA wal_autocheckpoint = 1000").unwrap();
        };
        for s in &segs {
            bytes += s.len();
            batch.push(s.clone());
            if bytes >= 8 << 20 {
                flush(std::mem::take(&mut batch));
                bytes = 0;
            }
        }
        if !batch.is_empty() {
            flush(batch);
        }
        let t = Instant::now();
        let mut r = cmd(serde_json::json!({"op": "ingest_finish", "now": now}), vec![]);
        while r["more"] == serde_json::json!(true) {
            r = cmd(serde_json::json!({"op": "replay_pending"}), vec![]);
        }
        let finish = ms(t);
        println!(
            "PROBE sliced mode={} total={}ms prepare={prepare}ms commit={commit}ms slices={slices} checkpoint={ckpt}ms finish={finish}ms",
            if seq { "seq" } else { "bulk" },
            ms(t0)
        );
    };
    super::bulk::production_window(|| if seq { super::bulk::sequential(run) } else { run() });
    let w = core.writer().unwrap();
    println!("PROBE sliced db={}MB wal={}MB", size_mb(&db), size_mb(&tmp.0.join("srs.db-wal")));
    let tables: Vec<String> = {
        let mut s = w.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name").unwrap();
        let v = s.query_map([], |r| r.get::<_, String>(0)).unwrap().collect::<Result<Vec<_>, _>>().unwrap();
        v
    };
    for t in tables {
        let cols: Vec<String> = {
            let mut s = w.prepare(&format!("SELECT name FROM pragma_table_info('{t}') ORDER BY cid")).unwrap();
            let v = s.query_map([], |r| r.get::<_, String>(0)).unwrap().map(|c| format!("quote({})", c.unwrap())).collect();
            v
        };
        let mut s = w.prepare(&format!("SELECT {} FROM {t}", cols.join(" || '|' || "))).unwrap();
        let mut q = s.query([]).unwrap();
        let (mut n, mut sum) = (0u64, 0u128);
        while let Some(r) = q.next().unwrap() {
            let row: String = r.get(0).unwrap();
            let h = blake3::hash(row.as_bytes());
            sum = sum.wrapping_add(u128::from_le_bytes(h.as_bytes()[..16].try_into().unwrap()));
            n += 1;
        }
        println!("PROBE table {t} rows={n} hash={sum:032x}");
    }
}
