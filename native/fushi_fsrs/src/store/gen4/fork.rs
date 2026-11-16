//! 本机身份分叉的检测（设计 §3.3、§4.2「身份分叉的检测与换身份重签发」；G8-6）。没有调用方：同步轮（G8-7）接线。
//!
//! 同一个身份出现在两个安装里（数据目录被拷到另一台机器、从整机备份还原后两边都在用），两边会在同一个 seq 上写出
//! 不同的操作。协议 3 用链值发现这种情况（`store/sync2/transport.rs` 的 `plan` / `own_fork_files` / `deliver_prepared`），
//! 换身份重签发（`rotate`）。协议 4 机制不变（§4.2），这里是新代的实现：
//!
//! 1. [judge_own_head]：位置上读到一份**本机当前身份**的 head（同集合、同设备 ID）。
//!    - 公钥不是本机的：别的钥匙冒用本机身份——不是分叉，是注入，拒收（[OwnHead::Impostor]）。
//!    - head 是本机日志的前缀（它的 `seq` 处的链值与本机相同）：没事（[OwnHead::Prefix]）。
//!    - 之前已经找到过分叉点（[recorded_fork]，收段被打断过）：不再拉段，直接换身份（[OwnHead::Known]）。
//!    - 否则要拉段逐条比（[OwnHead::Fetch]）：段清单按 seq 升序，前面链尾标签与本机相同的是共同前缀（链是哈希链，
//!      一旦分开就不会再相同，可以二分）；从第一处不同的**前一段**起拉（标签只有 4 字节，多拉一段兜住标签碰撞）。
//! 2. [ForkScan]：把拉来的本机身份的段（调用方已用本机公钥验过签）逐条与本机日志比链值，得出分叉点 `keep` =
//!    两边链值确认相同的最大 seq（[ForkScan::fork_point]）。空洞内部没有链值，那里的比较跳过；所以 `keep` 可能比真正的
//!    分叉点靠前——这是安全方向（换身份时多重签发几条两边共有的操作，不会把两边不同的操作留在旧身份下）。
//!    远端比本机多出的 seq 也算「不同」：另一个安装在本机的末尾之后接着写了（例如本机从旧备份还原），`keep` = 本机末尾、
//!    什么都不用搬，只换身份。
//! 3. [record_fork]：分叉点存进 `srs_meta`（`gen4_fork_at/<col>` = `<设备>:<keep>`，多次找到取最小），收段会话被打断后
//!    下一轮不必重拉；身份变了自动作废。[rotate_on_fork] 在全部远端操作投递之后换身份（`Truth::rotate_identity`
//!    会删掉这条记录）。
//!
//! 换身份之后旧身份冻结在 `keep`，另一个安装在它下面写的操作按普通设备收：新代的 `Truth::append_native` 从 `keep` 处的
//! 链值接着验。

use rusqlite::OptionalExtension;

use super::schema::sql;
use super::truth::{NativeStep, Rotated, Truth, fork_key};
use crate::gen4::head::Head4;
use crate::gen4::op::chain_next4;
use crate::gen4::segment::{NativeHeader, NativeItem};
use crate::sync2::id::Id;
use crate::sync2::segment::{Chain, chain_tag};

/// [judge_own_head] 的结论。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OwnHead {
    /// 不是本机当前身份的 head（别的设备、别的集合、本机换身份之前的旧身份）：按普通设备处理。
    Foreign,
    /// 本机的设备 ID、别的公钥：冒名，拒收。
    Impostor,
    /// 是本机日志的前缀：没有分叉。
    Prefix,
    /// 可能分叉：拉这些段（`(first, last, 链尾标签)`，head 里的原样）交给 [ForkScan]。
    Fetch { segs: Vec<(u64, u64, String)> },
    /// 之前已经找到分叉点：不再拉，直接 [rotate_on_fork]。
    Known { keep: u64 },
}

