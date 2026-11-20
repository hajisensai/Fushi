//! [super] 的测试，以及 G8-6 三个模块（换身份 `truth/own.rs`、分叉检测、小段合并 `compact.rs`）共用的测试装置。

use std::collections::BTreeMap;
use std::sync::Arc;

use rusqlite::{Connection, params};

use super::*;
use crate::gen4::op::tests::{native_edit, sample_log};
use crate::gen4::op::{Body4, Edit4, Log4, Op4};
use crate::gen4::segment::{open_native, pack_native, peek_native_header};
use crate::store::gen4::derive::Index;
use crate::store::gen4::derive::tests::dump;
use crate::store::gen4::schema::open_in_memory;
use crate::store::gen4::truth::tests::bound;
use crate::sync2::hlc::Hlc;
use crate::sync2::id::Key;
use crate::sync2::keys::DeviceKey;
use crate::sync2::op::EntKind;
use crate::sync2::segment::{CHAIN_ZERO, segment_file_name};
use crate::sync2::vv::{OpId, Vv};

pub(crate) const T0: i64 = 1_800_000_000_000;
pub(crate) const SEED: [u8; 32] = [7; 32];
/// 装置里本机身份的设备 ID（[setup] 用它建 `self_`）。
pub(crate) const OWN: Id = Id([0x0d, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xd0]);

pub(crate) fn idn(salt: u8, i: u64) -> Id {
    let mut b = [0u8; 16];
    b[0] = salt;
    b[8..].copy_from_slice(&i.to_be_bytes());
    Id(b)
}

/// 第 [i] 条操作的内容（[salt] 不同 = 另一个安装写的不同内容）：身份记录 / 修改 / 日志轮着来。
pub(crate) fn body(i: u64, salt: u8) -> Body4 {
    let note = Key::Uuid(idn(salt, i / 3));
    match i % 3 {
        0 => Body4::Entity {
            kind: EntKind::Note,
            id: note,
            data: r#"{"createdAt":1,"guid":"g","noteTypeId":"t"}"#.into(),
        },
        1 => Body4::Edit(Edit4 {
            entity: note,
            value: format!("\"v{i}-{salt}\""),
            ..native_edit()
        }),
        _ => Body4::Log(Log4 {
            id: Key::Uuid(idn(salt ^ 0x80, i)),
            card: Key::Uuid(idn(salt ^ 0x40, i / 3)),
            ..sample_log()
        }),
    }
}

/// 内存库、绑好集合、建好本机身份。
pub(crate) fn setup() -> (Connection, i64) {
    let conn = open_in_memory().unwrap();
    let col = {
        let t = Truth::new(&conn);
        let col = bound(&t);
        t.tx(|t| t.create_self(col, &OWN, &SEED, None, T0)).unwrap();
        col
    };
    (conn, col)
}

/// [device] 的第 [seq] 条操作。
pub(crate) fn op(device: Id, seq: u64, body: &Body4, deps: Vv) -> Op4 {
    Op4::of(
        OpId { device, seq },
        Hlc {
            wall: T0 + seq as i64,
            logical: 0,
            device,
        },
        Arc::new(deps),
        body,
    )
}

/// 本机当前身份往下写 [n] 条（内容 = `body(seq, 0)`）。返回每条之后的链值。
pub(crate) fn write_own(t: &Truth<'_>, col: i64, n: u64) -> Vec<Chain> {
    let me = t.self_identity(col).unwrap().unwrap();
    let last = t.last_of(col, &me.device).unwrap();
    t.tx(|t| {
        let mut out = Vec::new();
        for seq in last + 1..=last + n {
            out.push(t.append_native(col, &op(me.device, seq, &body(seq, 0), Vv::new()))?);
        }
        Ok(out)
    })
    .unwrap()
}

/// 本机日志 `first..=last` 的段内项（空洞按与范围的交集、区间末链值）。
pub(crate) fn own_items(t: &Truth<'_>, col: i64, first: u64, last: u64) -> Vec<NativeItem> {
    let me = t.self_identity(col).unwrap().unwrap();
    let mut items: Vec<NativeItem> = Vec::new();
    t.native_walk(col, &me.device, first, last, |s| {
        items.push(match s {
            NativeStep::Op(op) => NativeItem::Op(op),
            NativeStep::Void {
                first,
                last,
                chain_after,
                ..
            } => NativeItem::Void {
                count: last - first + 1,
                chain_after,
            },
        });
        Ok(())
    })
    .unwrap();
    items
}

