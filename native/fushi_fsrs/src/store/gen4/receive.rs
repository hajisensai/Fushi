//! 收段（规划 §1.5 / §2.1 的 G8-4）：把从位置上读到的协议 4 段——原生段 `FSG4`、中继件 `FRL4`、承袭段 `FSH4`——验过
//! 之后落进真相层，按因果投递，一批的终点用 [ingest_settle] 收派生层。还没有调用方（第一段）：同步轮（G8-7）列位置、
//! 读 head、记公钥与信任之后调这里。
//!
//! # 一批
//!
//! [Receiver::open] 开在调用方的事务里，[Receiver::native] / [Receiver::heritage] 每次收一段，[Receiver::finish] 先把
//! 等待缓冲里接得上的投完、再 [ingest_settle]。整批与落库同一个事务提交：崩溃 = 这一批全没发生，位置上的文件还在，
//! 下一轮重收（测试 `a_crash_mid_batch_commits_nothing_and_the_retry_lands_everything`）。收法（[Settle]）由调用方定：
//! 日常几段用 [Settle::Incremental]（逐条告诉索引），新设备第一次收全量用 [Settle::Rebuild]（只落真相，最后整个重建）。
//!
//! 单段的问题不让整批回滚：读到坏段、验不过的段、还收不了的段，[Receiver::native] / [Receiver::heritage] 答
//! [Taken::Rejected] / [Taken::Deferred]，**一条都不落**——所有核对（段头、集合、作者公钥、信任、签名、加密状态、整段的
//! 链 / 覆盖区间、每条操作的信封）都在落第一条之前做完；真相层对来路数据的矛盾答结果（[Put::Conflict]）而不是报错。
//! 返回 `Err` 的只有库本身出错，那时真相层会话已毒化，调用方整笔回滚。
//!
//! # 原生段：链与因果
//!
//! 作者签名担保段里的链（[crate::gen4::segment::OpenNative::verify]），本机核对它与作者日志接得上：
//!
//! - 段里已有的部分（seq ≤ 本机末尾）：不再落；在本机末尾那个 seq 上（或段整个落在本机日志里面时在段尾）比一次链值，
//!   不等 = 作者的日志与本机记的分叉了（克隆、回滚过的设备），答 [Taken::Diverged]，交给 G8-6 的身份分叉处理，这一段之后的
//!   部分不落。本机那里是空洞内部（已清除，没有链值）时比不了，跳过（作者签过的空洞本机照收，见下）。
//! - 正好接在末尾、依赖（`deps`，不含作者自己）都已在本机日志里：落库（[Truth::append_native]），本机算出的链值必须等于
//!   段里的，不等同样是 [Taken::Diverged]。
//! - 接得上本机日志的项**先比前一环、再看依赖**：正好接在末尾的比本机末尾，越过末尾的空洞比本机在它前一格的链值（那一格
//!   在本机空洞内部时比不了，跳过），不等就是 [Taken::Diverged]，与依赖齐不齐无关——否则依赖还没到的分叉项会先进缓冲，
//!   分叉看不看得出来就取决于到达顺序了（测试 `a_fork_still_waiting_on_its_deps_is_reported_whatever_the_order`）。
//! - 前面还缺、或依赖不齐：进等待缓冲 `op_wait`（设计 §4.2：新库真相层只有承袭用的 `op_pending`，原生的缓冲由 G8 加），
//!   连同这一项前后的链值；同一台设备后面的项也只能跟着等（日志从 1 起连续）。[Receiver::finish] 反复投「正好接在末尾、
//!   前一环链值等于本机末尾、依赖齐了」的项，直到投不动为止，所以一批之内各段的到达顺序不影响结果（测试
//!   `the_order_segments_arrive_in_does_not_change_the_result`）。同一个 seq 上有两项都声称接在本机末尾 = 作者自己写出过两支，
//!   一项都不投，等 G8-6（[Received::forked]）。等待项里前一环与本机不等的、整个已在本机日志里却与本机不同支的，是身份
//!   分叉的证据：不投、不删，留在缓冲里每批报进 [Received::diverged_waiting] 交 G8-6（设计 §3.2 / §6.3：两支都不丢）；
//!   与本机同一支的（重复收到的）删掉。
//! - 空洞（作者签出的已清除区间）：同样按「接在末尾」投，越过本机已有部分的只落多出来的那一截。空洞处链值读侧验不了，
//!   是作者签名担保的陈述（附录 B 第 9 条），本机照收；本机已有的完整操作不因此被清掉（本机的槽只由本机自己的清除推进）。
//!
//! 作者就是本机身份的段（从备份恢复了旧库、位置上有本机后来写的）照同样的规则收：接得上就接回来，接不上是
//! [Taken::Diverged]。不吸收远端时钟：本机写入时 [super::native::Native] 自己取各日志末尾 HLC 的最大值。
//!
//! # 承袭段
//!
//! - 上传者必须是本机**信任的**设备（D20：不受信上传者的承袭段留在位置上不收，等信任后再收）：本机记过它的公钥、
//!   信任表里没有它的行；否则 [Taken::Deferred]，什么都不落。
//! - 每个槽：本机日志里已有这个操作号的，按真相层的落库规则（[Truth::put_heritage]：同号同字节、本机推进过的不动、
//!   分叉留链指纹最小者……）；正好接在末尾、依赖齐了的落库；其余进 `op_pending`，带「前一环的链指纹」（段里上一个槽的，
//!   第一个槽取段头的 `prev_chain`），[Receiver::finish] 用 [Truth::pending_ready] 按链指纹投，依赖同样要齐。
//! - 承袭段先流式校验一遍再落（流走到头才算整段合规）：坏段一条都不落。
//! - 槽与本机已有的自相矛盾（同号同链指纹、同 T 版本而内容不同；待投递的槽说了两个不同的前一环）：真相层答
//!   [Put::Conflict]、什么都不写，这里记进 [Received::conflicts]、跳过这个槽、接着收。上传者的转译与本机的不同或段被改过，
//!   不是本机库坏了，不能因为位置上的一个文件让整批同步停下。
//!
//! # 集合
//!
//! 段头的集合必须是本机这个集合，或者本集合日志里一条 `Join` 并入过的集合（[Index::joins]：并入之后，被并入集合的位置
//! 上作者签过的段头还写着原来的集合标识，链不含集合标识，设计 §5.4）。别的一律 [Reject::WrongCollection]。
//!
//! # 加密
//!
//! [key] 是这一段所在位置的密钥（明文位置 = None）。加密位置上读到明文落盘的件（[OpenNative::stored_sealed] /
//! 承袭段头 `encrypted` 为假）一律拒（[Reject::PlainOnSealed]，BUG-4299 的口径：加密位置上绝不收明文）；明文位置上读到
//! 加密的件而本机没有密钥，[Defer::Undecryptable]。
//!
//! # 重切中继件
//!
//! `FRX4`（`gen4/recut.rs`）= 转发者把本机已彻底清除的操作挖掉（换成剔除项：信封、载荷哈希、作者签的清除目标、清掉它
//! 的 Purge）、用自己的钥匙问责签名的作者段。先要有作者的公钥（读过它的 head）与重切者的公钥，重切者必须是本机信任的
//! 设备（本机自己也算），否则 [Defer::UnknownSigner] / [Defer::UntrustedUploader]。之后：
//!
//! - **作者的原签名**照样验（`open_recut4`：逐项摘要、剔除项的摘要等于原操作的）、链逐条重算：段头与留下的每条操作都是
//!   作者签过的原件，挖掉的每一项对应作者签过的一条操作。验不过 = [Reject::BadSignature] / [Reject::ChainMismatch]。
//! - 每个**要落库**的剔除项（seq 在本机这位作者日志末尾之后）声称的 Purge：本机日志或等待缓冲里有了、确是 Purge、目标在
//!   作者签的清除目标里、这一项的作者写它时没见过它，才收；本机还没有它 = [Defer::PurgePending]（它在别的段里，到了
//!   再收）；它的作者本机不信任 = [Defer::UntrustedUploader]；有了却管不到 = [Reject::NotPurged]（重切者挖了没被清除的
//!   操作）。本机已有的那些 seq 不看：本机的槽只由本机自己的清除推进，件里的剔除项不会把它们挖掉。
//! - 落库同原生段：剔除项落成一条的空洞（链值是读者自己从信封与载荷哈希算的那一环，不是重切者填的），连同剔除记录
//!   （`relay_stubs`，本机以后再转发这一段时重切用）；作者签的空洞照原生段落。
//!
//! 收下的作者签的每一段（原生段、中继件、重切件）都记下作者签名与作者签的空洞（[Truth::note_author_version]，
//! `relay_auth`）：本机以后清除了这位作者的操作、要从日志重切这一段时用。

use std::collections::BTreeSet;

use rusqlite::params;

use super::derive::{Index, Settled};
use super::import::HERITAGE_MARK_EVERY;
use super::ingest::{Settle, ingest_settle};
use super::schema::{k_range, k_seq, sql};
use super::sync_state::{AuthorVersion, WaitKey, chain32, op_of_bytes};
use super::truth::{DEV_HERITAGE, DEV_NATIVE, Peer, Put, Truth};
use crate::gen4::heritage::{
    Fp, HeritageHeader, HeritageSlot, SlotBody, fingerprint, open_heritage_verified,
    peek_heritage_header,
};
use crate::gen4::op::{Body4, KIND_PURGE, Op4, chain_next4};
use crate::gen4::recut::{self, RecutItem, Stub, open_recut4, peek_recut4};
use crate::gen4::relay::{self, open_any4, peek_relay4};
use crate::gen4::segment::{NativeHeader, NativeItem, VerifiedNative, peek_native_header};
use crate::gen4::translate::{T_VERSION, translate};
use crate::store::sync2::collection_of;
use crate::sync2::id::Id;
use crate::sync2::keys::{CollectionKey, DeviceKey};
use crate::sync2::segment::{CHAIN_ZERO, Chain, SegmentError};
use crate::sync2::segment::{chain_next, open_verified, peek_header};
use crate::sync2::vv::{OpId, Vv};

/// 这一段现在收不了，留在位置上、下一轮再试。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Defer {
    /// 本机没记过作者（承袭段：上传者）的公钥：先读它的 head。
    UnknownSigner(Id),
    /// 承袭段的上传者 / 重切中继件（`FRX4`）的重切者还没被本机信任（D20）。
    UntrustedUploader(Id),
    /// 加密的件、本机没有（或拿错了）密钥。
    Undecryptable,
    /// 重切中继件（`FRX4`）里一条要落库的剔除项声称的那条 Purge 本机还没有（没落库、也不在等待缓冲里）：它到了再收
    /// （`gen4/recut.rs`「信任口径」第 3 条）。
    PurgePending(OpId),
}

/// 这一段是坏的，永远不收。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Reject {
    /// 截断、格式不对、解压不开、覆盖区间不对。
    Corrupt(String),
    BadSignature,
    /// 段里的链对不上段头。
    ChainMismatch,
    /// 段头的集合不是本集合、也没被本集合并入过。
    WrongCollection(Id),
    /// 加密位置上的明文件。
    PlainOnSealed,
    /// 段头的设备在本机已经是另一种日志（原生 / 承袭），或承袭日志的来源集合对不上。
    WrongLog(Id),
    /// 承袭段头担保的旧设备公钥（`author_key`）与本机记着的不同：上传者与本机至少有一方认的是冒充者，整段不收。
    AuthorKeyMismatch(Id),
    /// 重切中继件（`FRX4`）挖掉了 [0] 这条操作，而它声称的那条 Purge 本机有了、却管不到它（不是 Purge、目标不在
    /// 作者签的清除目标里、或作者写它时已经见过这条 Purge）：重切者挖了没被清除的操作，整件不收。
    NotPurged(OpId),
}

/// 收一段的结论。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Taken {
    /// 收了：落库的项数、本机已有的 seq 数、进等待缓冲的项数。
    Landed {
        landed: u64,
        known: u64,
        parked: u64,
    },
    Deferred(Defer),
    Rejected(Reject),
    /// 作者的日志在 [seq] 处与本机记的不同。这一段在它之前的部分已落，之后的没落。
    Diverged {
        device: Id,
        seq: u64,
    },
}

/// 一批的计数（[Receiver::finish]）。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Received {
    /// 收进来（[Taken::Landed]）的段数。
    pub segments: u64,
    pub deferred: u64,
    pub rejected: u64,
    pub diverged: u64,
    /// 直接落库的项（原生操作 / 空洞 / 承袭槽）。
    pub landed: u64,
    /// 从等待缓冲（`op_wait` / `op_pending`）投出去的项。
    pub delivered: u64,
    /// 收尾时还在等的原生项与承袭槽。
    pub waiting: u64,
    pub pending: u64,
    /// 收尾时等待缓冲里同一个 seq 有两支接在本机末尾、不自己投的设备（原生）。
    pub forked: Vec<Id>,
    /// 收尾时等待缓冲里与本机日志分叉的项（设备、seq）：前一环不等于本机该处的链值，或整个已在本机日志里却与本机
    /// 不同。它们留在缓冲里不投、不删，交 G8-6 的身份分叉处理（设计 §3.2 / §6.3：两支都不丢）。
    pub diverged_waiting: Vec<(Id, u64)>,
    /// 与本机已有的自相矛盾、没落的承袭槽（[Put::Conflict]）。
    pub conflicts: u64,
    /// 派生层的收尾。
    pub settled: Settled,
    /// 收尾时在真相层落成空洞的操作数（[Index::execute_purges]）。
    pub voided: u64,
    /// 收尾投递等待缓冲时预算用完、还有接得上的项没投（[Receiver::with_budget]）：调用方再开一个事务、不带段地收一次
    /// 接着投（`cmd/sync.rs` `ingest` 回包 `drainMore`）。不限预算时恒为 false。
    pub drain_more: bool,
    /// 这一批做的新工作数（[Receiver::with_budget] 数的那些，含收尾投出的原生等待项）。调用方拿它判断一片有没有进展：
    /// 只停放进等待缓冲、一项都没落库的一片（依赖方的段排在被依赖方前面）也是进展，不能拿落库数当代理。
    pub spent: u64,
}

fn reject_of(e: SegmentError) -> Taken {
    match e {
        SegmentError::Corrupt(m) => Taken::Rejected(Reject::Corrupt(m)),
        SegmentError::BadSignature => Taken::Rejected(Reject::BadSignature),
        SegmentError::ChainMismatch => Taken::Rejected(Reject::ChainMismatch),
        SegmentError::Undecryptable => Taken::Deferred(Defer::Undecryptable),
    }
}

/// 投一遍原生等待缓冲的结果。
#[derive(Default)]
struct DrainPass {
    delivered: u64,
    forked: Vec<Id>,
    diverged: BTreeSet<(Id, u64)>,
}

/// 一批收段。
pub struct Receiver<'t, 'c> {
    t: &'t Truth<'c>,
    idx: Index<'t, 'c>,
    col: i64,
    mode: Settle,
    /// 本集合与被它并入过的集合。
    collections: BTreeSet<Id>,
    /// 它们的位置目录名（旧根捡漏认来源用）。
    dirs: BTreeSet<String>,
    /// 本机身份（作者 / 上传者是它自己时，公钥从签名钥匙算）。
    me: Option<(Id, [u8; 32])>,
    /// 各设备日志的末尾（本批内随落库更新）。
    applied: Vv,
    tally: Received,
    /// 这一批段给出的完整原链值 (设备, seq, 链值)，收尾时记成记号（[Receiver::mark_due]）。
    marks_due: Vec<(Id, u64, Chain)>,
    /// 本机停用了的设备（[Truth::retired]，G8-7）：它们上面的依赖当成已满足（协议 3 `deps_ready` 同一口径）。
    retired: BTreeSet<Id>,
    /// 这一批 [Receiver::legacy] 逐段的结论（按调用顺序）。旧根核对的收尾（`oldroot.rs` 的
    /// [Receiver::finish_oldroot]）拿它判断本轮清单是否全部有了结论，不让调用方另报一份。
    legacy_taken: Vec<Taken>,
    /// 这一批最多做多少项新工作（落库 + 新进等待缓冲的原生项、收尾从原生等待缓冲投出的项，与承袭段落库 / 待投的槽；
    /// [Receiver::with_budget]）。
    /// None = 不限。
    budget: Option<u64>,
    /// 这一批已做的新工作。
    spent: u64,
    /// 上一个原生段因为 [Receiver::budget] 用完在中途停下（后面的项这一批没碰）。
    cut: bool,
    /// 收尾投递等待缓冲时预算用完、留下了接得上的项（[Received::drain_more]）。
    drain_cut: bool,
}

