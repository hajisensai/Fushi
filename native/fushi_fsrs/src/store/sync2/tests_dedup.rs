//! BUG-4005：存量重复流收敛（dedup.rs）。两台设备各自迁移了同一个旧库（一台的旧写入者被 profile 合并改过名、几条
//! 旧记录的实体 ID 被重映射过），作者（ID 较大的那台）发 `Dedup`、换骨架、同名重写；各设备（老设备、之后才来的新设备
//! ——逐条投递与收段通道两路）最终投影与摘要相同，并存的修改记录行没了，删除扣留只看原件，投递顺序怎样都一样。

use proptest::prelude::*;
use serde_json::{Value, json};

use super::tests::{Bucket, Device, P, edit};

const T0: i64 = 1_700_000_000_000;
const DAY: i64 = 86_400_000;
const NOW: i64 = T0 + 10 * DAY;

fn note_id(n: u64) -> String {
    format!("0193a1b2-0000-7000-8000-{n:012x}")
}

fn card_of(n: u64) -> String {
    crate::registers::card_id(&note_id(n), "t1", 0).unwrap()
}

fn exec(d: &Device, sql: &str, p: impl rusqlite::Params) {
    d.core.writer().unwrap().execute(sql, p).unwrap();
}

fn count(d: &Device, sql: &str) -> i64 {
    d.rows(sql)[1][0].parse().unwrap()
}

/// 旧库里一条笔记字段的旧修改记录。
fn legacy_edit(d: &Device, writer: &str, s: i64, n: u64, key: &str, v: Value, vv: Value) {
    let id = crate::registers::edit_id(writer, s);
    let note = note_id(n);
    let j = json!({"ctx": {"vv": vv}, "e": note, "f": key, "hlc": format!("{}:0:{writer}", T0 - 1000 + s), "id": id, "k": "note",
                   "p": P, "s": s, "ts": "wall", "v": v, "w": writer})
    .to_string();
    exec(
        d,
        "INSERT INTO srs_field_edits (id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, jslim) \
         VALUES (srs_id(?1), srs_id(?2), 'note', srs_id(?3), ?4, ?5, ?6, ?7)",
        rusqlite::params![id, P, note, key, writer, s, j],
    );
}

/// 旧库里一条复习日志。
fn legacy_log(d: &Device, id: &str, n: u64, at: i64) {
    let x = json!({"id": id, "p": P, "card": card_of(n), "kind": "review", "rating": 3, "hlc": format!("{at}:0:old1"), "at": at,
                   "ts": "anchored", "origin": "fushi", "rtype": "review", "utcOff": 0, "rollover": 4, "fv": 1,
                   "res": {"queue": "review", "dueDay": 19_700, "ivl": 3, "step": 0, "reps": 2, "lapses": 0, "scheduler": "fushi"}});
    exec(
        d,
        "INSERT INTO srs_review_logs (id, profile_uid, card_id, kind, rating, occurred_at, review_type, origin, jslim) \
         VALUES (srs_id(?1), srs_id(?2), srs_id(?3), 'review', 3, ?4, 'review', 'fushi', ?5)",
        rusqlite::params![id, P, card_of(n), at, x.to_string()],
    );
}

const LOGS: [&str; 3] = [
    "0193a1b2-0000-7000-8000-0000000010a1",
    "0193a1b2-0000-7000-8000-0000000010a2",
    "0193a1b2-0000-7000-8000-0000000010a3",
];

