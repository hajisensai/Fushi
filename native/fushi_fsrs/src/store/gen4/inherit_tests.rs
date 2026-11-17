//! 承袭上传与旧根捡漏落库（`Receiver::legacy`）的测试。`oldroot.rs` 的测试复用这里的旧根夹具。

use rusqlite::Connection;

use super::*;
use crate::gen4::heritage::open_heritage;
use crate::gen4::op::tests::id;
use crate::gen4::translate::{T_VERSION, translate};
use crate::store::gen4::derive::tests::assert_rebuild_is_identity;
use crate::store::gen4::ingest::Settle;
use crate::store::gen4::native::tests::{me, ready};
use crate::store::gen4::receive::{Received, Receiver, Taken};
use crate::store::gen4::schema::open_in_memory;
use crate::store::gen4::truth::tests::bound;
use crate::store::gen4::truth::{Entry, Peer, TRUST_PENDING, TRUST_REJECTED};
use crate::store::sync2::collection_of;
use crate::sync2::op as v3;
use crate::sync2::segment::tests::ops_for;
use crate::sync2::segment::{self as seg3, chain_next};

/// 旧设备（承袭日志）。
pub(crate) const OLD: u8 = 0xd1;
/// 另一台升级过的设备（上传者）。
const A: u8 = 0x21;
pub(crate) const NOW: i64 = 1_800_000_000_000;

pub(crate) fn key_of(dev: u8) -> DeviceKey {
    DeviceKey::from_seed(&[dev; 32])
}

pub(crate) fn peer(t: &Truth<'_>, col: i64, device: Id, public: [u8; 32]) {
    t.tx(|t| {
        t.set_peer(
            col,
            &Peer {
                device,
                public,
                name: None,
                ext: None,
                head_gen: None,
                first_seen: None,
            },
        )
    })
    .unwrap();
}

/// 旧设备 OLD 的 [n] 条协议 3 操作，与每条之后的链值。
pub(crate) fn old_log(n: u64) -> (Vec<v3::Op>, Vec<Chain>) {
    let ops = ops_for(id(OLD), n);
    let mut chain = CHAIN_ZERO;
    let chains = ops
        .iter()
        .map(|op| {
            chain = chain_next(&chain, op);
            chain
        })
        .collect();
    (ops, chains)
}

/// 旧根里 OLD 写的段 `[a, b]`（位置目录 `dir`）：(段头, 字节)。
pub(crate) fn old_seg(
    ops: &[v3::Op],
    chains: &[Chain],
    (a, b): (u64, u64),
    key: Option<&CollectionKey>,
) -> (seg3::SegmentHeader, Vec<u8>) {
    let prev = if a == 1 {
        CHAIN_ZERO
    } else {
        chains[a as usize - 2]
    };
    seg3::pack(
        collection_of("dir"),
        &ops[a as usize - 1..b as usize],
        prev,
        &key_of(OLD),
        key,
    )
    .unwrap()
}

/// 一批收旧根的段（位置目录 [dir]）。
pub(crate) fn scavenge(
    t: &Truth<'_>,
    col: i64,
    dir: &str,
    segs: &[&[u8]],
    key: Option<&CollectionKey>,
) -> (Vec<Taken>, Received) {
    t.tx(|t| {
        let mut r = Receiver::open(t, col, Settle::Incremental)?;
        let mut out = Vec::new();
        for s in segs {
            out.push(r.legacy(s, dir, key)?);
        }
        Ok((out, r.finish()?))
    })
    .unwrap()
}

pub(crate) fn landed(l: u64, k: u64, p: u64) -> Taken {
    Taken::Landed {
        landed: l,
        known: k,
        parked: p,
    }
}

fn log(t: &Truth<'_>, col: i64, device: &Id) -> Vec<Entry> {
    let mut out = Vec::new();
    t.for_each(col, device, 1, |e| {
        out.push(e);
        Ok(())
    })
    .unwrap();
    out
}

fn oid(seq: u64) -> OpId {
    OpId {
        device: id(OLD),
        seq,
    }
}

