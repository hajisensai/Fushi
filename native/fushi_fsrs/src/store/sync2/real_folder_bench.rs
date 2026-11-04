//! 用一个真实的同步文件夹（未加密）量新设备收齐的耗时，按阶段分（默认不跑）。
//! `SRS_BENCH_DIR=<…/fushi-srs/<profile>/v3> cargo test --release --lib bench_real_folder -- --ignored --nocapture`
//! 走生产的分发器：段按约 8 MB 一批 `ingest_prepare`，每批 `ingest_commit` 按默认时间片投完，`ingest_finish`
//! 加 `replay_pending` 收尾；另跑一遍「一次收完 + 全量重建缓存」作下限参照。
//!
//! 开关：`SRS_BENCH_ONLY=sliced|oneshot` 只跑一种；`SRS_BENCH_SEGS=n` 投到第 n 段为止；`SRS_BENCH_WAL_AUTOCKPT=n`
//! 设写连接的自动 checkpoint 阈值（生产收段期间 16384，Dart `bulkWrites`）；`SRS_BENCH_CKPT_EVERY=n` 每 n 片在另开的
//! 连接上并回一次 WAL（生产按 `SrsWalCheckpointPacer` 定，约每 3 片）。单次计时受本机负载影响能差三成，比较要交替多跑。

use std::path::{Path, PathBuf};
use std::time::Instant;

use serde_json::{json, Value};

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

fn load(dir: &Path) -> (Vec<Vec<u8>>, Vec<Vec<u8>>) {
    let mut all = Vec::new();
    files(&dir.join("devices"), &mut all);
    all.sort();
    let name = |p: &PathBuf| p.file_name().unwrap().to_string_lossy().into_owned();
    let heads = all.iter().filter(|p| crate::sync2::segment::parse_head_file_name(&name(p)).is_some()).map(|p| std::fs::read(p).unwrap()).collect();
    let segs = all.iter().filter(|p| name(p).starts_with("seg-")).map(|p| std::fs::read(p).unwrap()).collect();
    (heads, segs)
}

fn ms(t: Instant) -> u128 {
    t.elapsed().as_millis()
}

#[test]
#[ignore]
fn bench_real_folder() {
    let dir = PathBuf::from(std::env::var("SRS_BENCH_DIR").expect("SRS_BENCH_DIR"));
    let profile = dir.parent().unwrap().file_name().unwrap().to_string_lossy().into_owned();
    let (heads, segs) = load(&dir);
    let bytes: usize = segs.iter().map(Vec::len).sum();
    println!("BENCH profile={profile} heads={} segs={} bytes={}MB", heads.len(), segs.len(), bytes >> 20);
    let deck = super::config::default_deck_id(&profile);
    let now = 1_800_000_000_000i64;
    let only = std::env::var("SRS_BENCH_ONLY").unwrap_or_default();

    if only.is_empty() || only == "sliced" {
        let tmp = super::tests::tempdir::new("bench-real");
        let core = crate::store::SrsCore::open(&tmp.0.join("srs.db")).unwrap();
        let cmd = |mut req: Value, blobs: Vec<Vec<u8>>| -> Value {
            req["profile"] = json!(profile);
            req["caches"] = json!({"defaultDeck": deck});
            let (mut blobs, mut files) = (blobs, Vec::new());
            crate::store::ffi::sync2_dispatch(&core, &req, &mut blobs, &mut files).unwrap()
        };
        if let Ok(n) = std::env::var("SRS_BENCH_WAL_AUTOCKPT") {
            core.writer().unwrap().execute_batch(&format!("PRAGMA wal_autocheckpoint = {n}")).unwrap();
        }
        let max_segs: usize = std::env::var("SRS_BENCH_SEGS").ok().and_then(|v| v.parse().ok()).unwrap_or(usize::MAX);
        let t0 = Instant::now();
        cmd(json!({"op": "identity", "now": now}), vec![]);
        cmd(json!({"op": "plan"}), heads.clone());
        cmd(json!({"op": "ingest_begin"}), vec![]);
        let (mut prep, mut commit, mut slices) = (0u128, 0u128, 0usize);
        let ckpt_every: usize = std::env::var("SRS_BENCH_CKPT_EVERY").ok().and_then(|v| v.parse().ok()).unwrap_or(0);
        let (mut ckpt_ms, mut ckpt_n, mut ckpt_log_max, mut ckpt_log_sum) = (0u128, 0usize, 0i64, 0i64);
        let mut batch: Vec<Vec<u8>> = Vec::new();
        let mut i = 0;
        while i < segs.len() {
            batch.clear();
            let mut b = 0;
            while i < segs.len() && (batch.is_empty() || b + segs[i].len() <= 8 << 20) {
                b += segs[i].len();
                batch.push(segs[i].clone());
                i += 1;
            }
            let t = Instant::now();
            cmd(json!({"op": "ingest_prepare"}), batch.clone());
            prep += ms(t);
            let t = Instant::now();
            loop {
                slices += 1;
                let r = cmd(json!({"op": "ingest_commit", "now": now}), vec![]);
                if r["more"] != json!(true) {
                    break;
                }
                // 生产（Dart `sync2IngestBatch`）按 `SrsWalCheckpointPacer` 定的节奏在另开的连接上并回 WAL；
                // `SRS_BENCH_CKPT_EVERY=n` 改成固定每 n 片一次，用来对照。
                if ckpt_every > 0 && slices % ckpt_every == 0 {
                    let t = Instant::now();
                    let v = core.wal_checkpoint().unwrap();
                    ckpt_ms += ms(t);
                    ckpt_n += 1;
                    ckpt_log_max = ckpt_log_max.max(v["log"].as_i64().unwrap_or(0));
                    ckpt_log_sum += v["log"].as_i64().unwrap_or(0);
                }
            }
            commit += ms(t);
            println!("BENCH batch upto seg {i}: prepare {prep}ms commit {commit}ms slices {slices} ckpt {ckpt_n}x {ckpt_ms}ms walframes avg {} max {ckpt_log_max}", ckpt_log_sum / ckpt_n.max(1) as i64);
            if i >= max_segs {
                return;
            }
        }
        let t = Instant::now();
        let mut r = cmd(json!({"op": "ingest_finish", "now": now}), vec![]);
        let mut calls = 1;
        while r["more"] == json!(true) {
            r = cmd(json!({"op": "replay_pending"}), vec![]);
            calls += 1;
        }
        let finish = ms(t);
        println!(
            "BENCH sliced total {}ms = prepare {prep} + commit {commit} ({slices} slices) + finish {finish} ({calls} calls); pending={}",
            ms(t0),
            r["pending"]
        );
    }

    if only.is_empty() || only == "oneshot" {
        let tmp = super::tests::tempdir::new("bench-real-one");
        let core = crate::store::SrsCore::open(&tmp.0.join("srs.db")).unwrap();
        let t0 = Instant::now();
        core.sync2_identity(&profile, now).unwrap();
        core.sync2_plan(&profile, &heads).unwrap();
        let t = Instant::now();
        core.sync2_ingest(&profile, &segs, None, now).unwrap();
        let ingest = ms(t);
        let t = Instant::now();
        let req = json!({"op": "rebuild_caches", "profile": profile, "caches": {"defaultDeck": deck}});
        let (mut b, mut f) = (Vec::new(), Vec::new());
        crate::store::ffi::sync2_dispatch(&core, &req, &mut b, &mut f).unwrap();
        println!("BENCH oneshot total {}ms = ingest {ingest} + rebuild_caches {}", ms(t0), ms(t));
    }
}
