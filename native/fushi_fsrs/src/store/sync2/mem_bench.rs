//! 同步 v2 各条大数据路径的峰值内存（默认不跑）。每一步单独量：步前把峰值归零，量这一步里 Rust 堆与 SQLite 堆
//! 各自比步前多出的最高值。输入字节（段、导出包）在步前就在内存里，不计入；产出（导出包）计入。
//! 同一场景按两种数据量各跑一次，看峰值是否随数据量涨。
//!
//! `cargo test --release --lib bench_memory -- --ignored --nocapture --test-threads=1`
//! （`SRS_MEM_MB=32,128` 改数据量，单位是笔记正文 MiB）

use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering};

use serde_json::{json, Value};

use super::tests::{deck_entity, edit, Bucket, Device, P};

struct Counting;

static CUR: AtomicUsize = AtomicUsize::new(0);
static PEAK: AtomicUsize = AtomicUsize::new(0);

fn grew(n: usize) {
    let now = CUR.fetch_add(n, Ordering::Relaxed) + n;
    PEAK.fetch_max(now, Ordering::Relaxed);
}

// SAFETY: 只转发给系统分配器，另外记账。
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        let p = System.alloc(l);
        if !p.is_null() {
            grew(l.size());
        }
        p
    }
    unsafe fn alloc_zeroed(&self, l: Layout) -> *mut u8 {
        let p = System.alloc_zeroed(l);
        if !p.is_null() {
            grew(l.size());
        }
        p
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        System.dealloc(p, l);
        CUR.fetch_sub(l.size(), Ordering::Relaxed);
    }
    unsafe fn realloc(&self, p: *mut u8, l: Layout, new: usize) -> *mut u8 {
        let q = System.realloc(p, l, new);
        if !q.is_null() {
            if new >= l.size() {
                grew(new - l.size());
            } else {
                CUR.fetch_sub(l.size() - new, Ordering::Relaxed);
            }
        }
        q
    }
}

#[global_allocator]
static ALLOC: Counting = Counting;

const T0: i64 = 1_700_000_000_000;
const DAY: i64 = 86_400_000;
const MIB: f64 = 1024.0 * 1024.0;

/// 一步的测量：Rust / SQLite 堆峰值比步前多出的最高值、步后仍比步前多占的（常驻），耗时。
struct Mem {
    rust_peak: f64,
    sqlite_peak: f64,
    rust_kept: f64,
    sqlite_kept: f64,
    ms: u128,
}

fn measure<T>(f: impl FnOnce() -> T) -> (T, Mem) {
    let base = CUR.load(Ordering::Relaxed);
    PEAK.store(base, Ordering::Relaxed);
    // SAFETY: 读 / 复位 SQLite 全局内存统计量。
    let sq0 = unsafe {
        rusqlite::ffi::sqlite3_memory_highwater(1);
        rusqlite::ffi::sqlite3_memory_used()
    };
    let t = std::time::Instant::now();
    let out = f();
    let ms = t.elapsed().as_millis();
    let (sq_peak, sq_now) =
        unsafe { (rusqlite::ffi::sqlite3_memory_highwater(0), rusqlite::ffi::sqlite3_memory_used()) };
    let now = CUR.load(Ordering::Relaxed);
    let m = Mem {
        rust_peak: PEAK.load(Ordering::Relaxed).saturating_sub(base) as f64 / MIB,
        sqlite_peak: (sq_peak - sq0) as f64 / MIB,
        rust_kept: (now as f64 - base as f64) / MIB,
        sqlite_kept: (sq_now - sq0) as f64 / MIB,
        ms,
    };
    (out, m)
}

fn report(case: &str, mb: usize, m: Mem) {
    println!(
        "MEM_BENCH {case:<28} data={mb:>4}MiB  rust_peak={:>6.1}MiB kept={:>5.1}  sqlite_peak={:>5.1}MiB kept={:>5.1}  {}ms",
        m.rust_peak, m.rust_kept, m.sqlite_peak, m.sqlite_kept, m.ms
    );
}