/// 另一个安装：与本机共有 `1..=keep`，之后写 `keep+1..=upto`（内容 `body(seq, 9)`）。按约 [cut] 个 seq 一段打包，返回
/// (head, 段文件, 它写的那些操作)。
pub(crate) fn clone_location(
    t: &Truth<'_>,
    col: i64,
    keep: u64,
    upto: u64,
    cut: u64,
) -> (Head4, Vec<Vec<u8>>, Vec<Op4>) {
    let me = t.self_identity(col).unwrap().unwrap();
    let collection = t.binding(col).unwrap().unwrap().collection;
    let mut items = own_items(t, col, 1, keep);
    let theirs: Vec<Op4> = (keep + 1..=upto)
        .map(|seq| op(me.device, seq, &body(seq, 9), Vv::new()))
        .collect();
    items.extend(theirs.iter().cloned().map(NativeItem::Op));
    let mut files = Vec::new();
    let mut segs = Vec::new();
    let (mut seq, mut chain) = (1u64, CHAIN_ZERO);
    let mut rest = items.as_slice();
    while !rest.is_empty() {
        let mut take = 0usize;
        let mut span = 0u64;
        while take < rest.len() && span < cut {
            span += rest[take].span();
            take += 1;
        }
        let (h, bytes) = pack_native(
            collection,
            me.device,
            seq,
            &rest[..take],
            chain,
            &me.key(),
            None,
        )
        .unwrap();
        segs.push((h.first, h.last, chain_tag(&h.last_chain)));
        seq = h.last + 1;
        chain = h.last_chain;
        files.push(bytes);
        rest = &rest[take..];
    }
    let head = Head4 {
        gen: 1,
        protocol: 4,
        min_reader: 4,
        collection,
        device: me.device,
        public: me.public(),
        seq: seq - 1,
        chain,
        segs,
        ack: Vv::new(),
        digest: String::new(),
        at_ms: T0,
        name: String::new(),
        loc: String::new(),
        seal: String::new(),
        derive: 1,
        prev: None,
        ext: None,
        extra: BTreeMap::new(),
    };
    (head, files, theirs)
}

fn scan(t: &Truth<'_>, col: i64, files: &[Vec<u8>], public: &[u8; 32]) -> ForkScan {
    let mut s = ForkScan::new(t, col).unwrap();
    for f in files {
        let (h, items) = open_native(f, public, None).unwrap();
        s.feed(t, col, &h, &items).unwrap();
    }
    s
}

pub(crate) fn rebuild(t: &Truth<'_>, col: i64) {
    t.tx(|t| Index::new(t, col).rebuild_all().map(|_| ()))
        .unwrap();
}

#[test]
fn heads_that_are_not_ours_a_prefix_or_an_impostor_are_told_apart() {
    let (conn, col) = setup();
    let t = Truth::new(&conn);
    write_own(&t, col, 12);
    let (head, _, _) = clone_location(&t, col, 12, 12, 5);
    // 位置上的 head 与本机相同 / 落后（前缀）。
    assert_eq!(judge_own_head(&t, col, &head), Ok(OwnHead::Prefix));
    let (behind, _, _) = clone_location(&t, col, 7, 7, 5);
    assert_eq!(
        (behind.seq, behind.chain),
        (7, t.chain_at(col, &head.device, 7).unwrap())
    );
    assert_eq!(judge_own_head(&t, col, &behind), Ok(OwnHead::Prefix));
    let mut empty = head.clone();
    empty.seq = 0;
    empty.chain = CHAIN_ZERO;
    empty.segs = Vec::new();
    assert_eq!(judge_own_head(&t, col, &empty), Ok(OwnHead::Prefix));
    // 别的设备、别的集合。
    let mut other = head.clone();
    other.device = idn(1, 1);
    assert_eq!(judge_own_head(&t, col, &other), Ok(OwnHead::Foreign));
    let mut elsewhere = head.clone();
    elsewhere.collection = idn(2, 2);
    assert_eq!(judge_own_head(&t, col, &elsewhere), Ok(OwnHead::Foreign));
    // 本机的设备 ID、别的钥匙：冒名。
    let mut impostor = head.clone();
    impostor.public = DeviceKey::from_seed(&[8; 32]).public();
    assert_eq!(judge_own_head(&t, col, &impostor), Ok(OwnHead::Impostor));
}

