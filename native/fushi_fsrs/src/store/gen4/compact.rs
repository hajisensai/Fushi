//! 本机原生段的小段合并（设计 §4.1「按体积切段、分层合并」、§4.2 机制不变；G8-6）。没有调用方：G8-4 的段清单与
//! 同步轮（G8-7）接线。
//!
//! 协议 3 的做法（`store/sync2/transport.rs` 的 `compaction_plan` / `compact_segments`）原样搬到新代：每轮同步切出的
//! 小段按体积分层（[COMPACT_BASE] 起每 [COMPACT_FANOUT] 倍一层），同层相邻攒够 [COMPACT_FANOUT] 个就合成一个更高层
//! 的段——像二进制进位，本机的段数始终是「满段 + 每层不到几个」，每条操作一生只被重写对数次；满段（≥ [COMPACT_FULL]）
//! 不再动。合并 = 同一 seq 区间、同样的操作重新打包、重新签名，名字随之变化。
//!
//! 新代与协议 3 不同的两处：
//!
//! - **空洞**：原生段里已清除的区间是空洞槽，只带区间末的链值。本机库里相邻的清除会并成一个区间、中间的链值不留，
//!   所以切点只能落在链值已知的地方（一条操作之后，或一个空洞区间的末尾）；合并组的首尾是已发布段的边界，链值由
//!   调用方从段头给（[Cut::prev_chain] / [Cut::last_chain]），一个空洞区间跨出合并组末尾时，截下来的那一截的
//!   `chain_after` 就是组末的 `last_chain`（与段格式「空洞在段边界处截断」同一规则，`gen4/segment.rs` 文件头）。
//! - **核对**：重新打包时从组首的 `prev_chain` 沿本机日志折出的链值必须正好落在组末的 `last_chain` 上，组首处本机
//!   知道链值的也要相等；对不上 = 本机日志与已发布的段不一致（不该发生），报错、不产出——绝不签出一份与位置上的
//!   旧段内容不同、却占同一 seq 区间的新段。
//!
//! 只产出新段的字节，不改任何表：位置上的「要重传 / 待删」登记、段清单的替换由 G8-4 的段清单在同一个事务里做
//! （协议 3 的 `sync2_rewrites` / `sync2_obsolete` 规则不变）。
//!
//! 体积：分层看的是段文件的实际字节（[Cut::bytes]）。重新切段时按未压缩的估计体积切（[item_bytes]，压缩后只会更小），
//! 合并组整段打包能放进 [SEGMENT_TARGET_BYTES] 的就打成一段；放不进才按估计体积切成几段，切出的段数不少于原来的段数
//! 时这一组不合并（与协议 3 相同）。

use super::truth::{NativeStep, Truth};
use crate::gen4::op::chain_next4;
use crate::gen4::segment::{NativeHeader, NativeItem, pack_native};
use crate::sync2::keys::CollectionKey;
use crate::sync2::segment::{Chain, SEGMENT_MAX_RAW_BYTES, SEGMENT_TARGET_BYTES};

/// 同层攒够几个相邻小段就合并。
pub const COMPACT_FANOUT: usize = 4;
/// 第一层的体积下限。
pub const COMPACT_BASE: u64 = 16 * 1024;
/// 满段：不再参与合并。
pub const COMPACT_FULL: u64 = SEGMENT_TARGET_BYTES / 2;

/// 本机已发布的一个原生段（段清单里的一行）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Cut {
    pub first: u64,
    pub last: u64,
    /// 段文件的字节数。
    pub bytes: u64,
    /// 段头的 `prev_chain` / `last_chain`。
    pub prev_chain: Chain,
    pub last_chain: Chain,
}

/// 一组要合并的相邻段：`cuts[from..=to]`，体积之和 [Merge::bytes]。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Merge {
    pub from: usize,
    pub to: usize,
    pub bytes: u64,
}

fn tier(bytes: u64) -> u32 {
    let mut t = 0;
    let mut floor = COMPACT_BASE;
    while bytes >= floor {
        t += 1;
        floor = floor.saturating_mul(COMPACT_FANOUT as u64);
    }
    t
}

