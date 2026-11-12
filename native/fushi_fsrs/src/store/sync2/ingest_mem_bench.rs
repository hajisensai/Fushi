//! 大 profile 分批收段的逐批内存（默认不跑）：反馈 BUG-4012 的小米真机在 35 万条复习日志的 profile 上，收段
//! （`stage=downloading:ingest 1144/1230`，几十批）中 Scudo「internal map failure」原生 OOM。这里造同形数据：设备 A
//! 写 `SRS_BENCH_CARDS` 张卡（缺省 35000，每卡一条笔记）× `SRS_BENCH_REVIEWS` 次复习（缺省 10），按 `SRS_BENCH_CHUNK`
//! 张卡（缺省 300）一轮发件，切出上千个小段；新设备 B 走生产的分发器（ffi.rs `sync2_dispatch`）按会话收：
//! `ingest_begin` → 每 `SRS_BENCH_BATCH_SEGS` 段（缺省 30）一批 `ingest_prepare` + `ingest_commit` 直到 `more` 为假
//! （每 3 片在另一条连接上并回一次 WAL，同 Dart `SrsWalCheckpointPacer` 的量级）→ `ingest_finish` + `replay_pending`
//! → `ingest_end`。`SRS_BENCH_STUDIED=1`：B 本机先复习过一次（不是新设备，不走收段通道，逐条投递 + 每片刷新缓存）。每批的 prepare、commit（全部片）与收尾各量一次（mem_bench.rs `measure`：Rust 堆 / SQLite 堆比步前
//! 多出的峰值、步后常驻、耗时），另打印 Windows 进程的工作集与私有提交（含 mmap 映射页 / 不含）。
//!
//! `SRS_BENCH_ANSWERS=1`：每条复习带上与重放一致的作者结果与显式作答意图（真实作答的形状，见 [answers]）。
//! `SRS_BENCH_TAGS=1`：每条笔记另写一条整列表标签。`SRS_BENCH_OUT=<目录>`：只造数据——A 发完件后把位置上的文件写到 `<目录>/<profile>/v3/` 就结束，不收。
//!
//! 要用生产常量（投递窗口、缓冲字节、预处理留存、收尾缓存块；测试构建里压得很小），所以带 `--cfg srs_probe`、
//! 用单独的 target 目录：
//! `RUSTFLAGS="--cfg srs_probe" CARGO_TARGET_DIR=target/probe cargo test --release --lib bench_ingest_batches -- --ignored --nocapture --test-threads=1`

use serde_json::{Value, json};

use super::mem_bench::{Mem, measure};
use super::tests::{Bucket, Device, P, deck_entity, edit, review};

const T0: i64 = 1_700_000_000_000;
const DAY: i64 = 86_400_000;

