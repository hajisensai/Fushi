//! 大 profile 分批收段的逐批内存（默认不跑）：反馈 BUG-4004 的小米真机在 35 万条复习日志的 profile 上，收段
//! （`stage=downloading:ingest 1144/1230`，几十批）中 Scudo「internal map failure」原生 OOM。这里造同形数据：设备 A
//! 写 `SRS_BENCH_CARDS` 张卡（缺省 35000，每卡一条笔记）× `SRS_BENCH_REVIEWS` 次复习（缺省 10），按 `SRS_BENCH_CHUNK`
//! 张卡（缺省 300）一轮发件，切出上千个小段；新设备 B 走生产的分发器（ffi.rs `sync2_dispatch`）按会话收：
//! `ingest_begin` → 每 `SRS_BENCH_BATCH_SEGS` 段（缺省 30）一批 `ingest_prepare` + `ingest_commit` 直到 `more` 为假
//! （每 3 片在另一条连接上并回一次 WAL，同 Dart `SrsWalCheckpointPacer` 的量级）→ `ingest_finish` + `replay_pending`
//! → `ingest_end`。`SRS_BENCH_STUDIED=1`：B 本机先复习过一次（不是新设备，不走收段通道，逐条投递 + 每片刷新缓存）。每批的 prepare、commit（全部片）与收尾各量一次（mem_bench.rs `measure`：Rust 堆 / SQLite 堆比步前
//! 多出的峰值、步后常驻、耗时），另打印 Windows 进程的工作集与私有提交（含 mmap 映射页 / 不含）。
//!
//! 要用生产常量（投递窗口、缓冲字节、预处理留存、收尾缓存块；测试构建里压得很小），所以带 `--cfg srs_probe`、
//! 用单独的 target 目录：
//! `RUSTFLAGS="--cfg srs_probe" CARGO_TARGET_DIR=target/probe cargo test --release --lib bench_ingest_batches -- --ignored --nocapture --test-threads=1`

use serde_json::{json, Value};

use super::mem_bench::{measure, Mem};
use super::tests::{deck_entity, edit, review, Bucket, Device, P};

const T0: i64 = 1_700_000_000_000;
const DAY: i64 = 86_400_000;

fn env(k: &str, d: usize) -> usize {
    std::env::var(k).ok().and_then(|v| v.parse().ok()).unwrap_or(d)
}

/// 进程工作集与私有提交（MiB）。工作集含 mmap 映射进来的库文件页（干净、可回收），私有提交不含。
#[cfg(windows)]
fn process_mem() -> (f64, f64) {
    #[repr(C)]
    #[derive(Default)]
    struct Counters {
        cb: u32,
        page_fault_count: u32,
        peak_working_set: usize,
        working_set: usize,
        quota_peak_paged_pool: usize,
        quota_paged_pool: usize,
        quota_peak_non_paged_pool: usize,
        quota_non_paged_pool: usize,
        pagefile: usize,
        peak_pagefile: usize,
        private_usage: usize,
    }
    #[link(name = "kernel32")]
    extern "system" {
        fn GetCurrentProcess() -> isize;
        fn K32GetProcessMemoryInfo(p: isize, c: *mut Counters, cb: u32) -> i32;
    }
    let mut c = Counters { cb: std::mem::size_of::<Counters>() as u32, ..Default::default() };
    // SAFETY: 输出结构体是本函数的局部变量，大小如实给出。
    let ok = unsafe { K32GetProcessMemoryInfo(GetCurrentProcess(), &mut c, c.cb) };
    if ok == 0 {
        return (0.0, 0.0);
    }
    (c.working_set as f64 / 1048576.0, c.private_usage as f64 / 1048576.0)
}

#[cfg(not(windows))]
fn process_mem() -> (f64, f64) {
    (0.0, 0.0)
}

fn line(tag: &str, m: &Mem, extra: &str) {
    let (ws, private) = process_mem();
    println!(
        "INGEST_MEM {tag:<16} rust_peak={:>7.2} kept={:>7.2}  sqlite_peak={:>6.2} kept={:>6.2}  {:>6}ms  ws={ws:>6.0} priv={private:>6.0}  {extra}",
        m.rust_peak, m.rust_kept, m.sqlite_peak, m.sqlite_kept, m.ms
    );
}