/// 只看体积定出要合并的组（每组 ≥ 2 个相邻段），不读操作。[cuts] 按 seq 升序；不首尾相接（seq 有缺口或链值接不上）
/// 的两段之间是一道墙，不跨墙合并。
pub fn compaction_plan(cuts: &[Cut]) -> Vec<Merge> {
    fn flush(stack: &mut Vec<Merge>, merges: &mut Vec<Merge>) {
        merges.extend(stack.drain(..).filter(|g| g.to > g.from));
    }
    let mut merges = Vec::new();
    let mut stack: Vec<Merge> = Vec::new();
    for (i, c) in cuts.iter().enumerate() {
        let joined = i > 0 && {
            let p = &cuts[i - 1];
            c.first == p.last + 1 && c.prev_chain == p.last_chain
        };
        if !joined {
            flush(&mut stack, &mut merges);
        }
        if c.bytes >= COMPACT_FULL {
            flush(&mut stack, &mut merges);
            continue;
        }
        stack.push(Merge {
            from: i,
            to: i,
            bytes: c.bytes,
        });
        while stack.len() >= COMPACT_FANOUT {
            let n = stack.len();
            let t = tier(stack[n - 1].bytes);
            if !stack[n - COMPACT_FANOUT..]
                .iter()
                .all(|g| tier(g.bytes) == t)
            {
                break;
            }
            let group: Vec<Merge> = stack.drain(n - COMPACT_FANOUT..).collect();
            let merged = Merge {
                from: group[0].from,
                to: group[group.len() - 1].to,
                bytes: group.iter().map(|g| g.bytes).sum(),
            };
            if merged.bytes >= COMPACT_FULL {
                merges.push(merged);
                flush(&mut stack, &mut merges);
                break;
            }
            stack.push(merged);
        }
    }
    flush(&mut stack, &mut merges);
    merges
}

/// 一项在段体里的估计体积（未压缩：载荷 + 信封与依赖的上界）。
pub fn item_bytes(item: &NativeItem) -> u64 {
    match item {
        NativeItem::Op(op) => op.payload.len() as u64 + 24 + 20 * op.deps.0.len() as u64,
        NativeItem::Void { .. } => 48,
    }
}

/// 重新切出的一段（还没签名）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Piece {
    pub first: u64,
    pub last: u64,
    pub prev_chain: Chain,
    pub last_chain: Chain,
    pub items: Vec<NativeItem>,
}

/// 把本机身份原生日志的 `first..=last` 按估计体积 [target] 切成首尾相接的几段（一段至少一项）。[prev_chain] /
/// [last_chain] 是这一区间两端已发布的链值，与本机日志对不上就报错（文件头「核对」）。
pub fn recut(
    t: &Truth<'_>,
    col: i64,
    first: u64,
    last: u64,
    prev_chain: &Chain,
    last_chain: &Chain,
    target: u64,
) -> Result<Vec<Piece>, String> {
    let me = t
        .self_identity(col)?
        .ok_or_else(|| format!("gen4 compact: collection {col} has no local identity"))?;
    let device = me.device;
    if first == 0 || last < first {
        return Err("gen4 compact: empty range".to_owned());
    }
    if t.last_of(col, &device)? < last {
        return Err(format!(
            "gen4 compact: {device} log ends before {last}; cannot recut a range it does not hold"
        ));
    }
    if let Some(ours) = t.chain_known(col, &device, first - 1)? {
        if ours != *prev_chain {
            return Err(format!(
                "gen4 compact: local chain at {} disagrees with the published segment",
                first - 1
            ));
        }
    }
    let mut pieces: Vec<Piece> = Vec::new();
    let mut cur = Piece {
        first,
        last: first - 1,
        prev_chain: *prev_chain,
        last_chain: *prev_chain,
        items: Vec::new(),
    };
    let mut est = 0u64;
    let mut chain = *prev_chain;
    t.native_walk(col, &device, first, last, |step| {
        let (item, end) = match step {
            NativeStep::Op(op) => {
                chain = chain_next4(&chain, &op);
                let seq = op.id.seq;
                (NativeItem::Op(op), seq)
            }
            NativeStep::Void {
                first: a,
                last: b,
                end,
                chain_after,
            } => {
                chain = if b == end {
                    chain_after
                } else if b == last {
                    *last_chain
                } else {
                    return Err("gen4 compact: void run clipped inside the range".to_owned());
                };
                (
                    NativeItem::Void {
                        count: b - a + 1,
                        chain_after: chain,
                    },
                    b,
                )
            }
        };
        // 段里相邻的两个空洞槽必须合并（段格式只有一种字节形）：本机两个区间标志不同才会分开存。
        if let (
            NativeItem::Void { count, chain_after },
            Some(NativeItem::Void {
                count: c0,
                chain_after: a0,
            }),
        ) = (&item, cur.items.last_mut())
        {
            *c0 += count;
            *a0 = *chain_after;
        } else {
            est += item_bytes(&item);
            cur.items.push(item);
        }
        cur.last = end;
        cur.last_chain = chain;
        if est >= target {
            let next = Piece {
                first: end + 1,
                last: end,
                prev_chain: chain,
                last_chain: chain,
                items: Vec::new(),
            };
            pieces.push(std::mem::replace(&mut cur, next));
            est = 0;
        }
        Ok(())
    })?;
    if !cur.items.is_empty() {
        pieces.push(cur);
    }
    if pieces.last().map(|p| p.last) != Some(last) {
        return Err("gen4 compact: recut did not reach the end of the range".to_owned());
    }
    if chain != *last_chain {
        return Err(format!(
            "gen4 compact: local chain at {last} disagrees with the published segment"
        ));
    }
    Ok(pieces)
}