/// 本机（`ready`：集合 `dir`、本机身份 ME）把 OLD 的 1..=[n] 从旧根捡进来，旧段在 [ends] 处切开。
fn mine_with(ends: &[u64], n: u64) -> (Connection, i64, Vec<Chain>) {
    let conn = open_in_memory().unwrap();
    let (ops, chains) = old_log(n);
    let col = {
        let t = Truth::new(&conn);
        let col = ready(&t);
        peer(&t, col, id(OLD), key_of(OLD).public());
        let mut a = 1;
        let mut segs = Vec::new();
        for &e in ends {
            segs.push(old_seg(&ops, &chains, (a, e), None).1);
            a = e + 1;
        }
        let refs: Vec<&[u8]> = segs.iter().map(|s| s.as_slice()).collect();
        let (got, _) = scavenge(&t, col, "dir", &refs, None);
        assert!(
            got.iter().all(|g| matches!(g, Taken::Landed { .. })),
            "{got:?}"
        );
        col
    };
    (conn, col, chains)
}

fn my_public(t: &Truth<'_>, col: i64) -> [u8; 32] {
    DeviceKey::from_seed(&t.self_identity(col).unwrap().unwrap().sk).public()
}

/// 在一个事务里开一轮上传对账，看过 [seen]（路径, 字节）之后的结论、计划与按计划打出的段。
fn plan_after(
    t: &Truth<'_>,
    col: i64,
    max: u64,
    seen: &[(&str, &[u8])],
    key: Option<&CollectionKey>,
) -> (Vec<Seen>, UploadPlan, Vec<Vec<u8>>) {
    t.tx(|t| {
        let mut u = Uploader::open(t, col)?.max_slots(max);
        let mut got = Vec::new();
        for (p, b) in seen {
            got.push(u.see(p, b, key)?);
        }
        let plan = u.plan()?;
        let packed = plan
            .put
            .iter()
            .map(|s| u.pack(s, key))
            .collect::<Result<Vec<_>, String>>()?;
        Ok((got, plan, packed))
    })
    .unwrap()
}

/// 上传者 [up]（签名钥匙 [signer]）把本机日志里 OLD 的 `[a, b]` 打成承袭段，[edit] 改其中的槽。返回 (路径, 字节)。
fn their_seg(
    t: &Truth<'_>,
    col: i64,
    (up, signer): (Id, &DeviceKey),
    chains: &[Chain],
    (a, b): (u64, u64),
    edit: impl Fn(HeritageSlot) -> HeritageSlot,
) -> (String, Vec<u8>) {
    their_seg_by(t, col, (up, signer), chains, (a, b), edit, None)
}

/// [their_seg]，段头带作者公钥 [author]。
fn their_seg_by(
    t: &Truth<'_>,
    col: i64,
    (up, signer): (Id, &DeviceKey),
    chains: &[Chain],
    (a, b): (u64, u64),
    edit: impl Fn(HeritageSlot) -> HeritageSlot,
    author: Option<[u8; 32]>,
) -> (String, Vec<u8>) {
    let slots: Vec<HeritageSlot> = log(t, col, &id(OLD))[a as usize - 1..b as usize]
        .iter()
        .map(|e| edit(e.slot().unwrap()))
        .collect();
    let meta = HeritageMeta {
        collection: id(0xc0),
        source: collection_of("dir"),
        device: id(OLD),
        uploader: up,
        author_key: author,
        t_version: T_VERSION,
        prev_chain: if a == 1 {
            CHAIN_ZERO
        } else {
            chains[a as usize - 2]
        },
        last_chain: chains[b as usize - 1],
    };
    let (h, bytes) = pack_heritage(&meta, &slots, signer, None).unwrap();
    (device_path(&up, &heritage_file_name(&h)), bytes)
}

fn ranges(plan: &UploadPlan) -> Vec<(u64, u64, bool)> {
    plan.put
        .iter()
        .map(|p| (p.first, p.last, p.rewrite))
        .collect()
}

fn void_at(seq: u64) -> impl Fn(HeritageSlot) -> HeritageSlot {
    move |s: HeritageSlot| {
        if s.id.seq == seq {
            HeritageSlot::void(s.id, s.fp)
        } else {
            s
        }
    }
}

