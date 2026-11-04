//! 新设备冷启动耗时探针（默认不跑）：批量通道设计 `docs/specs/2026-11-03-srs-sync2-bulk-bootstrap.md` 的实测依据，
//! 实现批量通道时拿它的 `probe_fold_floor` 当下限对照。
//! `RUSTFLAGS="--cfg srs_probe" SRS_BENCH_DIR=<…/v3> [SRS_BENCH_SEGS=n] [PROBE_MODE=base|lean] cargo test --release --lib probe_ -- --ignored --nocapture --test-threads=1`
//!
//! `--cfg srs_probe`：测试构建里压小的切片 / 缓冲常量（transport.rs 的投递窗口、缓冲字节、预处理留存，ffi.rs 的收尾
//! 缓存块）取生产值，量到的才与 app 一致（不加时收尾缓存每块 5 个实体、投递窗口 3 条，数字偏大很多）。单独用一个
//! `CARGO_TARGET_DIR`，免得与普通测试构建互相重编。
//!
//! - `probe_oneshot_env`：现有逐条投递一次收完。`lean` = 同样的代码，只换执行环境：删掉摘要 / 学习 / 浏览触发器、
//!   `synchronous = OFF`、大页缓存，收完再一次性重建摘要。量「不改结构只换环境」能省多少。
//! - `probe_fold_floor`：批量通道的下限：解码验签 → 解析载荷 → 按实体分组一次 `land_stored` 折叠 → 排序后批量写
//!   操作 / 存活修改 / 复习日志进一个新库（journal off、synchronous off）。
//! - `probe_sliced`：生产形态端到端（8 MiB 一批、默认时间片、按节奏并回 WAL、收尾重放），`PROBE_SLICE_MS` 改片长；
//!   末尾逐表打印行数与内容哈希，不同实现之间对比即真实数据上的等价回归。新设备默认走收段通道（channel.rs，先追加
//!   后折叠），`PROBE_SEQ=1` 关掉通道、按逐条投递收（同一份代码的对照组）。
//! - `probe_ops_store`：只写操作日志（`sync2_ops`）的耗时与体积。
//! - `probe_channel_floor`：收段通道的原型（与 channel.rs 同一套「追加 → 分区折叠 → 复杂实体逐条」，在探针里手写、
//!   带分步计时），当时用来证可行性与量下限；生产实现以 `probe_sliced` 为准。
//! - `probe_finish` / `probe_finish_floor`：收尾（重放 + 缓存）。先用 `probe_sliced` 加 `PROBE_KEEP=<路径>` 留下「投递完、
//!   收尾前」的库，再在它的副本上反复跑：`probe_finish` 走生产的收尾函数（`PROBE_FINISH=prod|one|rebuild`），
//!   `probe_finish_floor` 是下限（日志与笔记修改记录各整表顺扫一遍、内存里算，不写库）。

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::Instant;

use rusqlite::{Connection, params};

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
    let heads = all
        .iter()
        .filter(|p| segment::parse_head_file_name(&name(p)).is_some())
        .map(|p| std::fs::read(p).unwrap())
        .collect();
    let segs = all
        .iter()
        .filter(|p| name(p).starts_with("seg-"))
        .take(max)
        .map(|p| std::fs::read(p).unwrap())
        .collect();
    (heads, segs)
}

fn ms(t: Instant) -> u128 {
    t.elapsed().as_millis()
}

fn env_usize(k: &str) -> usize {
    std::env::var(k)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(usize::MAX)
}

fn size_mb(p: &Path) -> u64 {
    std::fs::metadata(p).map(|m| m.len() >> 20).unwrap_or(0)
}

