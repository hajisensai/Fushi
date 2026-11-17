//! 承袭上传（设计 §6.2 第 2 步，D19 / D20；规划 §2.1 的 G8-5）：本机持有的承袭日志里，位置上还缺的区间打成承袭段
//! （`hrt-…`，`FSH4`，本机签名）传上去。还没有调用方（第一段）：同步轮（G8-7）列出位置上的承袭段、交给 [Uploader::see]，
//! 再按 [Uploader::plan] 逐段 [Uploader::pack] 写到 `v4/devices/<本机>/` 下。**先传承袭段、再传本机的原生段**（§6.2 第 2 步）
//! 由同步轮保证：这样位置上任何原生操作依赖的承袭操作一定也在位置上；[UploadPlan::blocked] 非空时这一点做不到，
//! 同步轮要把它报出来。
//!
//! # 只替本机信任的作者上传（G10-4，D20 的另一半）
//!
//! 收承袭段的设备只看上传者信不信（D20，`receive.rs`），段里各作者的操作按上传者担保收下、在收方没有信任行（=
//! 可信）；段头还带上传者记着的作者公钥（`author_key`），收方据此登记，之后旧根上这位作者的 head 是「已认识的设备」，
//! 换了钥匙的冒充者公钥对不上（G10-4 第四轮，`truth/trust.rs` 文件头）。
//! 所以上传者只能担保**自己信任的**作者：承袭日志的作者在本机是待确认 / 已拒绝（[vouches_for] 为假）的，这一轮整条
//! 不传、也不算进对账（[Uploader::open]、`cmd/sync_oldroot.rs` 的指纹），否则这位作者在本机被扣住的删除与彻底清除
//! 会经承袭段在别的设备上照常执行，首次信任只挡住了读旧根的那一台。本机确认它之后指纹变了，下一轮照常补传。
//!
//! 没传的作者别的设备照样拿得到：它的段还在旧根上，收方捡旧根时（位置上没有承袭段覆盖它）自己读它的 head、自己做
//! 首次信任。本机原生操作依赖这位作者的操作时，收方先把本机的操作放在等待缓冲里，捡完旧根就接上。已经传上去之后
//! 本机才改成不信任的，位置上那份收不回（同新代原生段：信任是各设备本机的事）。
//!
//! 所以文件头第一段「位置上任何原生操作依赖的承袭操作一定也在位置上」对待确认作者**有意不成立**：那部分只在旧根上。
//! 旧根因此不能先于下面任一条退役（清空、删除、不再可读）：所有设备都捡完了旧根，或者每台设备上都没有待确认 /
//! 已拒绝的承袭作者（确认了的下一轮会补传）。`cmd/sync_oldroot.rs` `heritage_plan` 的回包 `unvouched` 列出本机因作者
//! 不受信而不替传的承袭日志，同步页据此提示用户先处理这些设备。
//!
//! # 位置上「有」是什么意思
//!
//! 位置上的一个承袭段只有在下面都成立时才算进位置的现状（[Uploader::see] 答 [Seen::Counted]），否则它覆盖的区间一律按
//! 「位置上没有」处理、本机照传自己的一份：
//!
//! - 文件名就是段头算出来的名字、放在上传者自己的目录（`devices/<上传者>/hrt-…`）；
//! - 上传者是本机，或是本机记过公钥、信任的设备（D20：不受信上传者的承袭段留在位置上不收，那它也不能替本机「补过」
//!   这一段——不信任它的设备收不到这份，本机不传就没人有）；
//! - 签名、加密状态（加密位置上的明文件一律不算，BUG-4299 口径）、整段覆盖区间都对。
//!
//! 一个 seq 算「位置上有了」（满足）要求同一个链指纹（同一支：分叉的另一支不能替本机这一支）、而且**位置上那份不比
//! 本机的靠前**（完整 < 空洞 < 副本记录，设计 §3.2）：本机已经清成空洞的，位置上只有完整内容不算满足，要把空洞传上去，
//! 让位置上留靠后的一份；反过来位置上已是空洞、本机还是完整内容（本机不执行那条 Purge），算满足、**不把原文重新传上去**
//! （设计 §10 第 3 条）。
//!
//! # 只补缺口，同号槽只降不升（D19）
//!
//! - 只补没满足的 seq：缺口向外扩到最近的切点（下一节）再切段，扩出来的部分与位置上已有的重叠，读者按「已有」幂等收。
//! - 本机自己已传的段：位置上（别的受信上传者的段里）或本机有更靠后的状态时，**原区间重写**（同一个区间名字相同，
//!   覆盖写，不另起文件、不删别的），写进去的每个槽取「本机的、位置上的」里靠后的那份——只往靠后的方向改（降），永不
//!   把空洞 / 副本记录改回完整内容（升）。本机的槽不因此改变（本机的槽只由本机自己应用 Purge / Dedup 推进，§3.2）。
//! - 本机自己的段里有与本机日志**链指纹不同**的槽（本机后来把同号的另一支换进了日志，`Truth::rebalance`）：那个段是
//!   另一支在位置上的一份，重写就把它从位置上抹掉了，所以永不重写（两支都不丢，§3.2 第 2 种情况）。本机这一支照样要
//!   传上去：新切的段名字撞上它时（同一个区间、段尾链值也相同——`rebalance` 只换一个 seq 的槽，段尾不变），在这个区间
//!   里面的切点上切小再传，每一小段的区间不同、名字就不同；区间里没有别的切点、切不开的，才报进
//!   [UploadPlan::kept_forked]（位置上这里留着一个本机传不上去的分叉，同步轮必须报出来，由 G8-6 收敛）。
//! - 本机自己的段区间越过了本机日志的末尾（理论上不会：本机日志不变短）：不重写（本机打不出那么长的一段），它落后的
//!   那些 seq 照「位置上没有」另切新段补，名字与它不同、不覆盖它。
//!
//! # 切点
//!
//! 承袭段头带区间两端的完整原链值，一台设备只能在自己知道完整原链值的 seq 上切段（设计 §3.2、§10 第 10 条）。切点 =
//! seq 0（链的起点）∪ 本机这条日志的链值记号（迁移时每 4096 条与末尾、捡漏收的旧段每 4096 条与两端、收的承袭段两端，
//! `receive.rs`）∪ 这一轮看到的受信承袭段两端里链指纹对得上本机日志的。缺口向前扩到不晚于它的最近切点、向后扩到不早于
//! 它的最近切点，再按 [UPLOAD_MAX_SLOTS] 在切点上切成几段（两个相邻切点隔得比上限远就只能超长）；向后找不到切点的缺口
//! 传不了，进 [UploadPlan::blocked]。
//!
//! # 事务
//!
//! [Uploader] 只读真相层，开在调用方的事务里（同一份快照上 see / plan / pack；读事务也行）。不写库：位置上的现状每轮
//! 从头对账（D11 口径）。切点记号由收段写（`receive.rs`）。