fn len(v: &Value, k: &str) -> usize {
    v[k].as_array().map_or(0, Vec::len)
}

#[test]
#[ignore]
fn bench_ingest_batches() {
    let cards = env("SRS_BENCH_CARDS", 35_000);
    let reviews = env("SRS_BENCH_REVIEWS", 10);
    let chunk = env("SRS_BENCH_CHUNK", 300);
    let per_batch = env("SRS_BENCH_BATCH_SEGS", 30);
    let deck = super::config::default_deck_id(P);
    let now = T0 + (reviews as i64 + 5) * DAY;

    // A：按天、按块写，每块发一次件（一块切一段，真实形状：每轮同步一个小段）。
    let t = std::time::Instant::now();
    let a = Device::new("ingest-mem-a");
    // 真实形状的笔记类型（一个字段、一个模板），笔记 / 卡 ID 与生产同形：收尾的缓存刷新真的为每条笔记 / 每张卡写缓存行。
    a.apply(
        T0,
        vec![
            deck_entity(&deck),
            edit("deck", &deck, "name", json!("Default")),
            json!({"t": "entity", "x": {"id": "NT", "p": P, "k": "notetype", "d": {"createdAt": 1, "ntKind": "standard"}}}),
            edit("notetype", "NT", "fieldDef/fa", json!({"name": "Expression", "ord": 0})),
            edit("notetype", "NT", "tmplDef/t1", json!({"name": "C", "ord": 0, "front": "{{Expression}}"})),
        ],
    );
    let note_id = |n: usize| format!("0193a1b2-0000-7000-8000-{n:012x}");
    let card_id = |n: usize| crate::registers::card_id(&note_id(n), "t1", 0).unwrap();
    let mut bucket = Bucket::default();
    for r in 0..reviews {
        for from in (0..cards).step_by(chunk) {
            let mut input = Vec::new();
            for c in from..(from + chunk).min(cards) {
                let note = note_id(c);
                if r == 0 {
                    let text = format!("例文{c}：日本語の文章をここに書く。読み方と意味。");
                    input.push(json!({"e": json!({"t": "entity", "x": {"id": note, "p": P, "k": "note", "d": {"createdAt": 1, "guid": note, "noteTypeId": "NT"}}}), "note": note}));
                    input.push(json!({"e": edit("note", &note, "f/fa", json!(text)), "note": note}));
                }
                let at = T0 + r as i64 * DAY + c as i64;
                let e = review(&format!("r{c}-{r}"), &card_id(c), at, 1 + (r as i64 % 4), if r == 0 { "learn" } else { "review" });
                input.push(json!({"e": e, "note": note}));
            }
            a.core.sync2_apply_local(P, T0 + r as i64 * DAY + from as i64, &Value::Array(input).to_string()).unwrap();
            a.upload_all(&mut bucket, "loc");
        }
    }
    a.sync(&mut bucket, "loc", now);
    let heads: Vec<Vec<u8>> = bucket.0.iter().filter(|(k, _)| k.contains("/head-")).map(|(_, v)| v.clone()).collect();
    let segs: Vec<Vec<u8>> = bucket.0.iter().filter(|(k, _)| k.contains("/seg-")).map(|(_, v)| v.clone()).collect();
    drop(bucket);
    drop(a);
    let bytes: usize = segs.iter().map(Vec::len).sum();
    println!(
        "INGEST_MEM setup cards={cards} reviews={} segs={} bytes={:.1}MiB batches={} ({}ms)",
        cards * reviews,
        segs.len(),
        bytes as f64 / 1048576.0,
        segs.len().div_ceil(per_batch),
        t.elapsed().as_millis()
    );

    // B：新设备，按生产分发器的会话协议收。
    let b = Device::new("ingest-mem-b");
    b.core.sync2_identity(P, now).unwrap();
    b.core.sync2_plan(P, &heads).unwrap();
    if env("SRS_BENCH_STUDIED", 0) != 0 {
        // B 本机先复习过一次：不是新设备，不走收段通道（channel.rs），按逐条投递 + 每片刷新缓存收。
        b.apply(now, vec![review("b-own", &card_id(0), now, 3, "learn")]);
    }
    // 收段期间 Dart（`bulkWrites`）把写连接的自动 checkpoint 阈值调到 16384。
    b.core.writer().unwrap().execute_batch("PRAGMA wal_autocheckpoint = 16384").unwrap();
    let cmd = |mut req: Value, blobs: Vec<Vec<u8>>| -> Value {
        req["profile"] = json!(P);
        req["caches"] = json!({"defaultDeck": deck});
        req["localState"] = json!("{\"revision\":0}");
        let (mut blobs, mut files) = (blobs, Vec::new());
        crate::store::ffi::sync2_dispatch(&b.core, &req, &mut blobs, &mut files).unwrap()
    };
    let begin = cmd(json!({"op": "ingest_begin"}), vec![]);
    println!("INGEST_MEM begin {begin}");
    let (mut resident_rust, mut resident_sqlite) = (0.0f64, 0.0f64);
    let mut slices = 0usize;
    for (i, batch) in segs.chunks(per_batch).enumerate() {
        let batch = batch.to_vec();
        let (_, m) = measure(|| cmd(json!({"op": "ingest_prepare"}), batch));
        resident_rust += m.rust_kept;
        resident_sqlite += m.sqlite_kept;
        line(&format!("b{i:03} prepare"), &m, "");
        let (stats, m) = measure(|| {
            let (mut n, mut applied, mut replayed, mut changed, mut cache) = (0usize, 0i64, 0usize, 0usize, 0usize);
            let mut pending;
            loop {
                n += 1;
                let r = cmd(json!({"op": "ingest_commit", "now": now}), vec![]);
                applied += r["applied"].as_i64().unwrap_or(0);
                replayed += len(&r, "replayed");
                changed += len(&r, "changed");
                cache += len(&r["cache"], "cards") + len(&r["cache"], "notes");
                pending = r["pending"].as_i64().unwrap_or(0);
                if r["more"] != json!(true) {
                    break;
                }
                if n % 3 == 0 {
                    b.core.wal_checkpoint().unwrap();
                }
            }
            (n, applied, replayed, changed, cache, pending)
        });
        slices += stats.0;
        resident_rust += m.rust_kept;
        resident_sqlite += m.sqlite_kept;
        line(
            &format!("b{i:03} commit"),
            &m,
            &format!(
                "slices={} applied={} replayed={} changed={} cache={} pending={}  resident rust={resident_rust:.2} sqlite={resident_sqlite:.2}",
                stats.0, stats.1, stats.2, stats.3, stats.4, stats.5
            ),
        );
    }
    let (calls, m) = measure(|| {
        let mut r = cmd(json!({"op": "ingest_finish", "now": now}), vec![]);
        let mut calls = vec![(len(&r, "replayed"), len(&r["cache"], "cards") + len(&r["cache"], "notes"))];
        while r["more"] == json!(true) {
            r = cmd(json!({"op": "replay_pending"}), vec![]);
            calls.push((len(&r, "replayed"), len(&r["cache"], "cards") + len(&r["cache"], "notes")));
        }
        calls
    });
    let max_replayed = calls.iter().map(|c| c.0).max().unwrap_or(0);
    let max_cache = calls.iter().map(|c| c.1).max().unwrap_or(0);
    let total_cache: usize = calls.iter().map(|c| c.1).sum();
    line("finish", &m, &format!("calls={} max_replayed/call={max_replayed} max_cache_rows/call={max_cache} cache_rows={total_cache}", calls.len()));
    let (_, m) = measure(|| cmd(json!({"op": "ingest_end"}), vec![]));
    line("end", &m, &format!("slices={slices}"));
    let cached = b.rows("SELECT COUNT(*) FROM srs_cards_cache");
    assert_eq!(cached[1][0], cards.to_string(), "every card got a cache row");
    let logs = b.rows("SELECT COUNT(*) FROM srs_review_logs");
    let own = usize::from(env("SRS_BENCH_STUDIED", 0) != 0);
    assert_eq!(logs[1][0], (cards * reviews + own).to_string(), "every review log landed");
}