#[test]
fn runs_merge_and_report_gaps() {
    let mut r = Runs::new();
    r.insert(5, 7);
    r.insert(1, 2);
    r.insert(3, 3);
    r.insert(10, 12);
    r.insert(9, 8);
    assert_eq!(
        r.0.iter().map(|(a, b)| (*a, *b)).collect::<Vec<_>>(),
        vec![(1, 3), (5, 7), (10, 12)]
    );
    r.insert(4, 4);
    assert_eq!(r.0.len(), 2);
    assert_eq!(r.gaps(1, 15), vec![(8, 9), (13, 15)]);
    assert_eq!(r.gaps(2, 6), Vec::<(u64, u64)>::new());
    assert_eq!(r.gaps(9, 9), vec![(9, 9)]);
    assert!(r.contains(7) && !r.contains(8) && r.contains(10));
    assert!(r.touches(8, 10) && !r.touches(8, 9));
    r.insert(8, 9);
    assert_eq!(r.gaps(0, 13), vec![(0, 0), (13, 13)]);
    r.insert(u64::MAX - 1, u64::MAX);
    assert_eq!(
        r.gaps(u64::MAX - 2, u64::MAX),
        vec![(u64::MAX - 2, u64::MAX - 2)]
    );
}

/// 旧根里的段经 `Receiver::legacy` 逐条转译进承袭日志：与 T 的输出逐槽相同，段的两端记下完整链值；乱序到达照样
/// 接上；同一段的转发件、再收一遍都是已有。
#[test]
fn old_root_segments_are_translated_into_the_heritage_log() {
    let conn = open_in_memory().unwrap();
    let t = Truth::new(&conn);
    let col = ready(&t);
    peer(&t, col, id(OLD), key_of(OLD).public());
    let (ops, chains) = old_log(10);
    let (_, s1) = old_seg(&ops, &chains, (1, 6), None);
    let (_, s2) = old_seg(&ops, &chains, (7, 10), None);
    let (got, rec) = scavenge(&t, col, "dir", &[&s2, &s1], None);
    assert_eq!(got, vec![landed(0, 0, 4), landed(6, 0, 0)]);
    assert_eq!((rec.delivered, rec.pending), (4, 0));
    let want: Vec<HeritageSlot> = ops
        .iter()
        .zip(&chains)
        .map(|(op, c)| translate(op, c).unwrap())
        .collect();
    let have: Vec<HeritageSlot> = log(&t, col, &id(OLD))
        .iter()
        .map(|e| e.slot().unwrap())
        .collect();
    assert_eq!(have, want);
    // 段的两端在收尾、投完待投递之后记：段 2 先到也记得上。
    assert_eq!(
        t.tx(|t| t.marks(col, &id(OLD))).unwrap(),
        vec![(6, chains[5]), (10, chains[9])]
    );
    let relayed = seg3::relay_pack(&s2, None, None).unwrap();
    let (got, _) = scavenge(&t, col, "dir", &[&relayed, &s1], None);
    assert_eq!(got, vec![landed(0, 4, 0), landed(0, 6, 0)]);
    assert_eq!(
        t.tx(|t| t.marks(col, &id(OLD))).unwrap(),
        vec![(6, chains[5]), (10, chains[9])]
    );
    assert_eq!(t.tx(|t| t.audit(col)), Ok(10));
    assert_rebuild_is_identity(&t, col);
}

/// 坏的、别的集合的、公钥未知的、解不开的旧段一条都不落；整批回滚 = 什么都没发生，重收照常。
#[test]
fn old_root_segments_that_cannot_be_taken_land_nothing() {
    let conn = open_in_memory().unwrap();
    let t = Truth::new(&conn);
    let col = ready(&t);
    let (ops, chains) = old_log(4);
    let (_, s) = old_seg(&ops, &chains, (1, 4), None);
    let (got, _) = scavenge(&t, col, "dir", &[&s], None);
    assert_eq!(got, vec![Taken::Deferred(Defer::UnknownSigner(id(OLD)))]);
    peer(&t, col, id(OLD), key_of(OLD).public());
    let mut bad = s.clone();
    *bad.last_mut().unwrap() ^= 1;
    let other = seg3::pack(collection_of("x"), &ops, CHAIN_ZERO, &key_of(OLD), None)
        .unwrap()
        .1;
    let k = CollectionKey([9; 32]);
    let sealed = old_seg(&ops, &chains, (1, 4), Some(&k)).1;
    let (got, _) = scavenge(&t, col, "dir", &[&bad, &other, &sealed], None);
    assert_eq!(
        got,
        vec![
            Taken::Rejected(Reject::BadSignature),
            Taken::Rejected(Reject::WrongCollection(collection_of("x"))),
            Taken::Deferred(Defer::Undecryptable),
        ]
    );
    let (got, _) = scavenge(&t, col, "not-mine", &[&s], None);
    assert_eq!(
        got,
        vec![Taken::Rejected(Reject::WrongCollection(collection_of(
            "not-mine"
        )))]
    );
    assert_eq!(t.tx(|t| t.audit(col)), Ok(0));
    // 崩溃：收了、没提交。
    let crashed: Result<(), String> = t.tx(|t| {
        let mut r = Receiver::open(t, col, Settle::Incremental)?;
        r.legacy(&s, "dir", None)?;
        r.finish()?;
        Err("crash".into())
    });
    assert!(crashed.is_err());
    t.reset();
    assert_eq!(t.tx(|t| t.audit(col)), Ok(0));
    // 加密位置上：加密的旧段（同一把钥匙）与明文旧段都收。
    let (got, _) = scavenge(&t, col, "dir", &[&sealed], Some(&k));
    assert_eq!(got, vec![landed(4, 0, 0)]);
    let (got, _) = scavenge(&t, col, "dir", &[&s], Some(&k));
    assert_eq!(got, vec![landed(0, 4, 0)]);
    assert_eq!(t.tx(|t| t.audit(col)), Ok(4));
    // 同一个旧设备在本机已是另一个来源集合的承袭日志：拒。
    let conn2 = open_in_memory().unwrap();
    let t2 = Truth::new(&conn2);
    let col2 = ready(&t2);
    peer(&t2, col2, id(OLD), key_of(OLD).public());
    t2.tx(|t| {
        t.put_heritage(
            col2,
            &id(0x5c),
            &translate(&ops[0], &chains[0]).unwrap(),
            T_VERSION,
        )
    })
    .unwrap();
    let (got, _) = scavenge(&t2, col2, "dir", &[&s], None);
    assert_eq!(got, vec![Taken::Rejected(Reject::WrongLog(id(OLD)))]);
}