use std::collections::{BTreeMap, BTreeSet};

use super::receive::{Defer, Reject};
use super::truth::{DEV_HERITAGE, DevInfo, Truth};
use crate::gen4::heritage::{
    HeritageHeader, HeritageMeta, HeritageSlot, SlotBody, SlotStream, fingerprint,
    open_heritage_verified, pack_heritage, peek_heritage_header,
};
use crate::gen4::location::{V4File, device_path, heritage_file_name, parse_v4_path};
use crate::store::gen4::derive::Index;
use crate::sync2::id::Id;
use crate::sync2::keys::{CollectionKey, DeviceKey};
use crate::sync2::segment::{CHAIN_ZERO, Chain, SegmentError};
use crate::sync2::vv::OpId;

/// 一个承袭段最多切这么多个槽（设计 §2.6 的实测口径：每段 2 万个，样本库 71 段）。只在切点上切，所以是目标不是硬上限。
pub const UPLOAD_MAX_SLOTS: u64 = 20_000;

/// 本机能不能替承袭日志 [d] 的作者上传（模块文件头「只替本机信任的作者上传」）：是有内容的承袭日志，且作者在本机
/// 可信（没有待确认 / 已拒绝的信任行）。[Uploader::open] 与承袭对账的指纹（`cmd/sync_oldroot.rs`）用同一个判据。
pub fn vouches_for(t: &Truth<'_>, col: i64, d: &DevInfo) -> Result<bool, String> {
    Ok(d.kind == Some(DEV_HERITAGE) && d.last > 0 && t.trust_of(col, &d.id)?.is_none())
}

/// 同一个操作号、同一个链指纹的槽的先后（设计 §3.2：完整 < 空洞 < 副本记录）。位置上留靠后的一份。
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Rank {
    /// 操作 / 原样件。
    Whole,
    Void,
    Alias,
}