#[test]
fn a_cloned_identity_is_found_at_the_last_shared_op_and_rotated_away() {
    let (conn, col) = setup();
    let t = Truth::new(&conn);
    write_own(&t, col, 30);
    rebuild(&t, col);
    let me = t.self_identity(col).unwrap().unwrap();
    // 另一个安装共有 1..=17，之后写到 26。
    let (head, files, theirs) = clone_location(&t, col, 17, 26, 5);
    let OwnHead::Fetch { segs } = judge_own_head(&t, col, &head).unwrap() else {
        panic!("expected fetch");
    };
    // 段是 1-5、6-10、11-15、16-20、21-25、26：分叉在第 4 段，多拉前一段。
    assert_eq!(segs[0].0, 11);
    assert_eq!(segs.len(), head.segs.len() - 2);
    let wanted: Vec<String> = segs
        .iter()
        .map(|(a, b, tag)| segment_file_name(*a, *b, tag))
        .collect();
    let fetched: Vec<Vec<u8>> = files
        .iter()
        .filter(|f| wanted.contains(&peek_native_header(f).unwrap().file_name()))
        .cloned()
        .collect();
    assert_eq!(fetched.len(), wanted.len());
    assert_eq!(scan(&t, col, &fetched, &me.public()).fork_point(), Some(17));
    // 喂的顺序、重复喂都不影响。
    let mut rev = fetched.clone();
    rev.reverse();
    rev.push(fetched[0].clone());
    assert_eq!(scan(&t, col, &rev, &me.public()).fork_point(), Some(17));
    // 记下（取较小者），下一轮 judge 直接给 Known。
    assert_eq!(t.tx(|t| record_fork(t, col, 20)), Ok(20));
    assert_eq!(t.tx(|t| record_fork(t, col, 17)), Ok(17));
    assert_eq!(t.tx(|t| record_fork(t, col, 25)), Ok(17));
    assert_eq!(
        judge_own_head(&t, col, &head),
        Ok(OwnHead::Known { keep: 17 })
    );
    let e = record_fork(&t, col, 3).unwrap_err();
    assert!(e.contains("outside a transaction"), "{e}");
    // 换身份：18..=30 以新身份重签发，旧身份冻结在 17。
    let r = rotate_on_fork(&t, col, T0 + 1000).unwrap().unwrap();
    assert_eq!((r.previous, r.keep, r.moved.len()), (me.device, 17, 13));
    assert_eq!(recorded_fork(&t, col), Ok(None));
    assert_eq!(rotate_on_fork(&t, col, T0 + 2000), Ok(None));
    // 另一个安装在旧身份下写的 18..=26 现在按普通设备收：链从 17 处接着验，与它的段里的链值一致。
    let got: Vec<Chain> = t
        .tx(|t| theirs.iter().map(|op| t.append_native(col, op)).collect())
        .unwrap();
    let last_header = peek_native_header(files.last().unwrap()).unwrap();
    assert_eq!(*got.last().unwrap(), last_header.last_chain);
    // 本机的新身份不再被当成分叉：位置上那份 head 现在是「别的设备」。
    assert_eq!(judge_own_head(&t, col, &head), Ok(OwnHead::Foreign));
    // 派生索引：逐条维护（换身份 + 收旧身份的操作）与重建逐行相同。
    t.tx(|t| {
        let mut ix = Index::new(t, col);
        for op in &theirs {
            ix.add(&t.entry(col, &op.id)?.unwrap())?;
        }
        ix.settle().map(|_| ())
    })
    .unwrap();
    let inc = dump(&conn, col);
    rebuild(&t, col);
    assert_eq!(inc, dump(&conn, col));
}