/// 同一个旧库（已按旧协议裁剪过：没有被同一寄存器里别的记录支配的行）：[w] = 这台设备看到的旧写入者名，上下文是
/// 「这个写入者此前的全部」去掉同一寄存器里的（否则那些行早被裁掉）。[remapped] = 合并时 ID 重映射过的两条（作者
/// 一侧）落在哪些笔记上。
fn legacy_library(d: &Device, w: &str, remapped: (u64, u64)) {
    legacy_edit(d, w, 1, 1, "f/a", json!("a1"), json!({}));
    legacy_edit(d, w, 2, 1, "f/b", json!("b1"), json!({w: 1}));
    legacy_edit(d, w, 3, 2, "f/a", json!("c1"), json!({w: 2}));
    legacy_edit(d, w, 4, 2, "f/b", json!("c2"), json!({w: 3}));
    // seq 5：实体被重映射过（作者在笔记 3 上、原件在笔记 5 上）→ 不收；seq 6 两边都在笔记 3 上、配得上对，但作者一侧
    // 它的寄存器里有没配上对的 seq 5 → 也不收（寄存器检查）。
    legacy_edit(d, w, 5, remapped.0, "f/c", json!("z"), json!({w: 4}));
    legacy_edit(d, w, 6, 3, "f/c", json!("p"), json!({w: 4}));
    // seq 7：独占一个寄存器、实体被重映射过 → 不收，别的寄存器不受影响。
    legacy_edit(d, w, 7, remapped.1, "f/z", json!("q"), json!({w: 6}));
    legacy_edit(d, w, 8, 1, "f/c", json!("a3"), json!({w: 7}));
    for (i, id) in LOGS.iter().enumerate() {
        legacy_log(d, id, 4, T0 - (5 - i as i64) * DAY);
    }
}

fn migrate(d: &Device) {
    while d.core.sync2_migrate(P, T0, None).unwrap()["done"] != json!(true) {}
}

fn device_of(d: &Device) -> String {
    d.core.sync2_identity(P, T0).unwrap()["device"]
        .as_str()
        .unwrap()
        .to_owned()
}

/// 推进作业直到做完。返回发出的配对数。
fn run_dedup(d: &Device) -> u64 {
    let mut n = 0;
    for _ in 0..1000 {
        let r = d.core.sync2_dedup(P, NOW).unwrap();
        n += r["emitted"].as_u64().unwrap_or(0);
        if r["done"] == json!(true) {
            return n;
        }
    }
    panic!("dedup did not finish");
}

/// (作者, 原件持有者)：作者 = 设备 ID 较大的那台，旧写入者被改名成 `merged-x`，两条旧记录的实体被重映射。
fn pair() -> (Device, Device) {
    let x = Device::new("dd-x");
    let y = Device::new("dd-y");
    let (author, keeper) = if device_of(&x) > device_of(&y) {
        (x, y)
    } else {
        (y, x)
    };
    legacy_library(&author, "merged-x", (3, 7));
    legacy_library(&keeper, "orig", (5, 8));
    migrate(&author);
    migrate(&keeper);
    (author, keeper)
}

fn rows_of_writer(d: &Device, w: &str) -> i64 {
    count(
        d,
        &format!("SELECT COUNT(*) FROM srs_field_edits WHERE writer_id = srs_id('{w}')"),
    )
}

/// 投影三表 + 冲突中心 + 扣留 + 旧修改记录闭包（按设备）。
fn state(d: &Device) -> Vec<Vec<String>> {
    let mut out = super::tests::projection(d);
    out.extend(d.rows("SELECT kind, entity_kind, srs_idt(entity) AS e, other_count FROM sync2_conflicts ORDER BY 1, 2, 3"));
    out.extend(d.rows(
        "SELECT kind, srs_idt(entity) AS e, hex(device), seq FROM sync2_held ORDER BY 1, 2, 3, 4",
    ));
    out.extend(d.rows("SELECT hex(device), upto, ctx FROM sync2_legacy ORDER BY 1"));
    out
}