impl<'t, 'c> Receiver<'t, 'c> {
    /// 在调用方的事务里开一批。[col] 必须是绑着的集合。
    pub fn open(t: &'t Truth<'c>, col: i64, mode: Settle) -> Result<Receiver<'t, 'c>, String> {
        if t.conn().is_autocommit() {
            return Err("gen4 receive: outside a transaction".to_owned());
        }
        let binding = t
            .binding(col)?
            .ok_or_else(|| format!("gen4 receive: no collection {col}"))?;
        let mut idx = Index::new(t, col);
        let joins = idx.joins()?;
        let mut collections: BTreeSet<Id> = joins.iter().map(|j| j.from).collect();
        collections.insert(binding.collection);
        let mut dirs: BTreeSet<String> = joins.into_iter().map(|j| j.dir).collect();
        dirs.insert(binding.dir);
        let me = t.self_identity(col)?.map(|s| (s.device, s.public()));
        Ok(Receiver {
            t,
            idx,
            col,
            mode,
            collections,
            dirs,
            me,
            applied: t.applied(col)?,
            retired: t.retired(col)?.into_keys().collect(),
            tally: Received::default(),
            marks_due: Vec::new(),
            legacy_taken: Vec::new(),
            budget: None,
            spent: 0,
            cut: false,
            drain_cut: false,
        })
    }

    /// 收段让路（G8-7b）：这一批最多做 [items] 项新工作（落进日志的原生项 / 空洞 + 新进等待缓冲的原生项）。用完时
    /// 正在收的原生段在下一项之前停下（[Receiver::cut]）——已落的部分是本机日志的前缀，同一段下一批再交一次时这部分
    /// 按「本机已有」跳过（只重算链，不落库），从停下的地方接着落。调用方据此把一大批切成几个短事务，事务之间放开
    /// 写锁让作答插进来（`cmd/sync.rs` `ingest` 的 `maxItems`）。
    pub fn with_budget(mut self, items: Option<u64>) -> Self {
        self.budget = items.map(|n| n.max(1));
        self
    }

    /// 这一批的预算用完了（下一段不该再交）。
    pub fn exhausted(&self) -> bool {
        self.budget.is_some_and(|b| self.spent >= b)
    }

    /// 上一个 [Receiver::native] 在段的中途停下了：这一段还要原样再交一次。
    pub fn cut(&self) -> bool {
        self.cut
    }

    fn public_of(&self, device: &Id) -> Result<Option<[u8; 32]>, String> {
        if let Some((me, public)) = &self.me {
            if me == device {
                return Ok(Some(*public));
            }
        }
        self.t.device_key(self.col, device)
    }

    /// 本机日志里这台设备是哪一种（没见过它的日志 = None）与来源集合。
    fn kind_of(&self, device: &Id) -> Result<Option<(i64, Option<Id>)>, String> {
        Ok(self
            .t
            .devices(self.col)?
            .into_iter()
            .find(|d| d.id == *device)
            .and_then(|d| d.kind.map(|k| (k, d.src))))
    }

    fn tell(&mut self, id: &OpId) -> Result<(), String> {
        if self.mode == Settle::Incremental {
            let e = self
                .t
                .entry(self.col, id)?
                .ok_or_else(|| format!("gen4 receive: {}:{} did not land", id.device, id.seq))?;
            self.idx.add(&e)?;
        }
        Ok(())
    }

    fn count(&mut self, taken: Taken) -> Taken {
        match &taken {
            Taken::Landed { .. } => self.tally.segments += 1,
            Taken::Deferred(_) => self.tally.deferred += 1,
            Taken::Rejected(_) => self.tally.rejected += 1,
            Taken::Diverged { .. } => self.tally.diverged += 1,
        }
        taken
    }

    /// 先前计过的一次延后不算了（`cmd/sync.rs` `ingest` 把那一件交回 Dart、下一个事务重收，计重收那次的结论）。
    pub fn uncount_deferred(&mut self) {
        self.tally.deferred = self.tally.deferred.saturating_sub(1);
    }

    /// 这一批里先前因 [Defer::PurgePending] 延后的重切件再收一次（`cmd/sync.rs` `ingest` 在一批交完之后调：它点名的
    /// Purge 可能在同一批后面的段里，那时已落或进了等待缓冲）。先前那次延后不再计数，计这一次的结论。
    pub fn native_again(
        &mut self,
        bytes: &[u8],
        key: Option<&CollectionKey>,
    ) -> Result<Taken, String> {
        self.tally.deferred = self.tally.deferred.saturating_sub(1);
        self.native(bytes, key)
    }

    // ------------------------------------------------------------ 原生段

    /// 收一个原生段（`seg-…`，`FSG4`）、中继件（`rly-…`，`FRL4`）或重切中继件（`rly-…`，`FRX4`）。[key] = 它所在位置的密钥。
    pub fn native(&mut self, bytes: &[u8], key: Option<&CollectionKey>) -> Result<Taken, String> {
        self.cut = false;
        let taken = self.native_inner(bytes, key)?;
        Ok(self.count(taken))
    }

    fn native_inner(&mut self, bytes: &[u8], key: Option<&CollectionKey>) -> Result<Taken, String> {
        let peeked = if bytes.starts_with(recut::MAGIC) {
            peek_recut4(bytes).map(|p| (p.header, Some(p.recutter)))
        } else if bytes.starts_with(relay::MAGIC) {
            peek_relay4(bytes).map(|p| (p.header, None))
        } else {
            peek_native_header(bytes).map(|h| (h, None))
        };
        let (header, recutter): (NativeHeader, Option<Id>) = match peeked {
            Ok(h) => h,
            Err(e) => return Ok(reject_of(e)),
        };
        if !self.collections.contains(&header.collection) {
            return Ok(Taken::Rejected(Reject::WrongCollection(header.collection)));
        }
        let device = header.device;
        if matches!(self.kind_of(&device)?, Some((k, _)) if k != DEV_NATIVE) {
            return Ok(Taken::Rejected(Reject::WrongLog(device)));
        }
        let Some(public) = self.public_of(&device)? else {
            return Ok(Taken::Deferred(Defer::UnknownSigner(device)));
        };
        let start_last = self.t.last_of(self.col, &device)?;
        // 验过之后要落的项（重切件的剔除项带着它的剔除记录）、作者签名、作者签的空洞。
        let author_sig: [u8; 64];
        let items: Vec<(NativeItem, Option<Stub>)>;
        let author_voids: Option<Vec<(u64, u64, Chain)>>;
        let open_native_piece;
        let mut stream: Option<VerifiedNative<'_>> = None;
        match recutter {
            // 重切中继件（`gen4/recut.rs`）：作者的原签名与链照样验；重切者只为挖掉哪些负责（每个要落的剔除项核对它
            // 声称的 Purge），另外只收本机信任的重切者签的（同承袭段的上传者，D20）。
            Some(r) => {
                let Some(rp) = self.public_of(&r)? else {
                    return Ok(Taken::Deferred(Defer::UnknownSigner(r)));
                };
                if !matches!(&self.me, Some((me, _)) if *me == r)
                    && self.t.trust_of(self.col, &r)?.is_some()
                {
                    return Ok(Taken::Deferred(Defer::UntrustedUploader(r)));
                }
                let open = match open_recut4(bytes, &public, &rp, key) {
                    Ok(o) => o,
                    Err(e) => return Ok(reject_of(e)),
                };
                if key.is_some() && !open.stored_sealed {
                    return Ok(Taken::Rejected(Reject::PlainOnSealed));
                }
                if open.header != header {
                    return Ok(Taken::Rejected(Reject::Corrupt(
                        "header changed under the signature".into(),
                    )));
                }
                for item in &open.items {
                    if let RecutItem::Stub(s) = item {
                        if s.op.id.seq > start_last {
                            if let Some(t) = self.purge_vouches(s)? {
                                return Ok(t);
                            }
                        }
                    }
                }
                let mut seq = header.first;
                let mut voids = Vec::new();
                for item in &open.items {
                    if let RecutItem::Void { count, chain_after } = item {
                        voids.push((seq, *count, *chain_after));
                    }
                    seq += item.span();
                }
                author_sig = open.author_sig;
                author_voids = Some(voids);
                items = open.landing_items();
            }
            None => {
                let open = match open_any4(bytes, &public, key) {
                    Ok(o) => o,
                    Err(e) => return Ok(reject_of(e)),
                };
                if key.is_some() && !open.stored_sealed {
                    return Ok(Taken::Rejected(Reject::PlainOnSealed));
                }
                // 签名之下的段头才可信（peek 的只是提示）。
                if open.header != header {
                    return Ok(Taken::Rejected(Reject::Corrupt(
                        "header changed under the signature".into(),
                    )));
                }
                // 每条操作的信封：作者的、依赖里不点作者自己（真相层的原生日志拒收这两样，到落库时才发现就晚了）。流式解
                // 一遍、不落库；整段的链在下面 verify。
                let check = match open.items() {
                    Ok(s) => s,
                    Err(e) => return Ok(reject_of(e)),
                };
                for item in check {
                    match item {
                        Err(e) => return Ok(reject_of(e)),
                        Ok(NativeItem::Op(op))
                            if op.hlc.device != device || op.deps.get(&device) != 0 =>
                        {
                            return Ok(Taken::Rejected(Reject::Corrupt(format!(
                                "op {} names the wrong device in its envelope",
                                op.id.seq
                            ))));
                        }
                        Ok(_) => {}
                    }
                }
                author_sig = open.author_sig();
                author_voids = None;
                items = Vec::new();
                open_native_piece = open;
                stream = match open_native_piece.verify() {
                    Ok(v) => Some(v),
                    Err(e) => return Ok(reject_of(e)),
                };
            }
        }
        let mut native_voids: Vec<(u64, u64, Chain)> = Vec::new();
        let mut pairs = items.into_iter();
        let mut next = || -> Option<Result<(NativeItem, Option<Stub>), SegmentError>> {
            match stream.as_mut() {
                Some(s) => s.next().map(|r| r.map(|i| (i, None))),
                None => pairs.next().map(Ok),
            }
        };
        let mut last = start_last;
        let mut tail = self.tail(&device, last)?;
        let (mut landed, mut known, mut parked) = (0u64, 0u64, 0u64);
        let mut chain = header.prev_chain;
        let mut seq = header.first;
        while let Some(item) = next() {
            if self.exhausted() {
                // 预算用完：停在这一项之前。已落的是日志前缀，下一批再交这一段时按已有跳过。
                self.cut = true;
                self.tally.landed += landed;
                return Ok(Taken::Landed {
                    landed,
                    known,
                    parked,
                });
            }
            // verify() 已整段校验过；第二遍流式解（超大的段）不该再出错，出了就是库外的意外，整笔回滚。
            let (item, stub) =
                item.map_err(|e| format!("gen4 receive: segment changed while reading: {e}"))?;
            let prev = chain;
            let end = seq + item.span() - 1;
            let after = match &item {
                NativeItem::Op(op) => chain_next4(&prev, op),
                NativeItem::Void { chain_after, .. } => *chain_after,
            };
            if let (NativeItem::Void { count, .. }, None) = (&item, &stub) {
                native_voids.push((seq, *count, after));
            }
            if end <= last {
                known += item.span();
                if end == last && after != tail {
                    self.tally.landed += landed;
                    return Ok(Taken::Diverged { device, seq: end });
                }
            } else {
                // 接得上本机日志的（正好接在末尾，或空洞越过末尾）先比前一环，再看依赖：分叉与依赖齐不齐无关，
                // 依赖还没到就先进缓冲的话，分叉要等依赖到了才看得出来，一批之内的结果就取决于到达顺序了。
                if seq <= last + 1 {
                    let here = if seq == last + 1 {
                        Some(tail)
                    } else {
                        self.t.chain_known(self.col, &device, seq - 1)?
                    };
                    if here.is_some_and(|h| h != prev) {
                        self.tally.landed += landed;
                        return Ok(Taken::Diverged { device, seq });
                    }
                }
                // 剔除项落成空洞之前（或进等待缓冲之前）记下它的剔除记录：本机以后重切这一段要用。
                if let Some(s) = &stub {
                    self.t.put_stub(self.col, s)?;
                }
                if seq > last + 1 || !self.ready(&item) {
                    if self.park(&device, seq, &prev, &after, &item)? {
                        self.spent += 1;
                    }
                    parked += 1;
                    chain = after;
                    seq = end + 1;
                    continue;
                }
                // 正好接在末尾（seq == last + 1），或空洞越过末尾（seq <= last < end）。
                known += last + 1 - seq;
                self.land(&device, seq, last, &item, &after)?;
                landed += 1;
                self.spent += 1;
                last = end;
                tail = after;
            }
            chain = after;
            seq = end + 1;
        }
        self.tally.landed += landed;
        // 段整个落在本机日志里面：在段尾比一次链值。
        if header.last < last {
            // 本机那里在空洞内部（没有链值）才比不了；其余错误是库出错，原样往上报。
            if let Some(here) = self.t.chain_known(self.col, &device, header.last)? {
                if here != header.last_chain {
                    return Ok(Taken::Diverged {
                        device,
                        seq: header.last,
                    });
                }
            }
        }
        // 整段走完：记下作者签名与作者签的空洞（本机以后从日志重切这一段用，`sync_state.rs` `recut_from_log`）。
        if !matches!(&self.me, Some((me, _)) if *me == device) {
            self.t.note_author_version(
                self.col,
                &AuthorVersion {
                    header,
                    sig: author_sig,
                    voids: author_voids.unwrap_or(native_voids),
                },
            )?;
        }
        Ok(Taken::Landed {
            landed,
            known,
            parked,
        })
    }

    /// 重切件里一条要落库的剔除项 [s] 声称的那条 Purge 本机认不认（`gen4/recut.rs`「信任口径」第 3 条）：本机日志或等待
    /// 缓冲里有了这条操作、它是 Purge、目标在 [s] 作者签的清除目标里、[s] 的作者写它时没见过它、它的作者本机不拒绝 =
    /// None（认）；否则交回这一件的结论。
    fn purge_vouches(&self, s: &Stub) -> Result<Option<Taken>, String> {
        let p = s.purge;
        let mut candidates: Vec<Op4> = Vec::new();
        match self.t.entry(self.col, &p)? {
            Some(e) => match e.op() {
                Some(op) => candidates.push(op.clone()),
                None => return Ok(Some(Taken::Rejected(Reject::NotPurged(s.id())))),
            },
            None => {
                if let Some(k) = self.t.key_of(self.col, &p)? {
                    let rows: Vec<Option<Vec<u8>>> = {
                        let mut stmt = self
                            .t
                            .conn()
                            .prepare_cached("SELECT op FROM op_wait WHERE k = ?1")
                            .map_err(sql)?;
                        let rows = stmt.query_map([k], |r| r.get(0)).map_err(sql)?;
                        rows.collect::<rusqlite::Result<_>>().map_err(sql)?
                    };
                    for op in rows.into_iter().flatten() {
                        candidates.push(op_of_bytes(&op)?);
                    }
                }
            }
        }
        if candidates.is_empty() {
            return Ok(Some(Taken::Deferred(Defer::PurgePending(p))));
        }
        let covers = candidates.iter().any(|op| {
            op.id == p
                && op.kind == KIND_PURGE
                && matches!(op.body(), Ok(Body4::Purge { kind, entity }) if s.covered_by(&p, &(kind, entity.clone())))
        });
        if !covers {
            return Ok(Some(Taken::Rejected(Reject::NotPurged(s.id()))));
        }
        if !matches!(&self.me, Some((me, _)) if *me == p.device)
            && self.t.trust_of(self.col, &p.device)?.is_some()
        {
            return Ok(Some(Taken::Deferred(Defer::UntrustedUploader(p.device))));
        }
        Ok(None)
    }