/// 约 `mb` MiB 正文的笔记，分批写进设备。
fn write_notes(d: &Device, tag: &str, mb: usize, at: i64) {
    let filler = "日本語の例文。".repeat(1000); // 21 KiB
    let ops = mb * 1024 * 1024 / filler.len();
    let mut i = 0;
    let mut batch = 0;
    while i < ops {
        let events: Vec<Value> = (i..(i + 250).min(ops))
            .map(|k| edit("note", &format!("{tag}{k}"), "f/s", json!(format!("{filler}{k}"))))
            .collect();
        i += events.len();
        d.apply(at + batch, events);
        batch += 1;
    }
}

fn heads(bucket: &Bucket) -> Vec<Vec<u8>> {
    bucket.0.iter().filter(|(k, _)| k.contains("/head-")).map(|(_, v)| v.clone()).collect()
}

fn device_text(d: &Device) -> String {
    let w = d.core.writer().unwrap();
    super::Local::load(&w, P).unwrap().unwrap().device.text()
}

fn segments_of(bucket: &Bucket, dev: &str) -> Vec<Vec<u8>> {
    bucket.0.iter().filter(|(k, _)| k.contains(dev) && k.contains("/seg-")).map(|(_, v)| v.clone()).collect()
}

fn run(mb: usize) {
    use crate::sync2::segment::{self, CHAIN_ZERO};
    let now = T0 + 9 * DAY;

    // A 写 mb，B 收下后接着写 mb（B 的操作因果上依赖 A 的）。
    let a = Device::new("mem-a");
    let b = Device::new("mem-b");
    let deck = super::config::default_deck_id(P);
    a.apply(T0, vec![deck_entity(&deck)]);
    write_notes(&a, "A", mb, T0 + 1);
    let mut bucket = Bucket::default();
    a.sync(&mut bucket, "loc", T0 + DAY);
    b.sync(&mut bucket, "loc", T0 + DAY);
    write_notes(&b, "B", mb, T0 + 2 * DAY);
    b.sync(&mut bucket, "loc", T0 + 3 * DAY);
    let (a_dev, b_dev) = (device_text(&a), device_text(&b));

    // 1. 新设备一次收齐两台设备的全部段。
    let all: Vec<Vec<u8>> = bucket.0.iter().filter(|(k, _)| k.contains("/seg-")).map(|(_, v)| v.clone()).collect();
    let c = Device::new("mem-c");
    c.core.sync2_identity(P, now).unwrap();
    c.core.sync2_plan(P, &heads(&bucket)).unwrap();
    let (out, m) = measure(|| c.core.sync2_ingest(P, &all, None, now).unwrap());
    let out: Value = serde_json::from_str(&out).unwrap();
    assert_eq!(out["pending"], json!(0), "{out}");
    report("ingest all segments", 2 * mb, m);
    drop(c);

    // 2. 先只收 B（全部要等 A），再收 A。
    let d = Device::new("mem-d");
    d.core.sync2_identity(P, now).unwrap();
    d.core.sync2_plan(P, &heads(&bucket)).unwrap();
    let (b_files, a_files) = (segments_of(&bucket, &b_dev), segments_of(&bucket, &a_dev));
    let (out, m) = measure(|| d.core.sync2_ingest(P, &b_files, None, now).unwrap());
    let out: Value = serde_json::from_str(&out).unwrap();
    assert!(out["pending"].as_i64().unwrap() > 0, "{out}");
    report("ingest B (all waiting on A)", mb, m);
    let (out, m) = measure(|| d.core.sync2_ingest(P, &a_files, None, now).unwrap());
    let out: Value = serde_json::from_str(&out).unwrap();
    assert_eq!(out["pending"], json!(0), "{out}");
    report("ingest A (releases B)", 2 * mb, m);
    drop(d);

    // 3. 旧版本切出的一整个超大段（A 的全部操作并成一段）。
    let (collection, signer, public) = {
        let w = a.core.writer().unwrap();
        let local = super::Local::load(&w, P).unwrap().unwrap();
        let public = local.key.public();
        (local.collection, local.key, public)
    };
    let mut ops = Vec::new();
    for f in segments_of(&bucket, &a_dev) {
        ops.extend(segment::open(&f, &public, None).unwrap().ops);
    }
    let (_, big) = segment::pack(collection, &ops, CHAIN_ZERO, &signer, None).unwrap();
    drop(ops);
    let e = Device::new("mem-e");
    e.core.sync2_identity(P, now).unwrap();
    e.core.sync2_plan(P, &heads(&bucket)).unwrap();
    let big = vec![big];
    let (out, m) = measure(|| e.core.sync2_ingest(P, &big, None, now).unwrap());
    let out: Value = serde_json::from_str(&out).unwrap();
    assert_eq!(out["errors"], json!([]), "{out}");
    report("ingest one oversized segment", mb, m);
    drop(e);
    drop(big);

    // 4. .fushisrs 导出（B 有两台设备的全部操作）与导入到新设备。
    let (pkg, m) = measure(|| b.core.sync2_export(P).unwrap());
    report(".fushisrs export", 2 * mb, m);
    let f = Device::new("mem-f");
    f.core.sync2_identity(P, now).unwrap();
    let (out, m) = measure(|| f.core.sync2_import(P, &pkg, now).unwrap());
    let out: Value = serde_json::from_str(&out).unwrap();
    assert_eq!(out["pending"], json!(0), "{out}");
    report(".fushisrs import", 2 * mb, m);
}