/// `Dedup` 载荷与副本骨架的编码往返；解不开的骨架整条拒收（协议 2 的读者见到任何非 32 字节骨架都拒收）。
#[test]
fn dedup_body_and_duplicate_skeleton_round_trip() {
    use crate::sync2::id::Id;
    use crate::sync2::op::{self, Body, Op};
    use crate::sync2::vv::{OpId, Vv};
    let (d1, d2) = (Id::random(), Id::random());
    let pairs = vec![
        (3, OpId { device: d1, seq: 9 }),
        (4, OpId { device: d2, seq: 1 }),
        (
            900,
            OpId {
                device: d1,
                seq: 12,
            },
        ),
    ];
    let b = Body::Dedup {
        pairs: pairs.clone(),
    };
    assert_eq!(Body::decode(op::KIND_DEDUP, &b.encode()).unwrap(), b);
    let body = Body::Edit(crate::sync2::op::EditBody {
        kind: crate::sync2::op::EntKind::Note,
        entity: crate::sync2::id::Key::of("n"),
        key: "f/a".into(),
        value: "\"v\"".into(),
        machine: false,
        ts: 0,
        legacy: Some(crate::sync2::op::LegacyStamp {
            writer: "w".into(),
            seq: 4,
            ctx_json: "{\"vv\":{\"w\":3}}".into(),
            hlc: "1:0:w".into(),
            server_time: Some(7),
        }),
    });
    let author = Id::random();
    let o = Op {
        id: OpId {
            device: author,
            seq: 5,
        },
        hlc: crate::sync2::hlc::Hlc {
            wall: 1,
            logical: 0,
            device: author,
        },
        deps: std::sync::Arc::new(Vv::new()),
        kind: op::KIND_EDIT,
        schema: op::SCHEMA,
        payload: body.encode().into(),
        purged: false,
    };
    let dup = o.duplicate(pairs[0].1).unwrap();
    assert_eq!(
        dup.payload_hash(),
        o.payload_hash(),
        "the chain value does not move"
    );
    let Body::Edit(e) = body else { unreachable!() };
    assert_eq!(
        dup.body().unwrap(),
        Body::Duplicate {
            of: pairs[0].1,
            legacy: e.legacy
        }
    );
    let back = Op::read(&mut crate::sync2::codec::Reader::new(&dup.encode())).unwrap();
    assert_eq!(back, dup);
    let mut bad = dup.payload.to_vec();
    bad.truncate(40);
    assert!(
        op::check_skeleton(true, &bad).is_err(),
        "a truncated duplicate tail is rejected"
    );
    assert!(op::check_skeleton(true, &bad[..31]).is_err());
    assert!(
        op::check_skeleton(true, &bad[..32]).is_ok(),
        "a plain purge skeleton"
    );
}

/// 经生产分发器发一条 v2 命令。
fn cmd(d: &Device, req: Value, blobs: Vec<Vec<u8>>) -> Value {
    let mut req = req;
    req["profile"] = json!(P);
    req["caches"] = json!({"defaultDeck": super::config::default_deck_id(P)});
    let (mut blobs, mut files) = (blobs, Vec::new());
    crate::store::ffi::sync2_dispatch(&d.core, &req, &mut blobs, &mut files).unwrap()
}

/// 新设备经生产的分批收段会话收完 [b]（走收段通道，channel.rs）。
fn channel_session(d: &Device, b: &Bucket) {
    d.core.sync2_identity(P, NOW).unwrap();
    let heads: Vec<Vec<u8>> =
        b.0.iter()
            .filter(|(k, _)| {
                k.rsplit('/')
                    .next()
                    .and_then(crate::sync2::segment::parse_head_file_name)
                    .is_some()
            })
            .map(|(_, v)| v.clone())
            .collect();
    let segs: Vec<Vec<u8>> =
        b.0.iter()
            .filter(|(k, _)| k.contains("/seg-"))
            .map(|(_, v)| v.clone())
            .collect();
    cmd(d, json!({"op": "plan"}), heads);
    cmd(d, json!({"op": "ingest_begin"}), vec![]);
    assert!(
        super::channel::active(&d.core.writer().unwrap(), P).unwrap() || segs.is_empty(),
        "a new device takes the channel"
    );
    cmd(d, json!({"op": "ingest_prepare"}), segs);
    while cmd(
        d,
        json!({"op": "ingest_commit", "now": NOW, "sliceOps": 5}),
        vec![],
    )["more"]
        == json!(true)
    {}
    let mut r = cmd(d, json!({"op": "ingest_finish", "now": NOW}), vec![]);
    while r["more"] == json!(true) {
        r = cmd(d, json!({"op": "replay_pending", "now": NOW}), vec![]);
    }
}