fn env(k: &str, d: usize) -> usize {
    std::env::var(k)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(d)
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
    let mut c = Counters {
        cb: std::mem::size_of::<Counters>() as u32,
        ..Default::default()
    };
    // SAFETY: 输出结构体是本函数的局部变量，大小如实给出。
    let ok = unsafe { K32GetProcessMemoryInfo(GetCurrentProcess(), &mut c, c.cb) };
    if ok == 0 {
        return (0.0, 0.0);
    }
    (
        c.working_set as f64 / 1048576.0,
        c.private_usage as f64 / 1048576.0,
    )
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

/// 真实作答的作者结果：每张卡（[card_id]）的 [reviews] 次复习（[event] 给出第 r 次的日志事件，结果是占位值）按
/// 默认牌组此刻的配置重放一遍，取每条日志重放后的 `res`。生产里作答的结果由内核预览算出（同一段重放代码），别的
/// 设备重放得到同一个值、不改写日志行；结果留着占位值时收方会把每一条日志改写一遍（真实数据里只有并发复习才这样）。
fn answers(
    a: &Device,
    deck: &str,
    cards: usize,
    reviews: usize,
    event: impl Fn(usize, usize) -> Value,
) -> Vec<Vec<Value>> {
    use crate::sync2::op::Intent;
    use crate::sync2::replay::{Row, SNAPSHOT_KEY, replay};
    let cfg = {
        let w = a.core.writer().unwrap();
        super::config::DeckTree::load(&w, P)
            .unwrap()
            .config(deck)
            .to_json()
    };
    (0..cards)
        .map(|c| {
            let texts: Vec<String> = (0..reviews)
                .map(|r| {
                    let mut x = event(c, r)["x"].take();
                    x[SNAPSHOT_KEY] = cfg.clone();
                    x.to_string()
                })
                .collect();
            let rows: Vec<Row<'_>> = texts
                .iter()
                .map(|t| Row {
                    json: t,
                    server_time: None,
                    intent: Intent::Answer,
                })
                .collect();
            let out = replay(&rows).unwrap();
            out.rows
                .iter()
                .zip(&texts)
                .map(|(new, old)| {
                    serde_json::from_str::<Value>(new.as_deref().unwrap_or(old)).unwrap()["res"]
                        .take()
                })
                .collect()
        })
        .collect()
}

/// 位置上现行的段：每台设备从最小的起点起、每个起点取最长的那一段接成的一条链（`…/seg-<起>-<止>-<哈希>.bin`）。
/// 测试用的桶不删被合并取代的小段（生产里发件方按 head 的过时清单删），照原样落盘的话同一条操作会出现在很多个段
/// 里——收方要把每个段都解开、逐条认出「已经有了」，量到的就不是真实文件夹的形状（真实文件夹的段不重叠）。
fn current_segments<'a>(
    paths: impl Iterator<Item = &'a str>,
) -> std::collections::HashSet<&'a str> {
    use std::collections::BTreeMap;
    // 设备目录 → 起点 → （止点, 路径）里止点最大的。
    let mut by_device: BTreeMap<&str, BTreeMap<u64, (u64, &str)>> = BTreeMap::new();
    for path in paths {
        let Some((dir, name)) = path.rsplit_once('/') else {
            continue;
        };
        let mut parts = name.split('-');
        if parts.next() != Some("seg") {
            continue;
        }
        let (Some(Ok(first)), Some(Ok(last))) = (
            parts.next().map(str::parse::<u64>),
            parts.next().map(str::parse::<u64>),
        ) else {
            continue;
        };
        let longest = by_device
            .entry(dir)
            .or_default()
            .entry(first)
            .or_insert((last, path));
        if last > longest.0 {
            *longest = (last, path);
        }
    }
    let mut keep = std::collections::HashSet::new();
    for starts in by_device.values() {
        let mut at = starts.keys().next().copied();
        while let Some((last, path)) = at.and_then(|a| starts.get(&a)) {
            keep.insert(*path);
            at = Some(last + 1);
        }
    }
    keep
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
    let tags = env("SRS_BENCH_TAGS", 0) != 0;
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
    let event = |c: usize, r: usize| {
        review(
            &format!("r{c}-{r}"),
            &card_id(c),
            T0 + r as i64 * DAY + c as i64,
            1 + (r as i64 % 4),
            if r == 0 { "learn" } else { "review" },
        )
    };
    let answered =
        (env("SRS_BENCH_ANSWERS", 0) != 0).then(|| answers(&a, &deck, cards, reviews, event));
    let mut bucket = Bucket::default();
    for r in 0..reviews {
        for from in (0..cards).step_by(chunk) {
            let mut input = Vec::new();
            for c in from..(from + chunk).min(cards) {
                let note = note_id(c);
                if r == 0 {
                    let text = format!("例文{c}：日本語の文章をここに書く。読み方と意味。");
                    input.push(json!({"e": json!({"t": "entity", "x": {"id": note, "p": P, "k": "note", "d": {"createdAt": 1, "guid": note, "noteTypeId": "NT"}}}), "note": note}));
                    input
                        .push(json!({"e": edit("note", &note, "f/fa", json!(text)), "note": note}));
                    if tags {
                        // 整列表标签（旧形态的 `tags` 寄存器）：收段通道不折它，逐条投（channel.rs 的逐条阶段）。
                        let list =
                            json!([format!("deck{}", c % 40), "fushi", format!("lv{}", c % 7)]);
                        input.push(json!({"e": edit("note", &note, "tags", list), "note": note}));
                    }
                }
                let mut e = event(c, r);
                match &answered {
                    Some(res) => {
                        e["x"]["res"] = res[c][r].clone();
                        input.push(json!({"e": e, "note": note, "intent": "answer"}));
                    }
                    None => input.push(json!({"e": e, "note": note})),
                }
            }
            let out = a
                .core
                .sync2_apply_local(
                    P,
                    T0 + r as i64 * DAY + from as i64,
                    &Value::Array(input).to_string(),
                )
                .unwrap();
            if answered.is_some() {
                // 作者结果就是重放结果：本机重放一条都不改写。
                let out: Value = serde_json::from_str(&out).unwrap();
                assert_eq!(
                    out["replayed"],
                    json!([]),
                    "authored results must replay unchanged"
                );
            }
            a.upload_all(&mut bucket, "loc");
        }
    }
    a.sync(&mut bucket, "loc", now);
    if let Ok(out) = std::env::var("SRS_BENCH_OUT") {
        // 把位置上的文件按 `<out>/<profile>/v3/<路径>` 落盘后结束：同一份合成数据再交给冷启动探针
        // （bootstrap_probe.rs，`SRS_BENCH_DIR=<out>/<profile>/v3`）与 Dart 端到端基准
        // （`srs_sync2_ingest_bench_test.dart`，`FUSHI_SRS_INGEST_BENCH_DIR` 同一路径）收。
        let root = std::path::Path::new(&out).join(P).join("v3");
        let current = current_segments(bucket.0.keys().map(String::as_str));
        let mut written = 0usize;
        for (path, bytes) in &bucket.0 {
            if path.contains("/seg-") && !current.contains(path.as_str()) {
                continue;
            }
            written += 1;
            let file = root.join(path);
            std::fs::create_dir_all(file.parent().unwrap()).unwrap();
            std::fs::write(&file, bytes).unwrap();
        }
        println!(
            "INGEST_MEM wrote {written} of {} files to {} ({}ms)",
            bucket.0.len(),
            root.display(),
            t.elapsed().as_millis()
        );
        return;
    }
    let heads: Vec<Vec<u8>> = bucket
        .0
        .iter()
        .filter(|(k, _)| k.contains("/head-"))
        .map(|(_, v)| v.clone())
        .collect();
    let segs: Vec<Vec<u8>> = bucket
        .0
        .iter()
        .filter(|(k, _)| k.contains("/seg-"))
        .map(|(_, v)| v.clone())
        .collect();
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
    b.core
        .writer()
        .unwrap()
        .execute_batch("PRAGMA wal_autocheckpoint = 16384")
        .unwrap();
    let cmd = |mut req: Value, blobs: Vec<Vec<u8>>| -> Value {
        req["profile"] = json!(P);
        req["caches"] = json!({"defaultDeck": deck});
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
            let (mut n, mut applied, mut replayed, mut changed, mut cache) =
                (0usize, 0i64, 0usize, 0usize, 0usize);
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
        let mut calls = vec![(
            len(&r, "replayed"),
            len(&r["cache"], "cards") + len(&r["cache"], "notes"),
        )];
        while r["more"] == json!(true) {
            r = cmd(json!({"op": "replay_pending"}), vec![]);
            calls.push((
                len(&r, "replayed"),
                len(&r["cache"], "cards") + len(&r["cache"], "notes"),
            ));
        }
        calls
    });
    let max_replayed = calls.iter().map(|c| c.0).max().unwrap_or(0);
    let max_cache = calls.iter().map(|c| c.1).max().unwrap_or(0);
    let total_cache: usize = calls.iter().map(|c| c.1).sum();
    line(
        "finish",
        &m,
        &format!(
            "calls={} max_replayed/call={max_replayed} max_cache_rows/call={max_cache} cache_rows={total_cache}",
            calls.len()
        ),
    );
    let (_, m) = measure(|| cmd(json!({"op": "ingest_end"}), vec![]));
    line("end", &m, &format!("slices={slices}"));
    let cached = b.rows("SELECT COUNT(*) FROM srs_cards_cache");
    assert_eq!(
        cached[1][0],
        cards.to_string(),
        "every card got a cache row"
    );
    let logs = b.rows("SELECT COUNT(*) FROM srs_review_logs");
    let own = usize::from(env("SRS_BENCH_STUDIED", 0) != 0);
    assert_eq!(
        logs[1][0],
        (cards * reviews + own).to_string(),
        "every review log landed"
    );
}