    /// 本机这台设备日志末尾的链值（原生日志；一条都没有 = 链的起点）。
    fn tail(&self, device: &Id, last: u64) -> Result<Chain, String> {
        if last == 0 {
            Ok(CHAIN_ZERO)
        } else {
            self.t.chain_at(self.col, device, last)
        }
    }

    /// 依赖齐了（空洞没有依赖）。
    fn ready(&self, item: &NativeItem) -> bool {
        // 依赖都已在本机日志里，或落在本机停用了的设备上（[Receiver::retired]）。
        match item {
            NativeItem::Op(op) => self.deps_ready(&op.deps),
            NativeItem::Void { .. } => true,
        }
    }

    /// 落一项。[seq] 是这一项的第一个 seq，[last] 是本机现在的末尾（`seq == last + 1`，或空洞越过末尾时
    /// `seq <= last`：只落多出来的那一截）。
    fn land(
        &mut self,
        device: &Id,
        seq: u64,
        last: u64,
        item: &NativeItem,
        after: &Chain,
    ) -> Result<(), String> {
        match item {
            NativeItem::Op(op) => {
                if op.id.seq != last + 1 || op.id.seq != seq || op.id.device != *device {
                    return Err(format!(
                        "gen4 receive: {}:{} does not follow {last}",
                        op.id.device, op.id.seq
                    ));
                }
                let chain = self.t.append_native(self.col, op)?;
                if chain != *after {
                    // 前一环已核对过等于本机末尾，同一个函数算不出两个值。
                    return Err(format!(
                        "gen4 receive: {}:{} chained differently from its segment",
                        op.id.device, op.id.seq
                    ));
                }
                self.applied.set(*device, op.id.seq);
                self.tell(&op.id)?;
            }
            NativeItem::Void { count, chain_after } => {
                let end = seq + count - 1;
                if seq > last + 1 || end <= last {
                    return Err(format!(
                        "gen4 receive: void {seq}..={end} of {device} does not extend {last}"
                    ));
                }
                self.t
                    .append_native_void(self.col, device, end - last, chain_after)?;
                self.applied.set(*device, end);
            }
        }
        Ok(())
    }

    fn park(
        &mut self,
        device: &Id,
        seq: u64,
        prev: &Chain,
        after: &Chain,
        item: &NativeItem,
    ) -> Result<bool, String> {
        let k = self.t.key_for(
            self.col,
            &OpId {
                device: *device,
                seq,
            },
        )?;
        let op = match item {
            NativeItem::Op(op) => Some(op.encode()),
            NativeItem::Void { .. } => None,
        };
        let span = i64::try_from(item.span()).map_err(|_| "gen4 receive: span out of range")?;
        self.t.write(|| {
            self.t
                .conn()
                .prepare_cached(
                    "INSERT OR IGNORE INTO op_wait (k, prev, chain, span, op) VALUES (?1, ?2, ?3, ?4, ?5)",
                )
                .map_err(sql)?
                .execute(params![k, &prev[..], &after[..], span, op])
                .map_err(sql)
                .map(|n| n > 0)
        })
    }

    // ------------------------------------------------------------ 承袭段

    /// 收一个承袭段（`hrt-…`，`FSH4`）。[key] = 它所在位置的密钥。
    pub fn heritage(&mut self, bytes: &[u8], key: Option<&CollectionKey>) -> Result<Taken, String> {
        let taken = self.heritage_inner(bytes, key)?;
        Ok(self.count(taken))
    }

    fn heritage_inner(
        &mut self,
        bytes: &[u8],
        key: Option<&CollectionKey>,
    ) -> Result<Taken, String> {
        let header: HeritageHeader = match peek_heritage_header(bytes) {
            Ok(h) => h,
            Err(e) => return Ok(reject_of(e)),
        };
        if !self.collections.contains(&header.collection) {
            return Ok(Taken::Rejected(Reject::WrongCollection(header.collection)));
        }
        match self.kind_of(&header.device)? {
            Some((k, _)) if k != DEV_HERITAGE => {
                return Ok(Taken::Rejected(Reject::WrongLog(header.device)));
            }
            Some((_, src)) if src != Some(header.source) => {
                return Ok(Taken::Rejected(Reject::WrongLog(header.device)));
            }
            _ => {}
        }
        let uploader = header.uploader;
        let Some(public) = self.public_of(&uploader)? else {
            return Ok(Taken::Deferred(Defer::UnknownSigner(uploader)));
        };
        if self.t.trust_of(self.col, &uploader)?.is_some() {
            return Ok(Taken::Deferred(Defer::UntrustedUploader(uploader)));
        }
        let open = match open_heritage_verified(bytes, &public, key) {
            Ok(o) => o,
            Err(e) => return Ok(reject_of(e)),
        };
        if key.is_some() && !open.header.encrypted {
            return Ok(Taken::Rejected(Reject::PlainOnSealed));
        }
        if open.header != header {
            return Ok(Taken::Rejected(Reject::Corrupt(
                "header changed under the signature".into(),
            )));
        }
        // 第一遍：整段校验（覆盖区间、末槽的链指纹），一条都不落。
        let slots = match open.slots() {
            Ok(s) => s,
            Err(e) => return Ok(reject_of(e)),
        };
        for s in slots {
            if let Err(e) = s {
                return Ok(reject_of(e));
            }
        }
        if let Some(rejected) = self.vouched_author_key(&header)? {
            return Ok(Taken::Rejected(rejected));
        }
        // 第二遍：落库。
        let slots = open
            .slots()
            .map_err(|e| format!("gen4 receive: {e}"))?
            .map(|s| s.map_err(|e| format!("gen4 receive: segment changed while reading: {e}")));
        let taken = self.land_slots(
            &header.source,
            fingerprint(&header.prev_chain),
            header.t_version,
            slots,
        )?;
        // 段头的两端是上传者签过的完整原链值（末端另有末槽的链指纹核对），收尾时记下来给承袭上传切段用（inherit.rs）。
        self.marks_due
            .push((header.device, header.first - 1, header.prev_chain));
        self.marks_due
            .push((header.device, header.last, header.last_chain));
        Ok(taken)
    }

    /// 承袭段头带的旧设备公钥（`heritage.rs` 的 `author_key`，上传者签名担保；段已验过签、整段合规）。本机还没记过
    /// 这台旧设备的公钥就登记下来：之后有人拿另一把钥匙冒充它写 head（旧根的 v3 head、新根的 head），在 [Truth::set_peer]
    /// 就是公钥对不上（先到先得），不再是「第一次见到」——否则冒充者会被当成「本机已有它的日志」的熟设备，它签的段
    /// 按它自己报的钥匙验签、里面的清除照常执行（G10-4 第四轮复核 major）。不判首次信任：上传者受信，它担保的作者
    /// 与段里的操作同样可信（D20，`inherit.rs` 只替上传者自己信任的作者上传）。本机记的是另一把 =
    /// [Reject::AuthorKeyMismatch]。段头不带公钥（上传者也不知道：协议 3 里没有公钥的设备行）什么都不做。
    fn vouched_author_key(&self, header: &HeritageHeader) -> Result<Option<Reject>, String> {
        let Some(public) = header.author_key else {
            return Ok(None);
        };
        match self.t.device_key(self.col, &header.device)? {
            Some(cur) if cur != public => Ok(Some(Reject::AuthorKeyMismatch(header.device))),
            Some(_) => Ok(None),
            None => {
                self.t.set_peer(
                    self.col,
                    &Peer {
                        device: header.device,
                        public,
                        name: None,
                        ext: None,
                        head_gen: None,
                        first_seen: None,
                    },
                )?;
                Ok(None)
            }
        }
    }

    /// 承袭槽按序落库（[Receiver::heritage] 与 [Receiver::legacy] 共用）：已有的按落库规则，正好接在末尾、依赖齐了的
    /// 落进日志，其余进待投递、带前一环的链指纹（第一个槽的前一环是 [prev_fp]）。
    fn land_slots(
        &mut self,
        src: &Id,
        mut prev_fp: Fp,
        tv: u32,
        slots: impl Iterator<Item = Result<HeritageSlot, String>>,
    ) -> Result<Taken, String> {
        let (mut landed, mut known, mut parked) = (0u64, 0u64, 0u64);
        for s in slots {
            let s = s?;
            let last = self.t.last_of(self.col, &s.id.device)?;
            if s.id.seq <= last {
                known += 1;
                self.put_known(src, &s, tv)?;
            } else if s.id.seq == last + 1 && self.slot_ready(&s) {
                if self.put_next(src, &s, tv)? {
                    landed += 1;
                } else {
                    parked += 1;
                }
            } else if self.t.put_pending(self.col, src, &s, tv, Some(prev_fp))? == Put::Conflict {
                self.tally.conflicts += 1;
            } else {
                parked += 1;
            }
            prev_fp = s.fp;
        }
        self.tally.landed += landed;
        // 承袭段也计入收段让路的预算（[Receiver::with_budget]）：它在段的中途不停（承袭段不切），但用完预算之后这一批
        // 不再开下一段，一个事务最多超出一个承袭段。
        self.spent += landed + parked;
        Ok(Taken::Landed {
            landed,
            known,
            parked,
        })
    }

    /// 把这一批段里给出的完整原链值记成承袭日志的链值记号（[Receiver::finish] 在投完待投递之后调，所以乱序到达的段
    /// 一样记得上）：只记本机日志里已有、链指纹相符的 seq（还在待投递的、分叉另一支的不记；seq 0 是链的起点，不用记）。
    fn mark_due(&mut self) -> Result<(), String> {
        for (device, seq, chain) in std::mem::take(&mut self.marks_due) {
            if seq == 0 {
                continue;
            }
            let id = OpId { device, seq };
            if self.t.entry(self.col, &id)?.and_then(|e| e.fp) == Some(fingerprint(&chain)) {
                self.t.set_mark(self.col, &device, seq, &chain)?;
            }
        }
        Ok(())
    }

    // ------------------------------------------------------------ 旧根捡漏

    /// 收旧根（协议 3 的 `v3/devices/<作者>/` 下的 `seg-…` / `rly-…`，`FSG2` / `FSRL`）里的一段（设计 §6.2 第 4 步「捡漏」）：
    /// 按作者公钥验签、解密、重算协议 3 的链，逐条转译（T，`gen4::translate`）成承袭槽，再与 [Receiver::heritage] 一样
    /// 按序落库。[dir] 是这个旧根所在的位置目录名（本集合或被它并入过的集合的），来源集合 = 协议 3 集合标识
    /// `collection_of(dir)`；[key] = 这个位置的密钥。
    ///
    /// 与承袭段的区别：作者自己签的、链由本机重算核对，所以**不看信任**（与迁移灌入同口径：不信任的设备的旧操作照样进
    /// 承袭日志，信任只管派生层执行不执行它的删除 / 清除）；加密位置上的明文旧段照收（协议 3 时期写下的，BUG-4299
    /// 之前的旧客户端会写出这种段；不收就丢了那几条操作。本机从不往位置写明文，不受影响）。
    /// 段里每 [HERITAGE_MARK_EVERY] 条与两端的完整链值记成记号（之后切承袭段用）。
    pub fn legacy(
        &mut self,
        bytes: &[u8],
        dir: &str,
        key: Option<&CollectionKey>,
    ) -> Result<Taken, String> {
        let taken = self.legacy_inner(bytes, dir, key)?;
        self.legacy_taken.push(taken.clone());
        Ok(self.count(taken))
    }

    fn legacy_inner(
        &mut self,
        bytes: &[u8],
        dir: &str,
        key: Option<&CollectionKey>,
    ) -> Result<Taken, String> {
        let source = collection_of(dir);
        if !self.dirs.contains(dir) {
            return Ok(Taken::Rejected(Reject::WrongCollection(source)));
        }
        let header = match peek_header(bytes) {
            Ok(h) => h,
            Err(e) => return Ok(reject_of(e)),
        };
        if header.collection != source {
            return Ok(Taken::Rejected(Reject::WrongCollection(header.collection)));
        }
        match self.kind_of(&header.device)? {
            Some((k, _)) if k != DEV_HERITAGE => {
                return Ok(Taken::Rejected(Reject::WrongLog(header.device)));
            }
            Some((_, src)) if src != Some(source) => {
                return Ok(Taken::Rejected(Reject::WrongLog(header.device)));
            }
            _ => {}
        }
        let Some(public) = self.t.device_key(self.col, &header.device)? else {
            return Ok(Taken::Deferred(Defer::UnknownSigner(header.device)));
        };
        // 整段先验完、转译完再落（坏段一条都不落）。段的操作数有上限（协议 3 `SEGMENT_MAX_OPS`）。
        let seg = match open_verified(bytes, &public, key) {
            Ok(s) => s,
            Err(e) => return Ok(reject_of(e)),
        };
        if seg.header != header {
            return Ok(Taken::Rejected(Reject::Corrupt(
                "header changed under the signature".into(),
            )));
        }
        let ops = match seg.verify() {
            Ok(ops) => ops,
            Err(e) => return Ok(reject_of(e)),
        };
        let mut chain = header.prev_chain;
        let mut slots: Vec<HeritageSlot> = Vec::new();
        let mut marks: Vec<(u64, Chain)> = vec![(header.first - 1, header.prev_chain)];
        for op in ops {
            let op = match op {
                Ok(op) => op,
                Err(e) => return Ok(reject_of(e)),
            };
            chain = chain_next(&chain, &op);
            match translate(&op, &chain) {
                Ok(slot) => slots.push(slot),
                Err(m) => return Ok(Taken::Rejected(Reject::Corrupt(m.to_owned()))),
            }
            if op.id.seq % HERITAGE_MARK_EVERY == 0 {
                marks.push((op.id.seq, chain));
            }
        }
        if chain != header.last_chain {
            return Ok(Taken::Rejected(Reject::ChainMismatch));
        }
        marks.push((header.last, header.last_chain));
        let taken = self.land_slots(
            &source,
            fingerprint(&header.prev_chain),
            T_VERSION,
            slots.into_iter().map(Ok),
        )?;
        self.marks_due
            .extend(marks.into_iter().map(|(seq, c)| (header.device, seq, c)));
        Ok(taken)
    }

    /// 依赖都已在本机日志里，或落在本机停用了的设备上（[Receiver::retired]）。
    fn deps_ready(&self, deps: &Vv) -> bool {
        deps.0
            .iter()
            .all(|(d, &s)| s <= self.applied.get(d) || self.retired.contains(d))
    }

    fn slot_ready(&self, s: &HeritageSlot) -> bool {
        match &s.body {
            SlotBody::Op(op) => self.deps_ready(&op.deps),
            SlotBody::Raw3(raw) => self.deps_ready(raw.deps()),
            SlotBody::Alias(_) | SlotBody::Void => true,
        }
    }

    /// 本机日志里已有这个操作号：按落库规则，换掉了就告诉索引。
    fn put_known(&mut self, src: &Id, s: &HeritageSlot, tv: u32) -> Result<(), String> {
        let before = self.t.entry(self.col, &s.id)?;
        match self.t.put_heritage(self.col, src, s, tv)? {
            Put::Replaced if self.mode == Settle::Incremental => {
                let before = before.ok_or("gen4 receive: replaced a slot that was not there")?;
                self.idx.remove(&before)?;
                self.tell(&s.id)?;
            }
            Put::Conflict => self.tally.conflicts += 1,
            _ => {}
        }
        Ok(())
    }