#[test]
fn a_location_ahead_of_us_on_the_same_chain_keeps_everything_we_have() {
    // 本机从旧备份还原：位置上同一身份比本机多写了几条，本机有的部分两边相同。
    let (conn, col) = setup();
    let t = Truth::new(&conn);
    write_own(&t, col, 9);
    let me = t.self_identity(col).unwrap().unwrap();
    let (head, files, _) = clone_location(&t, col, 9, 14, 4);
    let OwnHead::Fetch { segs } = judge_own_head(&t, col, &head).unwrap() else {
        panic!("expected fetch");
    };
    // 段 1-4、5-8、9-12、13-14：前两段末尾相同，从第 2 段起拉。
    assert_eq!(segs[0].0, 5);
    let s = scan(&t, col, &files[1..], &me.public());
    assert_eq!(s.fork_point(), Some(9));
    let r = t
        .tx(|t| {
            record_fork(t, col, 9)?;
            rotate_on_fork(t, col, T0 + 50)
        })
        .unwrap()
        .unwrap();
    assert_eq!((r.keep, r.moved.len()), (9, 0));
}

#[test]
fn chains_inside_a_void_are_skipped_so_the_fork_point_only_moves_earlier() {
    let (conn, col) = setup();
    let t = Truth::new(&conn);
    write_own(&t, col, 20);
    let me = t.self_identity(col).unwrap().unwrap();
    let (_, files, _) = clone_location(&t, col, 14, 20, 50);
    // 本机清掉 12..=16（跨过分叉点 15）：12..=15 处本机没有链值，最后确认相同的是 11。
    t.tx(|t| {
        for seq in 12..=16 {
            t.advance_purge(
                col,
                &OpId {
                    device: me.device,
                    seq,
                },
            )?;
        }
        Ok(())
    })
    .unwrap();
    assert_eq!(scan(&t, col, &files, &me.public()).fork_point(), Some(11));
    // 对方清了、本机没清：对方空洞内部不比，区间末相同 = 没有分叉。
    let (conn2, col2) = setup();
    let t2 = Truth::new(&conn2);
    write_own(&t2, col2, 20);
    let me2 = t2.self_identity(col2).unwrap().unwrap();
    let collection = t2.binding(col2).unwrap().unwrap().collection;
    let mut items = own_items(&t2, col2, 1, 8);
    items.push(NativeItem::Void {
        count: 4,
        chain_after: t2.chain_at(col2, &me2.device, 12).unwrap(),
    });
    let (h, bytes) = pack_native(
        collection,
        me2.device,
        1,
        &items,
        CHAIN_ZERO,
        &me2.key(),
        None,
    )
    .unwrap();
    assert_eq!(h.last, 12);
    assert_eq!(scan(&t2, col2, &[bytes], &me2.public()).fork_point(), None);
}

#[test]
fn a_bad_feed_or_record_is_refused() {
    let (conn, col) = setup();
    let t = Truth::new(&conn);
    write_own(&t, col, 6);
    let me = t.self_identity(col).unwrap().unwrap();
    let (_, files, _) = clone_location(&t, col, 6, 6, 10);
    let (h, items) = open_native(&files[0], &me.public(), None).unwrap();
    let mut s = ForkScan::new(&t, col).unwrap();
    let mut wrong = h.clone();
    wrong.device = idn(3, 3);
    let e = s.feed(&t, col, &wrong, &items).unwrap_err();
    assert!(e.contains("fed to"), "{e}");
    let mut short = h.clone();
    short.last += 1;
    let e = s.feed(&t, col, &short, &items).unwrap_err();
    assert!(e.contains("cover"), "{e}");
    let mut tail = h.clone();
    tail.last_chain = [1; 32];
    let e = s.feed(&t, col, &tail, &items).unwrap_err();
    assert!(e.contains("does not end"), "{e}");
    assert_eq!(s.fork_point(), None);
    // 记录里存的身份不是当前身份 = 作废；坏记录报错。
    t.tx(|t| {
        t.conn()
            .execute(
                "INSERT INTO srs_meta (key, value) VALUES (?1, ?2)",
                params![fork_key(col), format!("{}:3", idn(4, 4).text())],
            )
            .map_err(sql)
    })
    .unwrap();
    assert_eq!(recorded_fork(&t, col), Ok(None));
    assert_eq!(rotate_on_fork(&t, col, T0), Ok(None));
    t.tx(|t| {
        t.conn()
            .execute(
                "UPDATE srs_meta SET value = 'x' WHERE key = ?1",
                [fork_key(col)],
            )
            .map_err(sql)
    })
    .unwrap();
    let e = recorded_fork(&t, col).unwrap_err();
    assert!(e.contains("bad fork record"), "{e}");
}