/// 老设备与新设备（逐条投递 / 收段通道）收敛：副本行没了、扣留只看原件、骨架带旧戳、段变小。
#[test]
fn duplicate_streams_converge_on_every_device() {
    let (a, k) = pair();
    let mut bucket = Bucket::default();
    // 原件持有者先发；第三台设备只见过它的流，删掉了复习过的那张卡（与作者那份副本日志「并发」）。
    k.sync(&mut bucket, "loc", T0);
    let c = Device::new("dd-c");
    migrate(&c);
    c.sync(&mut bucket, "loc", T0);
    let input =
        json!([{"e": edit("card", &card_of(4), "deleted", json!(T0 + DAY)), "note": note_id(4)}])
            .to_string();
    c.core.sync2_apply_local(P, T0 + DAY, &input).unwrap();
    // 作者收到原件持有者的流：日志重复 → 排作业。
    a.sync(&mut bucket, "loc", T0 + DAY);
    assert_eq!(
        count(&a, "SELECT COUNT(*) FROM sync2_dedup"),
        1,
        "a duplicate log from a smaller device enqueues the job"
    );
    for _ in 0..2 {
        for d in [&k, &c, &a] {
            d.sync(&mut bucket, "loc", T0 + 2 * DAY);
        }
    }
    assert_eq!(
        rows_of_writer(&k, "merged-x"),
        8,
        "before: the renamed copies sit next to the originals"
    );
    assert!(
        count(&k, "SELECT COUNT(*) FROM sync2_held") > 0,
        "before: the delete is held against the author's copies"
    );
    let own = format!("devices/{}/seg-", device_of(&a));
    let own_before: std::collections::BTreeMap<String, Vec<u8>> = bucket
        .0
        .iter()
        .filter(|(p, _)| p.contains(&own))
        .map(|(p, b)| (p.clone(), b.clone()))
        .collect();

    // 作者核对：seq 1–4、8 改名配上（6 被寄存器检查剔掉，5 / 7 内容不同），三条日志逐字节相同。
    let emitted = run_dedup(&a);
    assert_eq!(
        emitted,
        5 + 3,
        "renamed edits that passed the register check + identical logs"
    );
    assert_eq!(count(&a, "SELECT COUNT(*) FROM sync2_dedup"), 0);
    assert_eq!(
        count(
            &a,
            "SELECT COUNT(*) FROM srs_meta WHERE key = 'compact_pending'"
        ),
        1,
        "the job schedules a compaction"
    );
    for _ in 0..2 {
        for d in [&a, &k, &c] {
            d.sync(&mut bucket, "loc", NOW);
        }
    }
    // 已经传过的段同名重写成骨架（名字不变、内容换了）；`Dedup` 操作本身进新段。体积见 BUG-4005 的实测。
    assert!(
        own_before.keys().all(|p| bucket.0.contains_key(p)),
        "same names"
    );
    assert!(
        own_before.iter().any(|(p, b)| bucket.0[p] != *b),
        "the author's uploaded segments were rewritten in place"
    );

    // 新设备：逐条投递（`sync2_ingest`）与收段通道（生产的分批会话）。
    let n = Device::new("dd-n");
    for _ in 0..2 {
        n.sync(&mut bucket, "loc", NOW);
    }
    let ch = Device::new("dd-ch");
    channel_session(&ch, &bucket);
    assert_eq!(
        count(&ch, "SELECT COUNT(*) FROM sync2_ops"),
        count(&n, "SELECT COUNT(*) FROM sync2_ops")
    );
    for d in [&a, &k, &c, &n, &ch] {
        assert_eq!(
            rows_of_writer(d, "merged-x"),
            3,
            "only the copies that were not proven equal keep their rows (seq 5, 6, 7)"
        );
        assert_eq!(
            count(d, "SELECT COUNT(*) FROM sync2_held"),
            0,
            "the delete no longer waits for the author's copies"
        );
        assert_eq!(
            state(d),
            state(&a),
            "same projection / holds / closures everywhere"
        );
        assert_eq!(d.digest(), a.digest());
    }
    assert_eq!(
        count(&n, "SELECT COUNT(*) FROM sync2_ops WHERE purged = 1"),
        8,
        "the new device received the skeletons"
    );
    assert_eq!(
        count(&k, "SELECT COUNT(*) FROM sync2_ops WHERE purged = 1"),
        8,
        "old readers turned their copies into skeletons"
    );
}