    /// 正好接在末尾、依赖齐了。落进日志 = true；同号有待投递的另一支更小（[Put::Yielded]）也算落了（日志里是那一支）。
    fn put_next(&mut self, src: &Id, s: &HeritageSlot, tv: u32) -> Result<bool, String> {
        match self.t.put_heritage(self.col, src, s, tv)? {
            Put::Inserted | Put::Yielded => {
                self.applied.set(s.id.device, s.id.seq);
                self.tell(&s.id)?;
                Ok(true)
            }
            other => Err(format!(
                "gen4 receive: appending {}:{} gave {other:?}",
                s.id.device, s.id.seq
            )),
        }
    }

    // ------------------------------------------------------------ 收尾

    /// 这一批开在哪个真相层、哪个集合上（同一个事务；`oldroot.rs` 收尾记旧根指纹用）。
    pub(super) fn scope(&self) -> (&'t Truth<'c>, i64) {
        (self.t, self.col)
    }

    /// 这一批 [Receiver::legacy] 逐段的结论（按调用顺序）。
    pub(super) fn legacy_taken(&self) -> &[Taken] {
        &self.legacy_taken
    }

    /// 本机这一批改了某台设备的信任状态（`Truth::note_new_peer` 写了行）：收尾时把扣住的删除与清除重判
    /// （`weigh.rs` [Index::trust_changed]）。
    pub fn trust_changed(&mut self) {
        self.idx.trust_changed();
    }

    /// 把等待缓冲里接得上的投完，再收派生层。消费这一批。
    pub fn finish(mut self) -> Result<Received, String> {
        // 等待项的投递同样受预算约束（收段让路）：用完就停，剩下接得上的留给调用方下一个事务（`drain_more`）。
        // 停下时这一遍的分叉 / 两支报告可能不全，下一遍投完时再报。
        let last_pass = loop {
            let pass = self.drain_native()?;
            let heritage = self.drain_heritage()?;
            self.tally.delivered += pass.delivered + heritage;
            if pass.delivered + heritage == 0 || self.drain_cut {
                break pass;
            }
        };
        self.tally.drain_more = self.drain_cut;
        self.tally.spent = self.spent;
        self.tally.forked = last_pass.forked;
        self.tally.diverged_waiting = last_pass.diverged.into_iter().collect();
        // 只数不读：每片收尾都报这两个数，不能每片把整个缓冲解一遍（等待 8000 项时那是近似平方的开销）。
        self.tally.waiting = self.t.waiting_count(self.col)?;
        self.tally.pending = self.t.pending_count(self.col)?;
        self.mark_due()?;
        self.tally.settled = ingest_settle(self.t, &mut self.idx, self.col, self.mode)?;
        // 收进来的清除（或它的目标）让派生层判成「已清除」的操作：同一个事务里在真相层落成空洞（设计 §3.2，
        // `weigh.rs` [Index::execute_purges]）。本机已传的段里有它们 → 发件按空洞条数重切、重传。
        self.tally.voided = self.idx.execute_purges()?;
        Ok(self.tally)
    }

    /// 投一遍原生等待缓冲：投出的项数、同一个 seq 两支都接在末尾的设备、与本机日志分叉的等待项。
    ///
    /// 有界读取：每台设备只按主键区间读到「本机末尾 + 1」为止（[Truth::waiting_between]，不取操作正文），投出一项、
    /// 末尾前进了再读下一截；操作正文只为真要投的那一行点查（[Truth::waiting_op]）。所以一遍读到的行 = 这一遍投出的项
    /// + 已在本机日志里的（重复的删掉、另一支的报出来）+ 末尾后面那一格，与缓冲里排在后面、还接不上的项数无关——
    /// 等着 8000 项、每片只投几百项时，每片不再把整张 `op_wait` 连正文扫一遍（测试
    /// `draining_a_large_waiting_buffer_reads_only_what_it_delivers`）。
    fn drain_native(&mut self) -> Result<DrainPass, String> {
        type Row = WaitKey;
        let mut pass = DrainPass::default();
        for d in self.t.devices(self.col)? {
            if self.drain_cut {
                break;
            }
            // 等着的时候这台设备被一个承袭段认成了承袭日志：这些原生项永远落不下，丢掉（段还在位置上）。
            if d.kind.is_some_and(|k| k != DEV_NATIVE) {
                self.t.drop_waiting_of(d.dev)?;
                continue;
            }
            let (lo, hi) = k_range(d.dev);
            // 读到「末尾 + 1」那一格为止的主键上界。
            let upto = |last: u64| lo.saturating_add(last as i64 + 1).min(hi);
            let device = d.id;
            let mut last = d.last;
            let mut from = upto(last) + 1;
            let mut rows: Vec<Row> = self.t.waiting_between(lo, upto(last))?;
            if rows.is_empty() {
                continue;
            }
            let mut tail = self.tail(&device, last)?;
            let mut stale: Vec<(i64, Vec<u8>, Vec<u8>)> = Vec::new();
            let key = |r: &Row| (r.0, r.1.clone(), r.2.clone());
            let span_end = |r: &Row| k_seq(r.0) + r.3 as u64 - 1;
            // 整个已在本机日志里的：与本机同一支的（重复收到的、另一行投出后剩下的同一项）删；不同支的是身份分叉的
            // 证据，留在缓冲里报给 G8-6，不静默删。
            for r in &rows {
                if span_end(r) > last {
                    continue;
                }
                if self.waiting_diverges(&device, r)? {
                    pass.diverged.insert((device, k_seq(r.0)));
                } else {
                    stale.push(key(r));
                }
            }
            let mut i = 0;
            loop {
                if i == rows.len() {
                    // 这一截看完了：末尾前进过就接着读到新的「末尾 + 1」（同一个主键的行总在同一截里）。
                    let to = upto(last);
                    if from > to {
                        break;
                    }
                    rows = self.t.waiting_between(from, to)?;
                    from = to + 1;
                    i = 0;
                    if rows.is_empty() {
                        break;
                    }
                }
                let seq = k_seq(rows[i].0);
                let same: Vec<&Row> = rows[i..].iter().take_while(|r| r.0 == rows[i].0).collect();
                i += same.len();
                if seq > last + 1 {
                    break;
                }
                // 本轮投出后才落进日志的留给下一遍（上面那一段核对）。
                let live: Vec<&Row> = same.into_iter().filter(|r| span_end(r) > last).collect();
                if live.is_empty() {
                    continue;
                }
                // 接得上本机日志的前一环：正好在末尾之后的是末尾；越过末尾的空洞是它前一格（本机那里在空洞内部时
                // 比不了）。前一环不等的是另一支，报出来、留着。
                let here = if seq == last + 1 {
                    Some(tail)
                } else {
                    self.t.chain_known(self.col, &device, seq - 1)?
                };
                let mut fits: Vec<&Row> = Vec::new();
                for r in live {
                    match here {
                        Some(h) if chain32(&r.1)? != h => {
                            pass.diverged.insert((device, seq));
                        }
                        _ => fits.push(r),
                    }
                }
                if fits.len() > 1 {
                    pass.forked.push(device);
                    break;
                }
                let Some(r) = fits.first().map(|r| (*r).clone()) else {
                    break;
                };
                let after = chain32(&r.2)?;
                let item = match self.t.waiting_op(&r)? {
                    Some(op) => NativeItem::Op(op),
                    None => NativeItem::Void {
                        count: r.3 as u64,
                        chain_after: after,
                    },
                };
                if !self.ready(&item) {
                    break;
                }
                if let NativeItem::Op(op) = &item {
                    if op.id.seq != seq || op.id.device != device {
                        return Err(
                            "gen4 receive: a waiting op is filed under the wrong key".to_owned()
                        );
                    }
                    if chain_next4(&tail, op) != after {
                        // 前一环等于末尾、链值却对不上：缓冲里的这一行坏了，丢掉。
                        stale.push(key(&r));
                        break;
                    }
                }
                if self.exhausted() {
                    // 预算用完：这一项接得上但这一批不投（[Received::drain_more]）。
                    self.drain_cut = true;
                    break;
                }
                self.land(&device, seq, last, &item, &after)?;
                self.spent += 1;
                stale.push(key(&r));
                pass.delivered += 1;
                last = span_end(&r);
                tail = after;
            }
            self.delete_waiting(&stale)?;
        }
        Ok(pass)
    }

    /// 一个整个落在本机日志里的等待项与本机不是同一支：它的前一环、或它末尾的链值，与本机在同一处的不等（本机那里
    /// 在空洞内部、没有链值的那一头不比）。
    fn waiting_diverges(&self, device: &Id, r: &WaitKey) -> Result<bool, String> {
        let seq = k_seq(r.0);
        let end = seq + r.3 as u64 - 1;
        let prev = chain32(&r.1)?;
        let after = chain32(&r.2)?;
        let before = self.t.chain_known(self.col, device, seq - 1)?;
        let here = self.t.chain_known(self.col, device, end)?;
        Ok(before.is_some_and(|c| c != prev) || here.is_some_and(|c| c != after))
    }

    fn delete_waiting(&self, rows: &[(i64, Vec<u8>, Vec<u8>)]) -> Result<(), String> {
        if rows.is_empty() {
            return Ok(());
        }
        self.t.write(|| {
            for (k, prev, chain) in rows {
                self.t
                    .conn()
                    .prepare_cached("DELETE FROM op_wait WHERE k = ?1 AND prev = ?2 AND chain = ?3")
                    .map_err(sql)?
                    .execute(params![k, prev, chain])
                    .map_err(sql)?;
            }
            Ok(())
        })
    }

    /// 投一遍承袭待投递。按承袭日志逐台点查「接在末尾的那一槽」（[Truth::pending_ready]），不把整张 `op_pending`
    /// 解一遍；投出的槽同样计入预算（[Receiver::with_budget]），用完就停、报 [Received::drain_more]。
    fn drain_heritage(&mut self) -> Result<u64, String> {
        let mut delivered = 0u64;
        for d in self.t.devices(self.col)? {
            if self.drain_cut {
                break;
            }
            if d.kind.is_some_and(|k| k != DEV_HERITAGE) {
                continue;
            }
            let device = d.id;
            while let Some(p) = self.t.pending_ready(self.col, &device)? {
                if !self.slot_ready(&p.slot) {
                    break;
                }
                if self.exhausted() {
                    self.drain_cut = true;
                    break;
                }
                let src = d.src.ok_or_else(|| {
                    format!("gen4 receive: pending slots of {device} have no source")
                })?;
                if !self.put_next(&src, &p.slot, p.tv)? {
                    break;
                }
                self.spent += 1;
                delivered += 1;
            }
        }
        Ok(delivered)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gen4::heritage::{HeritageMeta, pack_heritage};
    use crate::gen4::op::Op4;
    use crate::gen4::op::tests::id;
    use crate::gen4::recut::recut4;
    use crate::gen4::relay::wrap_relay4;
    use crate::gen4::segment::pack_native;
    use crate::gen4::segment::tests::{chain_of, coll};
    use crate::store::gen4::derive::tests::{assert_rebuild_is_identity, dump, op};
    use crate::store::gen4::native::tests::{edit, ready};
    use crate::store::gen4::schema::open_in_memory;
    use crate::store::gen4::truth::{Peer, PeerPut, TRUST_PENDING, TRUST_REJECTED};
    use rusqlite::Connection;

    const A: u8 = 0x21;
    const B: u8 = 0x22;
    /// 旧设备（承袭日志）。
    const OLD: u8 = 0xd1;
    const NOW: i64 = 1_800_000_000_000;

    fn key_of(dev: u8) -> DeviceKey {
        DeviceKey::from_seed(&[dev; 32])
    }

    /// 绑集合、建本机身份、记下 A / B 的公钥。设备下标（`devs.dev`，本机的小整数，派生表的主键里有它）按第一次见到的
    /// 顺序发；这里先按固定顺序把 A、B、OLD 点个名，不同到达顺序的结果才能逐行比（语义上下标只是本机编号）。
    fn setup(t: &Truth<'_>) -> i64 {
        let col = ready(t);
        t.tx(|t| {
            for d in [A, B, OLD] {
                t.key_for(
                    col,
                    &OpId {
                        device: id(d),
                        seq: 1,
                    },
                )?;
            }
            for d in [A, B] {
                t.set_peer(
                    col,
                    &Peer {
                        device: id(d),
                        public: key_of(d).public(),
                        name: None,
                        ext: None,
                        head_gen: None,
                        first_seen: None,
                    },
                )?;
            }
            Ok(())
        })
        .unwrap();
        col
    }

    /// 设备 [dev] 的第 [seq] 条（值 = 设备 + seq）。
    fn nop(dev: u8, seq: u64, deps: &[(u8, u64)]) -> Op4 {
        op(
            dev,
            seq,
            seq as i64 * 10 + i64::from(dev),
            deps,
            &edit(&format!("{dev}-{seq}")),
        )
    }

    fn seg_of(dev: u8, prev: Chain, items: &[NativeItem], key: Option<&CollectionKey>) -> Vec<u8> {
        let first = match &items[0] {
            NativeItem::Op(o) => o.id.seq,
            NativeItem::Void { .. } => panic!("start with an op"),
        };
        seg_at(dev, first, prev, items, key)
    }

    fn seg_at(
        dev: u8,
        first: u64,
        prev: Chain,
        items: &[NativeItem],
        key: Option<&CollectionKey>,
    ) -> Vec<u8> {
        pack_native(coll(), id(dev), first, items, prev, &key_of(dev), key)
            .unwrap()
            .1
    }

    fn ops_items(ops: &[Op4]) -> Vec<NativeItem> {
        ops.iter().cloned().map(NativeItem::Op).collect()
    }

    /// A 1..=4、B 1..=2，互相依赖：B1 依赖 A2，A3 依赖 B1。切成三段。
    fn world() -> Vec<Vec<u8>> {
        let a: Vec<Op4> = vec![
            nop(A, 1, &[]),
            nop(A, 2, &[]),
            nop(A, 3, &[(B, 1)]),
            nop(A, 4, &[(B, 2)]),
        ];
        let b: Vec<Op4> = vec![nop(B, 1, &[(A, 2)]), nop(B, 2, &[(A, 2)])];
        let a12 = chain_of(CHAIN_ZERO, &a[..2]);
        vec![
            seg_of(A, CHAIN_ZERO, &ops_items(&a[..2]), None),
            seg_of(A, a12, &ops_items(&a[2..]), None),
            seg_of(B, CHAIN_ZERO, &ops_items(&b), None),
        ]
    }

    fn take(
        t: &Truth<'_>,
        col: i64,
        mode: Settle,
        segs: &[&[u8]],
        key: Option<&CollectionKey>,
    ) -> (Vec<Taken>, Received) {
        t.tx(|t| {
            let mut r = Receiver::open(t, col, mode)?;
            let mut out = Vec::new();
            for s in segs {
                out.push(if s.starts_with(crate::gen4::heritage::MAGIC) {
                    r.heritage(s, key)?
                } else {
                    r.native(s, key)?
                });
            }
            Ok((out, r.finish()?))
        })
        .unwrap()
    }

    /// (派生表, 各原生日志的末尾与链值, 原生等待项数, 承袭待投递数)。
    type Snapshot = (Vec<String>, Vec<(Id, u64, Chain)>, usize, usize);

    /// 真相 + 派生 + 缓冲的一份快照（比结果用）。
    fn state(conn: &Connection, t: &Truth<'_>, col: i64) -> Snapshot {
        let tails = t
            .devices(col)
            .unwrap()
            .into_iter()
            .filter(|d| d.kind == Some(DEV_NATIVE) && d.last > 0)
            .map(|d| (d.id, d.last, t.chain_at(col, &d.id, d.last).unwrap()))
            .collect();
        (
            dump(conn, col),
            tails,
            t.waiting(col).unwrap().len(),
            t.pending(col).unwrap().len(),
        )
    }

    fn landed(l: u64, k: u64, p: u64) -> Taken {
        Taken::Landed {
            landed: l,
            known: k,
            parked: p,
        }
    }

    #[test]
    fn segments_land_and_receiving_again_is_a_no_op() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = setup(&t);
        let w = world();
        let (got, rec) = take(&t, col, Settle::Incremental, &[&w[0], &w[2], &w[1]], None);
        assert_eq!(got, vec![landed(2, 0, 0), landed(2, 0, 0), landed(2, 0, 0)]);
        assert_eq!(
            (rec.segments, rec.landed, rec.delivered, rec.waiting),
            (3, 6, 0, 0)
        );
        assert_eq!(t.tx(|t| t.audit(col)), Ok(6));
        assert_rebuild_is_identity(&t, col);
        let before = state(&conn, &t, col);
        let (got, rec) = take(&t, col, Settle::Incremental, &[&w[0], &w[1], &w[2]], None);
        assert_eq!(got, vec![landed(0, 2, 0), landed(0, 2, 0), landed(0, 2, 0)]);
        assert_eq!(rec.landed, 0);
        assert_eq!(state(&conn, &t, col), before);
    }