/// 位置上什么都没有：整条承袭日志在切点上切段传上去；另一台设备收下之后与本机逐槽相同；本机再看到自己传的段，
/// 下一轮什么都不用传。
#[test]
fn upload_fills_the_location_and_others_receive_it_identically() {
    let (conn, col, _) = mine_with(&[6, 10], 10);
    let t = Truth::new(&conn);
    let (_, plan, packed) = plan_after(&t, col, UPLOAD_MAX_SLOTS, &[], None);
    assert_eq!(ranges(&plan), vec![(1, 10, false)]);
    let whole = plan.put[0].path.clone();
    // 目标 4 个槽一段：只能在切点（0、6、10）上切。
    let (_, plan, packed4) = plan_after(&t, col, 4, &[], None);
    assert_eq!(ranges(&plan), vec![(1, 6, false), (7, 10, false)]);
    assert!(plan.blocked.is_empty() && plan.kept_forked.is_empty());
    // 另一台设备（信任本机）收下：乱序到达也一样。
    let conn2 = open_in_memory().unwrap();
    let t2 = Truth::new(&conn2);
    let col2 = bound(&t2);
    peer(&t2, col2, me(), my_public(&t, col));
    let (got, _) = t2
        .tx(|t| {
            let mut r = Receiver::open(t, col2, Settle::Incremental)?;
            let got = vec![
                r.heritage(&packed4[1], None)?,
                r.heritage(&packed4[0], None)?,
            ];
            Ok((got, r.finish()?))
        })
        .unwrap();
    assert_eq!(got, vec![landed(0, 0, 4), landed(6, 0, 0)]);
    assert_eq!(log(&t2, col2, &id(OLD)), log(&t, col, &id(OLD)));
    // 收下的承袭段两端成了对方的切点：它也能再往别的位置传。
    assert_eq!(
        t2.tx(|t| t.marks(col2, &id(OLD))).unwrap(),
        t.tx(|t| t.marks(col, &id(OLD))).unwrap()
    );
    // 本机看到自己传的段：都满足了。
    let (p1, p2) = (plan.put[0].path.clone(), plan.put[1].path.clone());
    let (seen, plan, _) = plan_after(&t, col, 4, &[(&p1, &packed4[0]), (&p2, &packed4[1])], None);
    assert_eq!(
        seen,
        vec![Seen::Counted { matched: 6 }, Seen::Counted { matched: 4 }]
    );
    assert_eq!(plan, UploadPlan::default());
    let (_, plan, _) = plan_after(&t, col, UPLOAD_MAX_SLOTS, &[(&whole, &packed[0])], None);
    assert_eq!(plan, UploadPlan::default());
}