/// 一组合并的结果：替换掉 [Compacted::replaces] 这些段的新段（头 + 文件字节）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Compacted {
    /// 被替换的段 `(first, last)`，按 seq 升序。
    pub replaces: Vec<(u64, u64)>,
    pub segments: Vec<(NativeHeader, Vec<u8>)>,
}

/// 按 [compaction_plan] 合并本机当前身份的小段：每组重新切段、用本机钥匙签名（[key] = 位置密钥，明文位置 None）。
/// 切出的段数不少于原来的组不产出。只读库、不改表。
pub fn compact(
    t: &Truth<'_>,
    col: i64,
    cuts: &[Cut],
    key: Option<&CollectionKey>,
) -> Result<Vec<Compacted>, String> {
    compact_to(
        t,
        col,
        cuts,
        key,
        SEGMENT_TARGET_BYTES,
        SEGMENT_MAX_RAW_BYTES,
    )
}

/// [compact]，段的目标体积是 [target]、整组打一段时的未压缩估计体积上限是 [max_raw]（测试用小值走「切了几段、
/// 不比原来少就不合并」与「压缩后放得下、解压后太大」那两条路）。
fn compact_to(
    t: &Truth<'_>,
    col: i64,
    cuts: &[Cut],
    key: Option<&CollectionKey>,
    target: u64,
    max_raw: u64,
) -> Result<Vec<Compacted>, String> {
    let me = t
        .self_identity(col)?
        .ok_or_else(|| format!("gen4 compact: collection {col} has no local identity"))?;
    let collection = t
        .binding(col)?
        .ok_or_else(|| format!("gen4 compact: no collection {col}"))?
        .collection;
    let signer = me.key();
    let mut out = Vec::new();
    for m in compaction_plan(cuts) {
        let group = &cuts[m.from..=m.to];
        let (a, b) = (group[0].first, group[group.len() - 1].last);
        let (pc, lc) = (group[0].prev_chain, group[group.len() - 1].last_chain);
        let pack = |p: &Piece| {
            pack_native(
                collection,
                me.device,
                p.first,
                &p.items,
                p.prev_chain,
                &signer,
                key,
            )
        };
        // 先整组打成一段；放不进目标体积才按估计体积切。整组的未压缩估计体积也要在 [max_raw] 内：重复度高的内容
        // 压缩比能到上百倍，只看压缩后体积会打出解压后超过读侧上限（[crate::gen4::segment::MAX_BODY_RAW]）的段。
        let whole = recut(t, col, a, b, &pc, &lc, u64::MAX)?;
        let whole_raw: u64 = whole[0].items.iter().map(item_bytes).sum();
        let one = if whole_raw <= max_raw {
            Some(pack(&whole[0])?)
        } else {
            None
        };
        let segments = if let Some(one) = one.filter(|o| o.1.len() as u64 <= target) {
            vec![one]
        } else {
            let pieces = recut(t, col, a, b, &pc, &lc, target.min(max_raw))?;
            if pieces.len() >= group.len() {
                continue;
            }
            pieces.iter().map(pack).collect::<Result<Vec<_>, _>>()?
        };
        out.push(Compacted {
            replaces: group.iter().map(|c| (c.first, c.last)).collect(),
            segments,
        });
    }
    Ok(out)
}

#[cfg(test)]
#[path = "compact_tests.rs"]
mod tests;