pub fn rank_of(body: &SlotBody) -> Rank {
    match body {
        SlotBody::Op(_) | SlotBody::Raw3(_) => Rank::Whole,
        SlotBody::Void => Rank::Void,
        SlotBody::Alias(_) => Rank::Alias,
    }
}

/// 一组互不相交、不相邻的 seq 闭区间（按起点存）。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Runs(BTreeMap<u64, u64>);

impl Runs {
    pub fn new() -> Runs {
        Runs::default()
    }

    /// 并进 `[a, b]`（与已有的重叠或相邻的并成一段）。`a > b` 什么都不做。
    pub fn insert(&mut self, a: u64, b: u64) {
        if a > b {
            return;
        }
        let (mut lo, mut hi) = (a, b);
        // 起点不晚于 b + 1 的段里，与 [a, b] 重叠或相邻的都并进来。
        let touching: Vec<(u64, u64)> = self
            .0
            .range(..=b.saturating_add(1))
            .rev()
            .take_while(|(_, e)| e.saturating_add(1) >= a)
            .map(|(s, e)| (*s, *e))
            .collect();
        for (s, e) in touching {
            self.0.remove(&s);
            lo = lo.min(s);
            hi = hi.max(e);
        }
        self.0.insert(lo, hi);
    }

    pub fn contains(&self, seq: u64) -> bool {
        self.0
            .range(..=seq)
            .next_back()
            .is_some_and(|(_, e)| *e >= seq)
    }

    /// `[lo, hi]` 里不在这组区间里的部分，升序。
    pub fn gaps(&self, lo: u64, hi: u64) -> Vec<(u64, u64)> {
        let mut out = Vec::new();
        if lo > hi {
            return out;
        }
        let mut at = lo;
        let start = self.0.range(..=lo).next_back().map_or(lo, |(s, _)| *s);
        for (s, e) in self.0.range(start..=hi) {
            if *e < at {
                continue;
            }
            if *s > at {
                out.push((at, s - 1));
            }
            match e.checked_add(1) {
                Some(n) => at = at.max(n),
                None => return out,
            }
            if at > hi {
                return out;
            }
        }
        if at <= hi {
            out.push((at, hi));
        }
        out
    }

    /// `[a, b]` 里有没有一个 seq 在这组区间里。
    pub fn touches(&self, a: u64, b: u64) -> bool {
        a <= b && self.gaps(a, b) != vec![(a, b)]
    }
}

/// [Uploader::see] 的结论。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Seen {
    /// 算进了位置的现状。[matched] = 段里与本机日志同号同链指纹的槽数。
    Counted { matched: u64 },
    /// 现在不算（公钥未知、上传者不受信、解不开），它覆盖的区间按「位置上没有」处理。
    Ignored(Defer),
    /// 坏的（名字与段头不符、验不过、集合不对、加密位置上的明文件），永远不算。
    Rejected(Reject),
}

/// 一段要传（或原区间重写）的承袭段。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UploadSpec {
    /// 旧设备。
    pub device: Id,
    /// 来源集合。
    pub source: Id,
    pub first: u64,
    pub last: u64,
    /// 原协议 3 链在 `first - 1`、`last` 处的值（都是切点）。
    pub prev_chain: Chain,
    pub last_chain: Chain,
    /// 位置上的路径（相对 `v4/`）：`devices/<本机>/hrt-…`。
    pub path: String,
    /// 是本机已传的段原区间重写（同一个路径覆盖写）。
    pub rewrite: bool,
}

/// 一条承袭日志里传不了的缺口：向后找不到切点（本机不知道那之后任何一处的完整原链值）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Blocked {
    pub device: Id,
    pub first: u64,
    pub last: u64,
}

/// [Uploader::plan] 的结果。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct UploadPlan {
    /// 按 (旧设备, first) 升序。
    pub put: Vec<UploadSpec>,
    pub blocked: Vec<Blocked>,
    /// 位置上有未收敛分叉的段（本机自己已传、路径）：段里有与本机日志不同支的槽，所以永不重写；而且本机这一支有的
    /// seq 要么没法借重写补上（它本该重写），要么新切的段与它同名、区间里又没有别的切点能切开。**非空 = 位置上这几处
    /// 本机这一支传不上去**，只从位置上收的设备收不到本机日志里那一支，各设备在那些 seq 上可能长期分叉；同步轮必须把
    /// 它报出来，收敛交给 G8-6（另立切点、或让链指纹更小的一支有权覆盖写）。
    pub kept_forked: Vec<String>,
}