fn setup() -> (PathBuf, String, Vec<Vec<u8>>, Vec<Vec<u8>>) {
    let dir = PathBuf::from(std::env::var("SRS_BENCH_DIR").expect("SRS_BENCH_DIR"));
    let profile = dir
        .parent()
        .unwrap()
        .file_name()
        .unwrap()
        .to_string_lossy()
        .into_owned();
    let (heads, segs) = load(&dir, env_usize("SRS_BENCH_SEGS"));
    let bytes: usize = segs.iter().map(Vec::len).sum();
    println!(
        "PROBE profile={profile} heads={} segs={} bytes={}MB",
        heads.len(),
        segs.len(),
        bytes >> 20
    );
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
            let v = s
                .query_map([], |r| r.get::<_, String>(0))
                .unwrap()
                .collect::<Result<Vec<_>, _>>()
                .unwrap();
            v
        };
        let dg = names(
            "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'sync2_dg_%'",
        );
        let tmpt = names("SELECT name FROM sqlite_temp_master WHERE type = 'trigger'");
        for n in &dg {
            w.execute_batch(&format!("DROP TRIGGER main.{n}")).unwrap();
        }
        for n in &tmpt {
            w.execute_batch(&format!("DROP TRIGGER temp.{n}")).unwrap();
        }
        w.execute_batch("PRAGMA synchronous = OFF; PRAGMA wal_autocheckpoint = 65536; PRAGMA cache_size = -262144;").unwrap();
        println!(
            "PROBE lean: dropped {} digest + {} temp triggers",
            dg.len(),
            tmpt.len()
        );
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
    let ops: i64 = core
        .writer()
        .unwrap()
        .query_row("SELECT COUNT(*) FROM sync2_ops", [], |r| r.get(0))
        .unwrap();
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
    println!(
        "PROBE ops={} payload_raw={}MB kinds={kinds:?}",
        ops.len(),
        payload >> 20
    );

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
                    .push((
                        super::canonical(&row),
                        e.legacy.as_ref().and_then(|l| l.server_time),
                    ));
            }
            Body::Log(l) => logs.push((
                l.id.text(),
                l.card.text(),
                super::canonical(&super::log_row(&profile, op, l)),
            )),
            _ => {}
        }
    }
    let rows = ms(t);
    let t = Instant::now();
    let mut kept: Vec<String> = Vec::new();
    let mut edits = 0;
    for v in groups.values() {
        let items: Vec<crate::registers::StoredEdit<'_>> =
            v.iter().map(|(j, s)| (j.as_str(), *s, None)).collect();
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
    println!(
        "PROBE fold: entities={} edits={edits} survivors={} logs={}",
        groups.len(),
        kept.len(),
        logs.len()
    );
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
        let mut ins = tx
            .prepare("INSERT INTO ops VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)")
            .unwrap();
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
    tx.execute_batch("CREATE INDEX logs_card ON logs (card);")
        .unwrap();
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
        .query_row(
            "SELECT COUNT(*), TOTAL(LENGTH(payload)) FROM sync2_ops",
            [],
            |r| Ok((r.get(0)?, r.get::<_, f64>(1)? as i64)),
        )
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
/// `SrsWalCheckpointPacer` 的节奏另开连接并回，最后 `ingest_finish` + `replay_pending`。末尾打印每张表的行数与无序
/// 内容哈希，供不同实现之间逐表对比。
#[test]
#[ignore]
fn probe_sliced() {
    let (_dir, profile, heads, segs) = setup();
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
        let slice_ms: Option<u64> = std::env::var("PROBE_SLICE_MS")
            .ok()
            .and_then(|v| v.parse().ok());
        let pacer_pages: usize = std::env::var("PROBE_PACER_PAGES")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(8192);
        if let Some(mb) = std::env::var("PROBE_CACHE_MB")
            .ok()
            .and_then(|v| v.parse::<i64>().ok())
        {
            core.writer()
                .unwrap()
                .execute_batch(&format!("PRAGMA cache_size = -{}", mb * 1024))
                .unwrap();
        }
        let mut batch: Vec<Vec<u8>> = Vec::new();
        let mut bytes = 0usize;
        // 与 Dart `SrsDbStore.sync2IngestBatch` 相同：一批 = prepare + 若干片 commit，期间写连接的自动 checkpoint
        // 阈值调到 16384 页（`bulkWrites`），WAL 按 `SrsWalCheckpointPacer` 的节奏另开连接并回，批末并回一次再恢复。
        let mut flush = |batch: Vec<Vec<u8>>| {
            let t = Instant::now();
            cmd(serde_json::json!({"op": "ingest_prepare"}), batch);
            prepare += ms(t);
            core.writer()
                .unwrap()
                .execute_batch("PRAGMA wal_autocheckpoint = 16384")
                .unwrap();
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
                    let log = cmd(serde_json::json!({"op": "wal_checkpoint"}), vec![])["log"]
                        .as_u64()
                        .unwrap_or(0) as usize;
                    ckpt += ms(t);
                    let per = log / since.max(1);
                    every = if per == 0 {
                        64
                    } else {
                        (pacer_pages / per).clamp(1, 64)
                    };
                    since = 0;
                }
            }
            let t = Instant::now();
            cmd(serde_json::json!({"op": "wal_checkpoint"}), vec![]);
            ckpt += ms(t);
            core.writer()
                .unwrap()
                .execute_batch("PRAGMA wal_autocheckpoint = 1000")
                .unwrap();
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
        if let Ok(keep) = std::env::var("PROBE_KEEP") {
            core.writer()
                .unwrap()
                .execute_batch("PRAGMA wal_checkpoint(TRUNCATE)")
                .unwrap();
            std::fs::copy(&db, &keep).unwrap();
            println!(
                "PROBE kept pre-finish db at {keep} ({}MB)",
                size_mb(Path::new(&keep))
            );
            if std::env::var("PROBE_KEEP_ONLY").as_deref() == Ok("1") {
                return;
            }
        }
        let t = Instant::now();
        let mut r = cmd(
            serde_json::json!({"op": "ingest_finish", "now": now}),
            vec![],
        );
        let mut finish_calls = 1usize;
        while r["more"] == serde_json::json!(true) {
            r = cmd(serde_json::json!({"op": "replay_pending"}), vec![]);
            finish_calls += 1;
        }
        let finish = ms(t);
        println!(
            "PROBE sliced total={}ms prepare={prepare}ms commit={commit}ms slices={slices} checkpoint={ckpt}ms finish={finish}ms finish_calls={finish_calls}",
            ms(t0)
        );
    };
    if std::env::var("PROBE_SEQ").as_deref() == Ok("1") {
        println!("PROBE sliced mode=sequential");
        super::channel::sequential(run);
    } else {
        println!("PROBE sliced mode=channel");
        run();
    }
    let w = core.writer().unwrap();
    println!(
        "PROBE sliced db={}MB wal={}MB",
        size_mb(&db),
        size_mb(&tmp.0.join("srs.db-wal"))
    );
    table_hashes(&w);
}