/// 段头担保的作者公钥与本机记的不同（G10-4 第四轮）：不算位置上有、本机照传（收方 `receive.rs` 同样整段不收）；同一把
/// 照常算。本机打的段头带本机记着的作者公钥。
#[test]
fn coverage_vouching_another_author_key_does_not_count() {
    let (conn, col, chains) = mine_with(&[6, 10], 10);
    let t = Truth::new(&conn);
    let ka = key_of(A);
    peer(&t, col, id(A), ka.public());
    let evil = Some(key_of(0xee).public());
    let (path, bytes) = their_seg_by(&t, col, (id(A), &ka), &chains, (1, 10), |s| s, evil);
    let (seen, plan, packed) = plan_after(&t, col, UPLOAD_MAX_SLOTS, &[(&path, &bytes)], None);
    assert_eq!(
        seen,
        vec![Seen::Rejected(Reject::AuthorKeyMismatch(id(OLD)))]
    );
    assert_eq!(ranges(&plan), vec![(1, 10, false)]);
    assert_eq!(
        peek_heritage_header(&packed[0]).unwrap().author_key,
        Some(key_of(OLD).public())
    );
    let real = Some(key_of(OLD).public());
    let (path, bytes) = their_seg_by(&t, col, (id(A), &ka), &chains, (1, 10), |s| s, real);
    let (seen, plan, _) = plan_after(&t, col, UPLOAD_MAX_SLOTS, &[(&path, &bytes)], None);
    assert_eq!(seen, vec![Seen::Counted { matched: 10 }]);
    assert_eq!(plan, UploadPlan::default());
}

/// D20：不受信 / 公钥未知的上传者的段不算位置上有，本机照传；信任之后才算。名字对不上段头、加密位置上的明文件不算。
#[test]
fn coverage_by_an_untrusted_or_unknown_uploader_does_not_count() {
    let (conn, col, chains) = mine_with(&[6, 10], 10);
    let t = Truth::new(&conn);
    let ka = key_of(A);
    let (path, bytes) = their_seg(&t, col, (id(A), &ka), &chains, (1, 10), |s| s);
    let one = [(path.as_str(), bytes.as_slice())];
    let (seen, plan, _) = plan_after(&t, col, UPLOAD_MAX_SLOTS, &one, None);
    assert_eq!(seen, vec![Seen::Ignored(Defer::UnknownSigner(id(A)))]);
    assert_eq!(ranges(&plan), vec![(1, 10, false)]);
    peer(&t, col, id(A), ka.public());
    t.tx(|t| t.set_trust(col, &id(A), Some(TRUST_PENDING), NOW))
        .unwrap();
    let (seen, plan, _) = plan_after(&t, col, UPLOAD_MAX_SLOTS, &one, None);
    assert_eq!(seen, vec![Seen::Ignored(Defer::UntrustedUploader(id(A)))]);
    assert_eq!(ranges(&plan), vec![(1, 10, false)]);
    t.tx(|t| t.set_trust(col, &id(A), None, NOW)).unwrap();
    for wrong in [
        path.replace("hrt-", "hrt-0"),
        path.replace(&id(A).text(), &id(0x23).text()),
    ] {
        let (seen, plan, _) = plan_after(&t, col, UPLOAD_MAX_SLOTS, &[(&wrong, &bytes)], None);
        assert!(
            matches!(seen[0], Seen::Rejected(Reject::Corrupt(_))),
            "{seen:?}"
        );
        assert_eq!(ranges(&plan), vec![(1, 10, false)]);
    }
    let k = CollectionKey([9; 32]);
    let (seen, _, _) = plan_after(&t, col, UPLOAD_MAX_SLOTS, &one, Some(&k));
    assert_eq!(seen, vec![Seen::Rejected(Reject::PlainOnSealed)]);
    let (seen, plan, _) = plan_after(&t, col, UPLOAD_MAX_SLOTS, &one, None);
    assert_eq!(seen, vec![Seen::Counted { matched: 10 }]);
    assert_eq!(plan, UploadPlan::default());
}

