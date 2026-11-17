//! [super]（小段合并）的测试。装置在 `store/gen4/fork_tests.rs`。

use super::*;
use crate::gen4::segment::open_native;
use crate::store::gen4::fork::tests::{T0, body, op, setup, write_own};
use crate::sync2::segment::{CHAIN_ZERO, SEGMENT_MAX_RAW_BYTES};
use crate::sync2::vv::{OpId, Vv};

/// 首尾相接的段清单：边界 [bounds]（各段末 seq），体积都是 [bytes]，链值取自 [chains]（`chains[i]` = seq i+1 处）。
fn cuts(bounds: &[u64], bytes: &[u64], chains: &[Chain]) -> Vec<Cut> {
    let at = |s: u64| {
        if s == 0 {
            CHAIN_ZERO
        } else {
            chains[s as usize - 1]
        }
    };
    let mut out = Vec::new();
    let mut first = 1;
    for (i, &last) in bounds.iter().enumerate() {
        out.push(Cut {
            first,
            last,
            bytes: bytes[i],
            prev_chain: at(first - 1),
            last_chain: at(last),
        });
        first = last + 1;
    }
    out
}

/// 只看体积的段清单（链值按位置编出来，首尾相接）。
fn sized(bytes: &[u64]) -> Vec<Cut> {
    let chains: Vec<Chain> = (0..bytes.len() as u64 * 2)
        .map(|i| [i as u8 + 1; 32])
        .collect();
    let bounds: Vec<u64> = (1..=bytes.len() as u64).map(|i| i * 2).collect();
    cuts(&bounds, bytes, &chains)
}

fn groups(m: &[Merge]) -> Vec<(usize, usize)> {
    m.iter().map(|g| (g.from, g.to)).collect()
}

#[test]
fn the_plan_carries_like_a_binary_counter() {
    const K: u64 = 10 * 1024;
    // 四个同层小段合成一个上一层的；剩下不到四个的不动。
    assert_eq!(groups(&compaction_plan(&sized(&[K; 7]))), vec![(0, 3)]);
    // 十六个：先合成四个上一层的，再进一位合成一个。
    let p = compaction_plan(&sized(&[K; 16]));
    assert_eq!(groups(&p), vec![(0, 15)]);
    assert_eq!(p[0].bytes, 16 * K);
    // 层不同不合：一个已合并的大段后面跟三个小段。
    assert_eq!(
        groups(&compaction_plan(&sized(&[50 * K, K, K, K]))),
        Vec::<(usize, usize)>::new()
    );
    // 满段是一道墙，满段前后各自算。
    let mut b = vec![100u64; 3];
    b.push(COMPACT_FULL);
    b.extend([100; 4]);
    assert_eq!(groups(&compaction_plan(&sized(&b))), vec![(4, 7)]);
    // 合并出来够满段的直接定下。
    let big = COMPACT_FULL / 4 + 1;
    let p = compaction_plan(&sized(&[big, big, big, big, 100]));
    assert!(tier(big) > 0);
    assert_eq!(groups(&p), vec![(0, 3)]);
    assert!(p[0].bytes >= COMPACT_FULL);
}

#[test]
fn the_plan_never_merges_across_a_gap_or_a_broken_chain() {
    let mut c = sized(&[100; 6]);
    c[2].prev_chain = [0xee; 32];
    assert_eq!(groups(&compaction_plan(&c)), vec![(2, 5)]);
    let mut c = sized(&[100; 6]);
    c[2].first += 1;
    assert_eq!(groups(&compaction_plan(&c)), vec![(2, 5)]);
    assert!(compaction_plan(&[]).is_empty());
}