#[test]
fn a_malformed_own_head_is_an_error_not_a_silent_empty_fetch() {
    // 链值对不上、段清单却是空的：以前二分得出空的 Fetch，调用方没东西可拉，分叉被悄悄漏掉。
    let (conn, col) = setup();
    let t = Truth::new(&conn);
    write_own(&t, col, 12);
    let (head, _, _) = clone_location(&t, col, 6, 12, 5);
    assert!(matches!(
        judge_own_head(&t, col, &head),
        Ok(OwnHead::Fetch { .. })
    ));
    let mut bare = head.clone();
    bare.segs = Vec::new();
    let e = judge_own_head(&t, col, &bare).unwrap_err();
    assert!(e.contains("do not cover"), "{e}");
    // 段清单有缺口 / 没覆盖到 seq / 首段不从 1 起，同样报错。
    let mut gap = head.clone();
    gap.segs.remove(1);
    let e = judge_own_head(&t, col, &gap).unwrap_err();
    assert!(e.contains("not contiguous"), "{e}");
    let mut short = head.clone();
    short.segs.pop();
    let e = judge_own_head(&t, col, &short).unwrap_err();
    assert!(e.contains("do not cover"), "{e}");
    let mut late = head.clone();
    late.segs.remove(0);
    let e = judge_own_head(&t, col, &late).unwrap_err();
    assert!(e.contains("not contiguous"), "{e}");
    // 别的设备的畸形 head 不归这里判（按普通设备处理，由解码 / 收段那一层拒）。
    let mut other = bare.clone();
    other.device = idn(1, 1);
    assert_eq!(judge_own_head(&t, col, &other), Ok(OwnHead::Foreign));
}

#[test]
fn recording_a_fork_obeys_the_write_guards() {
    // 会话已毒化（同一事务里前一笔写失败）：分叉记录不许再写进这笔事务。
    let (conn, col) = setup();
    let t = Truth::new(&conn);
    write_own(&t, col, 4);
    let e = t
        .tx(|t| {
            let h = Hlc {
                wall: T0,
                logical: 1,
                device: idn(1, 1),
            };
            assert!(t.set_self_hlc(col + 999, &h).is_err());
            record_fork(t, col, 2)
        })
        .unwrap_err();
    assert!(e.contains("earlier write failed"), "{e}");
    assert_eq!(recorded_fork(&t, col), Ok(None));

    // 别的连接在缓存之后提交过、调用方自己开事务又没 reset：拒写，不落库。
    let dir = std::env::temp_dir().join(format!("fushi-g8-6-fork-{}", Id::random().text()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("srs4.db");
    let a = crate::store::gen4::schema::open(&path).unwrap();
    let b = crate::store::gen4::schema::open(&path).unwrap();
    let ta = Truth::new(&a);
    let col = crate::store::gen4::truth::tests::bound(&ta);
    ta.tx(|t| t.create_self(col, &OWN, &SEED, None, T0))
        .unwrap();
    write_own(&ta, col, 6);
    let tb = Truth::new(&b);
    let me = tb.self_identity(col).unwrap().unwrap();
    assert_eq!(tb.last_of(col, &me.device), Ok(6));
    write_own(&ta, col, 1);
    b.execute_batch("BEGIN IMMEDIATE").unwrap();
    let e = record_fork(&tb, col, 3).unwrap_err();
    assert!(e.contains("another connection committed"), "{e}");
    b.execute_batch("ROLLBACK").unwrap();
    tb.reset();
    assert_eq!(recorded_fork(&tb, col), Ok(None));
    // 经 tx 的正常路径照常写。
    assert_eq!(tb.tx(|t| record_fork(t, col, 3)), Ok(3));
    assert_eq!(recorded_fork(&ta, col), Ok(Some(3)));
    drop((ta, tb));
    drop((a, b));
    let _ = std::fs::remove_dir_all(&dir);
}