/// 本机在位置上的一个已传的段。
struct Mine {
    path: String,
    header: HeritageHeader,
    /// 段里每个 seq 的先后（从 first 起）；本机日志里没有这个 seq 的那部分不记。
    ranks: Vec<Rank>,
    /// 段里有与本机日志链指纹不同的槽。
    forked: bool,
    /// 本机日志里有比它靠后的状态。
    behind_local: bool,
}

/// 本机的一条承袭日志。
struct Log {
    src: Id,
    last: u64,
}

/// 一轮承袭上传的对账：位置上已有什么、还缺什么。
pub struct Uploader<'t, 'c> {
    t: &'t Truth<'c>,
    col: i64,
    collection: Id,
    /// 本集合与被它并入过的集合（承袭段头的集合必须是其中之一，同 `receive.rs`）。
    collections: BTreeSet<Id>,
    me: Id,
    signer: DeviceKey,
    max: u64,
    logs: BTreeMap<Id, Log>,
    /// 位置上满足了的 seq（文件头「位置上有是什么意思」）。
    sat: BTreeMap<Id, Runs>,
    /// 位置上比本机靠后的同号同链指纹的槽（取最靠后的一份）与转出它的 T 版本：本机传这个 seq 时传它。
    later: BTreeMap<OpId, (HeritageSlot, u32)>,
    /// 这一轮从受信承袭段头里得到的切点（链指纹对得上本机日志的）。
    cuts: BTreeMap<Id, BTreeMap<u64, Chain>>,
    mine: Vec<Mine>,
    seen: BTreeSet<String>,
}

fn not_counted(e: SegmentError) -> Seen {
    match e {
        SegmentError::Corrupt(m) => Seen::Rejected(Reject::Corrupt(m)),
        SegmentError::BadSignature => Seen::Rejected(Reject::BadSignature),
        SegmentError::ChainMismatch => Seen::Rejected(Reject::ChainMismatch),
        SegmentError::Undecryptable => Seen::Ignored(Defer::Undecryptable),
    }
}

impl<'t, 'c> Uploader<'t, 'c> {
    /// 在调用方的事务里开一轮。[col] 必须是绑着、有本机身份的集合。
    pub fn open(t: &'t Truth<'c>, col: i64) -> Result<Uploader<'t, 'c>, String> {
        if t.conn().is_autocommit() {
            return Err("gen4 inherit: outside a transaction".to_owned());
        }
        let binding = t
            .binding(col)?
            .ok_or_else(|| format!("gen4 inherit: no collection {col}"))?;
        let me = t
            .self_identity(col)?
            .ok_or_else(|| format!("gen4 inherit: collection {col} has no identity"))?;
        let mut collections: BTreeSet<Id> = Index::new(t, col)
            .joins()?
            .into_iter()
            .map(|j| j.from)
            .collect();
        collections.insert(binding.collection);
        // 只替本机信任的作者上传（文件头）：作者待确认 / 已拒绝的承袭日志不进这一轮。
        let mut logs: BTreeMap<Id, Log> = BTreeMap::new();
        for d in t.devices(col)? {
            if !vouches_for(t, col, &d)? {
                continue;
            }
            let src = d
                .src
                .ok_or_else(|| format!("gen4 inherit: heritage log {} has no source", d.id))?;
            logs.insert(d.id, Log { src, last: d.last });
        }
        Ok(Uploader {
            t,
            col,
            collection: binding.collection,
            collections,
            me: me.device,
            signer: me.key(),
            max: UPLOAD_MAX_SLOTS,
            logs,
            sat: BTreeMap::new(),
            later: BTreeMap::new(),
            cuts: BTreeMap::new(),
            mine: Vec::new(),
            seen: BTreeSet::new(),
        })
    }

    /// 改每段的目标槽数（测试用小段；必须 ≥ 1）。
    pub fn max_slots(mut self, n: u64) -> Uploader<'t, 'c> {
        self.max = n.max(1);
        self
    }