    /// 一批之内各段的到达顺序、两种收法，结果都与按序收相同，也等于从空重建。
    #[test]
    fn the_order_segments_arrive_in_does_not_change_the_result() {
        let w = world();
        let orders: [[usize; 3]; 6] = [
            [0, 1, 2],
            [0, 2, 1],
            [1, 0, 2],
            [1, 2, 0],
            [2, 0, 1],
            [2, 1, 0],
        ];
        let mut first = None;
        for mode in [Settle::Incremental, Settle::Rebuild] {
            for o in orders {
                let conn = open_in_memory().unwrap();
                let t = Truth::new(&conn);
                let col = setup(&t);
                let segs: Vec<&[u8]> = o.iter().map(|&i| w[i].as_slice()).collect();
                let (_, rec) = take(&t, col, mode, &segs, None);
                assert_eq!(rec.landed + rec.delivered, 6, "{o:?} {mode:?}");
                assert_eq!(rec.waiting, 0);
                assert_rebuild_is_identity(&t, col);
                let s = state(&conn, &t, col);
                match &first {
                    None => first = Some(s),
                    Some(f) => assert_eq!(&s, f, "{o:?} {mode:?}"),
                }
            }
        }
    }

    /// 依赖不齐的、前面缺着的进等待缓冲，跨事务留着，前提到了再投。
    #[test]
    fn early_ops_wait_across_batches_and_are_delivered_when_their_causes_arrive() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = setup(&t);
        let w = world();
        // B 依赖 A2；A 的第二段前面缺着。
        let (got, rec) = take(&t, col, Settle::Incremental, &[&w[2], &w[1]], None);
        assert_eq!(got, vec![landed(0, 0, 2), landed(0, 0, 2)]);
        assert_eq!((rec.waiting, rec.delivered), (4, 0));
        assert_eq!(t.tx(|t| t.audit(col)), Ok(0));
        let waiting: Vec<(Id, u64)> = t
            .waiting(col)
            .unwrap()
            .iter()
            .map(|w| (w.id.device, w.id.seq))
            .collect();
        assert_eq!(
            waiting,
            vec![(id(A), 3), (id(A), 4), (id(B), 1), (id(B), 2)]
        );
        // 下一批：A 的第一段到了，全部投出。
        let (got, rec) = take(&t, col, Settle::Incremental, &[&w[0]], None);
        assert_eq!(got, vec![landed(2, 0, 0)]);
        assert_eq!((rec.delivered, rec.waiting), (4, 0));
        assert_eq!(t.tx(|t| t.audit(col)), Ok(6));
        assert_rebuild_is_identity(&t, col);
        // 与一次按序收的逐行相同。
        let conn2 = open_in_memory().unwrap();
        let t2 = Truth::new(&conn2);
        let col2 = setup(&t2);
        take(&t2, col2, Settle::Incremental, &[&w[0], &w[2], &w[1]], None);
        assert_eq!(state(&conn, &t, col), state(&conn2, &t2, col2));
    }

    /// 「库还是空的」（首次信任的判据，`truth/trust.rs` [Truth::library_fresh]）把还停在等待缓冲里的原生操作算作
    /// 「有」：它们已经收下、只是前面缺着还没投递（协议 3 BUG-4478 同类缺口）。
    #[test]
    fn ops_still_waiting_count_as_user_data() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = setup(&t);
        let has = |t: &Truth<'_>| !t.tx(|t| t.library_fresh(col)).unwrap();
        assert!(!has(&t), "a fresh collection");
        let w = world();
        let (_, rec) = take(&t, col, Settle::Incremental, &[&w[2], &w[1]], None);
        assert_eq!((rec.waiting, rec.delivered), (4, 0));
        assert_eq!(t.tx(|t| t.audit(col)), Ok(0), "nothing landed yet");
        assert!(has(&t), "ops waiting in the buffer are user data");
    }

    /// 作者的日志与本机记的分叉：在末尾处比出来，之后的不落；段整个在本机日志里面时在段尾比。
    #[test]
    fn a_divergent_author_log_is_reported_and_nothing_after_it_lands() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = setup(&t);
        let a: Vec<Op4> = (1..=3).map(|s| nop(A, s, &[])).collect();
        take(
            &t,
            col,
            Settle::Incremental,
            &[&seg_of(A, CHAIN_ZERO, &ops_items(&a), None)],
            None,
        );
        let before = state(&conn, &t, col);
        // 另一支：第 3 条不同，带第 4 条。
        let mut other = a.clone();
        other[2] = op(A, 3, 999, &[], &edit("fork"));
        other.push(nop(A, 4, &[]));
        let s1 = seg_of(A, CHAIN_ZERO, &ops_items(&other), None);
        // 从第 3 条起的那一段（前一环与本机相同，自己不同）。
        let a2 = chain_of(CHAIN_ZERO, &a[..2]);
        let s2 = seg_of(A, a2, &ops_items(&other[2..]), None);
        // 接在本机末尾之后、前一环却不是本机末尾的。
        let forked_prefix = chain_of(CHAIN_ZERO, &other[..3]);
        let s3 = seg_of(A, forked_prefix, &ops_items(&other[3..]), None);
        // 整个在本机日志里面、段尾不同的。
        let s4 = seg_of(A, CHAIN_ZERO, &ops_items(&other[..3]), None);
        let (got, rec) = take(&t, col, Settle::Incremental, &[&s1, &s2, &s3, &s4], None);
        let d = |seq| Taken::Diverged { device: id(A), seq };
        assert_eq!(got, vec![d(3), d(3), d(4), d(3)]);
        assert_eq!((rec.diverged, rec.landed), (4, 0));
        assert_eq!(state(&conn, &t, col), before);
    }

    #[test]
    fn bad_or_early_segments_are_refused_whole() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = setup(&t);
        let a: Vec<Op4> = (1..=2).map(|s| nop(A, s, &[])).collect();
        let good = seg_of(A, CHAIN_ZERO, &ops_items(&a), None);
        let mut bad_sig = good.clone();
        *bad_sig.last_mut().unwrap() ^= 1;
        let truncated = good[..good.len() - 10].to_vec();
        let other_coll = pack_native(
            id(0xc9),
            id(A),
            1,
            &ops_items(&a),
            CHAIN_ZERO,
            &key_of(A),
            None,
        )
        .unwrap()
        .1;
        let stranger = seg_of(0x23, CHAIN_ZERO, &ops_items(&[nop(0x23, 1, &[])]), None);
        let k = CollectionKey([5; 32]);
        let sealed = seg_of(A, CHAIN_ZERO, &ops_items(&a), Some(&k));
        // 签名者冒名：A 的段用 B 的钥匙签。
        let forged = pack_native(
            coll(),
            id(A),
            1,
            &ops_items(&a),
            CHAIN_ZERO,
            &key_of(B),
            None,
        )
        .unwrap()
        .1;
        let (got, rec) = take(
            &t,
            col,
            Settle::Incremental,
            &[
                &bad_sig,
                &truncated,
                &other_coll,
                &stranger,
                &sealed,
                &forged,
            ],
            None,
        );
        assert_eq!(got[0], Taken::Rejected(Reject::BadSignature));
        assert!(
            matches!(got[1], Taken::Rejected(Reject::Corrupt(_))),
            "{:?}",
            got[1]
        );
        assert_eq!(got[2], Taken::Rejected(Reject::WrongCollection(id(0xc9))));
        assert_eq!(got[3], Taken::Deferred(Defer::UnknownSigner(id(0x23))));
        assert_eq!(got[4], Taken::Deferred(Defer::Undecryptable));
        assert_eq!(got[5], Taken::Rejected(Reject::BadSignature));
        assert_eq!((rec.rejected, rec.deferred, rec.landed), (4, 2, 0));
        // 加密位置上的明文件：拒（BUG-4299）；拿错密钥：等。
        let (got, _) = take(&t, col, Settle::Incremental, &[&good], Some(&k));
        assert_eq!(got, vec![Taken::Rejected(Reject::PlainOnSealed)]);
        let (got, _) = take(
            &t,
            col,
            Settle::Incremental,
            &[&sealed],
            Some(&CollectionKey([6; 32])),
        );
        assert_eq!(got, vec![Taken::Deferred(Defer::Undecryptable)]);
        assert_eq!(t.tx(|t| t.audit(col)), Ok(0));
        assert_eq!(t.waiting(col).unwrap(), vec![]);
        // 加密位置上的加密件：收。
        let (got, _) = take(&t, col, Settle::Incremental, &[&sealed], Some(&k));
        assert_eq!(got, vec![landed(2, 0, 0)]);
    }

    /// 作者 [dev] 的段 1..=n（[ops]）打包后的段头、作者签名与全部重切项。
    fn signed_by_author(ops: &[Op4], dev: u8) -> (NativeHeader, [u8; 64], Vec<RecutItem>) {
        let items = ops_items(ops);
        let (header, bytes) =
            pack_native(coll(), id(dev), 1, &items, CHAIN_ZERO, &key_of(dev), None).unwrap();
        let open = crate::gen4::segment::open_native_verified(&bytes, &key_of(dev).public(), None)
            .unwrap();
        let all = recut::from_native(&open).unwrap();
        (header, open.author_sig(), all)
    }

    /// 要被清除的那个实体（与 [nop] 写的实体不同：清除它不波及别的操作）。
    fn doomed_entity() -> crate::sync2::id::Key {
        crate::sync2::id::Key::Uuid(id(0x99))
    }

    /// 写 [doomed_entity] 的一条操作（设备 [dev] 第 [seq] 条）。
    fn doomed(dev: u8, seq: u64, deps: &[(u8, u64)]) -> Op4 {
        let e = crate::gen4::op::tests::native_edit();
        op(
            dev,
            seq,
            seq as i64 * 10 + i64::from(dev),
            deps,
            &Body4::Edit(crate::gen4::op::Edit4 {
                entity: doomed_entity(),
                value: format!("\"doomed-{dev}-{seq}\""),
                ..e
            }),
        )
    }

    /// 清除 [doomed_entity] 的一条 Purge（设备 [dev] 第 [seq] 条）。
    fn purge_op(dev: u8, seq: u64, deps: &[(u8, u64)]) -> Op4 {
        op(
            dev,
            seq,
            seq as i64 * 10 + i64::from(dev) + 5,
            deps,
            &Body4::Purge {
                kind: crate::gen4::op::tests::native_edit().kind,
                entity: doomed_entity(),
            },
        )
    }

    fn at(t: &Truth<'_>, col: i64, dev: u8, seq: u64) -> crate::store::gen4::truth::Entry {
        t.entry(
            col,
            &OpId {
                device: id(dev),
                seq,
            },
        )
        .unwrap()
        .unwrap()
    }

    /// 重切中继件（`gen4/recut.rs`）：重切者没记过公钥 = 等它的 head，待确认 = 等确认（这期间依赖作者的操作留在等待
    /// 缓冲）；重切者签名不是前缀里那个重切者的 = 坏件；受信之后照原生段落库，剔除项落成空洞、记下剔除记录与作者签名，
    /// 等着的操作随即投递。读者从没读过作者的 head 也收得下（区间与链尾由作者的原签名担保，不再看 head 的段清单）。
    #[test]
    fn recut_pieces_need_a_trusted_recutter_and_land_their_voids() {
        const C: u8 = 0x23;
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = setup(&t);
        let a = vec![nop(A, 1, &[]), doomed(A, 2, &[]), nop(A, 3, &[])];
        let (header, sig, all) = signed_by_author(&a, A);
        // B 清除 A2 写的那个实体（见过 A3），B 之后的操作都依赖它：拿不到 A 这一段就投不了。
        let p = purge_op(B, 1, &[(A, 3)]);
        let stubbed = recut::stub_one(&all, 1, 2, p.id).unwrap();
        let cut = |signer: u8, named: u8| {
            recut4(
                &header,
                &sig,
                &stubbed,
                &key_of(A).public(),
                &key_of(signer),
                id(named),
                None,
            )
            .unwrap()
        };
        let b = seg_of(B, CHAIN_ZERO, &ops_items(std::slice::from_ref(&p)), None);

        let (got, _) = take(&t, col, Settle::Incremental, &[&cut(C, C)], None);
        assert_eq!(got, vec![Taken::Deferred(Defer::UnknownSigner(id(C)))]);
        t.tx(|t| t.set_trust(col, &id(B), Some(TRUST_PENDING), NOW))
            .unwrap();
        let (got, r) = take(&t, col, Settle::Incremental, &[&cut(B, B), &b], None);
        assert_eq!(got[0], Taken::Deferred(Defer::UntrustedUploader(id(B))));
        assert_eq!(r.waiting, 1);
        assert_eq!(t.last_of(col, &id(A)).unwrap(), 0);

        t.tx(|t| t.set_trust(col, &id(B), None, NOW)).unwrap();
        let (got, _) = take(&t, col, Settle::Incremental, &[&cut(A, B)], None);
        assert_eq!(got, vec![Taken::Rejected(Reject::BadSignature)]);
        // B 的 Purge 在等待缓冲里（它依赖的 A3 还没到）：读者认得它，件照收。
        let (got, r) = take(&t, col, Settle::Incremental, &[&cut(B, B)], None);
        assert_eq!(got, vec![landed(3, 0, 0)]);
        assert_eq!((r.delivered, r.waiting), (1, 0));
        assert!(at(&t, col, A, 1).is_whole() && at(&t, col, A, 3).is_whole());
        assert!(!at(&t, col, A, 2).is_whole(), "the stub lands as a void");
        assert_eq!(t.last_of(col, &id(B)).unwrap(), 1);
        assert_eq!(t.chain_at(col, &id(A), 3).unwrap(), header.last_chain);
        // 本机以后重切这一段的材料：剔除记录与作者签名都记下了。
        let stub = t.stub_at(col, &id(A), 2).unwrap().unwrap();
        assert_eq!((stub.id(), stub.purge), (a[1].id, p.id));
        let v = t.author_version(col, &id(A), 1, 3).unwrap().unwrap();
        assert_eq!((v.header, v.sig, v.voids), (header, sig, vec![]));
    }

    /// 剔除项点名的 Purge 的作者本机不信任（待确认 / 已拒绝）：这条 Purge 本机不执行（weigh 判 S_DISTRUSTED），重切件
    /// 就不能让读者把作者的原件落成空洞——整件延后（UntrustedUploader = Purge 的作者），A 的日志不前进、不记剔除记录；
    /// 信任之后同一件照收。
    #[test]
    fn a_stub_naming_a_purge_by_an_untrusted_author_is_deferred_until_trusted() {
        for state in [TRUST_PENDING, TRUST_REJECTED] {
            let conn = open_in_memory().unwrap();
            let t = Truth::new(&conn);
            let col = setup(&t);
            let a = vec![nop(A, 1, &[]), doomed(A, 2, &[]), nop(A, 3, &[])];
            let (header, sig, all) = signed_by_author(&a, A);
            let p = purge_op(B, 1, &[(A, 3)]);
            let stubbed = recut::stub_one(&all, 1, 2, p.id).unwrap();
            // 重切者是 A 自己（受信），排除「重切者不受信」这条路。
            let piece = recut4(
                &header,
                &sig,
                &stubbed,
                &key_of(A).public(),
                &key_of(A),
                id(A),
                None,
            )
            .unwrap();
            // B 受信时收下它的 Purge（依赖 A3，进等待缓冲），之后改成不信任。
            let b = seg_of(B, CHAIN_ZERO, &ops_items(std::slice::from_ref(&p)), None);
            let (got, r) = take(&t, col, Settle::Incremental, &[&b], None);
            assert_eq!(got, vec![landed(0, 0, 1)]);
            assert_eq!(r.waiting, 1);
            t.tx(|t| t.set_trust(col, &id(B), Some(state), NOW))
                .unwrap();

            let (got, _) = take(&t, col, Settle::Incremental, &[&piece], None);
            assert_eq!(
                got,
                vec![Taken::Deferred(Defer::UntrustedUploader(id(B)))],
                "trust state {state}"
            );
            assert_eq!(t.last_of(col, &id(A)).unwrap(), 0);
            assert_eq!(t.stub_at(col, &id(A), 2).unwrap(), None);

            t.tx(|t| t.set_trust(col, &id(B), None, NOW)).unwrap();
            let (got, _) = take(&t, col, Settle::Incremental, &[&piece], None);
            assert_eq!(got, vec![landed(3, 0, 0)]);
            assert!(!at(&t, col, A, 2).is_whole());
            assert_eq!(t.stub_at(col, &id(A), 2).unwrap().unwrap().purge, p.id);
        }
    }

    /// 第五波根治（复核建议 (a)）：受信的重切者 B 换不了留下的操作、伪造不了作者没写到的 seq、挖不了没被清除的操作。
    /// 一律不落、不进等待缓冲；合法的那份之后照常收下。
    #[test]
    fn a_trusted_recutter_cannot_forge_kept_ops_future_seqs_or_unpurged_stubs() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = setup(&t);
        // A3 依赖 B1（= Purge）：A3 是作者见过这条清除之后写的，管不到它。
        let p = purge_op(B, 1, &[(A, 2)]);
        let a = vec![nop(A, 1, &[]), doomed(A, 2, &[]), doomed(A, 3, &[(B, 1)])];
        let (header, sig, all) = signed_by_author(&a, A);
        let author = key_of(A).public();
        let forge = |h: &NativeHeader, items: &[RecutItem]| {
            recut::sign_unchecked(h, &sig, items, &key_of(B), id(B))
        };
        // 什么都没落、等待缓冲里只有 B 自己的 [waiting] 条。
        let nothing = |t: &Truth<'_>, waiting: u64| {
            assert_eq!(t.last_of(col, &id(A)).unwrap(), 0);
            assert_eq!(t.waiting_count(col).unwrap(), waiting);
        };
        let good = recut::stub_one(&all, 1, 2, p.id).unwrap();
        // 1. 那条 Purge 本机还没有：等它（不落、不报坏）。
        let (got, _) = take(
            &t,
            col,
            Settle::Incremental,
            &[&forge(&header, &good)],
            None,
        );
        assert_eq!(got, vec![Taken::Deferred(Defer::PurgePending(p.id))]);
        nothing(&t, 0);
        // B 的段到了（Purge 等着 A2）。
        let b2 = nop(B, 2, &[(A, 2)]);
        let other = op(
            B,
            3,
            77,
            &[(A, 2)],
            &Body4::Purge {
                kind: crate::gen4::op::tests::native_edit().kind,
                entity: crate::sync2::id::Key::Uuid(id(0x77)),
            },
        );
        let bs = seg_of(
            B,
            CHAIN_ZERO,
            &ops_items(&[p.clone(), b2.clone(), other.clone()]),
            None,
        );
        let (got, r) = take(&t, col, Settle::Incremental, &[&bs], None);
        assert_eq!(got, vec![landed(0, 0, 3)]);
        assert_eq!(r.waiting, 3);
        // 2. 留下的操作换了内容（链尾跟着改成新链的值）：作者签名不认。
        let mut kept = good.clone();
        if let RecutItem::Op(op) = &mut kept[0] {
            op.hlc.logical += 1;
        }
        let mut h = header.clone();
        h.last_chain = recut::chain_through(h.prev_chain, &kept);
        // 3. 作者没写到的 seq：区间伸到 4，多一条伪造的操作。
        let mut future = good.clone();
        future.push(RecutItem::Op(op(A, 4, 47, &[], &edit("FORGED"))));
        let mut h4 = header.clone();
        h4.last = 4;
        h4.last_chain = recut::chain_through(h4.prev_chain, &future);
        // 4. 只带链值的重置空洞（作者没签过这个空洞）。
        let mut reset = good.clone();
        reset[0] = RecutItem::Void {
            count: 1,
            chain_after: chain_of(CHAIN_ZERO, &a[..1]),
        };
        for (bad, why) in [
            (forge(&h, &kept), Reject::BadSignature),
            (forge(&header, &kept), Reject::ChainMismatch),
            (forge(&h4, &future), Reject::BadSignature),
            (forge(&header, &reset), Reject::BadSignature),
        ] {
            let (got, _) = take(&t, col, Settle::Incremental, &[&bad], None);
            assert_eq!(got, vec![Taken::Rejected(why)]);
            nothing(&t, 3);
        }
        // 5. 挖掉没被清除的操作：声称的「Purge」是 B2（不是 Purge）、是清别的实体的 B3、或作者已经见过它（A3）。
        for (seq, by) in [(2, b2.id), (2, other.id), (3, p.id)] {
            let stubbed = recut::stub_one(&all, 1, seq, by).unwrap();
            let (got, _) = take(
                &t,
                col,
                Settle::Incremental,
                &[&forge(&header, &stubbed)],
                None,
            );
            assert_eq!(
                got,
                vec![Taken::Rejected(Reject::NotPurged(a[seq as usize - 1].id))]
            );
            nothing(&t, 3);
        }
        // 合法的那份：落下，B 的三条随即投递。
        assert!(recut::author_signed(&header, &sig, &good, &author));
        let (got, r) = take(
            &t,
            col,
            Settle::Incremental,
            &[&forge(&header, &good)],
            None,
        );
        // A1、A2（剔除项）落下；A3 依赖 B1，先进缓冲，随 B 的三条一起投递。
        assert_eq!(got, vec![landed(2, 0, 1)]);
        assert_eq!((r.delivered, r.waiting), (4, 0));
        assert_eq!(t.last_of(col, &id(A)).unwrap(), 3);
        assert!(!at(&t, col, A, 2).is_whole());
        assert!(at(&t, col, A, 3).is_whole(), "A3 saw the purge: kept");
    }

    /// 合法的重切件在各种读者上都收得下：只有 Purge 的、已有原文而还没有 Purge 的（不因此挖掉本机的完整操作）、
    /// 原文与 Purge 都有的、只有前一半的；作者的原签名担保区间与链尾，读者读没读过、读的是哪个位置的作者 head 都不相干。
    #[test]
    fn a_legal_recut_lands_on_every_reader() {
        let a = vec![
            nop(A, 1, &[]),
            nop(A, 2, &[]),
            doomed(A, 3, &[]),
            nop(A, 4, &[]),
        ];
        let (header, sig, all) = signed_by_author(&a, A);
        let p = purge_op(B, 1, &[(A, 4)]);
        let stubbed = recut::stub_one(&all, 1, 3, p.id).unwrap();
        let piece = recut4(
            &header,
            &sig,
            &stubbed,
            &key_of(A).public(),
            &key_of(B),
            id(B),
            None,
        )
        .unwrap();
        let b = seg_of(B, CHAIN_ZERO, &ops_items(std::slice::from_ref(&p)), None);
        let original = seg_of(A, CHAIN_ZERO, &ops_items(&a), None);
        let first_half = seg_of(A, CHAIN_ZERO, &ops_items(&a[..2]), None);
        // (读者已有的, 期望：A3 完整?, 期望：B 的末尾)
        let readers: [(&[&[u8]], bool, u64); 4] = [
            (&[&b], false, 1),
            (&[&original], true, 0),
            (&[&original, &b], false, 1),
            (&[&first_half, &b], false, 1),
        ];
        for (i, (before, keeps, b_last)) in readers.iter().enumerate() {
            let conn = open_in_memory().unwrap();
            let t = Truth::new(&conn);
            let col = setup(&t);
            take(&t, col, Settle::Incremental, before, None);
            let (got, r) = take(&t, col, Settle::Incremental, &[&piece], None);
            assert!(
                matches!(got[0], Taken::Landed { .. }),
                "reader {i}: {got:?}"
            );
            assert_eq!(r.waiting, 0, "reader {i}");
            assert_eq!(t.last_of(col, &id(A)).unwrap(), 4, "reader {i}");
            assert_eq!(t.last_of(col, &id(B)).unwrap(), *b_last, "reader {i}");
            assert_eq!(at(&t, col, A, 3).is_whole(), *keeps, "reader {i}");
            assert!(at(&t, col, A, 4).is_whole(), "reader {i}");
            assert_eq!(t.chain_at(col, &id(A), 4).unwrap(), header.last_chain);
        }
    }

    /// 本机自己的日志：别人以本机的名义伪造本机以后的 seq（作者签名是假的）不收。
    #[test]
    fn a_recut_of_my_own_log_must_carry_my_signature() {
        use crate::store::gen4::native::tests::ME;
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = setup(&t);
        let p = purge_op(B, 1, &[]);
        let mine = vec![nop(ME, 1, &[]), nop(ME, 2, &[])];
        let items: Vec<RecutItem> = vec![
            RecutItem::Op(mine[0].clone()),
            RecutItem::Stub(Stub::of(&mine[1], p.id)),
        ];
        let header = NativeHeader {
            encrypted: false,
            collection: coll(),
            device: id(ME),
            first: 1,
            last: 2,
            prev_chain: CHAIN_ZERO,
            last_chain: recut::chain_through(CHAIN_ZERO, &items),
        };
        let forged = recut::sign_unchecked(&header, &[0; 64], &items, &key_of(B), id(B));
        let (got, _) = take(&t, col, Settle::Incremental, &[&forged], None);
        assert_eq!(got, vec![Taken::Rejected(Reject::BadSignature)]);
        assert_eq!(t.last_of(col, &id(ME)).unwrap(), 0);
    }

    /// 中继件与原段收法相同；转发到加密位置的件必须封装，明文转发到加密位置的拒。
    #[test]
    fn relay_pieces_land_like_the_segments_they_carry() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = setup(&t);
        let a: Vec<Op4> = (1..=3).map(|s| nop(A, s, &[])).collect();
        let src_key = CollectionKey([1; 32]);
        let dst_key = CollectionKey([2; 32]);
        let seg = seg_of(A, CHAIN_ZERO, &ops_items(&a), Some(&src_key));
        let pub_a = key_of(A).public();
        let sealed_relay = wrap_relay4(&seg, &pub_a, Some(&src_key), Some(&dst_key)).unwrap();
        let plain_relay = wrap_relay4(&seg, &pub_a, Some(&src_key), None).unwrap();
        let (got, _) = take(
            &t,
            col,
            Settle::Incremental,
            &[&plain_relay],
            Some(&dst_key),
        );
        assert_eq!(got, vec![Taken::Rejected(Reject::PlainOnSealed)]);
        let (got, _) = take(
            &t,
            col,
            Settle::Incremental,
            &[&sealed_relay],
            Some(&dst_key),
        );
        assert_eq!(got, vec![landed(3, 0, 0)]);
        let (got, _) = take(&t, col, Settle::Incremental, &[&plain_relay], None);
        assert_eq!(got, vec![landed(0, 3, 0)]);
        assert_rebuild_is_identity(&t, col);
    }

    /// 作者签出的空洞照收，越过本机末尾的只落多出来的一截；本机已有的完整操作不被清掉。
    #[test]
    fn author_voids_land_and_never_take_local_ops_away() {
        let ops: Vec<Op4> = (1..=5).map(|s| nop(A, s, &[])).collect();
        let c = |n: usize| chain_of(CHAIN_ZERO, &ops[..n]);
        let items = vec![
            NativeItem::Op(ops[0].clone()),
            NativeItem::Void {
                count: 3,
                chain_after: c(4),
            },
            NativeItem::Op(ops[4].clone()),
        ];
        let voided = seg_of(A, CHAIN_ZERO, &items, None);
        // 新设备：直接收带空洞的段。
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = setup(&t);
        let (got, _) = take(&t, col, Settle::Incremental, &[&voided], None);
        assert_eq!(got, vec![landed(3, 0, 0)]);
        assert_eq!(t.tx(|t| t.audit(col)), Ok(5));
        assert!(!t.entry(col, &ops[2].id).unwrap().unwrap().is_whole());
        assert_eq!(t.chain_at(col, &id(A), 5).unwrap(), c(5));
        assert_rebuild_is_identity(&t, col);
        // 本机已有 1..=3 的完整操作：空洞越过末尾，只落第 4 条那一截，第 2、3 条保持完整。
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = setup(&t);
        take(
            &t,
            col,
            Settle::Incremental,
            &[&seg_of(A, CHAIN_ZERO, &ops_items(&ops[..3]), None)],
            None,
        );
        let (got, _) = take(&t, col, Settle::Incremental, &[&voided], None);
        assert_eq!(got, vec![landed(2, 3, 0)]);
        assert_eq!(t.tx(|t| t.audit(col)), Ok(5));
        for s in [2, 3] {
            assert!(
                t.entry(col, &ops[s - 1].id).unwrap().unwrap().is_whole(),
                "{s}"
            );
        }
        assert!(!t.entry(col, &ops[3].id).unwrap().unwrap().is_whole());
        assert_eq!(t.chain_at(col, &id(A), 5).unwrap(), c(5));
        assert_rebuild_is_identity(&t, col);
        // 空洞进等待缓冲（前面缺着）再投：同样只落越过末尾的那一截。
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = setup(&t);
        let tail = vec![
            NativeItem::Void {
                count: 3,
                chain_after: c(4),
            },
            NativeItem::Op(ops[4].clone()),
        ];
        let late = seg_at(A, 2, c(1), &tail, None);
        let (got, rec) = take(
            &t,
            col,
            Settle::Incremental,
            &[&late, &seg_of(A, CHAIN_ZERO, &ops_items(&ops[..1]), None)],
            None,
        );
        assert_eq!(got, vec![landed(0, 0, 2), landed(1, 0, 0)]);
        assert_eq!((rec.delivered, rec.waiting), (2, 0));
        assert_eq!(t.chain_at(col, &id(A), 5).unwrap(), c(5));
    }

    /// 同一个 seq 上两支都接在本机末尾：作者自己写出过两支，一支都不投。
    #[test]
    fn two_branches_waiting_at_one_seq_are_both_held() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = setup(&t);
        let a1 = nop(A, 1, &[]);
        let c1 = chain_of(CHAIN_ZERO, std::slice::from_ref(&a1));
        let x = op(A, 2, 30, &[(B, 1)], &edit("x"));
        let y = op(A, 2, 31, &[(B, 1)], &edit("y"));
        let sx = seg_of(A, c1, &ops_items(&[x]), None);
        let sy = seg_of(A, c1, &ops_items(&[y]), None);
        let a = seg_of(A, CHAIN_ZERO, &ops_items(&[a1]), None);
        let b = seg_of(B, CHAIN_ZERO, &ops_items(&[nop(B, 1, &[])]), None);
        let (got, rec) = take(&t, col, Settle::Incremental, &[&a, &sx, &sy, &b], None);
        assert_eq!(
            got,
            vec![
                landed(1, 0, 0),
                landed(0, 0, 1),
                landed(0, 0, 1),
                landed(1, 0, 0)
            ]
        );
        assert_eq!(rec.forked, vec![id(A)]);
        assert_eq!((rec.waiting, t.last_of(col, &id(A)).unwrap()), (2, 1));
        assert_rebuild_is_identity(&t, col);
    }

    /// 本集合日志里并入过的集合：它位置上的段（段头还写着原集合）照收；没并入过的拒。
    #[test]
    fn segments_of_a_joined_collection_are_admitted() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = setup(&t);
        // 本机绑着 coll()（目录 "dir"），并入目录名更小的 0xc7。
        t.join(col, &id(0xc7), "abc", NOW).unwrap();
        let a = vec![nop(A, 1, &[])];
        let old = seg_of(A, CHAIN_ZERO, &ops_items(&a), None);
        let new = pack_native(
            id(0xc7),
            id(A),
            1,
            &ops_items(&a),
            CHAIN_ZERO,
            &key_of(A),
            None,
        )
        .unwrap()
        .1;
        let stranger = pack_native(
            id(0xc8),
            id(A),
            1,
            &ops_items(&a),
            CHAIN_ZERO,
            &key_of(A),
            None,
        )
        .unwrap()
        .1;
        let (got, _) = take(&t, col, Settle::Incremental, &[&old, &new, &stranger], None);
        assert_eq!(
            got,
            vec![
                landed(1, 0, 0),
                landed(0, 1, 0),
                Taken::Rejected(Reject::WrongCollection(id(0xc8)))
            ]
        );
        assert_rebuild_is_identity(&t, col);
    }

    // ------------------------------------------------------------ 承袭段

    fn hslot(seq: u64, deps: &[(u8, u64)]) -> HeritageSlot {
        HeritageSlot::op(
            [seq as u8; 8],
            op(OLD, seq, seq as i64, deps, &edit(&format!("h{seq}"))),
        )
    }

    fn chain_with_fp(fp: u8) -> Chain {
        let mut c = [0x77; 32];
        c[..8].copy_from_slice(&[fp; 8]);
        c
    }

    /// 旧设备 OLD 的 [slots]，A 上传。
    fn hseg(slots: &[HeritageSlot], uploader: u8, key: Option<&CollectionKey>) -> Vec<u8> {
        hseg_with(slots, uploader, key, None)
    }

    /// [hseg]，段头带作者公钥 [author]（明文位置）。
    fn hseg_keyed(slots: &[HeritageSlot], uploader: u8, author: Option<[u8; 32]>) -> Vec<u8> {
        hseg_with(slots, uploader, None, author)
    }

    fn hseg_with(
        slots: &[HeritageSlot],
        uploader: u8,
        key: Option<&CollectionKey>,
        author: Option<[u8; 32]>,
    ) -> Vec<u8> {
        let first = slots[0].id.seq;
        let meta = HeritageMeta {
            collection: coll(),
            source: id(0x5c),
            device: id(OLD),
            uploader: id(uploader),
            author_key: author,
            t_version: T_VERSION,
            prev_chain: if first == 1 {
                CHAIN_ZERO
            } else {
                chain_with_fp(first as u8 - 1)
            },
            last_chain: chain_with_fp(slots.last().unwrap().id.seq as u8),
        };
        pack_heritage(&meta, slots, &key_of(uploader), key)
            .unwrap()
            .1
    }

    #[test]
    fn heritage_segments_need_a_trusted_uploader_and_wait_for_their_prefix() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = setup(&t);
        let s12 = hseg(&[hslot(1, &[]), hslot(2, &[])], A, None);
        let s34 = hseg(&[hslot(3, &[]), hslot(4, &[])], A, None);
        // 依赖承袭操作的原生操作。
        let b = seg_of(B, CHAIN_ZERO, &ops_items(&[nop(B, 1, &[(OLD, 4)])]), None);
        t.tx(|t| t.set_trust(col, &id(A), Some(TRUST_PENDING), NOW))
            .unwrap();
        let (got, _) = take(&t, col, Settle::Incremental, &[&s12], None);
        assert_eq!(got, vec![Taken::Deferred(Defer::UntrustedUploader(id(A)))]);
        let by_stranger = hseg(&[hslot(1, &[])], 0x23, None);
        let (got, _) = take(&t, col, Settle::Incremental, &[&by_stranger], None);
        assert_eq!(got, vec![Taken::Deferred(Defer::UnknownSigner(id(0x23)))]);
        assert_eq!(t.tx(|t| t.audit(col)), Ok(0));
        t.tx(|t| t.set_trust(col, &id(A), None, NOW)).unwrap();
        // 乱序：第二段、原生操作先到，都等着；第一段到了一起投出。
        let (got, rec) = take(&t, col, Settle::Incremental, &[&s34, &b, &s12], None);
        assert_eq!(got, vec![landed(0, 0, 2), landed(0, 0, 1), landed(2, 0, 0)]);
        assert_eq!((rec.delivered, rec.waiting, rec.pending), (3, 0, 0));
        assert_eq!(t.tx(|t| t.audit(col)), Ok(5));
        assert_rebuild_is_identity(&t, col);
        // 再收一遍：全是已有。
        let (got, _) = take(&t, col, Settle::Incremental, &[&s12, &s34, &b], None);
        assert_eq!(got, vec![landed(0, 2, 0), landed(0, 2, 0), landed(0, 1, 0)]);
        // 与按序收相同。
        let conn2 = open_in_memory().unwrap();
        let t2 = Truth::new(&conn2);
        let col2 = setup(&t2);
        take(&t2, col2, Settle::Rebuild, &[&s12, &s34, &b], None);
        assert_eq!(state(&conn, &t, col), state(&conn2, &t2, col2));
    }

    /// 承袭段头担保的作者公钥（G10-4 第四轮复核 major）：本机没记过就登记、不写信任行（上传者受信即可信），之后拿另一把
    /// 钥匙冒充这台旧设备的 head 在 `set_peer` 就是公钥对不上；本机记着另一把时，担保它的段整段不收（不落、不登记）。
    #[test]
    fn heritage_author_keys_are_registered_and_must_agree() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = setup(&t);
        let real = key_of(OLD).public();
        let evil = key_of(0xee).public();
        let s12 = hseg_keyed(&[hslot(1, &[]), hslot(2, &[])], A, Some(real));
        let (got, _) = take(&t, col, Settle::Incremental, &[&s12], None);
        assert_eq!(got, vec![landed(2, 0, 0)]);
        assert_eq!(t.tx(|t| t.device_key(col, &id(OLD))), Ok(Some(real)));
        assert_eq!(t.tx(|t| t.trust_of(col, &id(OLD))), Ok(None));
        let impostor = Peer {
            device: id(OLD),
            public: evil,
            name: Some("evil".into()),
            ext: None,
            head_gen: None,
            first_seen: None,
        };
        assert_eq!(
            t.tx(|t| t.set_peer(col, &impostor)),
            Ok(PeerPut::KeyMismatch)
        );
        // 另一个上传者担保另一把钥匙：整段不收。
        let forged = hseg_keyed(&[hslot(3, &[]), hslot(4, &[])], B, Some(evil));
        let (got, _) = take(&t, col, Settle::Incremental, &[&forged], None);
        assert_eq!(
            got,
            vec![Taken::Rejected(Reject::AuthorKeyMismatch(id(OLD)))]
        );
        assert_eq!(t.tx(|t| t.audit(col)), Ok(2));
        // 同一把、或不带：照收。
        let s3 = hseg_keyed(&[hslot(3, &[])], B, Some(real));
        let s4 = hseg_keyed(&[hslot(4, &[])], B, None);
        let (got, _) = take(&t, col, Settle::Incremental, &[&s3, &s4], None);
        assert_eq!(got, vec![landed(1, 0, 0), landed(1, 0, 0)]);
        assert_eq!(t.tx(|t| t.device_key(col, &id(OLD))), Ok(Some(real)));
        assert_rebuild_is_identity(&t, col);
    }

    #[test]
    fn bad_heritage_segments_are_refused_whole() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = setup(&t);
        let s = hseg(&[hslot(1, &[]), hslot(2, &[])], A, None);
        let mut bad = s.clone();
        *bad.last_mut().unwrap() ^= 1;
        let k = CollectionKey([9; 32]);
        let (got, _) = take(
            &t,
            col,
            Settle::Incremental,
            &[&bad, &s[..s.len() - 3]],
            None,
        );
        assert_eq!(got[0], Taken::Rejected(Reject::BadSignature));
        assert!(
            matches!(got[1], Taken::Rejected(Reject::Corrupt(_))),
            "{:?}",
            got[1]
        );
        let (got, _) = take(&t, col, Settle::Incremental, &[&s], Some(&k));
        assert_eq!(got, vec![Taken::Rejected(Reject::PlainOnSealed)]);
        assert_eq!(t.tx(|t| t.audit(col)), Ok(0));
        let (got, _) = take(&t, col, Settle::Incremental, &[&s], None);
        assert_eq!(got, vec![landed(2, 0, 0)]);
        // 旧设备已是承袭日志：拿它当原生段的作者，拒。
        t.tx(|t| {
            t.set_peer(
                col,
                &Peer {
                    device: id(OLD),
                    public: key_of(OLD).public(),
                    name: None,
                    ext: None,
                    head_gen: None,
                    first_seen: None,
                },
            )
        })
        .unwrap();
        let native_old = seg_of(OLD, CHAIN_ZERO, &ops_items(&[nop(OLD, 1, &[])]), None);
        let (got, _) = take(&t, col, Settle::Incremental, &[&native_old], None);
        assert_eq!(got, vec![Taken::Rejected(Reject::WrongLog(id(OLD)))]);
    }

    /// 两个上传者转出的同一个槽自相矛盾（同链指纹、同 T 版本、内容不同）：不落、记一笔，这一批照常收别的。
    #[test]
    fn contradicting_heritage_slots_are_skipped_without_stopping_the_batch() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = setup(&t);
        let twisted = |seq: u64| {
            HeritageSlot::op(
                [seq as u8; 8],
                op(OLD, seq, seq as i64, &[], &edit("twisted")),
            )
        };
        let by_a = hseg(&[hslot(1, &[]), hslot(2, &[])], A, None);
        let by_a_late = hseg(&[hslot(4, &[])], A, None);
        let by_b = hseg(&[twisted(1), hslot(2, &[])], B, None);
        let by_b_late = hseg(&[twisted(4)], B, None);
        let native = seg_of(A, CHAIN_ZERO, &ops_items(&[nop(A, 1, &[])]), None);
        let (got, rec) = take(
            &t,
            col,
            Settle::Incremental,
            &[&by_a, &by_a_late, &by_b, &by_b_late, &native],
            None,
        );
        assert_eq!(
            got,
            vec![
                landed(2, 0, 0),
                landed(0, 0, 1),
                landed(0, 2, 0),
                landed(0, 0, 0),
                landed(1, 0, 0)
            ]
        );
        assert_eq!(rec.conflicts, 2);
        assert_eq!(t.tx(|t| t.audit(col)), Ok(3));
        let first = t.entry(col, &hslot(1, &[]).id).unwrap().unwrap();
        assert_eq!(first.slot().unwrap(), hslot(1, &[]));
        assert_eq!(t.pending(col).unwrap()[0].slot, hslot(4, &[]));
        assert_rebuild_is_identity(&t, col);
    }

    /// 签过名的段里有一条信封不对的操作（依赖里点了作者自己）：整段拒，一条都不落，这一批照常。
    #[test]
    fn an_op_with_a_bad_envelope_refuses_its_whole_segment() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = setup(&t);
        let bad = vec![nop(A, 1, &[]), op(A, 2, 20, &[(A, 1)], &edit("self-dep"))];
        // `pack_native` 签不出这种段（摘要要逐项解码），手拼一个由 A 签名的。
        let header = NativeHeader {
            encrypted: false,
            collection: coll(),
            device: id(A),
            first: 1,
            last: 2,
            prev_chain: CHAIN_ZERO,
            last_chain: chain_of(CHAIN_ZERO, &bad),
        };
        let s = crate::gen4::segment::tests::assemble_by(
            &header,
            &crate::gen4::segment::write_body(&ops_items(&bad)),
            &key_of(A),
            None,
        );
        let b = seg_of(B, CHAIN_ZERO, &ops_items(&[nop(B, 1, &[])]), None);
        let (got, rec) = take(&t, col, Settle::Incremental, &[&s, &b], None);
        assert!(
            matches!(got[0], Taken::Rejected(Reject::Corrupt(_))),
            "{:?}",
            got[0]
        );
        assert_eq!(got[1], landed(1, 0, 0));
        assert_eq!((rec.rejected, rec.landed), (1, 1));
        assert_eq!(t.last_of(col, &id(A)).unwrap(), 0);
    }

    #[test]
    fn misuse_is_refused() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = setup(&t);
        let e = Receiver::open(&t, col, Settle::Incremental).err().unwrap();
        assert!(e.contains("outside a transaction"), "{e}");
        let e = t
            .tx(|t| Receiver::open(t, col + 1, Settle::Incremental).map(|_| ()))
            .unwrap_err();
        assert!(e.contains("no collection"), "{e}");
    }

    // ------------------------------------------------------------ 分叉的等待项

    /// 本机 A 1..=3；另一支的 A3 与本机不同。返回 (本机的 A 1..=4, 另一支的 A 1..=4)。
    fn local_a123(t: &Truth<'_>, col: i64) -> (Vec<Op4>, Vec<Op4>) {
        let a: Vec<Op4> = (1..=4).map(|s| nop(A, s, &[])).collect();
        take(
            t,
            col,
            Settle::Incremental,
            &[&seg_of(A, CHAIN_ZERO, &ops_items(&a[..3]), None)],
            None,
        );
        let mut other = a.clone();
        other[2] = op(A, 3, 999, &[], &edit("fork"));
        (a, other)
    }

    /// 正好接在本机末尾、前一环却不是本机末尾的项，依赖还没到也当场报分叉：一批之内先收依赖还是先收它，结果相同。
    #[test]
    fn a_fork_still_waiting_on_its_deps_is_reported_whatever_the_order() {
        let mut first = None;
        for fork_first in [false, true] {
            let conn = open_in_memory().unwrap();
            let t = Truth::new(&conn);
            let col = setup(&t);
            let (_, other) = local_a123(&t, col);
            let a4 = op(A, 4, 77, &[(B, 1)], &edit("a4"));
            let fork = seg_of(
                A,
                chain_of(CHAIN_ZERO, &other[..3]),
                &ops_items(&[a4]),
                None,
            );
            let b1 = seg_of(B, CHAIN_ZERO, &ops_items(&[nop(B, 1, &[])]), None);
            let segs: Vec<&[u8]> = if fork_first {
                vec![&fork, &b1]
            } else {
                vec![&b1, &fork]
            };
            let (got, rec) = take(&t, col, Settle::Incremental, &segs, None);
            let fork_taken = &got[usize::from(!fork_first)];
            assert_eq!(
                fork_taken,
                &Taken::Diverged {
                    device: id(A),
                    seq: 4
                },
                "fork_first={fork_first}"
            );
            assert_eq!(
                (rec.diverged, rec.waiting),
                (1, 0),
                "fork_first={fork_first}"
            );
            assert_eq!(t.last_of(col, &id(A)).unwrap(), 3);
            let s = state(&conn, &t, col);
            match &first {
                None => first = Some(s),
                Some(f) => assert_eq!(&s, f, "fork_first={fork_first}"),
            }
        }
    }

    /// 等待缓冲里前一环不对的项：前面的空洞补上之后不落库、报出来、留在缓冲里；与它同号的正确一支照投；正确一支
    /// 后来落进日志、它整个落在日志里面了也不被当成重复删掉。
    #[test]
    fn a_waiting_item_on_another_branch_is_reported_and_kept_not_landed() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = setup(&t);
        let a: Vec<Op4> = (1..=4).map(|s| nop(A, s, &[])).collect();
        let mut other = a.clone();
        other[2] = op(A, 3, 999, &[], &edit("fork"));
        take(
            &t,
            col,
            Settle::Incremental,
            &[&seg_of(A, CHAIN_ZERO, &ops_items(&a[..2]), None)],
            None,
        );
        // 前面缺着第 3 条：另一支的第 4 条与本机这一支的第 4 条都进缓冲。
        let fork = seg_of(
            A,
            chain_of(CHAIN_ZERO, &other[..3]),
            &ops_items(&other[3..]),
            None,
        );
        let good4 = seg_of(A, chain_of(CHAIN_ZERO, &a[..3]), &ops_items(&a[3..]), None);
        let (got, rec) = take(&t, col, Settle::Incremental, &[&fork, &good4], None);
        assert_eq!(got, vec![landed(0, 0, 1), landed(0, 0, 1)]);
        assert_eq!((rec.waiting, rec.diverged_waiting.len()), (2, 0));
        // 第 3 条到了：正确一支投出，另一支报出来、留着。
        let a3 = seg_of(A, chain_of(CHAIN_ZERO, &a[..2]), &ops_items(&a[2..3]), None);
        let (got, rec) = take(&t, col, Settle::Incremental, &[&a3], None);
        assert_eq!(got, vec![landed(1, 0, 0)]);
        assert_eq!(rec.delivered, 1);
        assert_eq!(rec.diverged_waiting, vec![(id(A), 4)]);
        assert_eq!(rec.waiting, 1);
        assert_eq!(t.last_of(col, &id(A)).unwrap(), 4);
        assert_eq!(
            t.chain_at(col, &id(A), 4).unwrap(),
            chain_of(CHAIN_ZERO, &a)
        );
        // 下一批什么都不收：它整个在日志里面了，仍然报、仍然留着。
        let (_, rec) = take(&t, col, Settle::Incremental, &[], None);
        assert_eq!((rec.diverged_waiting, rec.waiting), (vec![(id(A), 4)], 1));
        assert_eq!(t.tx(|t| t.audit(col)), Ok(4));
        assert_rebuild_is_identity(&t, col);

        // 另一种到达：另一支先进缓冲，正确的第 3、4 条随后整段直接落库。那一行整个落在日志里面，同样报出来、不删。
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = setup(&t);
        take(
            &t,
            col,
            Settle::Incremental,
            &[&seg_of(A, CHAIN_ZERO, &ops_items(&a[..2]), None)],
            None,
        );
        take(&t, col, Settle::Incremental, &[&fork], None);
        let a34 = seg_of(A, chain_of(CHAIN_ZERO, &a[..2]), &ops_items(&a[2..]), None);
        let (got, rec) = take(&t, col, Settle::Incremental, &[&a34], None);
        assert_eq!(got, vec![landed(2, 0, 0)]);
        assert_eq!((rec.diverged_waiting, rec.waiting), (vec![(id(A), 4)], 1));
        // 同一支重复收到的照样删（不是分叉证据）。
        let dup = seg_of(A, chain_of(CHAIN_ZERO, &a[..2]), &ops_items(&a[2..]), None);
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = setup(&t);
        let (_, rec) = take(&t, col, Settle::Incremental, &[&dup], None);
        assert_eq!(rec.waiting, 2);
        let (_, rec) = take(
            &t,
            col,
            Settle::Incremental,
            &[&seg_of(A, CHAIN_ZERO, &ops_items(&a), None)],
            None,
        );
        assert_eq!((rec.diverged_waiting, rec.waiting), (vec![], 0));
    }

    /// 越过本机末尾的空洞：本机在它前一格有链值时比前一环，不等是分叉、一格都不落；前一格在本机空洞内部时比不了，照收。
    #[test]
    fn a_void_overrunning_the_tail_is_checked_against_the_seq_before_it() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = setup(&t);
        let (a, _) = local_a123(&t, col);
        let before = state(&conn, &t, col);
        // 本机这一支、盖住 3..=4 的空洞：前一环（第 2 条）与本机相同。
        let c_other = |n: usize| chain_of(CHAIN_ZERO, &a[..n]);
        let fine_prev = seg_at(
            A,
            3,
            c_other(2),
            &[NativeItem::Void {
                count: 2,
                chain_after: c_other(4),
            }],
            None,
        );
        // 前一环（第 2 条）就不是本机的：一个从第 2 条起的空洞。
        let mut other2 = a.clone();
        other2[0] = op(A, 1, 555, &[], &edit("x"));
        let bad_prev = seg_at(
            A,
            2,
            chain_of(CHAIN_ZERO, &other2[..1]),
            &[NativeItem::Void {
                count: 3,
                chain_after: chain_of(CHAIN_ZERO, &other2[..4]),
            }],
            None,
        );
        let (got, rec) = take(&t, col, Settle::Incremental, &[&bad_prev], None);
        assert_eq!(
            got,
            vec![Taken::Diverged {
                device: id(A),
                seq: 2
            }]
        );
        assert_eq!((rec.diverged, rec.landed, rec.waiting), (1, 0, 0));
        assert_eq!(state(&conn, &t, col), before);
        // 前一环与本机相同的空洞（作者签名担保的陈述）照收，越过末尾的那一截落下。
        let (got, _) = take(&t, col, Settle::Incremental, &[&fine_prev], None);
        assert_eq!(got, vec![landed(1, 1, 0)]);
        assert_eq!(t.last_of(col, &id(A)).unwrap(), 4);

        // 前一格在本机空洞内部：比不了，照收。
        let ops: Vec<Op4> = (1..=6).map(|s| nop(A, s, &[])).collect();
        let c = |n: usize| chain_of(CHAIN_ZERO, &ops[..n]);
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = setup(&t);
        let local = seg_of(
            A,
            CHAIN_ZERO,
            &[
                NativeItem::Op(ops[0].clone()),
                NativeItem::Void {
                    count: 3,
                    chain_after: c(4),
                },
            ],
            None,
        );
        take(&t, col, Settle::Incremental, &[&local], None);
        assert_eq!(t.chain_known(col, &id(A), 2), Ok(None));
        let over = seg_at(
            A,
            3,
            c(2),
            &[NativeItem::Void {
                count: 4,
                chain_after: c(6),
            }],
            None,
        );
        let (got, _) = take(&t, col, Settle::Incremental, &[&over], None);
        assert_eq!(got, vec![landed(1, 2, 0)]);
        assert_eq!(t.chain_at(col, &id(A), 6).unwrap(), c(6));
    }

    /// [Truth::chain_known] 只在空洞内部答 None；区间末、完整操作处有值；不在日志里、不是原生日志的照样报错（收段
    /// 不把这些当成「比不了」吞掉）。
    #[test]
    fn chain_known_is_none_only_inside_a_void_run() {
        let ops: Vec<Op4> = (1..=5).map(|s| nop(A, s, &[])).collect();
        let c = |n: usize| chain_of(CHAIN_ZERO, &ops[..n]);
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = setup(&t);
        let items = vec![
            NativeItem::Op(ops[0].clone()),
            NativeItem::Void {
                count: 3,
                chain_after: c(4),
            },
            NativeItem::Op(ops[4].clone()),
        ];
        take(
            &t,
            col,
            Settle::Incremental,
            &[&seg_of(A, CHAIN_ZERO, &items, None)],
            None,
        );
        let known = |seq| t.chain_known(col, &id(A), seq);
        assert_eq!(known(0), Ok(Some(CHAIN_ZERO)));
        assert_eq!(known(1), Ok(Some(c(1))));
        assert_eq!(known(2), Ok(None));
        assert_eq!(known(3), Ok(None));
        assert_eq!(known(4), Ok(Some(c(4))));
        assert_eq!(known(5), Ok(Some(c(5))));
        assert!(known(6).is_err());
        assert!(t.chain_known(col, &id(0x77), 1).is_err());
        // OLD 点过名、没有原生日志。
        assert!(t.chain_known(col, &id(OLD), 1).is_err());
    }

    // ------------------------------------------------------------ 崩溃

    /// 子进程那一半：开事务收全部段、收尾，不提交就退出（等于收到一半被杀）。
    #[test]
    fn receive_child_process_half() {
        let Ok(path) = std::env::var("FUSHI_RECEIVE_CHILD_DB") else {
            return;
        };
        let conn = crate::store::gen4::schema::open(std::path::Path::new(&path)).unwrap();
        let col: i64 = conn
            .query_row("SELECT col FROM self_", [], |r| r.get(0))
            .unwrap();
        let t = Truth::new(&conn);
        conn.execute_batch("BEGIN IMMEDIATE").unwrap();
        t.reset();
        let w = world();
        let mut r = Receiver::open(&t, col, Settle::Incremental).unwrap();
        for s in [&w[2], &w[1], &w[0]] {
            r.native(s, None).unwrap();
        }
        let rec = r.finish().unwrap();
        println!(
            "RECEIVE_CHILD landed {} delivered {}, exiting without commit",
            rec.landed, rec.delivered
        );
        std::process::exit(0);
    }

    /// 崩溃：另一个进程收到一半退出（事务没提交）。重开之后真相、派生、等待缓冲都是收之前的样子，重收全部落下。
    #[test]
    fn a_crash_mid_batch_commits_nothing_and_the_retry_lands_everything() {
        let dir = crate::store::sync2::tests::tempdir::new("gen4-receive-crash");
        let path = dir.0.join("srs4.db");
        let col = {
            let conn = crate::store::gen4::schema::open(&path).unwrap();
            let t = Truth::new(&conn);
            setup(&t)
        };
        let out = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "store::gen4::receive::tests::receive_child_process_half",
                "--nocapture",
                "--test-threads=1",
            ])
            .env("FUSHI_RECEIVE_CHILD_DB", &path)
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert!(out.status.success(), "{stdout}");
        assert!(
            stdout.contains("RECEIVE_CHILD landed 2 delivered 4"),
            "{stdout}"
        );
        let conn = crate::store::gen4::schema::open(&path).unwrap();
        let t = Truth::new(&conn);
        assert_eq!(t.tx(|t| t.audit(col)), Ok(0));
        assert_eq!(t.waiting(col).unwrap(), vec![]);
        assert_eq!(dump(&conn, col), Vec::<String>::new());
        let w = world();
        let (_, rec) = take(&t, col, Settle::Incremental, &[&w[2], &w[1], &w[0]], None);
        assert_eq!((rec.landed, rec.delivered, rec.waiting), (2, 4, 0));
        assert_eq!(t.tx(|t| t.audit(col)), Ok(6));
        assert_rebuild_is_identity(&t, col);
    }

    /// 两个连接**先后**收同一批：第二个看到的全是已有（每个最外层事务开头 reset，读的是别人提交过的）。交错的并发见
    /// `a_batch_overtaken_by_another_connection_fails_whole_and_the_retry_is_right`。
    #[test]
    fn two_connections_receiving_one_after_another_land_them_once() {
        let dir = crate::store::sync2::tests::tempdir::new("gen4-receive-two");
        let path = dir.0.join("srs4.db");
        let c1 = crate::store::gen4::schema::open(&path).unwrap();
        let t1 = Truth::new(&c1);
        let col = setup(&t1);
        let c2 = crate::store::gen4::schema::open(&path).unwrap();
        let t2 = Truth::new(&c2);
        // 第二个连接先把缓存填上（读一次），再让第一个连接收。
        assert_eq!(t2.last_of(col, &id(A)).unwrap(), 0);
        let w = world();
        let segs: Vec<&[u8]> = w.iter().map(Vec::as_slice).collect();
        let (_, r1) = take(&t1, col, Settle::Incremental, &segs, None);
        let (got, r2) = take(&t2, col, Settle::Incremental, &segs, None);
        assert_eq!(r1.landed + r1.delivered, 6);
        assert_eq!(got, vec![landed(0, 2, 0), landed(0, 2, 0), landed(0, 2, 0)]);
        assert_eq!(r2.landed + r2.delivered, 0);
        assert_eq!(t2.tx(|t| t.audit(col)), Ok(6));
        assert_rebuild_is_identity(&t2, col);
    }

    /// 两个连接交错：c2 开了一批（读快照里 A 还是空的），c1 在 c2 的批中途收完同一批并提交；c2 的第一笔写升级不了
    /// 写锁（快照已过期，BUSY_SNAPSHOT），整笔报错回滚、一条都不落。重收看到的是 c1 提交的，全部是已有。
    /// 另一种交错：c1 拿着写锁没提交时 c2 收，c2 报错（忙等为零），c1 提交后 c2 重收同样正确。
    #[test]
    fn a_batch_overtaken_by_another_connection_fails_whole_and_the_retry_is_right() {
        let dir = crate::store::sync2::tests::tempdir::new("gen4-receive-race");
        let path = dir.0.join("srs4.db");
        let c1 = crate::store::gen4::schema::open(&path).unwrap();
        let t1 = Truth::new(&c1);
        let col = setup(&t1);
        let c2 = crate::store::gen4::schema::open(&path).unwrap();
        let t2 = Truth::new(&c2);
        let w = world();
        let segs: Vec<&[u8]> = w.iter().map(Vec::as_slice).collect();
        let r2 = t2.tx(|t| {
            let mut r = Receiver::open(t, col, Settle::Incremental)?;
            // c2 的读快照已开出；c1 整批收完、提交。
            let (_, r1) = take(&t1, col, Settle::Incremental, &segs, None);
            assert_eq!(r1.landed + r1.delivered, 6);
            for s in &segs {
                r.native(s, None)?;
            }
            r.finish()
        });
        let e = r2.unwrap_err();
        assert!(e.contains("locked") || e.contains("busy"), "{e}");
        assert!(c2.is_autocommit());
        let (got, r2) = take(&t2, col, Settle::Incremental, &segs, None);
        assert_eq!(got, vec![landed(0, 2, 0), landed(0, 2, 0), landed(0, 2, 0)]);
        assert_eq!((r2.landed, r2.delivered, r2.waiting), (0, 0, 0));
        assert_eq!(t2.tx(|t| t.audit(col)), Ok(6));
        assert_rebuild_is_identity(&t2, col);

        // c1 拿着写锁（收了一半没提交）时 c2 收：c2 拿不到锁、报错，什么都不落；c1 提交后重收正确。
        let dir = crate::store::sync2::tests::tempdir::new("gen4-receive-race2");
        let path = dir.0.join("srs4.db");
        let c1 = crate::store::gen4::schema::open(&path).unwrap();
        let t1 = Truth::new(&c1);
        let col = setup(&t1);
        let c2 = crate::store::gen4::schema::open(&path).unwrap();
        c2.busy_timeout(std::time::Duration::ZERO).unwrap();
        let t2 = Truth::new(&c2);
        c1.execute_batch("BEGIN IMMEDIATE").unwrap();
        t1.reset();
        let mut r1 = Receiver::open(&t1, col, Settle::Incremental).unwrap();
        for s in &segs {
            r1.native(s, None).unwrap();
        }
        let r1 = r1.finish().unwrap();
        let e = t2
            .tx(|t| {
                let mut r = Receiver::open(t, col, Settle::Incremental)?;
                for s in &segs {
                    r.native(s, None)?;
                }
                r.finish()
            })
            .unwrap_err();
        assert!(e.contains("locked") || e.contains("busy"), "{e}");
        c1.execute_batch("COMMIT").unwrap();
        assert_eq!(r1.landed + r1.delivered, 6);
        let (got, _) = take(&t2, col, Settle::Incremental, &segs, None);
        assert_eq!(got, vec![landed(0, 2, 0), landed(0, 2, 0), landed(0, 2, 0)]);
        assert_eq!(t2.tx(|t| t.audit(col)), Ok(6));
        assert_rebuild_is_identity(&t2, col);
    }
}