/// D19 / 设计 §10 第 3 条：位置上已是空洞、本机还是完整内容（本机不执行那条 Purge），不把原文传回去；别的受信上传者那里
/// 更靠后的状态，本机已传的段原区间重写成它（只降不升），本机的槽不动；本机自己清了，已传的段重写成空洞；位置上只有
/// 完整的、本机已清成空洞，补传空洞。
#[test]
fn same_seq_slots_on_the_location_only_move_later() {
    let (conn, col, chains) = mine_with(&[6, 10], 10);
    let t = Truth::new(&conn);
    let ka = key_of(A);
    peer(&t, col, id(A), ka.public());
    // A 的段在 3 处是空洞：本机完整内容算满足，什么都不传。
    let (a_path, a_bytes) = their_seg(&t, col, (id(A), &ka), &chains, (1, 10), void_at(3));
    let (seen, plan, _) = plan_after(&t, col, UPLOAD_MAX_SLOTS, &[(&a_path, &a_bytes)], None);
    assert_eq!(seen, vec![Seen::Counted { matched: 10 }]);
    assert_eq!(plan, UploadPlan::default());
    // 本机传过一份完整的；A 那里 5 是空洞：本机那份原区间重写，5 取 A 的空洞，别的照旧。
    let (_, plan, packed) = plan_after(&t, col, UPLOAD_MAX_SLOTS, &[], None);
    let (my_path, my_bytes) = (plan.put[0].path.clone(), packed[0].clone());
    let (a5_path, a5_bytes) = their_seg(&t, col, (id(A), &ka), &chains, (1, 6), void_at(5));
    let (_, plan, packed) = plan_after(
        &t,
        col,
        UPLOAD_MAX_SLOTS,
        &[(&my_path, &my_bytes), (&a5_path, &a5_bytes)],
        None,
    );
    assert_eq!(ranges(&plan), vec![(1, 10, true)]);
    assert_eq!(plan.put[0].path, my_path);
    let (_, slots) = open_heritage(&packed[0], &my_public(&t, col), None).unwrap();
    assert_eq!(slots[4], HeritageSlot::void(oid(5), slots[4].fp));
    assert!(
        slots
            .iter()
            .enumerate()
            .all(|(i, s)| i == 4 || rank_of(&s.body) == Rank::Whole)
    );
    // 本机的槽不动。
    assert!(t.tx(|t| t.entry(col, &oid(5))).unwrap().unwrap().is_whole());
    // 只剩改写后的那份（5 是空洞）在场：本机的完整内容不比它靠后，不改回去。
    let rewritten = packed[0].clone();
    let (seen, plan, _) = plan_after(&t, col, UPLOAD_MAX_SLOTS, &[(&my_path, &rewritten)], None);
    assert_eq!(seen, vec![Seen::Counted { matched: 10 }]);
    assert_eq!(plan, UploadPlan::default());
    // 本机自己清了 3：已传的那份重写，3 是空洞。
    assert_eq!(t.tx(|t| t.advance_purge(col, &oid(3))), Ok(true));
    let (_, plan, packed) = plan_after(&t, col, UPLOAD_MAX_SLOTS, &[(&my_path, &my_bytes)], None);
    assert_eq!(ranges(&plan), vec![(1, 10, true)]);
    let (_, slots) = open_heritage(&packed[0], &my_public(&t, col), None).unwrap();
    assert_eq!(slots[2], HeritageSlot::void(oid(3), slots[2].fp));
    // 位置上只有 A 的完整内容（A 不执行那条清除）：本机的空洞更靠后，补传；缺口 3 扩到切点 0、6。
    let (ops, old_chains) = old_log(3);
    let (a16, a16_bytes) = their_seg(&t, col, (id(A), &ka), &chains, (1, 6), |s| {
        if s.id.seq == 3 {
            translate(&ops[2], &old_chains[2]).unwrap()
        } else {
            s
        }
    });
    let (a7, a7_bytes) = their_seg(&t, col, (id(A), &ka), &chains, (7, 10), |s| s);
    let (_, plan, packed) = plan_after(
        &t,
        col,
        UPLOAD_MAX_SLOTS,
        &[(&a16, &a16_bytes), (&a7, &a7_bytes)],
        None,
    );
    assert_eq!(ranges(&plan), vec![(1, 6, false)]);
    let (_, slots) = open_heritage(&packed[0], &my_public(&t, col), None).unwrap();
    assert_eq!(rank_of(&slots[2].body), Rank::Void);
}