/// 40 条，清掉 15..=18（跨过已发布的切段点 16）与 30。
fn purged_log() -> (rusqlite::Connection, i64, Vec<Chain>) {
    let (conn, col) = setup();
    let chains = {
        let t = Truth::new(&conn);
        let chains = write_own(&t, col, 40);
        let me = t.self_identity(col).unwrap().unwrap();
        t.tx(|t| {
            for seq in (15..=18).chain([30]) {
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
        chains
    };
    (conn, col, chains)
}

fn shape(items: &[NativeItem]) -> Vec<(char, u64)> {
    items
        .iter()
        .map(|i| match i {
            NativeItem::Op(op) => ('o', op.id.seq),
            NativeItem::Void { count, .. } => ('v', *count),
        })
        .collect()
}

#[test]
fn small_segments_are_repacked_into_one_signed_segment_over_the_same_range() {
    let (conn, col, chains) = purged_log();
    let t = Truth::new(&conn);
    let me = t.self_identity(col).unwrap().unwrap();
    let c = cuts(&[8, 16, 24, 32, 40], &[100; 5], &chains);
    for key in [None, Some(CollectionKey([5; 32]))] {
        let out = compact(&t, col, &c, key.as_ref()).unwrap();
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].replaces, vec![(1, 8), (9, 16), (17, 24), (25, 32)]);
        assert_eq!(out[0].segments.len(), 1);
        let (h, bytes) = &out[0].segments[0];
        assert_eq!(
            (
                h.first,
                h.last,
                h.prev_chain,
                h.last_chain,
                h.device,
                h.encrypted
            ),
            (1, 32, CHAIN_ZERO, chains[31], me.device, key.is_some())
        );
        let (h2, items) = open_native(bytes, &me.public(), key.as_ref()).unwrap();
        assert_eq!(&h2, h);
        let mut want: Vec<(char, u64)> = (1..=14).map(|s| ('o', s)).collect();
        want.push(('v', 4));
        want.extend((19..=29).map(|s| ('o', s)));
        want.push(('v', 1));
        want.extend([('o', 31), ('o', 32)]);
        assert_eq!(shape(&items), want);
        // 空洞带的是区间末的完整链值。
        assert!(items.contains(&NativeItem::Void {
            count: 4,
            chain_after: chains[17],
        }));
        if key.is_some() {
            assert!(open_native(bytes, &me.public(), None).is_err());
        }
    }
    // 只读：不改库。
    assert_eq!(t.audit(col), Ok(40));
}

#[test]
fn a_void_crossing_the_range_edge_is_cut_there_with_the_published_chain() {
    let (conn, col, chains) = purged_log();
    let t = Truth::new(&conn);
    let me = t.self_identity(col).unwrap().unwrap();
    let collection = t.binding(col).unwrap().unwrap().collection;
    // 1..=16：15..=18 的空洞截成 15、16 两条，区间末链值 = 已发布的 16 处的链值（本机库里已经没有）。
    let p = recut(&t, col, 1, 16, &CHAIN_ZERO, &chains[15], u64::MAX).unwrap();
    assert_eq!(p.len(), 1);
    assert_eq!(
        p[0].items.last(),
        Some(&NativeItem::Void {
            count: 2,
            chain_after: chains[15],
        })
    );
    // 17..=24：开头是 17、18 两条空洞，接着 19 起的操作。
    let q = recut(&t, col, 17, 24, &chains[15], &chains[23], u64::MAX).unwrap();
    assert_eq!(
        q[0].items.first(),
        Some(&NativeItem::Void {
            count: 2,
            chain_after: chains[17],
        })
    );
    for piece in p.iter().chain(&q) {
        let (_, bytes) = pack_native(
            collection,
            me.device,
            piece.first,
            &piece.items,
            piece.prev_chain,
            &me.key(),
            None,
        )
        .unwrap();
        let (h, _) = open_native(&bytes, &me.public(), None).unwrap();
        assert_eq!(
            (h.first, h.last, h.last_chain),
            (piece.first, piece.last, piece.last_chain)
        );
    }
}

#[test]
fn a_small_target_cuts_where_the_chain_is_known_and_the_pieces_link_up() {
    let (conn, col, chains) = purged_log();
    let t = Truth::new(&conn);
    let me = t.self_identity(col).unwrap().unwrap();
    let p = recut(&t, col, 1, 40, &CHAIN_ZERO, &chains[39], 300).unwrap();
    assert!(p.len() > 3);
    let mut next = (1u64, CHAIN_ZERO);
    for piece in &p {
        assert_eq!((piece.first, piece.prev_chain), next);
        assert!(!piece.items.is_empty());
        let span: u64 = piece.items.iter().map(NativeItem::span).sum();
        assert_eq!(span, piece.last - piece.first + 1);
        let collection = t.binding(col).unwrap().unwrap().collection;
        let (h, bytes) = pack_native(
            collection,
            me.device,
            piece.first,
            &piece.items,
            piece.prev_chain,
            &me.key(),
            None,
        )
        .unwrap();
        open_native(&bytes, &me.public(), None).unwrap();
        assert_eq!(h.last_chain, piece.last_chain);
        next = (piece.last + 1, piece.last_chain);
    }
    assert_eq!(next, (41, chains[39]));
    // 目标体积太小、切出的段不比原来少：这一组不合并。
    let c = cuts(&[8, 16, 24, 32, 40], &[100; 5], &chains);
    assert!(
        compact_to(&t, col, &c, None, 300, SEGMENT_MAX_RAW_BYTES)
            .unwrap()
            .is_empty()
    );
    // 目标够大：合成更少的几段。
    let out = compact_to(&t, col, &c, None, 1500, SEGMENT_MAX_RAW_BYTES).unwrap();
    assert_eq!(out.len(), 1);
    assert!(out[0].segments.len() < 4);
    assert_eq!(out[0].segments.last().unwrap().0.last_chain, chains[31]);
}

/// 压缩后放得下、未压缩估计体积超过上限的整组不打成一段（K2 根治复核：读侧按 MAX_BODY_RAW 拒解压后过大的段，
/// 写侧不能只看压缩后体积），按上限切成几段，每段都在上限内、首尾相接。
#[test]
fn a_group_that_compresses_small_but_is_large_uncompressed_is_cut() {
    let (conn, col, chains) = purged_log();
    let t = Truth::new(&conn);
    let c = cuts(&[8, 16, 24, 32, 40], &[100; 5], &chains);
    // 压缩后的目标很宽松：不看未压缩体积时整组是一段。
    let loose = compact_to(&t, col, &c, None, 1 << 20, SEGMENT_MAX_RAW_BYTES).unwrap();
    assert_eq!(loose.len(), 1);
    assert_eq!(loose[0].segments.len(), 1);
    let max_raw = 1500;
    let out = compact_to(&t, col, &c, None, 1 << 20, max_raw).unwrap();
    assert_eq!(out.len(), 1);
    assert!(out[0].segments.len() > 1);
    let me = t.self_identity(col).unwrap().unwrap();
    let mut next = (1u64, CHAIN_ZERO);
    for (h, bytes) in &out[0].segments {
        assert_eq!((h.first, h.prev_chain), next);
        let (_, items) = open_native(bytes, &me.public(), None).unwrap();
        let raw: u64 = items.iter().map(item_bytes).sum();
        let last = items.last().map_or(0, item_bytes);
        assert!(
            raw - last < max_raw,
            "a piece closes once it reaches the limit"
        );
        next = (h.last + 1, h.last_chain);
    }
    assert_eq!(next.1, chains[31]);
}

#[test]
fn neighbouring_voids_of_different_origin_become_one_void_slot() {
    let (conn, col) = setup();
    let t = Truth::new(&conn);
    let me = t.self_identity(col).unwrap().unwrap();
    let chains = write_own(&t, col, 5);
    // 6..=8 是收来的空洞（标志 0），5 是本机清的（本机推进位）：库里是两个相邻区间。
    let chain8 = [0x42; 32];
    t.tx(|t| {
        t.append_native_void(col, &me.device, 3, &chain8)?;
        t.append_native(col, &op(me.device, 9, &body(9, 0), Vv::new()))?;
        t.advance_purge(
            col,
            &OpId {
                device: me.device,
                seq: 5,
            },
        )?;
        Ok(())
    })
    .unwrap();
    let tail = t.chain_at(col, &me.device, 9).unwrap();
    let p = recut(&t, col, 1, 9, &CHAIN_ZERO, &tail, u64::MAX).unwrap();
    assert_eq!(
        shape(&p[0].items),
        vec![('o', 1), ('o', 2), ('o', 3), ('o', 4), ('v', 4), ('o', 9)]
    );
    assert_eq!(chains.len(), 5);
    let collection = t.binding(col).unwrap().unwrap().collection;
    pack_native(
        collection,
        me.device,
        1,
        &p[0].items,
        CHAIN_ZERO,
        &me.key(),
        None,
    )
    .unwrap();
}

#[test]
fn a_range_that_disagrees_with_the_published_segments_is_refused() {
    let (conn, col, chains) = purged_log();
    let t = Truth::new(&conn);
    let e = recut(&t, col, 1, 8, &CHAIN_ZERO, &chains[6], u64::MAX).unwrap_err();
    assert!(e.contains("disagrees"), "{e}");
    let e = recut(&t, col, 9, 16, &chains[6], &chains[15], u64::MAX).unwrap_err();
    assert!(e.contains("disagrees"), "{e}");
    let e = recut(&t, col, 33, 41, &chains[31], &chains[39], u64::MAX).unwrap_err();
    assert!(e.contains("does not hold"), "{e}");
    let e = recut(&t, col, 5, 4, &chains[3], &chains[3], u64::MAX).unwrap_err();
    assert!(e.contains("empty range"), "{e}");
    // compact 把错误原样交回，不产出半截。
    let mut c = cuts(&[8, 16, 24, 32], &[100; 4], &chains);
    c[3].last_chain = [9; 32];
    assert!(
        compact(&t, col, &c, None)
            .unwrap_err()
            .contains("disagrees")
    );
    let _ = T0;
}
