//! BUG-4005 实测（默认不跑）：在一份真实 srs.db 的**副本**上跑重复流收敛作业，量作业本身、新设备首次同步要拉的字节、
//! 新设备收段（生产的分批会话，走收段通道）的峰值内存与耗时，收敛前后各一次；末尾比新设备与作者的状态摘要。
//!
//! `SRS_DEDUP_DB=<srs.db> cargo test --release --lib dedup_measure -- --ignored --nocapture --test-threads=1`
//!
//! 原库只读（连同 `-wal` / `-shm` 复制进临时目录再开）。别的设备的私钥不在库里，所以「位置上的段与 head」按库里每台
//! 设备的操作原样重新打包、用本机密钥签（head 里的公钥同样换成本机的，新设备首见即信）：字节数与签名长度与真实的段
//! 相同，切段按约 12 MiB 原文一段（生产按压缩后约 4 MB 切，段数不同、总字节基本相同）。

use std::path::{Path, PathBuf};

use rusqlite::params;
use serde_json::{Value, json};

use super::mem_bench::{Mem, measure};
use super::tests::tempdir;
use crate::store::SrsCore;
use crate::sync2::id::Id;
use crate::sync2::segment::{self, CHAIN_ZERO, Head};
use crate::sync2::vv::{OpId, Vv};

const CUT_BYTES: usize = 12 << 20;

fn copy_db(src: &Path, dir: &Path) -> PathBuf {
    let dst = dir.join("srs.db");
    std::fs::copy(src, &dst).unwrap();
    for ext in ["-wal", "-shm"] {
        let s = PathBuf::from(format!("{}{ext}", src.display()));
        if s.exists() {
            std::fs::copy(&s, PathBuf::from(format!("{}{ext}", dst.display()))).unwrap();
        }
    }
    dst
}

fn mib(n: u64) -> f64 {
    n as f64 / (1024.0 * 1024.0)
}

fn show(what: &str, m: &Mem) {
    println!(
        "DEDUP_MEASURE {what}: rust_peak={:.1}MiB sqlite_peak={:.1}MiB kept={:.1}/{:.1}MiB {}ms",
        m.rust_peak, m.sqlite_peak, m.rust_kept, m.sqlite_kept, m.ms
    );
}

/// 位置上的全部 head 与段（按库里每台设备的操作重新打包，见文件头），以及每台设备的段字节数。
fn world(core: &SrsCore, profile: &str) -> (Vec<Vec<u8>>, Vec<Vec<u8>>, Vec<(String, u64, u64)>) {
    let w = core.writer().unwrap();
    let local = super::Local::load(&w, profile).unwrap().unwrap();
    let devices: Vec<(Vec<u8>, i64)> = w
        .prepare("SELECT device, MAX(seq) FROM sync2_ops WHERE profile_uid = srs_id(?1) GROUP BY device ORDER BY device")
        .unwrap()
        .query_map([profile], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .map(Result::unwrap)
        .collect();
    let (mut heads, mut segs, mut sizes) = (Vec::new(), Vec::new(), Vec::new());
    for (d, max) in devices {
        let device = Id(d.as_slice().try_into().unwrap());
        let mut prev = CHAIN_ZERO;
        let mut list = Vec::new();
        let (mut bytes, mut skeletons) = (0u64, 0u64);
        let mut ops = Vec::new();
        let mut raw = 0usize;
        let mut flush = |ops: &mut Vec<crate::sync2::op::Op>,
                         prev: &mut segment::Chain,
                         list: &mut Vec<(u64, u64, String)>,
                         bytes: &mut u64| {
            if ops.is_empty() {
                return;
            }
            let (h, b) = segment::pack(local.collection, ops, *prev, &local.key, None).unwrap();
            *bytes += b.len() as u64;
            list.push((h.first, h.last, segment::chain_tag(&h.last_chain)));
            *prev = h.last_chain;
            segs.push(b);
            ops.clear();
        };
        for seq in 1..=max as u64 {
            let Some(o) = super::load_op(&w, profile, &OpId { device, seq }).unwrap() else {
                panic!("hole at {}:{seq}", device.text())
            };
            skeletons += u64::from(o.purged);
            raw += o.payload.len() + 64;
            ops.push(o);
            if raw >= CUT_BYTES {
                flush(&mut ops, &mut prev, &mut list, &mut bytes);
                raw = 0;
            }
        }
        flush(&mut ops, &mut prev, &mut list, &mut bytes);
        let head = Head {
            gen: 1,
            protocol: segment::PROTOCOL,
            min_reader: segment::MIN_READER,
            collection: local.collection,
            device,
            public: local.key.public(),
            seq: max as u64,
            chain: prev,
            segments: list,
            ack: Vv::new(),
            digest: String::new(),
            at_ms: 0,
            name: String::new(),
            ext: None,
        };
        heads.push(head.encode(&local.key));
        sizes.push((device.text(), bytes, skeletons));
    }
    (heads, segs, sizes)
}

fn cmd(core: &SrsCore, profile: &str, req: Value, blobs: Vec<Vec<u8>>) -> Value {
    let mut req = req;
    req["profile"] = json!(profile);
    req["caches"] = json!({"defaultDeck": super::config::default_deck_id(profile)});
    let (mut blobs, mut files) = (blobs, Vec::new());
    crate::store::ffi::sync2_dispatch(core, &req, &mut blobs, &mut files).unwrap()
}

/// 新设备经生产的分批会话收完（约 8 MiB 一批，默认时间片）。返回它的状态摘要。
fn fresh_ingest(dir: &Path, profile: &str, heads: &[Vec<u8>], segs: &[Vec<u8>]) -> (String, Mem) {
    let core = SrsCore::open(&dir.join("fresh.db")).unwrap();
    core.sync2_identity(profile, 0).unwrap();
    let (_, m) = measure(|| {
        cmd(&core, profile, json!({"op": "plan"}), heads.to_vec());
        cmd(&core, profile, json!({"op": "ingest_begin"}), vec![]);
        let mut batch: Vec<Vec<u8>> = Vec::new();
        let mut size = 0;
        let mut send = |batch: &mut Vec<Vec<u8>>| {
            cmd(
                &core,
                profile,
                json!({"op": "ingest_prepare"}),
                std::mem::take(batch),
            );
            while cmd(
                &core,
                profile,
                json!({"op": "ingest_commit", "now": 1}),
                vec![],
            )["more"]
                == json!(true)
            {}
        };
        for s in segs {
            size += s.len();
            batch.push(s.clone());
            if size >= 8 << 20 {
                send(&mut batch);
                size = 0;
            }
        }
        if !batch.is_empty() {
            send(&mut batch);
        }
        let mut r = cmd(
            &core,
            profile,
            json!({"op": "ingest_finish", "now": 1}),
            vec![],
        );
        while r["more"] == json!(true) {
            r = cmd(
                &core,
                profile,
                json!({"op": "replay_pending", "now": 1}),
                vec![],
            );
        }
    });
    let d = core.sync2_digest(profile).unwrap()["digest"]
        .as_str()
        .unwrap()
        .to_owned();
    drop(core);
    for ext in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(dir.join(format!("fresh.db{ext}")));
    }
    (d, m)
}