/// 每张表的行数与无序内容哈希（各行 `quote()` 拼起来的 BLAKE3 前 16 字节回绕加和），不同实现之间逐表对比。
fn table_hashes(w: &Connection) {
    let tables: Vec<String> = {
        let mut s = w.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name").unwrap();
        let v = s
            .query_map([], |r| r.get::<_, String>(0))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        v
    };
    for t in tables {
        let cols: Vec<String> = {
            let mut s = w
                .prepare(&format!(
                    "SELECT name FROM pragma_table_info('{t}') ORDER BY cid"
                ))
                .unwrap();
            let v = s
                .query_map([], |r| r.get::<_, String>(0))
                .unwrap()
                .map(|c| format!("quote({})", c.unwrap()))
                .collect();
            v
        };
        let mut s = w
            .prepare(&format!("SELECT {} FROM {t}", cols.join(" || '|' || ")))
            .unwrap();
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

/// 收尾的下限：日志与笔记修改记录各整表顺扫一遍进内存（按卡 / 按笔记分组），在内存里算重放、卡状态、有效复习投影
/// 与笔记视图，不写库。对照生产收尾（逐卡 / 逐块回读）。库同 [probe_finish]（`PROBE_FINISH_DB`）。
#[test]
#[ignore]
fn probe_finish_floor() {
    use crate::sync2::replay::{Row, infer_intent};
    let src = PathBuf::from(std::env::var("PROBE_FINISH_DB").expect("PROBE_FINISH_DB"));
    let tmp = super::tests::tempdir::new("probe-finish-floor");
    let db = tmp.0.join("srs.db");
    std::fs::copy(&src, &db).unwrap();
    let core = crate::store::SrsCore::open(&db).unwrap();
    let w = core.writer().unwrap();
    w.execute_batch("PRAGMA cache_size = -262144").unwrap();

    // 1. 日志整表顺扫（连服务器时刻、意图、拼回的 json）。
    let t = Instant::now();
    type L = (
        String,
        Option<i64>,
        Option<crate::history::LogCols>,
        String,
        Option<i64>,
        Option<i64>,
    );
    let mut logs: HashMap<String, Vec<L>> = HashMap::new();
    let mut bytes = 0usize;
    {
        let q = format!(
            "SELECT srs_idt(l.card_id) AS card_id, e.server_time, {}, l.json, m.intent, m.arg FROM srs_review_logs l \
             LEFT JOIN srs_event_local e ON e.event_id = l.id LEFT JOIN sync2_log_meta m ON m.log_id = l.id",
            crate::store::slim::LOG_READ
        );
        let mut s = w.prepare(&q).unwrap();
        let mut it = s.query([]).unwrap();
        while let Some(r) = it.next().unwrap() {
            let card: String = r.get(0).unwrap();
            let (j, cols) = crate::store::slim::log_row(r, 2).unwrap();
            let json: String = r.get(12).unwrap();
            bytes += j.len() + json.len();
            logs.entry(card).or_default().push((
                j,
                r.get(1).unwrap(),
                cols,
                json,
                r.get(13).unwrap(),
                r.get(14).unwrap(),
            ));
        }
    }
    let scan_logs = ms(t);
    let n_logs: usize = logs.values().map(Vec::len).sum();

    // 2. 重放（每张卡单独一组：真实库里前身链接极少，下限不算血统）。
    let t = Instant::now();
    let mut changed = 0usize;
    for rows in logs.values() {
        let input: Vec<Row<'_>> = rows
            .iter()
            .map(|(_, s, _, json, code, arg)| Row {
                json,
                server_time: *s,
                intent: match code {
                    Some(k) => super::intent_of(*k, *arg),
                    None => {
                        infer_intent(&serde_json::from_str(json).unwrap_or(serde_json::Value::Null))
                    }
                },
            })
            .collect();
        changed += crate::sync2::replay::replay(&input)
            .unwrap()
            .rows
            .iter()
            .filter(|r| r.is_some())
            .count();
    }
    let replay = ms(t);

    // 3. 卡状态 + 有效复习投影（同一份日志）。
    let t = Instant::now();
    let mut stat_rows = 0usize;
    for rows in logs.values() {
        let stored: Vec<crate::history::StoredLog<'_>> = rows
            .iter()
            .map(|(j, s, c, ..)| (j.as_str(), *s, c.as_ref()))
            .collect();
        let _ = crate::history::state_from_stored(&stored).unwrap();
        stat_rows += crate::history::stats_from_stored(&stored).unwrap().len();
    }
    let card_compute = ms(t);
    let n_cards = logs.len();
    drop(logs);

    // 4. 笔记：身份记录 + 修改记录整表顺扫，按笔记分组，物化视图。
    let t = Instant::now();
    let mut notes: HashMap<
        String,
        (
            Option<serde_json::Value>,
            Vec<(String, Option<i64>, Option<crate::registers::EditCols>)>,
        ),
    > = HashMap::new();
    {
        let mut s = w
            .prepare("SELECT srs_idt(id) AS id, payload_json FROM srs_entities WHERE kind = 'note'")
            .unwrap();
        let mut it = s.query([]).unwrap();
        while let Some(r) = it.next().unwrap() {
            let id: String = r.get(0).unwrap();
            let p: String = r.get(1).unwrap();
            notes.entry(id).or_default().0 = Some(serde_json::from_str(&p).unwrap());
        }
        let q = format!(
            "SELECT srs_idt(f.entity_id) AS entity_id, e.server_time, {} FROM srs_field_edits f LEFT JOIN srs_event_local e ON e.event_id = f.id \
             WHERE f.entity_kind = 'note'",
            crate::store::slim::EDIT_READ
        );
        let mut s = w.prepare(&q).unwrap();
        let mut it = s.query([]).unwrap();
        while let Some(r) = it.next().unwrap() {
            let id: String = r.get(0).unwrap();
            let (j, cols) = crate::store::slim::edit_row(r, 2).unwrap();
            notes
                .entry(id)
                .or_default()
                .1
                .push((j, r.get(1).unwrap(), cols));
        }
    }
    let scan_notes = ms(t);
    let t = Instant::now();
    let mut views = 0usize;
    for (payload, es) in notes.values() {
        let Some(p) = payload else { continue };
        let stored: Vec<crate::registers::StoredEdit<'_>> = es
            .iter()
            .map(|(j, s, c)| (j.as_str(), *s, c.as_ref()))
            .collect();
        let _ = crate::registers::note_view_of(p, &stored).unwrap();
        views += 1;
    }
    let note_views = ms(t);
    println!(
        "PROBE finish_floor logs={n_logs} cards={} log_bytes={}MB scan_logs={scan_logs}ms replay={replay}ms (changed {changed}) \
         card_state+stats={card_compute}ms (stat rows {stat_rows}) scan_notes={scan_notes}ms note_views={note_views}ms ({views} notes) total={}ms",
        n_cards,
        bytes >> 20,
        scan_logs + replay + card_compute + scan_notes + note_views
    );
}

/// 收尾（重放 + 缓存）分解：在 `probe_sliced` 用 `PROBE_KEEP=<路径>` 留下的「投递完、收尾前」的库副本上跑。
/// `PROBE_FINISH=prod`（默认）= 生产形态：一次重放完，再按 512 个实体一块从待刷新集合刷缓存；`one` = 待刷新
/// 集合一次刷完；`rebuild` = 丢掉缓存全量重建（全部笔记 + 全部有日志的卡）。
#[test]
#[ignore]
fn probe_finish() {
    use super::transport::{CommitBudget, replay_pending, take_cache_pending};
    let dir = PathBuf::from(std::env::var("SRS_BENCH_DIR").expect("SRS_BENCH_DIR"));
    let profile = dir
        .parent()
        .unwrap()
        .file_name()
        .unwrap()
        .to_string_lossy()
        .into_owned();
    let src = PathBuf::from(std::env::var("PROBE_FINISH_DB").expect("PROBE_FINISH_DB"));
    let mode = std::env::var("PROBE_FINISH").unwrap_or_else(|_| "prod".to_owned());
    let tmp = super::tests::tempdir::new("probe-finish");
    let db = tmp.0.join("srs.db");
    std::fs::copy(&src, &db).unwrap();
    let core = crate::store::SrsCore::open(&db).unwrap();
    let w = core.writer().unwrap();
    let n = |q: &str| -> i64 { w.query_row(q, [], |r| r.get(0)).unwrap() };
    println!(
        "PROBE finish mode={mode} replay_pending={} cache_pending={} (types {} notes {} cards {}) logs={} log_cards={} notes={} cards={}",
        n("SELECT count(*) FROM sync2_replay_pending"),
        n("SELECT count(*) FROM sync2_cache_pending"),
        n("SELECT count(*) FROM sync2_cache_pending WHERE kind = 0"),
        n("SELECT count(*) FROM sync2_cache_pending WHERE kind = 1"),
        n("SELECT count(*) FROM sync2_cache_pending WHERE kind = 2"),
        n("SELECT count(*) FROM srs_review_logs"),
        n("SELECT count(DISTINCT card_id) FROM srs_review_logs"),
        n("SELECT count(*) FROM srs_entities WHERE kind = 'note'"),
        n("SELECT count(*) FROM srs_entities WHERE kind = 'card'"),
    );
    let cfg = crate::store::caches::CacheConfig::parse(
        &serde_json::json!({"defaultDeck": super::config::default_deck_id(&profile)}),
    )
    .unwrap();
    let t0 = Instant::now();
    let (replayed, _) = super::in_savepoint(&w, |c| {
        replay_pending(c, &profile, &mut CommitBudget::unlimited())
    })
    .unwrap();
    let replay = ms(t0);
    println!(
        "PROBE finish replay={replay}ms changed_cards={}",
        replayed.len()
    );
    let t = Instant::now();
    let mut chunks = 0;
    match mode.as_str() {
        "rebuild" => {
            super::in_savepoint(&w, |c| crate::store::caches::rebuild(c, &profile, &cfg)).unwrap();
            chunks = 1;
        }
        "one" => {
            super::in_savepoint(&w, |c| {
                let (d, _) = take_cache_pending(c, &profile, usize::MAX >> 1)?;
                crate::store::caches::refresh(c, &profile, &cfg, d)
            })
            .unwrap();
            chunks = 1;
        }
        _ => loop {
            let more = super::in_savepoint(&w, |c| {
                let (d, _) = take_cache_pending(c, &profile, 512)?;
                let written = crate::store::caches::refresh(c, &profile, &cfg, d)?;
                super::transport::settle_refreshed_cards(c, &profile, &written.cards)?;
                super::transport::cache_is_pending(c, &profile)
            })
            .unwrap();
            chunks += 1;
            if !more {
                break;
            }
        },
    }
    let caches = ms(t);
    println!(
        "PROBE finish total={}ms replay={replay}ms caches={caches}ms chunks={chunks} notes_cache={} cards_cache={} stat_reviews={}",
        ms(t0),
        n("SELECT count(*) FROM srs_notes_cache"),
        n("SELECT count(*) FROM srs_cards_cache"),
        n("SELECT count(*) FROM srs_stat_reviews"),
    );
}

/// 独立通道（先追加、后折叠）的下限，真实表结构与生产写入语句：
/// 1. 解码验签、重算链；
/// 2. 按逐条投递同一判据（每台设备按 seq 接续、依赖向量被已投的覆盖）排出投递顺序，投不上的留着；
/// 3. 按这个顺序把操作写进操作日志（一个事务）；
/// 4. 内存里按投递顺序折叠：字段修改按实体一次 `land_stored`（依次到达语义）、日志与 `sync2_log_meta` 先到先得、
///    `sync2_edit_ops` 后到者胜、身份记录取规范文本最小者、旧修改记录闭包在内存里按到达更新；
/// 5. 关掉摘要触发器、摘掉 TEMP 触发器，按主键有序写进投影与记账表（`PROBE_DROP_INDEXES=1`：先删二级索引、写完再建）；
/// 6. 其余操作（标签、媒体、清除、复杂实体上的一切）按投递顺序走生产的逐条投影；
/// 7. 旧修改记录闭包写回、摘要重建；
/// 8. 生产形态的收尾（重放 + 分块刷缓存）。
///
/// 末尾逐表打印行数与哈希，对照 `probe_sliced` 的输出。复杂实体 = 有过 `deleted` 写入 / 被清除 / 带合成写入者的
/// 旧记录，加上移进复杂牌组的卡（迭代到不动点）。
#[test]
#[ignore]
fn probe_channel_floor() {
    use crate::sync2::dvv::Dvv;
    use crate::sync2::id::Id;
    use crate::sync2::op::{EntKind, Op};
    use crate::sync2::segment::Chain;
    use crate::sync2::vv::Vv;
    use rusqlite::config::DbConfig;
    use serde_json::{Value, json};

    let (_dir, profile, heads, segs) = setup();
    let now = 1_800_000_000_000i64;
    let pubs: HashMap<_, _> = heads
        .iter()
        .map(|h| {
            let h = segment::Head::decode(h).unwrap();
            (h.device, h.public)
        })
        .collect();
    let tmp = super::tests::tempdir::new("probe-channel");
    let db = tmp.0.join("srs.db");
    let core = crate::store::SrsCore::open(&db).unwrap();
    core.sync2_identity(&profile, now).unwrap();
    let deck = super::config::default_deck_id(&profile);
    let cmd = |req: Value, blobs: Vec<Vec<u8>>| -> Value {
        let mut req = req;
        req["profile"] = json!(profile);
        req["caches"] = json!({"defaultDeck": deck});
        let mut blobs = blobs;
        let mut files = Vec::new();
        crate::store::ffi::sync2_dispatch(&core, &req, &mut blobs, &mut files).unwrap()
    };
    cmd(json!({"op": "plan"}), heads.clone());
    let t_all = Instant::now();

    // 1. 解码验签 + 链值。
    let t = Instant::now();
    let mut by_dev: BTreeMap<Id, Vec<(Op, Chain)>> = BTreeMap::new();
    for s in &segs {
        let hdr = segment::peek_header(s).unwrap();
        let open = segment::open_verified(s, &pubs[&hdr.device], None).unwrap();
        let mut chain = open.header.prev_chain;
        for op in open.verify().unwrap() {
            let op = op.unwrap();
            chain = segment::chain_next(&chain, &op);
            by_dev.entry(op.id.device).or_default().push((op, chain));
        }
    }
    for v in by_dev.values_mut() {
        v.sort_by_key(|(o, _)| o.id.seq);
        v.dedup_by_key(|(o, _)| o.id.seq);
    }
    let total: usize = by_dev.values().map(Vec::len).sum();
    let decode = ms(t);

    // 2. 投递顺序。
    let t = Instant::now();
    let mut vv = Vv::new();
    let mut next: BTreeMap<Id, usize> = by_dev.keys().map(|d| (*d, 0)).collect();
    let mut order: Vec<(Id, usize)> = Vec::new();
    loop {
        let mut progress = false;
        for (d, ops) in &by_dev {
            let i = next.get_mut(d).unwrap();
            while *i < ops.len() {
                let op = &ops[*i].0;
                if op.id.seq != vv.get(d) + 1 || !op.deps.le(&vv) {
                    break;
                }
                vv.set(*d, op.id.seq);
                order.push((*d, *i));
                *i += 1;
                progress = true;
            }
        }
        if !progress {
            break;
        }
    }
    let order_ms = ms(t);
    let at: Vec<&(Op, Chain)> = order.iter().map(|(d, i)| &by_dev[d][*i]).collect();

    // 3. 操作日志（投递顺序，一个事务）+ 设备进度。
    let w = core.writer().unwrap();
    w.execute_batch("PRAGMA cache_size = -524288").unwrap();
    let t = Instant::now();
    w.execute_batch("BEGIN").unwrap();
    let mut dep_ids: HashMap<Vec<u8>, i64> = HashMap::new();
    for k in 0..order.len() {
        let (op, chain) = at[k];
        let bytes = op.deps.encode();
        let dep = match dep_ids.get(&bytes) {
            Some(&x) => x,
            None => {
                let x = super::intern_deps(&w, &bytes).unwrap();
                dep_ids.insert(bytes, x);
                x
            }
        };
        super::insert_op_at(&w, &profile, op, chain, now, dep).unwrap();
    }
    for (d, ops) in &by_dev {
        let n = next[d];
        if n == 0 {
            continue;
        }
        let (op, chain) = &ops[n - 1];
        w.execute(
            "UPDATE sync2_devices SET applied = ?3, chain = ?4 WHERE profile_uid = srs_id(?1) AND device = ?2",
            params![profile, d.0.to_vec(), op.id.seq as i64, chain.to_vec()],
        )
        .unwrap();
    }
    w.execute_batch("COMMIT").unwrap();
    let append = ms(t);
    let t = Instant::now();
    w.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)").unwrap();
    let ckpt_append = ms(t);
    println!(
        "PROBE channel ops={total} delivered={} undelivered={} decode={decode}ms order={order_ms}ms append={append}ms ckpt={ckpt_append}ms deps={}",
        order.len(),
        total - order.len(),
        dep_ids.len()
    );

    // 4. 解析 + 复杂实体 + 内存折叠。
    let t = Instant::now();
    let bodies: Vec<Body> = at.iter().map(|x| x.0.body().unwrap()).collect();
    let parse = ms(t);
    let t = Instant::now();
    let mut complex: HashSet<(&'static str, String)> = HashSet::new();
    // 合成写入者的旧 `tags` 记录走标签路径（不进寄存器折叠），不算复杂；`PROBE_STRICT_SYNTH=1` 回到一律算复杂。
    let strict_synth = std::env::var("PROBE_STRICT_SYNTH").as_deref() == Ok("1");
    let mut reasons: BTreeMap<String, usize> = BTreeMap::new();
    for b in &bodies {
        match b {
            Body::Edit(e) => {
                let synth = e
                    .legacy
                    .as_ref()
                    .is_some_and(|l| super::is_synthetic_writer(&l.writer));
                let why = if e.key == "deleted" {
                    Some(format!("deleted:{}", e.kind.wire()))
                } else if synth && (strict_synth || e.key != "tags") {
                    Some(format!(
                        "synthetic:{}:{}",
                        e.kind.wire(),
                        if e.key == "tags" { "tags" } else { "other" }
                    ))
                } else {
                    if synth {
                        *reasons
                            .entry("synthetic_tags_ignored".to_owned())
                            .or_default() += 1;
                    }
                    None
                };
                if let Some(why) = why {
                    *reasons.entry(why).or_default() += 1;
                    complex.insert((e.kind.wire(), e.entity.text()));
                }
            }
            Body::Purge { kind, entity } => {
                *reasons.entry(format!("purge:{}", kind.wire())).or_default() += 1;
                complex.insert((kind.wire(), entity.text()));
            }
            _ => {}
        }
    }
    let seeds = complex.len();
    println!("PROBE channel seed reasons {reasons:?}");
    loop {
        let before = complex.len();
        for b in &bodies {
            if let Body::Edit(e) = b {
                if e.kind == EntKind::Card && e.key == "deck" {
                    if let Ok(Value::String(d)) = serde_json::from_str::<Value>(&e.value) {
                        if complex.contains(&("deck", d)) {
                            complex.insert(("card", e.entity.text()));
                        }
                    }
                }
            }
        }
        if complex.len() == before {
            break;
        }
    }

    struct Arr {
        eid: String,
        text: String,
        writer: String,
        seq: i64,
        key: String,
        server: Option<i64>,
    }
    struct LogRow {
        card: String,
        kind: String,
        rating: Option<i64>,
        at: i64,
        rtype: String,
        origin: String,
        dur: i64,
        text: String,
    }
    let mut legacy: BTreeMap<Id, (i64, Dvv)> = BTreeMap::new();
    let mut groups: HashMap<(EntKind, String), Vec<Arr>> = HashMap::new();
    let mut entities: HashMap<String, (&'static str, String, String, i64)> = HashMap::new();
    let mut logs: HashMap<String, LogRow> = HashMap::new();
    type Meta = (String, Option<String>, i64, Option<i64>, Vec<u8>, i64);
    let mut log_meta: HashMap<String, Meta> = HashMap::new();
    let mut edit_ops: HashMap<String, (Vec<u8>, i64)> = HashMap::new();
    let mut ent_ops: HashMap<(&'static str, String, Vec<u8>, i64), String> = HashMap::new();
    let mut server: HashMap<String, i64> = HashMap::new();
    let mut per_op: Vec<usize> = Vec::new();
    let mut touched = super::Touched::default();
    let mut replay: BTreeSet<String> = BTreeSet::new();
    let partial_before = super::partial_closures();
    let min_server = |m: &mut HashMap<String, i64>, id: &str, s: i64| {
        let e = m.entry(id.to_owned()).or_insert(s);
        *e = (*e).min(s);
    };
    for (k, body) in bodies.iter().enumerate() {
        let op = &at[k].0;
        let dev = op.id.device.0.to_vec();
        let seq = op.id.seq as i64;
        match body {
            Body::Edit(e) => {
                if let Some(l) = &e.legacy {
                    // `note_legacy` 的同一算法，行在内存里。
                    let cur = legacy
                        .remove(&op.id.device)
                        .map(|(_, d)| d)
                        .unwrap_or_default();
                    let mut d = cur;
                    d.merge(&Dvv::parse(&l.ctx_json));
                    if !super::is_synthetic_writer(&l.writer) {
                        d.add(&l.writer, l.seq);
                    }
                    d.drop_writers(crate::registers::SYNTHETIC_WRITER_PREFIX);
                    legacy.insert(op.id.device, (op.id.seq as i64, d));
                }
                let ent = e.entity.text();
                if complex.contains(&(e.kind.wire(), ent.clone()))
                    || (e.kind == EntKind::Note && e.key == "tags")
                {
                    per_op.push(k);
                    continue;
                }
                let (eid, v) = super::edit_row_with(&profile, op, e, |vv| {
                    super::legacy_closure_with(&w, &profile, vv, |d| {
                        Ok(legacy.get(d).map(|(u, x)| (*u, x.clone())))
                    })
                })
                .unwrap();
                edit_ops.insert(eid.clone(), (dev.clone(), seq));
                ent_ops
                    .entry((e.kind.wire(), ent.clone(), dev.clone(), seq))
                    .or_insert_with(|| e.key.clone());
                if e.kind == EntKind::Card && e.key == "deck" {
                    if let Ok(Value::String(d)) = serde_json::from_str::<Value>(&e.value) {
                        ent_ops
                            .entry(("deck", d, dev.clone(), seq))
                            .or_insert_with(|| "#move".to_owned());
                    }
                }
                groups.entry((e.kind, ent)).or_default().push(Arr {
                    eid,
                    text: super::canonical(&v),
                    writer: v["w"].as_str().unwrap_or_default().to_owned(),
                    seq: v["s"].as_i64().unwrap_or(0),
                    key: e.key.clone(),
                    server: e.legacy.as_ref().and_then(|l| l.server_time),
                });
            }
            Body::Log(l) => {
                let card = l.card.text();
                let note = l.note.as_ref().map(|n| n.text());
                if complex.contains(&("card", card.clone()))
                    || note
                        .as_ref()
                        .is_some_and(|n| complex.contains(&("note", n.clone())))
                {
                    per_op.push(k);
                    continue;
                }
                let lid = l.id.text();
                let (intent, arg) = super::intent_code(&l.intent);
                log_meta
                    .entry(lid.clone())
                    .or_insert_with(|| (card.clone(), note.clone(), intent, arg, dev.clone(), seq));
                ent_ops
                    .entry(("card", card.clone(), dev.clone(), seq))
                    .or_insert_with(|| "#log".to_owned());
                if let Some(n) = &note {
                    ent_ops
                        .entry(("note", n.clone(), dev.clone(), seq))
                        .or_insert_with(|| "#log".to_owned());
                }
                if !logs.contains_key(&lid) {
                    let row = super::log_row(&profile, op, l);
                    if let Some(s) = l.legacy_server_time {
                        min_server(&mut server, &lid, s);
                    }
                    touched.marks.log(&card);
                    replay.insert(card.clone());
                    logs.insert(
                        lid,
                        LogRow {
                            card,
                            kind: l.kind.clone(),
                            rating: l.rating,
                            at: l.at,
                            rtype: l.rtype.clone(),
                            origin: l.origin.clone(),
                            dur: l.dur,
                            text: super::canonical(&row),
                        },
                    );
                }
            }
            Body::Entity { kind, id, data } => {
                let idt = id.text();
                if complex.contains(&(kind.wire(), idt.clone())) {
                    per_op.push(k);
                    continue;
                }
                let d: Value = serde_json::from_str(data).unwrap_or(Value::Null);
                let rec =
                    super::canonical(&json!({"id": idt, "p": profile, "k": kind.wire(), "d": d}));
                let write = match entities.get(&idt) {
                    None => true,
                    Some(old) => rec < old.1,
                };
                if write {
                    entities.insert(
                        idt.clone(),
                        (
                            kind.wire(),
                            rec,
                            super::canonical(&d),
                            d["createdAt"].as_i64().unwrap_or(0),
                        ),
                    );
                    touched.marks.entity(*kind, &idt);
                }
            }
            _ => per_op.push(k),
        }
    }
    let partial = super::partial_closures() - partial_before;
    let rows_ms = ms(t);

    let t = Instant::now();
    let mut fe: Vec<(String, &'static str, String, String, String, i64, String)> = Vec::new();
    let (mut arrived, mut landed_n) = (0usize, 0usize);
    for ((kind, ent), arrs) in groups {
        let items: Vec<crate::registers::StoredEdit<'_>> = arrs
            .iter()
            .map(|a| (a.text.as_str(), a.server, None))
            .collect();
        let (landed, deleted) = crate::registers::land_stored(&items, 0).unwrap();
        let gone: HashSet<usize> = deleted.iter().flatten().copied().collect();
        arrived += arrs.len();
        for (i, a) in arrs.into_iter().enumerate() {
            if !landed[i] {
                continue;
            }
            landed_n += 1;
            if let Some(s) = a.server {
                min_server(&mut server, &a.eid, s);
            }
            touched.marks.edit(kind, &ent, &a.key);
            if kind == EntKind::Card {
                if let Some(p) = a.key.strip_prefix("historyFrom/") {
                    replay.insert(ent.clone());
                    replay.insert(p.to_owned());
                }
            }
            if !gone.contains(&i) {
                fe.push((
                    a.eid,
                    kind.wire(),
                    ent.clone(),
                    a.key,
                    a.writer,
                    a.seq,
                    a.text,
                ));
            }
        }
    }
    let fold = ms(t);
    println!(
        "PROBE channel parse={parse}ms rows={rows_ms}ms fold={fold}ms complex={} (seeds {seeds}) per_op={} partial_closures={partial} \
         edits={arrived} landed={landed_n} survivors={} logs={} entities={} ent_ops={} event_local={}",
        complex.len(),
        per_op.len(),
        fe.len(),
        logs.len(),
        entities.len(),
        ent_ops.len(),
        server.len()
    );

    // 5. 有序写。
    let names = |sql: &str| -> Vec<String> {
        let mut s = w.prepare(sql).unwrap();
        let v = s
            .query_map([], |r| r.get::<_, String>(0))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        v
    };
    for n in names("SELECT name FROM sqlite_temp_master WHERE type = 'trigger'") {
        w.execute_batch(&format!("DROP TRIGGER temp.{n}")).unwrap();
    }
    w.set_db_config(DbConfig::SQLITE_DBCONFIG_ENABLE_TRIGGER, false)
        .unwrap();
    let drop_indexes = std::env::var("PROBE_DROP_INDEXES").as_deref() == Ok("1");
    let written = [
        "srs_entities",
        "srs_field_edits",
        "srs_review_logs",
        "srs_event_local",
        "sync2_edit_ops",
        "sync2_ent_ops",
        "sync2_log_meta",
    ];
    let indexes: Vec<(String, String)> = if drop_indexes {
        let q = format!(
            "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL AND tbl_name IN ({})",
            written
                .iter()
                .map(|t| format!("'{t}'"))
                .collect::<Vec<_>>()
                .join(", ")
        );
        let mut s = w.prepare(&q).unwrap();
        let v = s
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        v
    } else {
        Vec::new()
    };
    let t_write = Instant::now();
    w.execute_batch("BEGIN").unwrap();
    for (n, _) in &indexes {
        w.execute_batch(&format!("DROP INDEX {n}")).unwrap();
    }
    let mut per_table: Vec<(&str, u128)> = Vec::new();
    let t = Instant::now();
    {
        let mut v: Vec<_> = entities.into_iter().collect();
        v.sort_by(|a, b| a.0.cmp(&b.0));
        let mut s = w
            .prepare("INSERT INTO srs_entities (id, profile_uid, kind, payload_json, created_at) VALUES (srs_id(?1), srs_id(?2), ?3, ?4, ?5)")
            .unwrap();
        for (id, (kind, _, payload, created)) in &v {
            s.execute(params![id, profile, kind, payload, created])
                .unwrap();
        }
    }
    per_table.push(("entities", ms(t)));
    let t = Instant::now();
    {
        fe.sort_by(|a, b| a.0.cmp(&b.0));
        let mut s = w
            .prepare(
                "INSERT INTO srs_field_edits (id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, jslim) \
                 VALUES (srs_id(?1), srs_id(?2), ?3, srs_id(?4), ?5, srs_id(?6), ?7, srs_edit_pack(?8, ?1, ?2, ?3, ?4, ?5, ?6, ?7))",
            )
            .unwrap();
        for (eid, kind, ent, key, writer, seq, text) in &fe {
            s.execute(params![eid, profile, kind, ent, key, writer, seq, text])
                .unwrap();
        }
    }
    per_table.push(("field_edits", ms(t)));
    let t = Instant::now();
    {
        let mut v: Vec<_> = logs.into_iter().collect();
        v.sort_by(|a, b| a.0.cmp(&b.0));
        let mut s = w
            .prepare(
                "INSERT INTO srs_review_logs (id, profile_uid, card_id, kind, rating, occurred_at, review_type, origin, duration_ms, jslim) \
                 VALUES (srs_id(?1), srs_id(?2), srs_id(?3), ?4, ?5, ?6, ?7, ?8, ?9, srs_log_pack(?10, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9))",
            )
            .unwrap();
        for (lid, r) in &v {
            s.execute(params![
                lid, profile, r.card, r.kind, r.rating, r.at, r.rtype, r.origin, r.dur, r.text
            ])
            .unwrap();
        }
    }
    per_table.push(("review_logs", ms(t)));
    let t = Instant::now();
    {
        let mut v: Vec<_> = server.into_iter().collect();
        v.sort();
        let mut s = w
            .prepare(
                "INSERT INTO srs_event_local (event_id, profile_uid, outbox_seq, server_time, received_at) VALUES (srs_id(?1), srs_id(?2), NULL, ?3, ?4)",
            )
            .unwrap();
        for (id, st) in &v {
            s.execute(params![id, profile, st, now]).unwrap();
        }
    }
    per_table.push(("event_local", ms(t)));
    let t = Instant::now();
    {
        let mut v: Vec<_> = edit_ops.into_iter().collect();
        v.sort();
        let mut s = w.prepare("INSERT INTO sync2_edit_ops (edit_id, profile_uid, device, seq) VALUES (srs_id(?1), srs_id(?2), ?3, ?4)").unwrap();
        for (eid, (d, sq)) in &v {
            s.execute(params![eid, profile, d, sq]).unwrap();
        }
    }
    per_table.push(("edit_ops", ms(t)));
    let t = Instant::now();
    {
        let mut v: Vec<_> = ent_ops.into_iter().collect();
        v.sort();
        let mut s = w
            .prepare("INSERT INTO sync2_ent_ops (profile_uid, kind, entity, device, seq, what) VALUES (srs_id(?1), ?2, srs_id(?3), ?4, ?5, ?6)")
            .unwrap();
        for ((kind, ent, d, sq), what) in &v {
            s.execute(params![profile, kind, ent, d, sq, what]).unwrap();
        }
    }
    per_table.push(("ent_ops", ms(t)));
    let t = Instant::now();
    {
        let mut v: Vec<_> = log_meta.into_iter().collect();
        v.sort_by(|a, b| a.0.cmp(&b.0));
        let mut s = w
            .prepare(
                "INSERT INTO sync2_log_meta (log_id, profile_uid, card_id, note_id, intent, arg, device, seq) \
                 VALUES (srs_id(?1), srs_id(?2), srs_id(?3), srs_id(?4), ?5, ?6, ?7, ?8)",
            )
            .unwrap();
        for (lid, (card, note, intent, arg, d, sq)) in &v {
            s.execute(params![lid, profile, card, note, intent, arg, d, sq])
                .unwrap();
        }
    }
    per_table.push(("log_meta", ms(t)));
    let t = Instant::now();
    for (_, sql) in &indexes {
        w.execute_batch(sql).unwrap();
    }
    per_table.push(("reindex", ms(t)));

    // 6. 其余操作逐条投影（投递顺序）。
    let t = Instant::now();
    let mut by_kind: BTreeMap<&'static str, (usize, u128)> = BTreeMap::new();
    for &k in &per_op {
        let op = &at[k].0;
        let tk = Instant::now();
        let name: &'static str = match &bodies[k] {
            Body::Edit(e) if e.key == "tags" => "edit_tags",
            Body::Edit(_) => "edit",
            Body::Log(_) => "log",
            Body::Entity { .. } => "entity",
            Body::TagAdd { .. } => "tag_add",
            Body::TagRemove { .. } => "tag_remove",
            Body::TagOrder { .. } => "tag_order",
            _ => "other",
        };
        match &bodies[k] {
            Body::Edit(e) => {
                super::project_edit_noted(&w, &profile, op, e, now, true, &mut touched).unwrap()
            }
            b => super::project_body(&w, &profile, op, b.clone(), now, true, &mut touched).unwrap(),
        }
        let e = by_kind.entry(name).or_default();
        e.0 += 1;
        e.1 += tk.elapsed().as_micros();
    }
    let per_op_ms = ms(t);
    println!(
        "PROBE channel per_op by kind {:?}",
        by_kind
            .iter()
            .map(|(k, (n, us))| format!(
                "{k}: n={n} {}ms {:.0}us/op",
                us / 1000,
                *us as f64 / *n as f64
            ))
            .collect::<Vec<_>>()
    );

    // 7. 旧修改记录闭包写回 + 摘要重建。
    let t = Instant::now();
    for (d, (upto, x)) in &legacy {
        w.execute(
            "INSERT OR REPLACE INTO sync2_legacy (profile_uid, device, upto, ctx) VALUES (srs_id(?1), ?2, ?3, ?4)",
            params![profile, d.0.to_vec(), upto, x.to_json().to_string()],
        )
        .unwrap();
    }
    super::digest::rebuild(&w).unwrap();
    let digest_ms = ms(t);
    w.set_db_config(DbConfig::SQLITE_DBCONFIG_ENABLE_TRIGGER, true)
        .unwrap();
    let t = Instant::now();
    w.execute_batch("COMMIT").unwrap();
    let commit_ms = ms(t);
    let write_ms = ms(t_write);
    let t = Instant::now();
    w.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)").unwrap();
    let ckpt_write = ms(t);
    println!(
        "PROBE channel write={write_ms}ms {per_table:?} per_op={per_op_ms}ms legacy+digest={digest_ms}ms commit={commit_ms}ms ckpt={ckpt_write}ms drop_indexes={drop_indexes}"
    );

    // 8. 收尾（与 probe_finish 的 prod 相同）。
    let t = Instant::now();
    replay.extend(touched.cards.iter().cloned());
    let mut dirty = crate::store::caches::Dirty::default();
    dirty.notes.extend(touched.marks.notes.iter().cloned());
    dirty.cards.extend(touched.marks.cards.iter().cloned());
    dirty
        .note_types
        .extend(touched.marks.note_types.iter().cloned());
    for (kind, id) in &touched.entities_changed {
        match kind.as_str() {
            "note" => dirty.notes.insert(id.clone()),
            "card" => dirty.cards.insert(id.clone()),
            "notetype" => dirty.note_types.insert(id.clone()),
            _ => false,
        };
    }
    super::in_savepoint(&w, |c| {
        super::transport::defer_replay(c, &profile, &replay)?;
        super::transport::defer_cache_refresh(c, &profile, std::mem::take(&mut dirty), false)
            .map(|_| ())
    })
    .unwrap();
    let cfg = crate::store::caches::CacheConfig::parse(
        &json!({"defaultDeck": super::config::default_deck_id(&profile)}),
    )
    .unwrap();
    let (replayed, _) = super::in_savepoint(&w, |c| {
        super::transport::replay_pending(
            c,
            &profile,
            &mut super::transport::CommitBudget::unlimited(),
        )
    })
    .unwrap();
    let replay_ms = ms(t);
    let t = Instant::now();
    loop {
        let more = super::in_savepoint(&w, |c| {
            let (d, _) = super::transport::take_cache_pending(c, &profile, 512)?;
            let written = crate::store::caches::refresh(c, &profile, &cfg, d)?;
            super::transport::settle_refreshed_cards(c, &profile, &written.cards)?;
            super::transport::cache_is_pending(c, &profile)
        })
        .unwrap();
        if !more {
            break;
        }
    }
    let caches_ms = ms(t);
    let t = Instant::now();
    w.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)").unwrap();
    let ckpt_finish = ms(t);
    println!(
        "PROBE channel finish replay={replay_ms}ms (cards {} changed {}) caches={caches_ms}ms ckpt={ckpt_finish}ms",
        replay.len(),
        replayed.len()
    );
    println!("PROBE channel total={}ms db={}MB", ms(t_all), size_mb(&db));
    table_hashes(&w);
}

/// 新设备收段通道的收尾分阶段计时：从 [probe_sliced] 在收尾前存下的库（`PROBE_KEEP` → `PROBE_FINISH_DB`，通道停在追加
/// 阶段）起，经生产分发器循环 `replay_pending` 到 `more` 为假，按每次调用之前所处的阶段（折叠 / 逐条 / 重放 / 缓存）
/// 记耗时与调用数。`PROBE_SLICE_MS` 改片长。
#[test]
#[ignore]
fn probe_channel_finish() {
    use rusqlite::OptionalExtension;
    let dir = PathBuf::from(std::env::var("SRS_BENCH_DIR").expect("SRS_BENCH_DIR"));
    let profile = dir
        .parent()
        .unwrap()
        .file_name()
        .unwrap()
        .to_string_lossy()
        .into_owned();
    let src = PathBuf::from(std::env::var("PROBE_FINISH_DB").expect("PROBE_FINISH_DB"));
    let tmp = super::tests::tempdir::new("probe-channel-finish");
    let db = tmp.0.join("srs.db");
    std::fs::copy(&src, &db).unwrap();
    let core = crate::store::SrsCore::open(&db).unwrap();
    // 与收段会话里一样：会话收完之前写连接放回时留着页缓存（ffi.rs 收尾刷完才放）。
    {
        let mut phase = core.ingest_phase().unwrap();
        core.set_ingest_phase(
            &mut phase,
            super::transport::IngestPhase::Draining(profile.clone()),
        );
    }
    let deck = super::config::default_deck_id(&profile);
    let slice_ms: Option<u64> = std::env::var("PROBE_SLICE_MS")
        .ok()
        .and_then(|v| v.parse().ok());
    let phase = || -> &'static str {
        let w = core.writer().unwrap();
        let boot: Option<i64> = w
            .query_row("SELECT phase FROM sync2_boot", [], |r| r.get(0))
            .optional()
            .unwrap();
        match boot {
            Some(0) => "append",
            Some(1) => "fold",
            Some(2) => "merge",
            Some(_) => "one",
            None => {
                let rp: bool = w
                    .query_row(
                        "SELECT EXISTS(SELECT 1 FROM sync2_replay_pending)",
                        [],
                        |r| r.get(0),
                    )
                    .unwrap();
                if rp { "replay" } else { "cache" }
            }
        }
    };
    {
        let w = core.writer().unwrap();
        let n = |q: &str| -> i64 { w.query_row(q, [], |r| r.get(0)).unwrap() };
        println!(
            "PROBE cfinish order={} one_by_one={} complex={}",
            n("SELECT count(*) FROM sync2_boot_order"),
            n("SELECT count(*) FROM sync2_boot_order WHERE part = 64"),
            n("SELECT count(*) FROM sync2_boot_complex"),
        );
    }
    let mut acc: BTreeMap<&'static str, (u128, usize, u128)> = BTreeMap::new();
    let t0 = Instant::now();
    let mut last = "";
    let mut cache_calls = 0usize;
    loop {
        let p = phase();
        if p == "cache" {
            cache_calls += 1;
        }
        if p != last || (p == "cache" && cache_calls % 500 == 0) {
            let w = core.writer().unwrap();
            let n = |q: &str| -> i64 { w.query_row(q, [], |r| r.get(0)).unwrap() };
            println!(
                "PROBE cfinish enter={p} replay_pending={} cache_pending types={} notes={} cards={}",
                n("SELECT count(*) FROM sync2_replay_pending"),
                n("SELECT count(*) FROM sync2_cache_pending WHERE kind = 0"),
                n("SELECT count(*) FROM sync2_cache_pending WHERE kind = 1"),
                n("SELECT count(*) FROM sync2_cache_pending WHERE kind = 2"),
            );
            last = p;
        }
        let mut req = serde_json::json!({"op": "replay_pending", "profile": profile, "caches": {"defaultDeck": deck}});
        if let Some(s) = slice_ms {
            req["sliceMs"] = serde_json::json!(s);
        }
        let t = Instant::now();
        let r = crate::store::ffi::sync2_dispatch(&core, &req, &mut Vec::new(), &mut Vec::new())
            .unwrap();
        let d = t.elapsed().as_micros();
        let e = acc.entry(p).or_default();
        e.0 += d;
        e.1 += 1;
        e.2 = e.2.max(d);
        if r["more"] != serde_json::json!(true) {
            break;
        }
    }
    let total = ms(t0);
    for (p, (us, n, max)) in &acc {
        println!(
            "PROBE cfinish phase={p} ms={} calls={n} max_call_ms={}",
            us / 1000,
            max / 1000
        );
    }
    let w = core.writer().unwrap();
    println!(
        "PROBE cfinish total={total}ms db={}MB wal={}MB",
        size_mb(&db),
        size_mb(&tmp.0.join("srs.db-wal"))
    );
    table_hashes(&w);
}