    /// 本机日志里 `[a, b]` 每个 seq 的 (链指纹, 先后)，从 a 起。
    fn local(&self, device: &Id, a: u64, b: u64) -> Result<Vec<([u8; 8], Rank)>, String> {
        let mut out = Vec::with_capacity(b.saturating_sub(a).saturating_add(1) as usize);
        self.t.for_range(self.col, device, a, b, |e| {
            let fp = e.fp.ok_or_else(|| {
                format!("gen4 inherit: {}:{} has no fingerprint", device, e.id.seq)
            })?;
            out.push((fp, rank_of(&e.body)));
            Ok(())
        })?;
        if out.len() as u64 != b - a + 1 {
            return Err(format!(
                "gen4 inherit: {device} log has a hole in {a}..={b}"
            ));
        }
        Ok(out)
    }

    /// 看位置上的一个承袭段。[path] 是它相对 `v4/` 的路径，[key] = 这个位置的密钥。同一个路径一轮只看一次。
    pub fn see(
        &mut self,
        path: &str,
        bytes: &[u8],
        key: Option<&CollectionKey>,
    ) -> Result<Seen, String> {
        if !self.seen.insert(path.to_owned()) {
            return Err(format!("gen4 inherit: {path} seen twice"));
        }
        if !matches!(parse_v4_path(path), Some(V4File::Heritage { .. })) {
            return Ok(Seen::Rejected(Reject::Corrupt(
                "not a heritage file name".into(),
            )));
        }
        let header = match peek_heritage_header(bytes) {
            Ok(h) => h,
            Err(e) => return Ok(not_counted(e)),
        };
        if device_path(&header.uploader, &heritage_file_name(&header)) != path {
            return Ok(Seen::Rejected(Reject::Corrupt(
                "file name does not match its header".into(),
            )));
        }
        if !self.collections.contains(&header.collection) {
            return Ok(Seen::Rejected(Reject::WrongCollection(header.collection)));
        }
        let uploader = header.uploader;
        let public = if uploader == self.me {
            self.signer.public()
        } else {
            match self.t.device_key(self.col, &uploader)? {
                None => return Ok(Seen::Ignored(Defer::UnknownSigner(uploader))),
                Some(_) if self.t.trust_of(self.col, &uploader)?.is_some() => {
                    return Ok(Seen::Ignored(Defer::UntrustedUploader(uploader)));
                }
                Some(p) => p,
            }
        };
        let open = match open_heritage_verified(bytes, &public, key) {
            Ok(o) => o,
            Err(e) => return Ok(not_counted(e)),
        };
        if key.is_some() && !open.header.encrypted {
            return Ok(Seen::Rejected(Reject::PlainOnSealed));
        }
        if open.header != header {
            return Ok(Seen::Rejected(Reject::Corrupt(
                "header changed under the signature".into(),
            )));
        }
        // 段头担保的作者公钥与本机记的不同（`receive.rs` 同样整段不收）：不能替本机补过这一段。
        if let Some(k) = header.author_key {
            if self
                .t
                .device_key(self.col, &header.device)?
                .is_some_and(|cur| cur != k)
            {
                return Ok(Seen::Rejected(Reject::AuthorKeyMismatch(header.device)));
            }
        }
        // 第一遍：整段合规才算（流走到头才验得出覆盖区间与末槽）。
        let stream: SlotStream<'_> = match open.slots() {
            Ok(s) => s,
            Err(e) => return Ok(not_counted(e)),
        };
        for s in stream {
            if let Err(e) = s {
                return Ok(not_counted(e));
            }
        }
        let device = header.device;
        let Some(log) = self.logs.get(&device) else {
            return Ok(Seen::Counted { matched: 0 });
        };
        if log.src != header.source || header.first > log.last {
            return Ok(Seen::Counted { matched: 0 });
        }
        let upto = header.last.min(log.last);
        let local = self.local(&device, header.first, upto)?;
        let mine = uploader == self.me;
        let mut ranks: Vec<Rank> = Vec::new();
        let (mut forked, mut behind_local) = (false, false);
        let mut matched = 0u64;
        let sat = self.sat.entry(device).or_default();
        for s in open.slots().map_err(|e| format!("gen4 inherit: {e}"))? {
            let s = s.map_err(|e| format!("gen4 inherit: segment changed while reading: {e}"))?;
            if s.id.seq > upto {
                break;
            }
            let (lfp, lrank) = local[(s.id.seq - header.first) as usize];
            let rank = rank_of(&s.body);
            if mine {
                ranks.push(rank);
            }
            if s.fp != lfp {
                forked = true;
                continue;
            }
            matched += 1;
            if rank >= lrank {
                sat.insert(s.id.seq, s.id.seq);
            } else {
                behind_local = true;
            }
            if rank > lrank {
                let id = s.id;
                let keep = self
                    .later
                    .get(&id)
                    .is_none_or(|(have, _)| rank_of(&have.body) < rank);
                if keep {
                    self.later.insert(id, (s, header.t_version));
                }
            }
        }
        // 段头两端链指纹对得上本机日志的，是这一轮的切点。
        let before = match header.first {
            1 => None,
            f => Some(self.local(&device, f - 1, f - 1)?[0].0),
        };
        let cuts = self.cuts.entry(device).or_default();
        if header.last <= upto
            && local[(header.last - header.first) as usize].0 == fingerprint(&header.last_chain)
        {
            cuts.insert(header.last, header.last_chain);
        }
        if before == Some(fingerprint(&header.prev_chain)) {
            cuts.insert(header.first - 1, header.prev_chain);
        }
        if mine {
            self.mine.push(Mine {
                path: path.to_owned(),
                header,
                ranks,
                forked,
                behind_local,
            });
        }
        Ok(Seen::Counted { matched })
    }

    /// 这条日志的切点：seq 0、本机的链值记号、这一轮从段头得到的。
    fn cut_points(&self, device: &Id) -> Result<BTreeMap<u64, Chain>, String> {
        let mut k: BTreeMap<u64, Chain> = self.t.marks(self.col, device)?.into_iter().collect();
        if let Some(c) = self.cuts.get(device) {
            k.extend(c.iter().map(|(s, c)| (*s, *c)));
        }
        k.insert(0, CHAIN_ZERO);
        Ok(k)
    }

    fn spec(
        &self,
        device: Id,
        source: Id,
        (first, last): (u64, u64),
        (prev_chain, last_chain): (Chain, Chain),
        rewrite: bool,
    ) -> UploadSpec {
        let header = HeritageHeader {
            encrypted: false,
            collection: self.collection,
            source,
            device,
            uploader: self.me,
            author_key: None,
            t_version: 0,
            first,
            last,
            prev_chain,
            last_chain,
        };
        UploadSpec {
            device,
            source,
            first,
            last,
            prev_chain,
            last_chain,
            path: device_path(&self.me, &heritage_file_name(&header)),
            rewrite,
        }
    }

    /// 算出这一轮要传的段（文件头的规则）。
    pub fn plan(&self) -> Result<UploadPlan, String> {
        let mut plan = UploadPlan::default();
        let forked_paths: BTreeSet<&str> = self
            .mine
            .iter()
            .filter(|m| m.forked)
            .map(|m| m.path.as_str())
            .collect();
        for (device, log) in &self.logs {
            let mut todo = self.sat.get(device).cloned().unwrap_or_default();
            // 本机已传、落后了的段：原区间重写（写进去的是靠后的那份，所以重写完这些 seq 都满足了）。
            for m in self.mine.iter().filter(|m| m.header.device == *device) {
                let behind_location = m.ranks.iter().enumerate().any(|(i, r)| {
                    let id = OpId {
                        device: *device,
                        seq: m.header.first + i as u64,
                    };
                    self.later
                        .get(&id)
                        .is_some_and(|(s, _)| rank_of(&s.body) > *r)
                });
                if !(m.behind_local || behind_location) {
                    continue;
                }
                if m.forked {
                    plan.kept_forked.push(m.path.clone());
                    continue;
                }
                let h = &m.header;
                // 区间越过本机日志末尾：本机打不出这一段，不重写；落后的 seq 不算满足，下面照缺口另切新段补。
                if h.last > log.last {
                    continue;
                }
                plan.put.push(self.spec(
                    *device,
                    log.src,
                    (h.first, h.last),
                    (h.prev_chain, h.last_chain),
                    true,
                ));
                todo.insert(h.first, h.last.min(log.last));
            }
            let gaps = todo.gaps(1, log.last);
            if gaps.is_empty() {
                continue;
            }
            let k = self.cut_points(device)?;
            // 缺口扩到切点，重叠的并起来。
            let mut spans = Runs::new();
            for (a, b) in gaps {
                let lo = *k.range(..a).next_back().expect("seq 0 is a cut point").0;
                match k.range(b..).next() {
                    Some((hi, _)) => spans.insert(lo + 1, *hi),
                    None => plan.blocked.push(Blocked {
                        device: *device,
                        first: a,
                        last: b,
                    }),
                }
            }
            for (s, e) in spans.0 {
                // 在切点上切成不超过目标的几段；只传里面真有缺口的。
                let mut at = s - 1;
                while at < e {
                    let reach = at.saturating_add(self.max).min(e);
                    let next = k
                        .range(at + 1..=reach)
                        .next_back()
                        .or_else(|| k.range(reach + 1..=e).next())
                        .map(|(n, _)| *n)
                        .ok_or_else(|| {
                            format!("gen4 inherit: no cut point in {device} {at}..={e}")
                        })?;
                    if todo.gaps(at + 1, next) != Vec::new() {
                        let spec =
                            self.spec(*device, log.src, (at + 1, next), (k[&at], k[&next]), false);
                        if !forked_paths.contains(spec.path.as_str()) {
                            plan.put.push(spec);
                        } else {
                            // 撞上本机那份另一支的段名：在区间里面的切点上切小（每一小段区间不同、名字不同，不覆盖它）。
                            let inner: Vec<u64> = k.range(at + 1..next).map(|(n, _)| *n).collect();
                            if inner.is_empty() {
                                plan.kept_forked.push(spec.path);
                            } else {
                                let mut a = at;
                                for b in inner.into_iter().chain([next]) {
                                    if todo.gaps(a + 1, b) != Vec::new() {
                                        let piece = self.spec(
                                            *device,
                                            log.src,
                                            (a + 1, b),
                                            (k[&a], k[&b]),
                                            false,
                                        );
                                        if forked_paths.contains(piece.path.as_str()) {
                                            plan.kept_forked.push(piece.path);
                                        } else {
                                            plan.put.push(piece);
                                        }
                                    }
                                    a = b;
                                }
                            }
                        }
                    }
                    at = next;
                }
            }
        }
        plan.put.sort_by_key(|p| (p.device, p.first, p.last));
        plan.put.dedup_by(|a, b| a.path == b.path);
        plan.kept_forked.sort();
        plan.kept_forked.dedup();
        Ok(plan)
    }

    /// 打包一段（[key] = 目标位置的密钥）。槽取本机日志的；位置上有同号同链指纹、更靠后的一份时取那一份（只降不升）。
    /// 一段只含同一个 T 版本转出的槽：本机与位置上的版本不一致时报错（现在只有版本 1；出版本 2 的 PR 定规则，设计 §3.1）。
    pub fn pack(&self, spec: &UploadSpec, key: Option<&CollectionKey>) -> Result<Vec<u8>, String> {
        let mut slots: Vec<HeritageSlot> = Vec::new();
        let mut tv: Option<u32> = None;
        self.t
            .for_range(self.col, &spec.device, spec.first, spec.last, |e| {
                let mine = e.slot().ok_or_else(|| {
                    format!("gen4 inherit: {} is not a heritage log", spec.device)
                })?;
                let (slot, v) = match self.later.get(&e.id) {
                    Some((s, v)) if s.fp == mine.fp && rank_of(&s.body) > rank_of(&mine.body) => {
                        (s.clone(), *v)
                    }
                    _ => (mine, e.tv),
                };
                if *tv.get_or_insert(v) != v {
                    return Err(format!(
                        "gen4 inherit: {}:{}..={} mixes translator versions",
                        spec.device, spec.first, spec.last
                    ));
                }
                slots.push(slot);
                Ok(())
            })?;
        if slots.len() as u64 != spec.last - spec.first + 1 {
            return Err(format!(
                "gen4 inherit: {} log does not hold {}..={}",
                spec.device, spec.first, spec.last
            ));
        }
        let meta = HeritageMeta {
            collection: self.collection,
            source: spec.source,
            device: spec.device,
            uploader: self.me,
            author_key: self.t.device_key(self.col, &spec.device)?,
            t_version: tv.ok_or("gen4 inherit: empty segment")?,
            prev_chain: spec.prev_chain,
            last_chain: spec.last_chain,
        };
        let (header, bytes) = pack_heritage(&meta, &slots, &self.signer, key)?;
        if device_path(&self.me, &heritage_file_name(&header)) != spec.path {
            return Err("gen4 inherit: packed segment does not match its planned name".to_owned());
        }
        Ok(bytes)
    }
}

#[cfg(test)]
#[path = "inherit_tests.rs"]
pub(crate) mod tests;
