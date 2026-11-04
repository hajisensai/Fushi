//! 存量重复流探针（默认不跑）：真实库里两条操作流字节相同的日志 / 实体操作有多少、谁先谁后、因果关系如何。
//! `SRS_DEDUP_DB=<srs.db 只读副本> cargo test --release --lib dedup_probe -- --ignored --nocapture`

use std::collections::HashMap;
use std::time::Instant;

use rusqlite::{Connection, OpenFlags};

use crate::sync2::id::Id;
use crate::sync2::op::Body;

#[test]
#[ignore]
fn dedup_probe_real_db() {
    let path = std::env::var("SRS_DEDUP_DB").expect("SRS_DEDUP_DB");
    let uri = format!("file:///{}?immutable=1", path.replace('\\', "/"));
    let c = Connection::open_with_flags(
        &uri,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
    )
    .unwrap();
    crate::store::configure(&c).unwrap();
    let (profile, me): (String, Vec<u8>) = c
        .query_row(
            "SELECT srs_idt(profile_uid), device FROM sync2_self",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    let me = Id(me.try_into().unwrap());
    println!("profile={profile} me={}", me.text());
    let t = Instant::now();
    // (kind, payload) → 各设备的 (seq, wall)
    let mut by: HashMap<(u16, Vec<u8>), Vec<(Id, u64, i64)>> = HashMap::new();
    let mut st = c
        .prepare("SELECT device, seq, wall, kind, payload, purged, sc, sc_at, pz FROM sync2_ops WHERE profile_uid = srs_id(?1) AND kind IN (1, 3)")
        .unwrap();
    let mut q = st.query([&profile]).unwrap();
    let mut n = 0u64;
    while let Some(r) = q.next().unwrap() {
        let dev: Vec<u8> = r.get(0).unwrap();
        let seq: i64 = r.get(1).unwrap();
        let wall: i64 = r.get(2).unwrap();
        let kind: i64 = r.get(3).unwrap();
        let p: Vec<u8> = r.get(4).unwrap();
        let purged: i64 = r.get(5).unwrap();
        assert_eq!(purged, 0);
        let p = super::snapshots::unpack_payload(
            &c,
            p,
            r.get(6).unwrap(),
            r.get(7).unwrap(),
            r.get(8).unwrap(),
        )
        .unwrap();
        by.entry((kind as u16, p)).or_default().push((
            Id(dev.try_into().unwrap()),
            seq as u64,
            wall,
        ));
        n += 1;
    }
    println!("scanned {n} ops in {:?}", t.elapsed());
    let mut groups: HashMap<String, (u64, u64)> = HashMap::new();
    let (mut legacy, mut no_legacy, mut me_later, mut me_earlier, mut same_wall) =
        (0u64, 0u64, 0u64, 0u64, 0u64);
    let mut dup_bytes = 0u64;
    for ((kind, p), v) in &by {
        let mut devs: Vec<String> = v.iter().map(|x| x.0.text()[..8].to_owned()).collect();
        devs.sort();
        let e = groups
            .entry(format!("k{kind} {}", devs.join(",")))
            .or_default();
        e.0 += 1;
        e.1 += p.len() as u64;
        if v.len() > 1 {
            dup_bytes += p.len() as u64;
            if *kind == 3 {
                match Body::decode(3, p).unwrap() {
                    Body::Log(l) if l.legacy_hlc.is_some() => legacy += 1,
                    _ => no_legacy += 1,
                }
            }
            let mine = v.iter().find(|x| x.0 == me);
            let other = v.iter().find(|x| x.0 != me);
            if let (Some(m), Some(o)) = (mine, other) {
                match m.2.cmp(&o.2) {
                    std::cmp::Ordering::Greater => me_later += 1,
                    std::cmp::Ordering::Less => me_earlier += 1,
                    std::cmp::Ordering::Equal => same_wall += 1,
                }
            }
        }
    }
    let mut gs: Vec<_> = groups.into_iter().collect();
    gs.sort();
    for (k, (cnt, bytes)) in gs {
        println!("{k}: {cnt} payloads, {bytes} bytes");
    }

    // ---- 第二部分：判据前提与真实字节量
    let d = by
        .values()
        .flat_map(|v| v.iter().map(|x| x.0))
        .filter(|x| *x != me)
        .min()
        .unwrap();
    // 本机流里有更小设备副本的操作 → 该副本的 seq
    let mut strip: HashMap<u64, (Id, u64)> = HashMap::new();
    for v in by.values() {
        let kept = v.iter().filter(|x| x.0 < me).min_by_key(|x| (x.0, x.1));
        if let Some(k) = kept {
            for x in v.iter().filter(|x| x.0 == me) {
                strip.insert(x.1, (k.0, k.1));
            }
        }
    }
    println!(
        "strip candidates={} (kept device min={})",
        strip.len(),
        d.text()
    );
    let local = super::Local::load(&c, &profile).unwrap().unwrap();
    let top = local.next_seq - 1;
    let last = super::load_op(
        &c,
        &profile,
        &crate::sync2::vv::OpId {
            device: me,
            seq: top,
        },
    )
    .unwrap()
    .unwrap();
    let max_k = strip.values().map(|k| k.1).max().unwrap();
    println!(
        "my top={top} last.deps[D]={} max kept seq={max_k}",
        last.deps.get(&d)
    );
    let (mut saw, mut not_saw) = (0u64, 0u64);
    for (s, k) in &strip {
        let op = super::load_op(
            &c,
            &profile,
            &crate::sync2::vv::OpId {
                device: me,
                seq: *s,
            },
        )
        .unwrap()
        .unwrap();
        if op.saw(&crate::sync2::vv::OpId {
            device: k.0,
            seq: k.1,
        }) {
            saw += 1
        } else {
            not_saw += 1
        }
    }
    println!("S saw K: {saw}, concurrent: {not_saw}");
    let mut st = c.prepare("SELECT device, ack, frozen, head_seq FROM sync2_devices WHERE profile_uid = srs_id(?1)").unwrap();
    let rows: Vec<(Vec<u8>, Option<Vec<u8>>, i64, i64)> = st
        .query_map([&profile], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
        })
        .unwrap()
        .map(Result::unwrap)
        .collect();
    for (dev, ack, frozen, hs) in rows {
        let ack = ack.map(|a| {
            crate::sync2::vv::Vv::read(&mut crate::sync2::codec::Reader::new(&a)).unwrap()
        });
        println!(
            "device {} frozen={frozen} head_seq={hs} ack[me]={:?} ack={:?}",
            Id(dev.try_into().unwrap()).text(),
            ack.as_ref().map(|a| a.get(&me)),
            ack.map(|a| a
                .0
                .iter()
                .map(|(k, v)| (k.text()[..8].to_owned(), *v))
                .collect::<Vec<_>>())
        );
    }
    let dels: i64 = c
        .query_row(
            "SELECT COUNT(*) FROM sync2_ent_ops WHERE what = 'deleted'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    println!("v2 deleted index rows={dels}");
    // 同一日志 ID 不同载荷
    let mut lid: HashMap<String, std::collections::HashSet<Vec<u8>>> = HashMap::new();
    for (k, _) in by.iter().filter(|(k, _)| k.0 == 3) {
        if let Ok(Body::Log(l)) = Body::decode(3, &k.1) {
            lid.entry(l.id.text())
                .or_default()
                .insert(blake3::hash(&k.1).as_bytes().to_vec());
        }
    }
    println!(
        "log ids with >1 distinct payload: {}",
        lid.values().filter(|v| v.len() > 1).count()
    );
    // 真实段字节量：本机当前切法，原样 vs 骨架化
    let segs: Vec<(i64, i64)> = c
        .prepare("SELECT first, last FROM sync2_segments WHERE profile_uid = srs_id(?1) AND device = ?2 ORDER BY first")
        .unwrap()
        .query_map(rusqlite::params![profile, me.0.to_vec()], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .map(Result::unwrap)
        .collect();
    let (mut before, mut after) = (0usize, 0usize);
    let t = Instant::now();
    for (a, b) in segs {
        let mut ops = Vec::new();
        for seq in a..=b {
            ops.push(
                super::load_op(
                    &c,
                    &profile,
                    &crate::sync2::vv::OpId {
                        device: me,
                        seq: seq as u64,
                    },
                )
                .unwrap()
                .unwrap(),
            );
        }
        let prev: Vec<u8> = if a == 1 {
            crate::sync2::segment::CHAIN_ZERO.to_vec()
        } else {
            c.query_row("SELECT chain FROM sync2_ops WHERE profile_uid = srs_id(?1) AND device = ?2 AND seq = ?3", rusqlite::params![profile, me.0.to_vec(), a - 1], |r| r.get(0)).unwrap()
        };
        let prev: [u8; 32] = prev.try_into().unwrap();
        let (_, full) =
            crate::sync2::segment::pack(local.collection, &ops, prev, &local.key, None).unwrap();
        let skel: Vec<_> = ops
            .iter()
            .map(|o| {
                if strip.contains_key(&o.id.seq) {
                    o.purge()
                } else {
                    o.clone()
                }
            })
            .collect();
        let (_, thin) =
            crate::sync2::segment::pack(local.collection, &skel, prev, &local.key, None).unwrap();
        before += full.len();
        after += thin.len();
    }
    println!(
        "own segments bytes before={before} after={after} ({:?})",
        t.elapsed()
    );
    println!(
        "dup payload bytes={dup_bytes} log legacy_hlc={legacy} no_legacy={no_legacy} me_later={me_later} me_earlier={me_earlier} same_wall={same_wall}"
    );
}