/// 看一份位置上的 head 是不是本机身份分叉了。只读。
///
/// 同一个身份在位置上可能有好几份 head（两个安装各写各的）：调用方（G8-7 的同步轮）要让**每一份**本机设备 ID 的
/// head 都过一遍，只判一份会漏掉分叉。段清单不首尾相接、不覆盖 `1..=seq` 的畸形 head 报错（`Head4` 的解码器会拒，
/// 这里防的是不经解码器构造的值）：段清单为空时二分没东西可拉，分叉会被悄悄漏掉。
pub fn judge_own_head(t: &Truth<'_>, col: i64, h: &Head4) -> Result<OwnHead, String> {
    let me = t
        .self_identity(col)?
        .ok_or_else(|| format!("gen4 fork: collection {col} has no local identity"))?;
    let binding = t
        .binding(col)?
        .ok_or_else(|| format!("gen4 fork: no collection {col}"))?;
    if h.collection != binding.collection || h.device != me.device {
        return Ok(OwnHead::Foreign);
    }
    if h.public != me.public() {
        return Ok(OwnHead::Impostor);
    }
    check_segs(h)?;
    if let Some(keep) = recorded_fork(t, col)? {
        return Ok(OwnHead::Known { keep });
    }
    if t.chain_held(col, &me.device, h.seq)? == Some(h.chain) {
        return Ok(OwnHead::Prefix);
    }
    let same = |i: usize| -> Result<bool, String> {
        let (_, b, tag) = &h.segs[i];
        Ok(t.chain_held(col, &me.device, *b)?
            .is_some_and(|ours| chain_tag(&ours) == *tag))
    };
    // 二分：same(i) 为真 ⇒ 第 i 段末尾之前两边相同（哈希链）。不知道链值（空洞内部）当作不同，只会多拉。
    let (mut lo, mut hi) = (0usize, h.segs.len());
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        if same(mid)? {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    Ok(OwnHead::Fetch {
        segs: h.segs[lo.saturating_sub(1)..].to_vec(),
    })
}

/// 段清单必须首尾相接、覆盖 `1..=seq`（与 `Head4` 解码器同一判据）。
fn check_segs(h: &Head4) -> Result<(), String> {
    let mut next = 1u64;
    for &(a, b, _) in &h.segs {
        if a != next || b < a {
            return Err("gen4 fork: head segs are not contiguous".to_owned());
        }
        next = b + 1;
    }
    if next != h.seq + 1 {
        return Err("gen4 fork: head segs do not cover its seq".to_owned());
    }
    Ok(())
}

/// 逐条比本机身份的段与本机日志的链值。
#[derive(Clone, Debug)]
pub struct ForkScan {
    device: Id,
    /// 两边链值确认相同的最大 seq。
    agree: Option<u64>,
    /// 两边确认不同（含远端有、本机没有）的最小 seq。
    differ: Option<u64>,
}

impl ForkScan {
    /// 为本机当前身份开一次比较。
    pub fn new(t: &Truth<'_>, col: i64) -> Result<ForkScan, String> {
        let me = t
            .self_identity(col)?
            .ok_or_else(|| format!("gen4 fork: collection {col} has no local identity"))?;
        Ok(ForkScan {
            device: me.device,
            agree: None,
            differ: None,
        })
    }

    fn note(&mut self, seq: u64, local_last: u64, ours: Option<Chain>, theirs: Option<Chain>) {
        if seq > local_last {
            self.differ = Some(self.differ.map_or(seq, |d| d.min(seq)));
            return;
        }
        if let (Some(a), Some(b)) = (ours, theirs) {
            if a == b {
                self.agree = Some(self.agree.map_or(seq, |x| x.max(seq)));
            } else {
                self.differ = Some(self.differ.map_or(seq, |d| d.min(seq)));
            }
        }
    }

    /// 喂一段（调用方已用本机公钥验过签、解出了全部槽）。段可以按任意顺序、重复地喂。
    pub fn feed(
        &mut self,
        t: &Truth<'_>,
        col: i64,
        header: &NativeHeader,
        items: &[NativeItem],
    ) -> Result<(), String> {
        if header.device != self.device {
            return Err(format!(
                "gen4 fork: segment of {} fed to the fork scan of {}",
                header.device, self.device
            ));
        }
        let span: u64 = items.iter().map(NativeItem::span).sum();
        if header.first == 0 || span != header.last - header.first + 1 {
            return Err("gen4 fork: segment items do not cover its range".to_owned());
        }
        let local_last = t.last_of(col, &self.device)?;
        // 本机这一段的链值：下标 i ↔ seq = first - 1 + i。
        let upto = header.last.min(local_last);
        let mut ours: Vec<Option<Chain>> = Vec::new();
        let mut cur = t.chain_held(col, &self.device, header.first - 1)?;
        if header.first - 1 <= local_last {
            ours.push(cur);
        }
        t.native_walk(col, &self.device, header.first, upto, |step| {
            match step {
                NativeStep::Op(op) => {
                    cur = cur.map(|c| chain_next4(&c, &op));
                    ours.push(cur);
                }
                NativeStep::Void {
                    first,
                    last,
                    end,
                    chain_after,
                } => {
                    for _ in first..last {
                        ours.push(None);
                    }
                    cur = (last == end).then_some(chain_after);
                    ours.push(cur);
                }
            }
            Ok(())
        })?;
        let at = |seq: u64| -> Option<Chain> {
            ours.get((seq - (header.first - 1)) as usize)
                .copied()
                .flatten()
        };
        let mut theirs = header.prev_chain;
        let mut seq = header.first - 1;
        self.note(seq, local_last, at(seq), Some(theirs));
        for item in items {
            match item {
                NativeItem::Op(op) => {
                    if op.id.device != self.device || op.id.seq != seq + 1 {
                        return Err("gen4 fork: segment op out of place".to_owned());
                    }
                    theirs = chain_next4(&theirs, op);
                    seq += 1;
                    self.note(seq, local_last, at(seq), Some(theirs));
                }
                NativeItem::Void { count, chain_after } => {
                    for _ in 1..*count {
                        seq += 1;
                        self.note(seq, local_last, at(seq), None);
                    }
                    theirs = *chain_after;
                    seq += 1;
                    self.note(seq, local_last, at(seq), Some(theirs));
                }
            }
        }
        if theirs != header.last_chain {
            return Err("gen4 fork: segment chain does not end at its header".to_owned());
        }
        Ok(())
    }

    /// 分叉点：找到了不同之处时，两边确认相同的最大 seq（比不同之处靠前；一处都没确认 = 0）。没找到不同 = None。
    pub fn fork_point(&self) -> Option<u64> {
        let differ = self.differ?;
        Some(self.agree.filter(|a| *a < differ).unwrap_or(0))
    }
}

fn parse_record(v: &str) -> Option<(Id, u64)> {
    let (d, k) = v.split_once(':')?;
    let device = Id::parse(d)?;
    (device.text() == d).then_some(())?;
    Some((device, k.parse().ok()?))
}

/// 记下本机当前身份的分叉点（已有记录的取较小者）。返回记下的值。必须在事务里。
///
/// 与本模块其它写入同一套纪律（`Truth::write` 的守卫）：会话已毒化、或别的连接在缓存之后提交过，都拒写。
pub fn record_fork(t: &Truth<'_>, col: i64, keep: u64) -> Result<u64, String> {
    t.record_fork_point(col, keep)
}

/// 本机当前身份记着的分叉点（没有、或记的是换身份之前的旧身份 = None）。
pub fn recorded_fork(t: &Truth<'_>, col: i64) -> Result<Option<u64>, String> {
    let Some(me) = t.self_identity(col)? else {
        return Ok(None);
    };
    let v: Option<String> = t
        .conn()
        .prepare_cached("SELECT value FROM srs_meta WHERE key = ?1")
        .map_err(sql)?
        .query_row([fork_key(col)], |r| r.get(0))
        .optional()
        .map_err(sql)?;
    let Some(v) = v else {
        return Ok(None);
    };
    let (device, keep) =
        parse_record(&v).ok_or_else(|| format!("gen4 fork: bad fork record {v:?}"))?;
    Ok((device == me.device).then_some(keep))
}

/// 有记着的分叉点就换身份（同步轮在全部远端操作投递之后调）。没有 = None。
pub fn rotate_on_fork(t: &Truth<'_>, col: i64, now: i64) -> Result<Option<Rotated>, String> {
    t.tx(|t| match recorded_fork(t, col)? {
        // 记录的分叉点不超过本机末尾（[ForkScan] 只在本机有的 seq 上记「相同」，本机日志只有换身份会截短，而换身份
        // 删掉这条记录）；真超了 `rotate_identity_report` 报错，不压。
        Some(keep) => t.rotate_identity_report(col, keep, now).map(Some),
        None => Ok(None),
    })
}

#[cfg(test)]
#[path = "fork_tests.rs"]
pub(crate) mod tests;