/// 本机自己的段里有另一支的槽（链指纹与本机日志不同）：永不重写，新切的段撞上它的名字也不写。
#[test]
fn my_own_segment_holding_another_branch_is_never_overwritten() {
    let (conn, col, chains) = mine_with(&[10], 10);
    let t = Truth::new(&conn);
    let mine = DeviceKey::from_seed(&t.self_identity(col).unwrap().unwrap().sk);
    let fork4 = |s: HeritageSlot| {
        if s.id.seq == 4 {
            HeritageSlot { fp: [0xee; 8], ..s }
        } else {
            s
        }
    };
    let (path, bytes) = their_seg(&t, col, (me(), &mine), &chains, (1, 10), fork4);
    let (seen, plan, _) = plan_after(&t, col, UPLOAD_MAX_SLOTS, &[(&path, &bytes)], None);
    assert_eq!(seen, vec![Seen::Counted { matched: 9 }]);
    // 4 没满足；切点只有 0、10，新段正好是 1..=10，名字与那份另一支的相同：不写。
    assert!(plan.put.is_empty(), "{plan:?}");
    assert_eq!(plan.kept_forked, vec![path.clone()]);
    // 本机清了 2：那份本该重写，照样不动。
    assert_eq!(t.tx(|t| t.advance_purge(col, &oid(2))), Ok(true));
    let (_, plan, _) = plan_after(&t, col, UPLOAD_MAX_SLOTS, &[(&path, &bytes)], None);
    assert!(plan.put.iter().all(|p| p.path != path), "{plan:?}");
    assert_eq!(plan.kept_forked, vec![path]);
}

/// 本机自己那份另一支的段与新切的段同名（同区间、段尾链值相同），但区间里还有别的切点：切小了传，本机这一支照样上了
/// 位置，那份另一支不动、也不再报未收敛。
#[test]
fn a_name_clash_with_my_forked_segment_is_cut_at_inner_points() {
    let (conn, col, chains) = mine_with(&[5, 10], 10);
    let t = Truth::new(&conn);
    let mine = DeviceKey::from_seed(&t.self_identity(col).unwrap().unwrap().sk);
    let fork = |s: HeritageSlot| {
        if s.id.seq == 4 || s.id.seq == 8 {
            HeritageSlot { fp: [0xee; 8], ..s }
        } else {
            s
        }
    };
    let (path, bytes) = their_seg(&t, col, (me(), &mine), &chains, (1, 10), fork);
    let (seen, plan, packed) = plan_after(&t, col, UPLOAD_MAX_SLOTS, &[(&path, &bytes)], None);
    assert_eq!(seen, vec![Seen::Counted { matched: 8 }]);
    assert_eq!(ranges(&plan), vec![(1, 5, false), (6, 10, false)]);
    assert!(plan.put.iter().all(|p| p.path != path), "{plan:?}");
    assert!(plan.kept_forked.is_empty(), "{plan:?}");
    // 传上去之后（两份都在位置上）：本机这一支都满足了，什么都不再传。
    let pieces: Vec<(String, Vec<u8>)> = plan
        .put
        .iter()
        .zip(packed)
        .map(|(p, b)| (p.path.clone(), b))
        .collect();
    let mut all: Vec<(&str, &[u8])> = vec![(&path, &bytes)];
    all.extend(pieces.iter().map(|(p, b)| (p.as_str(), b.as_slice())));
    let (_, plan, _) = plan_after(&t, col, UPLOAD_MAX_SLOTS, &all, None);
    assert_eq!(plan, UploadPlan::default());
}

/// 本机自己已传的段区间越过本机日志的末尾（同一身份在别处写得更长的）：落后了也不原区间重写（打不出来、不能让整轮
/// 失败），落后的 seq 另切新段补，名字不同、不覆盖它。
#[test]
fn my_segment_reaching_past_my_log_is_not_rewritten() {
    let (longer, lcol, lchains) = mine_with(&[12], 12);
    let (path, bytes) = {
        let t = Truth::new(&longer);
        let mine = DeviceKey::from_seed(&t.self_identity(lcol).unwrap().unwrap().sk);
        their_seg(&t, lcol, (me(), &mine), &lchains, (1, 12), |s| s)
    };
    let (conn, col, _) = mine_with(&[10], 10);
    let t = Truth::new(&conn);
    assert_eq!(t.tx(|t| t.advance_purge(col, &oid(3))), Ok(true));
    let (seen, plan, packed) = plan_after(&t, col, UPLOAD_MAX_SLOTS, &[(&path, &bytes)], None);
    assert_eq!(seen, vec![Seen::Counted { matched: 10 }]);
    assert_eq!(ranges(&plan), vec![(1, 10, false)]);
    assert_ne!(plan.put[0].path, path);
    assert!(plan.blocked.is_empty() && plan.kept_forked.is_empty());
    let (_, slots) = open_heritage(&packed[0], &my_public(&t, col), None).unwrap();
    assert_eq!(rank_of(&slots[2].body), Rank::Void);
}