#[test]
#[ignore]
fn bench_memory() {
    let sizes: Vec<usize> = std::env::var("SRS_MEM_MB")
        .ok()
        .map(|v| v.split(',').filter_map(|s| s.trim().parse().ok()).collect())
        .unwrap_or_else(|| vec![32, 128]);
    for mb in sizes {
        run(mb);
    }
}

/// 写连接上的整批读命令（缓存重建、全量重放）的耗时与 SQLite 峰值：页缓存大小要看它们。
/// `SRS_BENCH_CARDS=20000 cargo test --release --lib bench_writer_reads -- --ignored --nocapture --test-threads=1`
#[test]
#[ignore]
fn bench_writer_reads() {
    use super::tests::review;
    let cards: i64 = std::env::var("SRS_BENCH_CARDS").ok().and_then(|v| v.parse().ok()).unwrap_or(5000);
    let a = Device::new("mem-reads");
    let deck = super::config::default_deck_id(P);
    a.apply(T0, vec![deck_entity(&deck), edit("deck", &deck, "name", json!("Default"))]);
    for chunk in 0..(cards + 99) / 100 {
        let mut input = Vec::new();
        for c in chunk * 100..((chunk + 1) * 100).min(cards) {
            input.push(json!({"e": edit("note", &format!("N{c}"), "f/s", json!(format!("例文{c}"))), "note": format!("N{c}")}));
            for r in 0..20 {
                let at = T0 + r * DAY + c;
                let e = review(&format!("r{c}-{r}"), &format!("C{c}"), at, 3, if r == 0 { "learn" } else { "review" });
                input.push(json!({"e": e, "note": format!("N{c}")}));
            }
        }
        a.core.sync2_apply_local(P, T0 + chunk, &Value::Array(input).to_string()).unwrap();
    }
    let cfg = crate::store::caches::CacheConfig::parse(&json!({"defaultDeck": deck})).unwrap();
    for round in 0..3 {
        let w = a.core.writer().unwrap();
        let (_, m) = measure(|| super::in_savepoint(&w, |c| crate::store::caches::rebuild(c, P, &cfg)).unwrap());
        drop(w);
        report(&format!("cache rebuild #{round}"), cards as usize, m);
        let (_, m) = measure(|| a.core.sync2_replay_all(P).unwrap());
        report(&format!("replay_all #{round}"), cards as usize, m);
    }
}