#[test]
#[ignore]
fn dedup_measure_real_db() {
    let src = PathBuf::from(std::env::var("SRS_DEDUP_DB").expect("SRS_DEDUP_DB"));
    let dir = tempdir::new("dedup-measure");
    let path = copy_db(&src, &dir.0);
    let core = SrsCore::open(&path).unwrap();
    let profile: String = core
        .writer()
        .unwrap()
        .query_row("SELECT srs_idt(profile_uid) FROM sync2_self", [], |r| {
            r.get(0)
        })
        .unwrap();
    let job = core
        .writer()
        .unwrap()
        .query_row("SELECT COUNT(*) FROM sync2_dedup", [], |r| {
            r.get::<_, i64>(0)
        })
        .unwrap();
    println!("DEDUP_MEASURE profile {profile}: job rows after v24 upgrade = {job}");

    let (heads, segs, sizes) = world(&core, &profile);
    let total: u64 = sizes.iter().map(|s| s.1).sum();
    for (d, b, k) in &sizes {
        println!(
            "DEDUP_MEASURE before {d}: {:.1} MiB, {k} skeletons",
            mib(*b)
        );
    }
    println!(
        "DEDUP_MEASURE before: new device downloads {:.1} MiB in {} segments",
        mib(total),
        segs.len()
    );
    let skip_fresh = std::env::var("SRS_DEDUP_SKIP_FRESH").is_ok();
    let before = (!skip_fresh).then(|| fresh_ingest(&dir.0, &profile, &heads, &segs));
    if let Some((_, m)) = &before {
        show("fresh ingest before", m);
    }
    drop((heads, segs));

    let mut steps = 0;
    let mut emitted = 0;
    let (_, m) = measure(|| {
        loop {
            let r = core.sync2_dedup(&profile, 1).unwrap();
            steps += 1;
            emitted += r["emitted"].as_u64().unwrap_or(0);
            if r["done"] == json!(true) {
                break;
            }
        }
    });
    show(&format!("dedup job ({steps} steps, {emitted} pairs)"), &m);
    let w = core.writer().unwrap();
    for (k, n) in w
        .prepare("SELECT kind, COUNT(*) FROM sync2_ops WHERE profile_uid = srs_id(?1) AND purged = 1 AND length(payload) > 32 GROUP BY kind")
        .unwrap()
        .query_map([&profile], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?)))
        .unwrap()
        .map(Result::unwrap)
    {
        println!("DEDUP_MEASURE duplicate skeletons kind {k}: {n}");
    }
    let rows: i64 = w
        .query_row("SELECT COUNT(*) FROM srs_field_edits", params![], |r| {
            r.get(0)
        })
        .unwrap();
    let held: i64 = w
        .query_row("SELECT COUNT(*) FROM sync2_held", params![], |r| r.get(0))
        .unwrap();
    println!("DEDUP_MEASURE after: srs_field_edits rows = {rows}, held deletes = {held}");
    drop(w);
    let author = core.sync2_digest(&profile).unwrap()["digest"]
        .as_str()
        .unwrap()
        .to_owned();

    let (heads, segs, sizes) = world(&core, &profile);
    let after: u64 = sizes.iter().map(|s| s.1).sum();
    for (d, b, k) in &sizes {
        println!("DEDUP_MEASURE after {d}: {:.1} MiB, {k} skeletons", mib(*b));
    }
    println!(
        "DEDUP_MEASURE after: new device downloads {:.1} MiB in {} segments ({:+.1} MiB)",
        mib(after),
        segs.len(),
        mib(after) - mib(total)
    );
    if !skip_fresh {
        let (d, m) = fresh_ingest(&dir.0, &profile, &heads, &segs);
        show("fresh ingest after", &m);
        println!(
            "DEDUP_MEASURE digest: author {author}, new device {d}, equal = {}",
            author == d
        );
        if let Some((b, _)) = before {
            println!("DEDUP_MEASURE digest before dedup (new device): {b}");
        }
    }
}