/// 缺口之后本机不知道任何一处的完整原链值：传不了，报出来；记上链值之后就传。
#[test]
fn a_gap_without_a_known_chain_after_it_is_blocked() {
    let conn = open_in_memory().unwrap();
    let t = Truth::new(&conn);
    let col = ready(&t);
    let (ops, chains) = old_log(3);
    t.tx(|t| {
        for (op, c) in ops.iter().zip(&chains) {
            t.put_heritage(
                col,
                &collection_of("dir"),
                &translate(op, c).unwrap(),
                T_VERSION,
            )?;
        }
        Ok(())
    })
    .unwrap();
    let (_, plan, _) = plan_after(&t, col, UPLOAD_MAX_SLOTS, &[], None);
    assert!(plan.put.is_empty());
    assert_eq!(
        plan.blocked,
        vec![Blocked {
            device: id(OLD),
            first: 1,
            last: 3
        }]
    );
    t.tx(|t| t.set_mark(col, &id(OLD), 3, &chains[2])).unwrap();
    let (_, plan, packed) = plan_after(&t, col, UPLOAD_MAX_SLOTS, &[], None);
    assert_eq!(ranges(&plan), vec![(1, 3, false)]);
    assert!(plan.blocked.is_empty());
    assert_eq!(
        peek_heritage_header(&packed[0]).unwrap().last_chain,
        chains[2]
    );
}

#[test]
fn the_uploader_needs_a_transaction_and_sees_each_file_once() {
    let (conn, col, chains) = mine_with(&[10], 10);
    let t = Truth::new(&conn);
    assert!(Uploader::open(&t, col).is_err());
    let ka = key_of(A);
    peer(&t, col, id(A), ka.public());
    let (path, bytes) = their_seg(&t, col, (id(A), &ka), &chains, (1, 10), |s| s);
    let twice: Result<(), String> = t.tx(|t| {
        let mut u = Uploader::open(t, col)?;
        u.see(&path, &bytes, None)?;
        u.see(&path, &bytes, None)?;
        Ok(())
    });
    assert!(twice.unwrap_err().contains("seen twice"));
}

/// 长的旧段每 4096 条记一个完整链值（与迁移灌入同口径），切承袭段才有中间的切点。
#[test]
fn long_old_segments_leave_a_cut_point_every_4096_slots() {
    let conn = open_in_memory().unwrap();
    let t = Truth::new(&conn);
    let col = ready(&t);
    peer(&t, col, id(OLD), key_of(OLD).public());
    let (ops, chains) = old_log(4097);
    let (_, s) = old_seg(&ops, &chains, (1, 4097), None);
    let (got, _) = scavenge(&t, col, "dir", &[&s], None);
    assert_eq!(got, vec![landed(4097, 0, 0)]);
    assert_eq!(
        t.tx(|t| t.marks(col, &id(OLD))).unwrap(),
        vec![(4096, chains[4095]), (4097, chains[4096])]
    );
    let (_, plan, _) = plan_after(&t, col, 4000, &[], None);
    assert_eq!(ranges(&plan), vec![(1, 4096, false), (4097, 4097, false)]);
}

/// 只替本机信任的作者上传（G10-4，文件头）：承袭日志的作者在本机待确认 / 已拒绝时，这一轮不替它切段、不传；本机确认
/// 之后照常整条传。判据只看作者在本机的信任，与有没有别的承袭日志无关（[Uploader::open] 本身就筛，不靠同步轮的指纹）。
#[test]
fn an_author_this_device_does_not_trust_is_not_uploaded() {
    let (conn, col, _) = mine_with(&[6, 10], 10);
    let t = Truth::new(&conn);
    for state in [TRUST_PENDING, TRUST_REJECTED] {
        t.tx(|t| t.set_trust(col, &id(OLD), Some(state), NOW))
            .unwrap();
        let (_, plan, packed) = plan_after(&t, col, UPLOAD_MAX_SLOTS, &[], None);
        assert_eq!(plan, UploadPlan::default(), "state {state}");
        assert!(packed.is_empty());
    }
    t.tx(|t| t.set_trust(col, &id(OLD), None, NOW)).unwrap();
    let (_, plan, _) = plan_after(&t, col, UPLOAD_MAX_SLOTS, &[], None);
    assert_eq!(ranges(&plan), vec![(1, 10, false)]);
}