/// 归档位置不重写副本收敛换下的段（原文留着）；彻底清除照样重写。
#[test]
fn archive_locations_keep_the_original_segments() {
    let (a, k) = pair();
    let mut live = Bucket::default();
    k.sync(&mut live, "loc", T0);
    a.sync(&mut live, "loc", T0);
    let mut archive = Bucket::default();
    a.upload_all(&mut archive, "arc");
    let before = archive.0.clone();
    run_dedup(&a);
    let rewrites = count(
        &a,
        "SELECT COUNT(*) FROM sync2_rewrites WHERE location = 'arc' AND restamp = 2",
    );
    assert!(rewrites > 0);
    // 发出去的只有水位之上的新段（`Dedup` 操作本身），已在归档里的段一个不覆盖。
    let batch = a
        .core
        .sync2_outbox_to(P, "arc", None, u64::MAX, 64, true)
        .unwrap();
    assert!(
        batch.files.iter().all(|(p, _)| !before.contains_key(p)),
        "an archive location gets no dedup rewrites"
    );
    assert_eq!(
        count(
            &a,
            "SELECT COUNT(*) FROM sync2_rewrites WHERE location = 'arc'"
        ),
        0
    );
    let batch = a.core.sync2_outbox(P, "loc", None, u64::MAX, 64).unwrap();
    assert!(
        batch.files.iter().any(|(p, _)| live.0.contains_key(p)),
        "a sync location does get them"
    );
}

/// 一个动作：哪台设备同步一轮，或作者推进作业（[Step::Dedup] 一次走到底）。
#[derive(Clone, Copy, Debug)]
enum Step {
    Sync(usize),
    Dedup,
}

fn run(order: &[Step]) -> (String, Vec<Vec<String>>) {
    let (a, k) = pair();
    let c = Device::new("dd-pc");
    migrate(&c);
    let n = Device::new("dd-pn");
    let devs = [&a, &k, &c, &n];
    let mut bucket = Bucket::default();
    let mut t = T0;
    let mut deleted = false;
    for s in order {
        t += 1000;
        match *s {
            Step::Sync(i) => {
                devs[i].sync(&mut bucket, "loc", t);
                if i == 2 && !deleted {
                    deleted = true;
                    let input = json!([{"e": edit("card", &card_of(4), "deleted", json!(t)), "note": note_id(4)}]).to_string();
                    c.core.sync2_apply_local(P, t, &input).unwrap();
                }
            }
            Step::Dedup => {
                run_dedup(&a);
            }
        }
    }
    // 生产每轮同步都推进作业（srs_sync2_round.dart）。
    for _ in 0..3 {
        for d in devs {
            d.sync(&mut bucket, "loc", NOW);
        }
        run_dedup(&a);
    }
    for _ in 0..2 {
        for d in devs {
            d.sync(&mut bucket, "loc", NOW);
        }
    }
    let s = state(&a);
    for (i, d) in devs.iter().enumerate() {
        let x = state(d);
        let only_a: Vec<&Vec<String>> = s.iter().filter(|r| !x.contains(r)).collect();
        let only_d: Vec<&Vec<String>> = x.iter().filter(|r| !s.contains(r)).collect();
        assert!(
            only_a.is_empty() && only_d.is_empty(),
            "{order:?}: device {i} differs from the author\nauthor only: {only_a:?}\ndevice only: {only_d:?}"
        );
        assert_eq!(d.digest(), a.digest());
    }
    (a.digest(), s)
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 12, ..ProptestConfig::default() })]

    /// 投递顺序（谁先同步、作业在哪一步跑、新设备何时加入）怎样都收敛到同一个结果：投影、扣留、闭包、摘要。
    #[test]
    fn convergence_does_not_depend_on_delivery_order(order in prop::collection::vec(prop_oneof![
        (0usize..4).prop_map(Step::Sync),
        Just(Step::Dedup),
    ], 2..9)) {
        let (_, s) = run(&order);
        let merged = s.iter().filter(|r| r.iter().any(|c| c.contains("\"w\":\"merged-x\""))).count();
        prop_assert_eq!(merged, 3);
    }
}
