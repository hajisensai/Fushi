//! 真相层：每台设备一条从 1 起连续的日志，落在 `ops` / `op_alias` / `op_voids` 三张表里（设计 §2.1、§2.2、§3.2）。
//!
//! 两种日志：
//!
//! - **承袭日志**（`devs.kind = 1`）：旧设备的协议 3 日志经转译 T 得到的槽（操作 / 原样件 / 副本记录 / 空洞），每个槽带
//!   8 字节原链指纹。不成链；首尾与中途的完整原链值记在 `log_marks`（承袭段头要用）。
//! - **原生日志**（`devs.kind = 0`）：协议 4 的操作，成链（`devs.tail` 是末尾的链值）。被清除的操作成为空洞，空洞区间
//!   记区间末的链值（附录 B 第 9 条），于是链可以越过空洞接着算。
//!
//! # 槽的落库规则（设计 §3.2，所有者 2026-11-12 批准的那三条在这里接）
//!
//! [Truth::put_heritage] 收一个槽：
//!
//! | 本机这个操作号 | 结果 |
//! |---|---|
//! | 没有，且正好接在末尾 | 收什么留什么（[Put::Inserted]）；同号有待投递的槽、链指纹更小时见「分叉」一行（[Put::Yielded]） |
//! | 没有，前面还缺 | 报错——前面缺一段的槽走 [Truth::put_pending] |
//! | 有，链指纹不同 | 那台旧设备分叉过。**链指纹字节序最小的那个槽在日志里，其余在 `op_forks`**：来的更小就与本机的对调（[Put::Replaced]），否则存进 `op_forks`（[Put::Fork]） |
//! | 有，链指纹相同，逐字节相同 | [Put::Same] |
//! | 有，链指纹相同，一边完整、一边是空洞 / 副本记录（或空洞对副本记录） | **本机的不动**（[Put::Kept]）。本机的槽只由本机自己应用 Purge / Dedup 推进（[Truth::advance_purge] / [Truth::advance_dedup]） |
//! | 有，链指纹相同，同秩而内容不同，来的 T 版本更高 | 换成来的（[Put::Replaced]） |
//! | 同上，来的 T 版本更低 | 本机的不动（[Put::Kept]） |
//! | 同上，T 版本相同 | 异常：不落库，[Put::Conflict] |
//!
//! 「异常」是来的数据与本机已有的自相矛盾（上传者的转译与本机的不是同一套、或段被改过），不是本机库坏了，所以是一个
//! 结果而不是错误：什么都没写、会话不毒化，调用方决定怎么办——迁移灌入（`import.rs`）当错误整批停下，收段（`receive.rs`）
//! 记一笔、跳过这个槽、接着收别的段。待投递与分叉的另一支上同样的矛盾（同号同链指纹、同 T 版本、内容不同；待投递的
//! 槽说了两个不同的前一环）也是 [Put::Conflict]。
//!
//! 分叉时谁在日志里只看链指纹，不看谁先到：同一批槽不管按什么顺序收，日志与 `op_forks` 都一样（派生层只读日志，
//! 所以派生结果也一样）。选择是逐个操作号做的——转译之后没有办法重算协议 3 的链，槽与槽之间「同一支」的关系只剩
//! 每个槽自己的链指纹，所以两支都很长时日志里可以是两支交错的；它不是哪一台旧设备真实写出过的一条链，只是全集的
//! 一个确定的函数。被对调出去的那一条若是本机推进过的（空洞 / 副本记录），原样挪进 `op_forks`。
//!
//! 「完整 < 空洞 < 副本记录」的并（`gen4::translate::join_slots`）只用在本机还**没应用**的槽上：待投递的与分叉的另一支
//! （它们没有被本机的 Purge / Dedup 推进过，同一个 `(操作号, 链指纹)` 来了两份就留靠后的）。
//!
//! # 待投递（设计 §3.1 末、§10 第 12 条）
//!
//! 前面缺一段的槽存进 `op_pending`，带一个「前一环的链指纹」`prev_fp`：
//!
//! - 迁移时旧代读入器能在协议 3 的口径下验出「这条紧接在上一条之后」（`chain_next(上一条的链值, 这条) == 它声明的链值`）
//!   的，`prev_fp` = 上一条的链指纹；验不出的（前面缺着）是空。
//! - [Truth::pending_ready] 只交出「正好接在本机末尾、且 `prev_fp` 等于本机末尾那个槽的链指纹」的待投递槽。
//!   `prev_fp` 为空的永远不自己投递：转译之后已经没有办法重算协议 3 的链，它只能等同一个操作号经承袭段到达——
//!   那时链指纹相同就是确认（待投递行删掉），不同就是分叉的一支（挪进 `op_forks`）。
//! - 因果上该不该投（依赖是否齐）不在这一层，是同步轮的事。
//!
//! # 会话与事务
//!
//! [Truth] 在内存里缓存设备下标、名字表、每条日志的末尾。所有写入必须在事务里（[Truth::tx]，或调用方自己开的事务）；
//! 事务回滚后缓存可能领先于库，必须 [Truth::reset]（[Truth::tx] 出错时自动做）。一次写入报错后，这个会话在 reset 之前
//! 拒绝再写。
//!
//! **每个最外层事务开头都 reset**（规划缺口 G-1）：同一个库文件可能有别的连接（另一个进程、查词弹窗的只读连接、
//! 同进程的另一个会话）在两个事务之间写过，上一个事务留下的缓存（日志末尾、链值、设备下标）就不再可信。[Truth::tx]
//! 在最外层（连接处于自动提交）时先 reset 再开事务，所以「读到的缓存」总是这个事务的快照里的。调用方自己开最外层
//! 事务（`BEGIN …`）时，开完必须先调 [Truth::reset] 再用这个会话。新代下只有主进程写（D10），辅助进程的只读会话
//! 同样经 [Truth::tx] 读（它在只读连接上也是一个读事务）。
//!
//! 这条约定有检测：会话记下缓存所对应的 `PRAGMA data_version`（reset 之后、缓存第一次从库里填之前记——不管这一读
//! 在不在事务里，见 `Truth::ensure_snapshot`），每次写入前比一次。别的连接在这之后提交过（值变了）= 调用方自己开了事务却没 reset，写入报错、不落库（不
//! 毒化会话：reset 之后照常）。同一个连接自己的提交不改这个值；拿着写事务时别人提交不了，所以事务内不会误报。

use std::cell::{Cell, RefCell};
use std::collections::{BTreeSet, HashMap};
use std::sync::Arc;

use rusqlite::{Connection, OptionalExtension, Row, params};

use super::derive::Ref;
use super::pack::{self, F_RAW3, F_SNAP, F_STAMP, Names, tv_bits, tv_of};
use super::schema::{in_tx, in_write_tx, k_dev, k_range, k_seq, opk, sql};
use crate::gen4::head::PrevIdentity;
use crate::gen4::heritage::{Alias, Fp, HeritageSlot, Raw3, SlotBody, fingerprint};
use crate::gen4::name::{read_name, write_name};
use crate::gen4::op::{
    BODY_FMT, Body4, Edit4, EditHead4, KIND_EDIT, KIND_JOIN, KIND_SALTS, Op4, chain_next4,
    decode_edit_parts, native_allowed, payload_within_cap, purge_targets_v1, purge_unseen_by,
};
use crate::gen4::recut::Stub;
use crate::gen4::stamp::HeritageStamp;
use crate::gen4::translate::{Joined, applied_body, dedup_slot, join_slots};
use crate::sync2::codec::{Reader, Writer};
use crate::sync2::hlc::{Clock, Hlc};
use crate::sync2::id::Id;
use crate::sync2::keys::DeviceKey;
use crate::sync2::op as v3;
use crate::sync2::segment::{CHAIN_ZERO, Chain};
use crate::sync2::vv::{OpId, Vv};

/// 本机身份（`self_`）与换身份（G8-6）。
mod own;
pub use own::Rotated;
/// 首见设备的信任判定（BUG-4306）。
mod trust;
pub(crate) use own::{NativeStep, fork_key};
pub use trust::FirstSeen;

/// `devs.kind`：原生日志。
pub const DEV_NATIVE: i64 = 0;
/// `devs.kind`：承袭日志。
pub const DEV_HERITAGE: i64 = 1;

/// 一台设备的待投递槽数（[Truth::pending_count]）：`op_pending` 主键区间上的计数。
pub(crate) const PENDING_COUNT_SQL: &str =
    "SELECT COUNT(*) FROM op_pending WHERE k BETWEEN ?1 AND ?2";

/// `op_alias.flags` / `op_voids.flags`：这个槽现在的样子是本机自己应用 Purge / Dedup 推进出来的（不是收来的）。
const A_LOCAL: i64 = 1;
/// `op_alias.flags`：`stamp` 一列存的是旧戳的线格式规范字节（内部化后读不回原值时的退路）。
const A_STAMP_WIRE: i64 = 2;

/// 原生日志每隔这么多条记一个链值（`log_marks`），[Truth::chain_at] 最多从这里往后折这么多条。
pub const MARK_EVERY: u64 = 1024;

const CACHE_MAX: usize = 65_536;

/// [Truth::put_heritage] / [Truth::put_pending] 的结果。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Put {
    /// 接在日志末尾，落库了。
    Inserted,
    /// 接在日志末尾，但同一个操作号上早有一个待投递的槽、链指纹更小：日志里是那一个，来的这份成了分叉的另一支。
    /// 派生层照 [Put::Inserted] 处理（把日志里现在的那一条加进去）；来的这份的链值不是日志里那一条的。
    Yielded,
    /// 本机已有逐字节相同的一份。
    Same,
    /// 本机已有同一个操作号、同一个链指纹的槽，来的这份不改它。
    Kept,
    /// 来的这份换掉了本机的（同一个链指纹、更高的 T 版本；或者分叉的另一支、链指纹更小）。派生层要重算这个操作号。
    Replaced,
    /// 链指纹与本机的不同、且不比本机的小：记成分叉的另一支。
    Fork,
    /// 前面还缺：进了待投递。
    Pending,
    /// 来的与本机已有的自相矛盾（文件头落库规则表最后一行），什么都没写。
    Conflict,
}

/// 设备信任状态：待本机确认。
pub const TRUST_PENDING: i64 = 1;
/// 设备信任状态：本机拒绝了。
pub const TRUST_REJECTED: i64 = 2;

/// 一条完整操作的信封（[Truth::head_by_key]）。
#[derive(Clone, Debug)]
pub(crate) struct Head {
    pub id: OpId,
    pub wall: i64,
    pub logical: i64,
    pub deps: Arc<Vv>,
    pub kind: u16,
    /// 原样件：载荷是协议 3 的字节，带不带旧戳要解开才知道。
    pub raw: bool,
    /// 转译过的承袭修改，带旧戳。
    pub stamped: bool,
}

impl Head {
    /// 作者写这条时见过 [other]（协议 3 `Op::saw`）。
    pub fn saw(&self, other: &OpId) -> bool {
        if other.device == self.id.device {
            other.seq < self.id.seq
        } else {
            self.deps.contains(other)
        }
    }
}

/// [Truth::edit_read] 的结果：一条修改操作的信封与头部，字段值按需。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct EditRead {
    pub id: OpId,
    pub wall: i64,
    pub logical: u32,
    pub deps: Arc<Vv>,
    pub head: EditHead4,
    /// 只在 `with_value` 时有（规范 JSON 文本）。
    pub value: Option<String>,
}

/// 日志里的一条：承袭日志的槽，或原生日志的操作 / 空洞。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub id: OpId,
    /// 原链指纹。原生日志没有。
    pub fp: Option<Fp>,
    /// 转译 T 的版本（原生日志恒为 1）。
    pub tv: u32,
    /// 这个空洞 / 副本记录是本机自己应用 Purge / Dedup 推进出来的。
    pub local: bool,
    pub body: SlotBody,
}

impl Entry {
    /// 承袭日志的槽（原生日志的条目没有）。
    pub fn slot(&self) -> Option<HeritageSlot> {
        self.fp.map(|fp| HeritageSlot {
            id: self.id,
            fp,
            body: self.body.clone(),
        })
    }

    /// 操作（原样件、副本记录、空洞没有）。
    pub fn op(&self) -> Option<&Op4> {
        match &self.body {
            SlotBody::Op(op) => Some(op),
            _ => None,
        }
    }

    pub fn is_whole(&self) -> bool {
        matches!(self.body, SlotBody::Op(_) | SlotBody::Raw3(_))
    }
}

/// 没应用的槽：待投递的，或分叉的另一支。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Parked {
    pub slot: HeritageSlot,
    pub tv: u32,
    /// 前一环的链指纹（只有待投递的、且验得出的才有）。
    pub prev_fp: Option<Fp>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DevInfo {
    pub dev: i64,
    pub id: Id,
    /// 空 = 只被别的操作点过名，还没见过它的日志。
    pub kind: Option<i64>,
    /// 承袭日志的来源集合（原协议 3 集合标识）。
    pub src: Option<Id>,
    /// 日志末尾的 seq（0 = 一条都没有）。
    pub last: u64,
}

/// 一台设备的公钥与本机记下的信息（`peers` 表）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Peer {
    pub device: Id,
    /// Ed25519 公钥。
    pub public: [u8; 32],
    /// 设备名（None = 不知道 / 不改）。
    pub name: Option<String>,
    /// 扩展信息（JSON 文本；None = 不知道 / 不改）。
    pub ext: Option<String>,
    /// 见过的最新 head 代号。
    pub head_gen: Option<i64>,
    /// 第一次见到它的时刻（毫秒）。
    pub first_seen: Option<i64>,
}

/// 本机在一个集合里的身份（`self_` 表；设计 §3.3）。原生写入者（`native.rs`）从这里取设备 ID 与时钟；换身份
/// （G8-6，`truth/own.rs` 的 [Truth::rotate_identity]）整行换掉。本机身份只有这一个类型、这一组读写
/// （[Truth::self_identity] / [Truth::create_self] / [Truth::set_self_hlc] / 换身份）。
///
/// `Debug` 不打印签名钥匙种子（日志、断言失败信息里不能出现私钥）。
#[derive(Clone, PartialEq, Eq)]
pub struct SelfId {
    pub device: Id,
    /// 签名钥匙种子（Ed25519）。换身份沿用同一把（§3.3）。
    pub sk: [u8; 32],
    /// 本机时钟发出过 / 吸收过的最大 HLC（`device` 恒为本机）。存成文本 `<wall>:<logical>`（[hlc_text]），只收规范形。
    pub hlc: Hlc,
    /// 换身份之前的上一个身份冻结在哪（没换过 = None）。由换身份（G8-6）写，形状与 head 的 `prev` 相同；见
    /// [prev_cols] 的存储口径（`seq` 可以是 0：上一个身份一条操作都没留下）。
    pub prev: Option<PrevIdentity>,
    /// 这一行（这个身份）建立的时刻（毫秒）。
    pub created: i64,
}

impl std::fmt::Debug for SelfId {
    /// 不打印钥匙种子。
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SelfId")
            .field("device", &self.device)
            .field("hlc", &self.hlc)
            .field("prev", &self.prev)
            .field("created", &self.created)
            .finish_non_exhaustive()
    }
}

impl SelfId {
    /// 签名钥匙。
    pub fn key(&self) -> DeviceKey {
        DeviceKey::from_seed(&self.sk)
    }

    /// 本机公钥。
    pub fn public(&self) -> [u8; 32] {
        self.key().public()
    }

    /// 本机时钟（下一次 `tick` 发出的时刻严格大于 [SelfId::hlc]）。
    pub fn clock(&self) -> Clock {
        Clock {
            device: self.device,
            last: Hlc {
                device: self.device,
                ..self.hlc
            },
        }
    }
}

/// `self_.prev_device` / `prev_seq` / `prev_chain` 的存储形（[SelfId::prev]）：没换过 = 三列全空；换过 = 三列全有，
/// `prev_seq` ≥ 0（0 = 上一个身份冻结在链的起点、一条操作都没留下，这时 `prev_chain` 必须是 [CHAIN_ZERO]，与 head 的
/// `prev` 同一口径：head 收 `seq = 0`）。写（换身份）与读（[Truth::self_identity]）都经这一对函数。
pub(crate) fn prev_cols(
    prev: Option<&PrevIdentity>,
) -> (Option<Vec<u8>>, Option<i64>, Option<Vec<u8>>) {
    match prev {
        None => (None, None, None),
        Some(p) => (
            Some(p.device.0.to_vec()),
            Some(p.seq as i64),
            Some(p.chain.to_vec()),
        ),
    }
}

/// [prev_cols] 的逆；只收它写得出的形状（只存了一部分、负的 seq、seq 0 却不是链起点）。
fn prev_from_cols(
    col: i64,
    device: Option<Vec<u8>>,
    seq: Option<i64>,
    chain: Option<Vec<u8>>,
) -> Result<Option<PrevIdentity>, String> {
    let torn = || format!("gen4 store: collection {col} has a torn prev identity");
    match (device, seq, chain) {
        (None, None, None) => Ok(None),
        (Some(d), Some(s), Some(c)) if s >= 0 => {
            let chain = chain_of(&c)?;
            if s == 0 && chain != CHAIN_ZERO {
                return Err(torn());
            }
            Ok(Some(PrevIdentity {
                device: id_of(&d)?,
                seq: s as u64,
                chain,
            }))
        }
        _ => Err(torn()),
    }
}

/// [SelfId::hlc] 的存储文本：`<wall>:<logical>`。
pub fn hlc_text(hlc: &Hlc) -> String {
    format!("{}:{}", hlc.wall, hlc.logical)
}

/// [hlc_text] 的逆。只收它写得出的形（再写一遍逐字节相同），别的一律报错——时钟读错会让本机发出比已发过的更小的
/// HLC，不能「尽量解析」。
pub fn hlc_parse(text: &str, device: Id) -> Result<Hlc, String> {
    let bad = || format!("gen4 store: bad hlc text {text:?}");
    let (w, l) = text.split_once(':').ok_or_else(bad)?;
    let hlc = Hlc {
        wall: w.parse().map_err(|_| bad())?,
        logical: l.parse().map_err(|_| bad())?,
        device,
    };
    if hlc_text(&hlc) != text {
        return Err(bad());
    }
    Ok(hlc)
}

/// [Truth::set_peer] 的结果。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PeerPut {
    Inserted,
    Updated,
    Same,
    /// 已经记过另一个公钥：没写。
    KeyMismatch,
}

/// profile ↔ 集合的绑定（设计 §5.1）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Binding {
    pub col: i64,
    pub profile: String,
    /// 集合标识。
    pub collection: Id,
    /// 位置目录名。
    pub dir: String,
    /// 盐集合（这个集合里出现过的旧 uid）。它是派生值：= 本机信任的作者写的带盐操作（Salts、Join）的盐之并（设计
    /// §5.1）。这一列只是那个并的缓存，由派生层写（`alias.rs` 的 `settle_salts`，[Truth::set_salts]）。
    pub salts: BTreeSet<String>,
}

/// 绑定状态的阶段（设计 §5.1、D28；协议 3 `store/binding.rs` 的 `provisional` / `settled`）。存在 `collections.state`。
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum BindStage {
    /// 暂定：想先加入已有集合但没赶上，照常写入、之后由并入兜底。
    Provisional,
    /// 已定：已经在某个位置上跑完关联，之后在别的位置上看到别的集合只交给用户选。
    Settled,
}

impl BindStage {
    /// `collections.state` 里的值。
    pub fn code(self) -> i64 {
        match self {
            BindStage::Provisional => 1,
            BindStage::Settled => 2,
        }
    }

    pub fn of_code(code: i64) -> Option<BindStage> {
        match code {
            1 => Some(BindStage::Provisional),
            2 => Some(BindStage::Settled),
            _ => None,
        }
    }

    /// 协议 3 线上 / 命令回包里的文本（`binding_get` / `binding_set` 的形状不变，规划 §1.6）。
    pub fn text(self) -> &'static str {
        match self {
            BindStage::Provisional => "provisional",
            BindStage::Settled => "settled",
        }
    }

    pub fn of_text(text: &str) -> Option<BindStage> {
        match text {
            "provisional" => Some(BindStage::Provisional),
            "settled" => Some(BindStage::Settled),
            _ => None,
        }
    }
}

/// 一个集合的绑定状态（`collections.state / via / at`）：阶段、在哪定下 / 想在哪加入（位置的 directoryKey 或
/// `backup`）、写下的时刻（毫秒）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BindState {
    pub stage: BindStage,
    pub via: String,
    pub at: i64,
}

impl BindState {
    /// 协议 3 `binding_get` 回包里 `binding` 那一项的形状：`{state, via, at}`。
    pub fn json(&self) -> serde_json::Value {
        serde_json::json!({"state": self.stage.text(), "via": self.via, "at": self.at})
    }
}

#[derive(Clone)]
struct DevRow {
    col: i64,
    id: Id,
    kind: Option<i64>,
    src: Option<Id>,
    tail: Option<Chain>,
    last: Option<u64>,
    parked: Option<bool>,
}

#[derive(Default)]
struct State {
    poisoned: bool,
    /// 缓存对应的 `PRAGMA data_version`（文件头「会话与事务」）。没记 = None。
    data_version: Option<i64>,
    dev_ix: HashMap<(i64, Id), i64>,
    devs: HashMap<i64, DevRow>,
    writer_ix: HashMap<String, u64>,
    writer_name: HashMap<u64, String>,
    snap_ix: HashMap<[u8; 32], u64>,
    snap_body: HashMap<u64, String>,
    deps_ix: HashMap<Vec<u8>, i64>,
    deps_vv: HashMap<i64, Arc<Vv>>,
}

/// 新代库上的一个读写会话。
pub struct Truth<'c> {
    conn: &'c Connection,
    st: RefCell<State>,
    no_deps: Arc<Vv>,
    /// 这个会话里有操作落成了空洞（[Truth::advance_purge]）：提交之后要做字节层收尾（`scrub.rs`）。
    voided: Cell<bool>,
    /// 库句柄的缓存配置记忆（`cache.rs` [super::cache::CfgMemo]，`kernel.rs` `G4Core::truth` 给）。没有 = 每次现算。
    cfg_memo: Option<Arc<super::cache::CfgMemo>>,
    /// 库句柄的取消令牌（`cancel.rs`，`kernel.rs` `G4Core::truth` 给）：每一次写入的守卫先看它。没有 = 不可取消
    /// （迁移、测试装置）。
    cancel: Option<super::cancel::Cancel>,
}

struct N<'a, 'c>(&'a Truth<'c>);

impl Names for N<'_, '_> {
    fn writer_id(&mut self, name: &str) -> Result<u64, String> {
        self.0.writer_id(name)
    }

    fn writer_name(&mut self, id: u64) -> Result<String, String> {
        self.0.writer_name(id)
    }

    fn snapshot_id(&mut self, body: &str) -> Result<u64, String> {
        self.0.snapshot_id(body)
    }

    fn snapshot_body(&mut self, id: u64) -> Result<String, String> {
        self.0.snapshot_body(id)
    }
}

fn id_of(b: &[u8]) -> Result<Id, String> {
    b.try_into()
        .map(Id)
        .map_err(|_| "gen4 store: bad id blob".to_owned())
}

fn fp_of(b: &[u8]) -> Result<Fp, String> {
    b.try_into()
        .map_err(|_| "gen4 store: bad fingerprint blob".to_owned())
}

fn chain_of(b: &[u8]) -> Result<Chain, String> {
    b.try_into()
        .map_err(|_| "gen4 store: bad chain blob".to_owned())
}

fn slot_of(bytes: &[u8]) -> Result<HeritageSlot, String> {
    let mut r = Reader::new(bytes);
    let slot = HeritageSlot::read(&mut r).map_err(|e| format!("gen4 store: parked slot: {e}"))?;
    if !r.is_empty() {
        return Err("gen4 store: parked slot has trailing bytes".to_owned());
    }
    Ok(slot)
}

struct OpRow {
    k: i64,
    wall: i64,
    logical: i64,
    deps: i64,
    kind: i64,
    fmt: i64,
    flags: i64,
    body: Vec<u8>,
    aux: Option<Vec<u8>>,
    fp: Option<Vec<u8>>,
}

fn op_row(r: &Row<'_>) -> rusqlite::Result<OpRow> {
    Ok(OpRow {
        k: r.get(0)?,
        wall: r.get(1)?,
        logical: r.get(2)?,
        deps: r.get(3)?,
        kind: r.get(4)?,
        fmt: r.get(5)?,
        flags: r.get(6)?,
        body: r.get(7)?,
        aux: r.get(8)?,
        fp: r.get(9)?,
    })
}

struct AliasRow {
    k: i64,
    kind: i64,
    wall: i64,
    logical: i64,
    of_dev: i64,
    of_seq: i64,
    flags: i64,
    stamp: Option<Vec<u8>>,
    fp: Vec<u8>,
}

fn alias_row(r: &Row<'_>) -> rusqlite::Result<AliasRow> {
    Ok(AliasRow {
        k: r.get(0)?,
        kind: r.get(1)?,
        wall: r.get(2)?,
        logical: r.get(3)?,
        of_dev: r.get(4)?,
        of_seq: r.get(5)?,
        flags: r.get(6)?,
        stamp: r.get(7)?,
        fp: r.get(8)?,
    })
}

struct VoidRun {
    k: i64,
    n: u64,
    flags: i64,
    /// 承袭日志：每个 seq 8 字节链指纹，按 seq 拼接。
    fps: Option<Vec<u8>>,
    /// 原生日志：区间末的链值。
    chain: Option<Vec<u8>>,
}

fn void_row(r: &Row<'_>) -> rusqlite::Result<VoidRun> {
    Ok(VoidRun {
        k: r.get(0)?,
        n: r.get::<_, i64>(1)? as u64,
        flags: r.get(2)?,
        fps: r.get(3)?,
        chain: r.get(4)?,
    })
}

impl VoidRun {
    fn end(&self) -> u64 {
        k_seq(self.k) + self.n - 1
    }
}

/// 没应用的槽（待投递 / 分叉的另一支）同一个 `(操作号, 链指纹)` 来了第二份：该把存着的换成什么（不用换 = None）。
/// [merge_parked] 的结论。
enum Merged {
    /// 已有的不用改。
    Keep,
    /// 存这一份。
    Store(HeritageSlot, u32),
    /// 同一个 T 版本转出了两份不同的：矛盾（[Put::Conflict]）。
    Conflict,
}

fn merge_parked(have: Option<(HeritageSlot, u32)>, slot: &HeritageSlot, tv: u32) -> Merged {
    let Some((have, have_tv)) = have else {
        return Merged::Store(slot.clone(), tv);
    };
    if have == *slot {
        return if tv > have_tv {
            Merged::Store(have, tv)
        } else {
            Merged::Keep
        };
    }
    if tv != have_tv {
        return if tv > have_tv {
            Merged::Store(slot.clone(), tv)
        } else {
            Merged::Keep
        };
    }
    match join_slots(&have, slot) {
        Joined::One(s) if s == have => Merged::Keep,
        Joined::One(s) => Merged::Store(s, tv),
        Joined::Fork | Joined::Conflict => Merged::Conflict,
    }
}

impl<'c> Truth<'c> {
    pub fn new(conn: &'c Connection) -> Truth<'c> {
        conn.set_prepared_statement_cache_capacity(128);
        Truth {
            conn,
            st: RefCell::new(State::default()),
            no_deps: Arc::new(Vv::new()),
            voided: Cell::new(false),
            cfg_memo: None,
            cancel: None,
        }
    }

    /// 带上库句柄的取消令牌（`cancel.rs`）：[Truth::write] 与 [Truth::check_cancelled] 看它。
    pub fn with_cancel(self, cancel: super::cancel::Cancel) -> Truth<'c> {
        Truth {
            cancel: Some(cancel),
            ..self
        }
    }

    /// 批次边界（`cancel.rs`）：库句柄开始关了就报 `CLOSED`，调用方照常把错误往上交、事务整笔回滚。
    pub(super) fn check_cancelled(&self) -> Result<(), String> {
        match &self.cancel {
            Some(c) => c.check(),
            None => Ok(()),
        }
    }

    /// [Truth::new]，缓存配置的解析结果跨命令记在 [memo] 里（`cache.rs` [super::cache::CfgMemo]）。
    pub fn with_cfg_memo(conn: &'c Connection, memo: Arc<super::cache::CfgMemo>) -> Truth<'c> {
        Truth {
            cfg_memo: Some(memo),
            ..Truth::new(conn)
        }
    }

    pub(super) fn cfg_memo(&self) -> Option<&super::cache::CfgMemo> {
        self.cfg_memo.as_deref()
    }

    pub fn conn(&self) -> &'c Connection {
        self.conn
    }

    /// 取走「这个会话里有操作落成了空洞」（[Truth::advance_purge]）：写命令提交之后据此做字节层收尾（`scrub.rs`）。
    pub(crate) fn take_voided(&self) -> bool {
        self.voided.replace(false)
    }

    fn data_version(&self) -> Result<i64, String> {
        self.conn
            .prepare_cached("PRAGMA data_version")
            .and_then(|mut s| s.query_row([], |r| r.get(0)))
            .map_err(sql)
    }

    /// 缓存从空状态第一次查库之前调：还没记 `data_version` 就先记下（文件头「会话与事务」）。凡是从库里读、再把结果
    /// 放进 `st` 的入口都在查库之前走这里，所以记下的版本不晚于缓存里任何一项的来源。在事务外调时，记下的这一读与
    /// 随后的查询是两个隐式事务，中间别人提交了只会让之后的写入误报（拒绝、reset 后重来），不会漏报。
    fn ensure_snapshot(&self) -> Result<(), String> {
        if self.st.borrow().data_version.is_none() {
            let dv = self.data_version()?;
            self.st.borrow_mut().data_version = Some(dv);
        }
        Ok(())
    }

    /// 丢掉内存里的缓存（事务回滚之后必须调）。
    pub fn reset(&self) {
        *self.st.borrow_mut() = State::default();
    }

    /// 在一个事务里跑 [f]；出错整笔回滚并 [Truth::reset]。可以嵌套。最外层的那一次开头先 [Truth::reset]（文件头
    /// 「会话与事务」：别的连接可能在上一个事务之后写过）。
    pub fn tx<T>(&self, f: impl FnOnce(&Truth<'c>) -> Result<T, String>) -> Result<T, String> {
        let outer = self.conn.is_autocommit();
        if outer {
            self.reset();
        }
        let r = in_tx(self.conn, |_| {
            let v = f(self)?;
            if outer {
                // 放在 f 之后：f 里的读已经开出了事务快照，记下的就是这个事务的版本；放在前面会让这一读先开出读
                // 快照，f 的第一笔写就得从读升级成写（别人刚提交过会 BUSY_SNAPSHOT）。f 填过缓存或写过的话已经记了。
                self.ensure_snapshot()?;
            }
            Ok(v)
        });
        if r.is_err() {
            self.reset();
        }
        r
    }

    /// [Truth::tx]，但最外层时一开始就拿写锁（`BEGIN IMMEDIATE`，经忙等排队）：给「先读一大片、再写」又可能与别的
    /// 连接并发的一次性大事务用（导入）。延迟事务读完再升级成写时，别的连接在这之间提交过就是 `SQLITE_BUSY_SNAPSHOT`，
    /// 忙等救不了，整笔失败。已在事务里时就是 [Truth::tx]（嵌套的保存点；拿锁的口径由最外层的调用方定）。
    pub fn tx_immediate<T>(
        &self,
        f: impl FnOnce(&Truth<'c>) -> Result<T, String>,
    ) -> Result<T, String> {
        if !self.conn.is_autocommit() {
            return self.tx(f);
        }
        self.reset();
        let r = in_write_tx(self.conn, |_| {
            let v = f(self)?;
            self.ensure_snapshot()?;
            Ok(v)
        });
        if r.is_err() {
            self.reset();
        }
        r
    }

    /// 一次写入的守卫：会话没被毒化、在事务里、缓存与库同一个版本；[f] 报错就毒化会话。新代的其余本机状态表
    /// （`sync_state.rs`）、收段（`receive.rs`）写库也经这里，口径与真相层相同。库句柄开始关了（取消令牌，`cancel.rs`
    /// 「批次边界」）就报 `CLOSED`、毒化会话，调用方的事务整笔回滚。
    pub(super) fn write<T>(&self, f: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
        if let Err(e) = self.check_cancelled() {
            self.st.borrow_mut().poisoned = true;
            return Err(e);
        }
        if self.st.borrow().poisoned {
            return Err(
                "gen4 store: an earlier write failed; roll back and reset first".to_owned(),
            );
        }
        if self.conn.is_autocommit() {
            return Err("gen4 store: write outside a transaction".to_owned());
        }
        self.ensure_snapshot()?;
        let seen = self.st.borrow().data_version;
        if seen != Some(self.data_version()?) {
            return Err(
                "gen4 store: another connection committed since this session's cache was \
                 filled (a transaction opened without Truth::reset); reset first"
                    .to_owned(),
            );
        }
        let r = f();
        if r.is_err() {
            self.st.borrow_mut().poisoned = true;
        }
        r
    }

    // ------------------------------------------------------------ 绑定

    fn binding_where(
        &self,
        clause: &str,
        arg: &dyn rusqlite::ToSql,
    ) -> Result<Option<Binding>, String> {
        let row = self
            .conn
            .prepare_cached(&format!(
                "SELECT col, profile_uid, collection, dir, salts FROM collections WHERE {clause} = ?1"
            ))
            .map_err(sql)?
            .query_row([arg], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, Vec<u8>>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, String>(4)?,
                ))
            })
            .optional()
            .map_err(sql)?;
        let Some((col, profile, collection, dir, salts)) = row else {
            return Ok(None);
        };
        Ok(Some(Binding {
            col,
            profile,
            collection: id_of(&collection)?,
            dir,
            salts: serde_json::from_str(&salts)
                .map_err(|e| format!("gen4 store: bad salts for collection {col}: {e}"))?,
        }))
    }

    /// 这个 profile 绑定的集合（没绑过 = None）。
    pub fn binding_of(&self, profile: &str) -> Result<Option<Binding>, String> {
        self.binding_where("profile_uid", &profile)
    }

    pub fn binding(&self, col: i64) -> Result<Option<Binding>, String> {
        self.binding_where("col", &col)
    }

    /// 绑着集合标识 [collection] 的本机集合（没有 = None）。
    pub fn binding_of_collection(&self, collection: &Id) -> Result<Option<Binding>, String> {
        self.binding_where("collection", &collection.0.as_slice())
    }

    /// 本机其他 profile 当前绑定的集合，与 `collection_adopt` 用同一张表判断归属。
    pub(crate) fn other_collections(&self, col: i64) -> Result<Vec<Id>, String> {
        let mut stmt = self
            .conn
            .prepare_cached(
                "SELECT collection FROM collections WHERE col != ?1 ORDER BY collection",
            )
            .map_err(sql)?;
        let rows = stmt
            .query_map([col], |r| r.get::<_, Vec<u8>>(0))
            .map_err(sql)?;
        rows.map(|r| id_of(&r.map_err(sql)?)).collect()
    }

    /// 位置目录名是 [dir] 的本机 profile（按 uid 排）。一个集合只绑一个 profile，但目录名不唯一（并入后两个本机
    /// 集合可能指向同一个目录），所以回列表。`collections` 一台设备只有几行，全表扫（不加索引、不升 SCHEMA）。
    pub fn profiles_of_dir(&self, dir: &str) -> Result<Vec<String>, String> {
        let mut st = self
            .conn
            .prepare_cached(
                "SELECT profile_uid FROM collections WHERE dir = ?1 ORDER BY profile_uid",
            )
            .map_err(sql)?;
        let rows = st
            .query_map([dir], |r| r.get::<_, String>(0))
            .map_err(sql)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(sql)
    }

    /// 把 profile 绑到一个集合上，返回本机集合号。同一个 profile 再绑同一个集合是幂等的；一个 profile 只能绑一个集合，
    /// 一个集合只能绑一个 profile（设计 §5.1：同机两个 profile 不能绑定同一个集合）。改绑定是身份接线（G9）的事。
    pub fn bind(&self, profile: &str, collection: &Id, dir: &str) -> Result<i64, String> {
        self.write(|| {
            if let Some(b) = self.binding_of(profile)? {
                if b.collection == *collection && b.dir == dir {
                    return Ok(b.col);
                }
                return Err(format!(
                    "gen4 store: profile {profile} is already bound to collection {}",
                    b.collection
                ));
            }
            if let Some(b) = self.binding_where("collection", &collection.0.as_slice())? {
                return Err(format!(
                    "gen4 store: collection {collection} is already bound to profile {}",
                    b.profile
                ));
            }
            self.conn
                .prepare_cached(
                    "INSERT INTO collections (profile_uid, collection, dir, salts) VALUES (?1, ?2, ?3, '[]')",
                )
                .map_err(sql)?
                .execute(params![profile, collection.0.as_slice(), dir])
                .map_err(sql)?;
            Ok(self.conn.last_insert_rowid())
        })
    }

    /// 把盐集合的缓存写成 [salts]。返回有没有变。调用方只有一处：派生层算完「受信作者的带盐操作之并」之后。
    pub fn set_salts(&self, col: i64, salts: &BTreeSet<String>) -> Result<bool, String> {
        self.write(|| {
            let b = self
                .binding(col)?
                .ok_or_else(|| format!("gen4 store: no collection {col}"))?;
            if b.salts == *salts {
                return Ok(false);
            }
            let text = serde_json::to_string(salts).map_err(sql)?;
            self.conn
                .prepare_cached("UPDATE collections SET salts = ?2 WHERE col = ?1")
                .map_err(sql)?
                .execute(params![col, text])
                .map_err(sql)?;
            Ok(true)
        })
    }

    /// 集合 [col] 的绑定状态（没写过 = None）。`state` 列里认不出的值当作没有记录（协议 3 `binding.rs` 的 `parse`
    /// 同口径：坏值不让读失败）。
    pub fn binding_state(&self, col: i64) -> Result<Option<BindState>, String> {
        let row = self
            .conn
            .prepare_cached("SELECT state, via, at FROM collections WHERE col = ?1")
            .map_err(sql)?
            .query_row([col], |r| {
                Ok((
                    r.get::<_, Option<i64>>(0)?,
                    r.get::<_, Option<String>>(1)?,
                    r.get::<_, Option<i64>>(2)?,
                ))
            })
            .optional()
            .map_err(sql)?;
        let Some((state, via, at)) = row else {
            return Err(format!("gen4 store: no collection {col}"));
        };
        Ok(state.and_then(BindStage::of_code).map(|stage| BindState {
            stage,
            via: via.unwrap_or_default(),
            at: at.unwrap_or(0),
        }))
    }

    /// 写集合 [col] 的绑定状态，返回写完之后的状态（同 [Truth::binding_state]）。语义照搬协议 3 的 `binding_set`
    /// （`store/binding.rs` 文件头）：**只进不退**——已经 `settled` 时什么都不改（第一次定下的位置为准）；`provisional`
    /// 可以升成 `settled`；再写 `provisional` 只换 `via` / `at`。只动本机，不随同步传。
    pub fn settle_binding(
        &self,
        col: i64,
        stage: BindStage,
        via: &str,
        at: i64,
    ) -> Result<BindState, String> {
        self.write(|| {
            if let Some(cur) = self.binding_state(col)? {
                if cur.stage == BindStage::Settled {
                    return Ok(cur);
                }
            }
            self.conn
                .prepare_cached(
                    "UPDATE collections SET state = ?2, via = ?3, at = ?4 WHERE col = ?1",
                )
                .map_err(sql)?
                .execute(params![col, stage.code(), via, at])
                .map_err(sql)?;
            Ok(BindState {
                stage,
                via: via.to_owned(),
                at,
            })
        })
    }

    /// 把本机集合 [col] 改绑到另一个集合标识与位置目录名上（设计 §5.4 第 2 条：集合号、操作、本机状态都不动，只换
    /// 「这批操作现在属于哪个集合」）。**只给并入用**（`identity.rs`）：改绑必须与写进日志的那条 `Join` 同一个事务，
    /// 单独改绑会让别的设备无从跟随。目标集合已经绑在本机别的 profile 上时报错（设计 §5.1）。
    pub(super) fn rebind(&self, col: i64, collection: &Id, dir: &str) -> Result<(), String> {
        self.write(|| {
            if dir.is_empty() {
                return Err("gen4 store: empty location directory".to_owned());
            }
            if let Some(b) = self.binding_where("collection", &collection.0.as_slice())? {
                if b.col != col {
                    return Err(format!(
                        "gen4 store: collection {collection} is already bound to profile {}",
                        b.profile
                    ));
                }
            }
            let n = self
                .conn
                .prepare_cached("UPDATE collections SET collection = ?2, dir = ?3 WHERE col = ?1")
                .map_err(sql)?
                .execute(params![col, collection.0.as_slice(), dir])
                .map_err(sql)?;
            if n != 1 {
                return Err(format!("gen4 store: no collection {col}"));
            }
            Ok(())
        })
    }

    // ------------------------------------------------------------ 设备

    fn cache_dev(&self, dev: i64, row: DevRow) {
        let mut st = self.st.borrow_mut();
        st.dev_ix.insert((row.col, row.id), dev);
        st.devs.insert(dev, row);
    }

    fn dev_find(&self, col: i64, id: &Id) -> Result<Option<i64>, String> {
        if let Some(&d) = self.st.borrow().dev_ix.get(&(col, *id)) {
            return Ok(Some(d));
        }
        self.ensure_snapshot()?;
        let row = self
            .conn
            .prepare_cached("SELECT dev, kind, src, tail FROM devs WHERE col = ?1 AND id = ?2")
            .map_err(sql)?
            .query_row(params![col, id.0.as_slice()], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, Option<i64>>(1)?,
                    r.get::<_, Option<Vec<u8>>>(2)?,
                    r.get::<_, Option<Vec<u8>>>(3)?,
                ))
            })
            .optional()
            .map_err(sql)?;
        let Some((dev, kind, src, tail)) = row else {
            return Ok(None);
        };
        self.cache_dev(
            dev,
            DevRow {
                col,
                id: *id,
                kind,
                src: src.as_deref().map(id_of).transpose()?,
                tail: tail.as_deref().map(chain_of).transpose()?,
                last: None,
                parked: None,
            },
        );
        Ok(Some(dev))
    }

    /// 设备的下标（没有就登记一个，种类未知）。
    fn dev(&self, col: i64, id: &Id) -> Result<i64, String> {
        if let Some(d) = self.dev_find(col, id)? {
            return Ok(d);
        }
        if self.binding(col)?.is_none() {
            return Err(format!("gen4 store: no collection {col}"));
        }
        self.conn
            .prepare_cached("INSERT INTO devs (col, id) VALUES (?1, ?2)")
            .map_err(sql)?
            .execute(params![col, id.0.as_slice()])
            .map_err(sql)?;
        let dev = self.conn.last_insert_rowid();
        opk(dev, 1)?;
        self.cache_dev(
            dev,
            DevRow {
                col,
                id: *id,
                kind: None,
                src: None,
                tail: None,
                last: Some(0),
                parked: Some(false),
            },
        );
        Ok(dev)
    }

    fn dev_row(&self, dev: i64) -> Result<DevRow, String> {
        if let Some(r) = self.st.borrow().devs.get(&dev) {
            return Ok(r.clone());
        }
        self.ensure_snapshot()?;
        let (col, id, kind, src, tail) = self
            .conn
            .prepare_cached("SELECT col, id, kind, src, tail FROM devs WHERE dev = ?1")
            .map_err(sql)?
            .query_row([dev], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, Vec<u8>>(1)?,
                    r.get::<_, Option<i64>>(2)?,
                    r.get::<_, Option<Vec<u8>>>(3)?,
                    r.get::<_, Option<Vec<u8>>>(4)?,
                ))
            })
            .optional()
            .map_err(sql)?
            .ok_or_else(|| format!("gen4 store: no device {dev}"))?;
        let row = DevRow {
            col,
            id: id_of(&id)?,
            kind,
            src: src.as_deref().map(id_of).transpose()?,
            tail: tail.as_deref().map(chain_of).transpose()?,
            last: None,
            parked: None,
        };
        self.cache_dev(dev, row.clone());
        Ok(row)
    }

    fn with_dev(&self, dev: i64, f: impl FnOnce(&mut DevRow)) -> Result<(), String> {
        self.dev_row(dev)?;
        f(self
            .st
            .borrow_mut()
            .devs
            .get_mut(&dev)
            .expect("device row was just cached"));
        Ok(())
    }

    /// 这台设备的日志是哪一种：第一次见到它的日志时定下来，之后不能变。
    fn claim(&self, dev: i64, kind: i64, src: Option<&Id>) -> Result<(), String> {
        let row = self.dev_row(dev)?;
        match row.kind {
            Some(k) if k != kind => Err(format!(
                "gen4 store: device {} already has a {} log",
                row.id,
                if k == DEV_NATIVE {
                    "native"
                } else {
                    "heritage"
                }
            )),
            Some(_) if kind == DEV_HERITAGE && row.src.as_ref() != src => Err(format!(
                "gen4 store: heritage device {} belongs to another source collection",
                row.id
            )),
            Some(_) => Ok(()),
            None => {
                self.conn
                    .prepare_cached("UPDATE devs SET kind = ?2, src = ?3 WHERE dev = ?1")
                    .map_err(sql)?
                    .execute(params![dev, kind, src.map(|s| s.0.to_vec())])
                    .map_err(sql)?;
                self.with_dev(dev, |d| {
                    d.kind = Some(kind);
                    d.src = src.copied();
                })
            }
        }
    }

    fn last(&self, dev: i64) -> Result<u64, String> {
        if let Some(n) = self.dev_row(dev)?.last {
            return Ok(n);
        }
        self.ensure_snapshot()?;
        let (lo, hi) = k_range(dev);
        let mut n = 0u64;
        for q in [
            "SELECT MAX(k) FROM ops WHERE k BETWEEN ?1 AND ?2",
            "SELECT MAX(k) FROM op_alias WHERE k BETWEEN ?1 AND ?2",
        ] {
            let k: Option<i64> = self
                .conn
                .prepare_cached(q)
                .map_err(sql)?
                .query_row(params![lo, hi], |r| r.get(0))
                .map_err(sql)?;
            n = n.max(k.map_or(0, k_seq));
        }
        if let Some(run) = self.run_at_or_before(dev, k_seq(hi))? {
            n = n.max(run.end());
        }
        self.with_dev(dev, |d| d.last = Some(n))?;
        Ok(n)
    }

    /// 这个集合里登记过的设备（按下标升序）。
    pub fn devices(&self, col: i64) -> Result<Vec<DevInfo>, String> {
        let devs: Vec<i64> = {
            let mut stmt = self
                .conn
                .prepare_cached("SELECT dev FROM devs WHERE col = ?1 ORDER BY dev")
                .map_err(sql)?;
            let rows = stmt.query_map([col], |r| r.get(0)).map_err(sql)?;
            rows.collect::<rusqlite::Result<_>>().map_err(sql)?
        };
        let mut out = Vec::with_capacity(devs.len());
        for dev in devs {
            let row = self.dev_row(dev)?;
            out.push(DevInfo {
                dev,
                id: row.id,
                kind: row.kind,
                src: row.src,
                last: self.last(dev)?,
            });
        }
        Ok(out)
    }

    /// 本机已应用的版本向量（每台设备日志的末尾）。
    pub fn applied(&self, col: i64) -> Result<Vv, String> {
        let mut vv = Vv::new();
        for d in self.devices(col)? {
            if d.last > 0 {
                vv.0.insert(d.id, d.last);
            }
        }
        Ok(vv)
    }

    /// 一台设备日志的末尾（没见过 = 0）。
    pub fn last_of(&self, col: i64, device: &Id) -> Result<u64, String> {
        match self.dev_find(col, device)? {
            Some(dev) => self.last(dev),
            None => Ok(0),
        }
    }

    // ------------------------------------------------------------ 内部化表

    fn writer_id(&self, name: &str) -> Result<u64, String> {
        if let Some(&i) = self.st.borrow().writer_ix.get(name) {
            return Ok(i);
        }
        self.ensure_snapshot()?;
        let mut w = Writer::new();
        write_name(&mut w, name);
        let bytes = w.into_vec();
        let found: Option<i64> = self
            .conn
            .prepare_cached("SELECT id FROM writers WHERE name = ?1")
            .map_err(sql)?
            .query_row([&bytes], |r| r.get(0))
            .optional()
            .map_err(sql)?;
        let id = match found {
            Some(i) => i,
            None => {
                self.conn
                    .prepare_cached("INSERT INTO writers (name) VALUES (?1)")
                    .map_err(sql)?
                    .execute([&bytes])
                    .map_err(sql)?;
                self.conn.last_insert_rowid()
            }
        } as u64;
        let mut st = self.st.borrow_mut();
        if st.writer_ix.len() >= CACHE_MAX {
            st.writer_ix.clear();
            st.writer_name.clear();
        }
        st.writer_ix.insert(name.to_owned(), id);
        st.writer_name.insert(id, name.to_owned());
        Ok(id)
    }

    fn writer_name(&self, id: u64) -> Result<String, String> {
        if let Some(n) = self.st.borrow().writer_name.get(&id) {
            return Ok(n.clone());
        }
        self.ensure_snapshot()?;
        let bytes: Vec<u8> = self
            .conn
            .prepare_cached("SELECT name FROM writers WHERE id = ?1")
            .map_err(sql)?
            .query_row([id as i64], |r| r.get(0))
            .optional()
            .map_err(sql)?
            .ok_or_else(|| format!("gen4 store: no writer {id}"))?;
        let mut r = Reader::new(&bytes);
        let name = read_name(&mut r).map_err(|e| format!("gen4 store: writer {id}: {e}"))?;
        if !r.is_empty() {
            return Err(format!("gen4 store: writer {id} has trailing bytes"));
        }
        let mut st = self.st.borrow_mut();
        if st.writer_name.len() >= CACHE_MAX {
            st.writer_ix.clear();
            st.writer_name.clear();
        }
        st.writer_ix.insert(name.clone(), id);
        st.writer_name.insert(id, name.clone());
        Ok(name)
    }

    fn snapshot_id(&self, body: &str) -> Result<u64, String> {
        let key = *blake3::hash(body.as_bytes()).as_bytes();
        if let Some(&i) = self.st.borrow().snap_ix.get(&key) {
            return Ok(i);
        }
        self.ensure_snapshot()?;
        let found: Option<i64> = self
            .conn
            .prepare_cached("SELECT id FROM snapshots WHERE body = ?1")
            .map_err(sql)?
            .query_row([body], |r| r.get(0))
            .optional()
            .map_err(sql)?;
        let id = match found {
            Some(i) => i,
            None => {
                self.conn
                    .prepare_cached("INSERT INTO snapshots (body) VALUES (?1)")
                    .map_err(sql)?
                    .execute([body])
                    .map_err(sql)?;
                self.conn.last_insert_rowid()
            }
        } as u64;
        let mut st = self.st.borrow_mut();
        if st.snap_ix.len() >= 4096 {
            st.snap_ix.clear();
            st.snap_body.clear();
        }
        st.snap_ix.insert(key, id);
        st.snap_body.insert(id, body.to_owned());
        Ok(id)
    }

    fn snapshot_body(&self, id: u64) -> Result<String, String> {
        if let Some(b) = self.st.borrow().snap_body.get(&id) {
            return Ok(b.clone());
        }
        self.ensure_snapshot()?;
        let body: String = self
            .conn
            .prepare_cached("SELECT body FROM snapshots WHERE id = ?1")
            .map_err(sql)?
            .query_row([id as i64], |r| r.get(0))
            .optional()
            .map_err(sql)?
            .ok_or_else(|| format!("gen4 store: no snapshot {id}"))?;
        let mut st = self.st.borrow_mut();
        if st.snap_body.len() >= 4096 {
            st.snap_ix.clear();
            st.snap_body.clear();
        }
        st.snap_body.insert(id, body.clone());
        Ok(body)
    }

    /// 依赖向量 → 内部化的号（空向量 = 0，不占行）。存的是 `(设备下标, seq)` 按下标升序。
    fn deps_id(&self, col: i64, deps: &Vv) -> Result<i64, String> {
        if deps.0.is_empty() {
            return Ok(0);
        }
        let mut items: Vec<(i64, u64)> = Vec::with_capacity(deps.0.len());
        for (id, &seq) in &deps.0 {
            items.push((self.dev(col, id)?, seq));
        }
        items.sort_unstable();
        let mut w = Writer::new();
        w.uv(items.len() as u64);
        for (d, s) in items {
            w.uv(d as u64);
            w.uv(s);
        }
        let bytes = w.into_vec();
        if let Some(&i) = self.st.borrow().deps_ix.get(&bytes) {
            return Ok(i);
        }
        self.ensure_snapshot()?;
        let found: Option<i64> = self
            .conn
            .prepare_cached("SELECT id FROM op_deps WHERE bytes = ?1")
            .map_err(sql)?
            .query_row([&bytes], |r| r.get(0))
            .optional()
            .map_err(sql)?;
        let id = match found {
            Some(i) => i,
            None => {
                self.conn
                    .prepare_cached("INSERT INTO op_deps (bytes) VALUES (?1)")
                    .map_err(sql)?
                    .execute([&bytes])
                    .map_err(sql)?;
                self.conn.last_insert_rowid()
            }
        };
        let mut st = self.st.borrow_mut();
        if st.deps_ix.len() >= CACHE_MAX {
            st.deps_ix.clear();
        }
        st.deps_ix.insert(bytes, id);
        Ok(id)
    }

    fn deps_of(&self, id: i64) -> Result<Arc<Vv>, String> {
        if id == 0 {
            return Ok(self.no_deps.clone());
        }
        if let Some(v) = self.st.borrow().deps_vv.get(&id) {
            return Ok(v.clone());
        }
        self.ensure_snapshot()?;
        let bytes: Vec<u8> = self
            .conn
            .prepare_cached("SELECT bytes FROM op_deps WHERE id = ?1")
            .map_err(sql)?
            .query_row([id], |r| r.get(0))
            .optional()
            .map_err(sql)?
            .ok_or_else(|| format!("gen4 store: no deps {id}"))?;
        let bad = |e: crate::sync2::codec::DecodeError| format!("gen4 store: deps {id}: {e}");
        let mut r = Reader::new(&bytes);
        let n = r.uv().map_err(bad)?;
        let mut vv = Vv::new();
        for _ in 0..n {
            let dev = r.uv().map_err(bad)? as i64;
            let seq = r.uv().map_err(bad)?;
            vv.0.insert(self.dev_row(dev)?.id, seq);
        }
        if !r.is_empty() {
            return Err(format!("gen4 store: deps {id} has trailing bytes"));
        }
        let vv = Arc::new(vv);
        let mut st = self.st.borrow_mut();
        if st.deps_vv.len() >= CACHE_MAX {
            st.deps_vv.clear();
        }
        st.deps_vv.insert(id, vv.clone());
        Ok(vv)
    }

    // ------------------------------------------------------------ 读

    fn op_entry(&self, row: OpRow) -> Result<Entry, String> {
        let dev = self.dev_row(k_dev(row.k))?;
        let id = OpId {
            device: dev.id,
            seq: k_seq(row.k),
        };
        let payload = pack::unpack_payload(row.flags, &row.body, row.aux.as_deref(), &mut N(self))?;
        let hlc = Hlc {
            wall: row.wall,
            logical: row.logical as u32,
            device: dev.id,
        };
        let deps = self.deps_of(row.deps)?;
        let body = if row.flags & F_RAW3 != 0 {
            SlotBody::Raw3(Raw3::of_v3(&v3::Op {
                id,
                hlc,
                deps,
                kind: row.kind as u16,
                schema: row.fmt as u16,
                payload: payload.into(),
                purged: false,
            }))
        } else {
            SlotBody::Op(Op4 {
                id,
                hlc,
                deps,
                kind: row.kind as u16,
                fmt: row.fmt as u16,
                payload: payload.into(),
            })
        };
        Ok(Entry {
            id,
            fp: row.fp.as_deref().map(fp_of).transpose()?,
            tv: tv_of(row.flags),
            local: false,
            body,
        })
    }

    fn alias_entry(&self, row: AliasRow) -> Result<Entry, String> {
        let dev = self.dev_row(k_dev(row.k))?;
        let of = self.dev_row(row.of_dev)?.id;
        let stamp = match &row.stamp {
            None => None,
            Some(b) if row.flags & A_STAMP_WIRE != 0 => {
                let mut r = Reader::new(b);
                let s = HeritageStamp::read(&mut r)
                    .map_err(|e| format!("gen4 store: stored alias stamp: {e}"))?;
                if !r.is_empty() {
                    return Err("gen4 store: stored alias stamp has trailing bytes".to_owned());
                }
                Some(s)
            }
            Some(b) => Some(pack::unpack_stamp(b, &mut N(self))?),
        };
        Ok(Entry {
            id: OpId {
                device: dev.id,
                seq: k_seq(row.k),
            },
            fp: Some(fp_of(&row.fp)?),
            tv: tv_of(row.flags),
            local: row.flags & A_LOCAL != 0,
            body: SlotBody::Alias(Alias {
                kind: row.kind as u16,
                wall: row.wall,
                logical: row.logical as u32,
                of: OpId {
                    device: of,
                    seq: row.of_seq as u64,
                },
                stamp,
            }),
        })
    }

    fn void_entry(&self, run: &VoidRun, seq: u64) -> Result<Entry, String> {
        let dev = self.dev_row(k_dev(run.k))?;
        let fp = match &run.fps {
            None => None,
            Some(f) => {
                let i = ((seq - k_seq(run.k)) * 8) as usize;
                Some(fp_of(f.get(i..i + 8).ok_or_else(|| {
                    "gen4 store: void run has too few fingerprints".to_owned()
                })?)?)
            }
        };
        Ok(Entry {
            id: OpId {
                device: dev.id,
                seq,
            },
            fp,
            tv: tv_of(run.flags),
            local: run.flags & A_LOCAL != 0,
            body: SlotBody::Void,
        })
    }

    /// 设备 [device] 的日志在 `first..=last` 里已经落成空洞（已清除）的 seq 区间，按 seq 升序、各自截到这个范围里。
    /// 本机没有这台设备 = 空。转发缓存据此拒收带着已清除内容的作者段（`cmd/sync_relay.rs` `keep`）。
    pub fn voids_within(
        &self,
        col: i64,
        device: &Id,
        first: u64,
        last: u64,
    ) -> Result<Vec<(u64, u64)>, String> {
        if first == 0 || last < first {
            return Ok(Vec::new());
        }
        let Some(dev) = self.dev_find(col, device)? else {
            return Ok(Vec::new());
        };
        let mut out = Vec::new();
        if let Some(run) = self.run_at_or_before(dev, first)? {
            if run.end() >= first {
                out.push((first, run.end().min(last)));
            }
        }
        if first < last {
            let mut stmt = self
                .conn
                .prepare_cached("SELECT k, n FROM op_voids WHERE k BETWEEN ?1 AND ?2 ORDER BY k")
                .map_err(sql)?;
            let rows = stmt
                .query_map(params![opk(dev, first + 1)?, opk(dev, last)?], |r| {
                    Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)? as u64))
                })
                .map_err(sql)?;
            for row in rows {
                let (k, n) = row.map_err(sql)?;
                let s = k_seq(k);
                out.push((s, (s + n - 1).min(last)));
            }
        }
        Ok(out)
    }

    /// 起点不晚于 [seq] 的最后一个空洞区间（不一定盖得到 [seq]）。
    fn run_at_or_before(&self, dev: i64, seq: u64) -> Result<Option<VoidRun>, String> {
        let (lo, _) = k_range(dev);
        self.conn
            .prepare_cached(
                "SELECT k, n, flags, fps, chain FROM op_voids WHERE k BETWEEN ?1 AND ?2 ORDER BY k DESC LIMIT 1",
            )
            .map_err(sql)?
            .query_row(params![lo, opk(dev, seq)?], void_row)
            .optional()
            .map_err(sql)
    }

    fn entry_at(&self, dev: i64, seq: u64) -> Result<Option<Entry>, String> {
        let k = opk(dev, seq)?;
        let op = self
            .conn
            .prepare_cached(
                "SELECT k, wall, logical, deps, kind, fmt, flags, body, aux, fp FROM ops WHERE k = ?1",
            )
            .map_err(sql)?
            .query_row([k], op_row)
            .optional()
            .map_err(sql)?;
        if let Some(row) = op {
            return self.op_entry(row).map(Some);
        }
        let alias = self
            .conn
            .prepare_cached(
                "SELECT k, kind, wall, logical, of_dev, of_seq, flags, stamp, fp FROM op_alias WHERE k = ?1",
            )
            .map_err(sql)?
            .query_row([k], alias_row)
            .optional()
            .map_err(sql)?;
        if let Some(row) = alias {
            return self.alias_entry(row).map(Some);
        }
        match self.run_at_or_before(dev, seq)? {
            Some(run) if seq <= run.end() => self.void_entry(&run, seq).map(Some),
            _ => Ok(None),
        }
    }

    /// 日志里的一条（主支；分叉的另一支见 [Truth::forks]）。
    pub fn entry(&self, col: i64, id: &OpId) -> Result<Option<Entry>, String> {
        match self.dev_find(col, &id.device)? {
            Some(dev) if id.seq >= 1 && id.seq <= self.last(dev)? => self.entry_at(dev, id.seq),
            _ => Ok(None),
        }
    }

    // ------------------------------------------------------------ 读：派生层用的按主键访问

    /// 操作号 → 主键（本机没见过这台设备 = None）。
    pub(crate) fn key_of(&self, col: i64, id: &OpId) -> Result<Option<i64>, String> {
        match self.dev_find(col, &id.device)? {
            Some(dev) => opk(dev, id.seq).map(Some),
            None => Ok(None),
        }
    }

    /// 操作号 → 主键；本机没见过这台设备就先给它一个下标（`devs.kind` 空：只被点过名，还没见过它的日志）。收段把
    /// 还接不上的原生操作放进等待缓冲（`op_wait`）时用。
    pub(super) fn key_for(&self, col: i64, id: &OpId) -> Result<i64, String> {
        self.write(|| opk(self.dev(col, &id.device)?, id.seq))
    }

    /// 主键 → 操作号。
    pub(crate) fn id_of_key(&self, k: i64) -> Result<OpId, String> {
        Ok(OpId {
            device: self.dev_row(k_dev(k))?.id,
            seq: k_seq(k),
        })
    }

    /// 主键 → 日志里的那一条。
    pub(crate) fn entry_by_key(&self, k: i64) -> Result<Option<Entry>, String> {
        self.entry_at(k_dev(k), k_seq(k))
    }

    /// 修改操作的字段值（规范 JSON 文本）。只读 `ops` 一行的主体、不还原旧戳（整列读正文的路径，设计 §2.3）；
    /// 不是完整的修改操作 = None。
    pub(crate) fn edit_value(&self, k: i64) -> Result<Option<String>, String> {
        let row: Option<(i64, i64, i64, Vec<u8>)> = self
            .conn
            .prepare_cached("SELECT kind, fmt, flags, body FROM ops WHERE k = ?1")
            .map_err(sql)?
            .query_row([k], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
            .optional()
            .map_err(sql)?;
        let Some((kind, fmt, flags, body)) = row else {
            return Ok(None);
        };
        if kind != i64::from(KIND_EDIT) {
            return Ok(None);
        }
        if flags & F_RAW3 != 0 {
            // 原样件：协议 3 的载荷，走完整的还原。
            let e = self.entry_by_key(k)?;
            return Ok(e
                .and_then(|e| e.slot())
                .and_then(|s| applied_body(&s))
                .and_then(|b| match b {
                    Body4::Edit(e) => Some(e.value),
                    _ => None,
                }));
        }
        let main = pack::main_bytes(flags, &body)?;
        match Body4::decode(KIND_EDIT, fmt as u16, &main) {
            Ok(Body4::Edit(e)) => Ok(Some(e.value)),
            _ => Ok(None),
        }
    }

    /// 主键 [k] 上的修改操作，按派生层要的读法（BUG-5137）：信封（操作号、HLC、依赖）+ 操作体头部（实体、键、旧戳），
    /// 字段值只在 [with_value] 时复制出来。判定与 `entry_by_key` + `derive::body_of` 逐字段相同（测试
    /// `edit_read_matches_the_full_decode`），但不做那条路上的三件冗余事：把内部化的旧戳拼回规范字节、整份载荷再克隆一次、
    /// 再从头解一遍字段值（笔记正文）。
    ///
    /// 不是修改（别的种类、解不开、副本记录、空洞）= None；这个主键上什么都没有 = Err（派生层的寄存器行只指向日志里
    /// 实有的条目）。原样件（协议 3 的载荷要经转译）与剪了快照的行走整条读法。
    pub(crate) fn edit_read(&self, k: i64, with_value: bool) -> Result<Option<EditRead>, String> {
        let row = self
            .conn
            .prepare_cached(
                "SELECT k, wall, logical, deps, kind, fmt, flags, body, aux, fp FROM ops WHERE k = ?1",
            )
            .map_err(sql)?
            .query_row([k], op_row)
            .optional()
            .map_err(sql)?;
        let Some(row) = row else {
            return match self.entry_by_key(k)? {
                Some(_) => Ok(None),
                None => Err(format!("gen4 store: no op at key {k}")),
            };
        };
        if row.kind != i64::from(KIND_EDIT) {
            return Ok(None);
        }
        let (wall, logical) = (row.wall, row.logical as u32);
        let deps = self.deps_of(row.deps)?;
        let (head, value) = if row.flags & (F_RAW3 | F_SNAP) != 0 {
            let e = self.op_entry(row)?;
            match super::derive::body_of(&e) {
                Some(Body4::Edit(ed)) => {
                    let (h, v) = ed.into_parts();
                    (h, with_value.then_some(v))
                }
                _ => return Ok(None),
            }
        } else {
            let main = pack::main_bytes(row.flags, &row.body)?;
            if row.flags & F_STAMP != 0 {
                let aux = row
                    .aux
                    .as_deref()
                    .ok_or("gen4 store: stamped edit without its stamp")?;
                let stamp = pack::unpack_stamp(aux, &mut N(self))?;
                let Ok((mut h, v)) = decode_edit_parts(BODY_FMT, &main) else {
                    return Err("gen4 store: stored edit does not decode".to_owned());
                };
                h.stamp = Some(stamp);
                (h, with_value.then(|| v.to_owned()))
            } else {
                match decode_edit_parts(row.fmt as u16, &main) {
                    Ok((h, v)) => (h, with_value.then(|| v.to_owned())),
                    Err(_) => return Ok(None),
                }
            }
        };
        Ok(Some(EditRead {
            id: self.id_of_key(k)?,
            wall,
            logical,
            deps,
            head,
            value,
        }))
    }

    /// 一条完整操作的信封（不解操作体）：语义层判「谁见过谁」用。空洞、副本记录 = None。
    pub(crate) fn head_by_key(&self, k: i64) -> Result<Option<Head>, String> {
        let row: Option<(i64, i64, i64, i64, i64)> = self
            .conn
            .prepare_cached("SELECT wall, logical, deps, kind, flags FROM ops WHERE k = ?1")
            .map_err(sql)?
            .query_row([k], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
            })
            .optional()
            .map_err(sql)?;
        let Some((wall, logical, deps, kind, flags)) = row else {
            return Ok(None);
        };
        Ok(Some(Head {
            id: self.id_of_key(k)?,
            wall,
            logical,
            deps: self.deps_of(deps)?,
            kind: kind as u16,
            raw: flags & F_RAW3 != 0,
            stamped: flags & F_STAMP != 0,
        }))
    }

    // ------------------------------------------------------------ 本机状态：派生层的宿主输入

    /// 派生层的输入里只有宿主知道的那一部分（随应用版本走的表：内置笔记类型、缓存配置……），按名字存一份文本。
    /// 派生表是「真相 + 本机信任状态 + 这些输入」的函数：重建与逐条维护读的是同一份，不靠调用方每次传对。
    pub fn derive_cfg(&self, col: i64, key: &str) -> Result<Option<String>, String> {
        self.conn
            .prepare_cached("SELECT value FROM derive_cfg WHERE col = ?1 AND key = ?2")
            .map_err(sql)?
            .query_row(params![col, key], |r| r.get(0))
            .optional()
            .map_err(sql)
    }

    /// 改一项宿主输入（None = 删掉）。返回变没变；变了之后，用到它的派生表要由调用方重建。
    pub fn set_derive_cfg(&self, col: i64, key: &str, value: Option<&str>) -> Result<bool, String> {
        self.write(|| {
            if self.derive_cfg(col, key)?.as_deref() == value {
                return Ok(false);
            }
            match value {
                Some(v) => self
                    .conn
                    .prepare_cached(
                        "INSERT INTO derive_cfg (col, key, value) VALUES (?1, ?2, ?3) \
                         ON CONFLICT (col, key) DO UPDATE SET value = excluded.value",
                    )
                    .map_err(sql)?
                    .execute(params![col, key, v])
                    .map_err(sql)?,
                None => self
                    .conn
                    .prepare_cached("DELETE FROM derive_cfg WHERE col = ?1 AND key = ?2")
                    .map_err(sql)?
                    .execute(params![col, key])
                    .map_err(sql)?,
            };
            Ok(true)
        })
    }

    // ------------------------------------------------------------ 本机状态：设备公钥

    /// 一台设备的公钥（Ed25519，32 字节）。没见过 = None。验签、导出、迁移灌入共用（规划缺口 G-11）。
    pub fn device_key(&self, col: i64, device: &Id) -> Result<Option<[u8; 32]>, String> {
        let row: Option<Vec<u8>> = self
            .conn
            .prepare_cached("SELECT public FROM peers WHERE col = ?1 AND device = ?2")
            .map_err(sql)?
            .query_row(params![col, &device.0[..]], |r| r.get(0))
            .optional()
            .map_err(sql)?;
        match row {
            None => Ok(None),
            Some(b) => b
                .try_into()
                .map(Some)
                .map_err(|_| format!("gen4 store: bad public key for device {device}")),
        }
    }

    /// 一台设备的整行。
    pub fn peer(&self, col: i64, device: &Id) -> Result<Option<Peer>, String> {
        self.conn
            .prepare_cached(
                "SELECT public, name, ext, head_gen, first_seen FROM peers WHERE col = ?1 AND device = ?2",
            )
            .map_err(sql)?
            .query_row(params![col, &device.0[..]], |r| {
                Ok((
                    r.get::<_, Vec<u8>>(0)?,
                    r.get::<_, Option<String>>(1)?,
                    r.get::<_, Option<String>>(2)?,
                    r.get::<_, Option<i64>>(3)?,
                    r.get::<_, Option<i64>>(4)?,
                ))
            })
            .optional()
            .map_err(sql)?
            .map(|(public, name, ext, head_gen, first_seen)| {
                Ok(Peer {
                    device: *device,
                    public: public
                        .try_into()
                        .map_err(|_| format!("gen4 store: bad public key for device {device}"))?,
                    name,
                    ext,
                    head_gen,
                    first_seen,
                })
            })
            .transpose()
    }

    /// 记下一台设备（迁移灌入 `sync2_devices`、收到它的 head）。公钥先到先得（协议 3 `trust_head` 的口径）：已经记过
    /// 另一个公钥 = [PeerPut::KeyMismatch]，什么都不写，由调用方当作冒名处理。同一个公钥：`name` / `ext` 给了就换，
    /// `head_gen` 只升不降，`first_seen` 留第一次的。
    pub fn set_peer(&self, col: i64, peer: &Peer) -> Result<PeerPut, String> {
        self.write(|| {
            let Some(cur) = self.peer(col, &peer.device)? else {
                self.conn
                    .prepare_cached(
                        "INSERT INTO peers (col, device, public, name, ext, head_gen, first_seen) \
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                    )
                    .map_err(sql)?
                    .execute(params![
                        col,
                        &peer.device.0[..],
                        &peer.public[..],
                        peer.name,
                        peer.ext,
                        peer.head_gen,
                        peer.first_seen
                    ])
                    .map_err(sql)?;
                return Ok(PeerPut::Inserted);
            };
            if cur.public != peer.public {
                return Ok(PeerPut::KeyMismatch);
            }
            let next = Peer {
                device: peer.device,
                public: peer.public,
                name: peer.name.clone().or(cur.name.clone()),
                ext: peer.ext.clone().or(cur.ext.clone()),
                head_gen: match (cur.head_gen, peer.head_gen) {
                    (Some(a), Some(b)) => Some(a.max(b)),
                    (a, b) => a.or(b),
                },
                first_seen: cur.first_seen.or(peer.first_seen),
            };
            if next == cur {
                return Ok(PeerPut::Same);
            }
            self.conn
                .prepare_cached(
                    "UPDATE peers SET name = ?3, ext = ?4, head_gen = ?5, first_seen = ?6 \
                     WHERE col = ?1 AND device = ?2",
                )
                .map_err(sql)?
                .execute(params![
                    col,
                    &peer.device.0[..],
                    next.name,
                    next.ext,
                    next.head_gen,
                    next.first_seen
                ])
                .map_err(sql)?;
            Ok(PeerPut::Updated)
        })
    }

    // ------------------------------------------------------------ 本机状态：本机身份

    /// 本机在集合 [col] 里的身份（还没建 = None）。
    pub fn self_identity(&self, col: i64) -> Result<Option<SelfId>, String> {
        let row = self
            .conn
            .prepare_cached(
                "SELECT device, sk, hlc, prev_device, prev_seq, prev_chain, created FROM self_ WHERE col = ?1",
            )
            .map_err(sql)?
            .query_row([col], |r| {
                Ok((
                    r.get::<_, Vec<u8>>(0)?,
                    r.get::<_, Vec<u8>>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, Option<Vec<u8>>>(3)?,
                    r.get::<_, Option<i64>>(4)?,
                    r.get::<_, Option<Vec<u8>>>(5)?,
                    r.get::<_, i64>(6)?,
                ))
            })
            .optional()
            .map_err(sql)?;
        let Some((device, sk, hlc, pd, ps, pc, created)) = row else {
            return Ok(None);
        };
        let device = id_of(&device)?;
        let prev = prev_from_cols(col, pd, ps, pc)?;
        Ok(Some(SelfId {
            device,
            sk: sk
                .try_into()
                .map_err(|_| format!("gen4 store: bad signing key seed for collection {col}"))?,
            hlc: hlc_parse(&hlc, device)?,
            prev,
            created,
        }))
    }

    /// 给集合 [col] 建本机身份：设备 [device]、签名钥匙种子 [sk]，时钟从零起；同时把本机公钥记进 `peers`（验自己的段、
    /// 导出都按公钥表查，与别的设备同一条路）。返回建没建：已有逐项相同（设备、钥匙、[prev]）的身份 = `false`（迁移
    /// 续做幂等）；已有另一个身份 = 报错（换身份是 G8-6 的 `rotate_identity`，不走这里）。
    ///
    /// [prev] = 这个身份接替的上一个身份冻结在哪（设计 §3.3：迁移时是协议 3 的旧设备 ID、它日志的末尾 seq 与该处的
    /// 完整链值；全新安装 = None）。存储口径同 [prev_cols]：`seq` 可以是 0，这时链值必须是 [CHAIN_ZERO]；不能是新身份
    /// 自己。给了 [prev] 时同一把钥匙的公钥也记到旧设备名下（读者核对 `prev` 用，与换身份同口径）；旧设备已经记过
    /// 另一个公钥 = 报错。
    ///
    /// 新身份必须是这个集合里没出现过日志的设备：同一个设备 ID 已有日志（承袭日志、或别人的原生日志）时接着写会让两条
    /// 日志撞号，报错。
    pub fn create_self(
        &self,
        col: i64,
        device: &Id,
        sk: &[u8; 32],
        prev: Option<&PrevIdentity>,
        now: i64,
    ) -> Result<bool, String> {
        self.write(|| {
            if self.binding(col)?.is_none() {
                return Err(format!("gen4 store: no collection {col}"));
            }
            if let Some(p) = prev {
                if p.device == *device {
                    return Err(format!(
                        "gen4 store: device {device} cannot be its own previous identity"
                    ));
                }
                if p.seq == 0 && p.chain != CHAIN_ZERO {
                    return Err(format!(
                        "gen4 store: previous identity {} at seq 0 must sit at the chain start",
                        p.device
                    ));
                }
                if p.seq > i64::MAX as u64 {
                    return Err(format!(
                        "gen4 store: previous identity {} has a bad seq {}",
                        p.device, p.seq
                    ));
                }
            }
            if let Some(cur) = self.self_identity(col)? {
                if cur.device == *device && cur.sk == *sk && cur.prev.as_ref() == prev {
                    return Ok(false);
                }
                return Err(format!(
                    "gen4 store: collection {col} already has local identity {}",
                    cur.device
                ));
            }
            if self.last_of(col, device)? > 0 {
                return Err(format!(
                    "gen4 store: device {device} already has a log in collection {col}"
                ));
            }
            let public = DeviceKey::from_seed(sk).public();
            self.own_peer(col, device, public, now)?;
            if let Some(p) = prev {
                self.own_peer(col, &p.device, public, now)?;
            }
            let zero = Hlc {
                wall: 0,
                logical: 0,
                device: *device,
            };
            let (pd, ps, pc) = prev_cols(prev);
            self.conn
                .prepare_cached(
                    "INSERT INTO self_ (col, device, sk, hlc, prev_device, prev_seq, prev_chain, created) \
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                )
                .map_err(sql)?
                .execute(params![
                    col,
                    &device.0[..],
                    &sk[..],
                    hlc_text(&zero),
                    pd,
                    ps,
                    pc,
                    now
                ])
                .map_err(sql)?;
            Ok(true)
        })
    }

    /// 把本机的公钥记到 [device] 名下（新建的身份；换身份时的新身份与冻结的旧身份）。验自己的段、导出都按公钥表查，
    /// 与别的设备同一条路。已经记过另一个公钥 = 报错。
    fn own_peer(&self, col: i64, device: &Id, public: [u8; 32], now: i64) -> Result<(), String> {
        let peer = Peer {
            device: *device,
            public,
            name: None,
            ext: None,
            head_gen: None,
            first_seen: Some(now),
        };
        if self.set_peer(col, &peer)? == PeerPut::KeyMismatch {
            return Err(format!(
                "gen4 store: device {device} is already known with another public key"
            ));
        }
        Ok(())
    }

    /// 记下本机时钟发出过的最大 HLC（原生写入者每写一条调一次，与那条操作同一个事务）。只升不降：比已记的小或相等
    /// 是调用方的 bug（会发出重复 / 倒退的 HLC），报错。
    pub(crate) fn set_self_hlc(&self, col: i64, hlc: &Hlc) -> Result<(), String> {
        self.write(|| {
            let cur = self
                .self_identity(col)?
                .ok_or_else(|| format!("gen4 store: collection {col} has no local identity"))?;
            if hlc.device != cur.device {
                return Err(format!(
                    "gen4 store: hlc of {} is not the local identity {}",
                    hlc.device, cur.device
                ));
            }
            if *hlc <= cur.hlc {
                return Err(format!(
                    "gen4 store: local clock would go back ({} after {})",
                    hlc_text(hlc),
                    hlc_text(&cur.hlc)
                ));
            }
            self.conn
                .prepare_cached("UPDATE self_ SET hlc = ?2 WHERE col = ?1")
                .map_err(sql)?
                .execute(params![col, hlc_text(hlc)])
                .map_err(sql)?;
            Ok(())
        })
    }

    // ------------------------------------------------------------ 本机状态：设备信任

    /// 一台设备的信任状态：[TRUST_PENDING] / [TRUST_REJECTED]；可信 = None。
    pub fn trust_of(&self, col: i64, device: &Id) -> Result<Option<i64>, String> {
        self.conn
            .prepare_cached("SELECT state FROM trust WHERE col = ?1 AND device = ?2")
            .map_err(sql)?
            .query_row(params![col, &device.0[..]], |r| r.get(0))
            .optional()
            .map_err(sql)
    }

    /// 一台设备的信任记录：(状态, 第一次记下的时刻 `since`)；可信 = None。同步页设备行的 `trust` / `trustSince` 用。
    pub fn trust_entry(&self, col: i64, device: &Id) -> Result<Option<(i64, i64)>, String> {
        self.conn
            .prepare_cached("SELECT state, since FROM trust WHERE col = ?1 AND device = ?2")
            .map_err(sql)?
            .query_row(params![col, &device.0[..]], |r| Ok((r.get(0)?, r.get(1)?)))
            .optional()
            .map_err(sql)
    }

    /// 还没信任的设备：(设备, 状态)，按设备 ID 升序。
    pub fn untrusted(&self, col: i64) -> Result<Vec<(Id, i64)>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT device, state FROM trust WHERE col = ?1 ORDER BY device")
            .map_err(sql)?;
        let rows = stmt
            .query_map([col], |r| {
                Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, i64>(1)?))
            })
            .map_err(sql)?;
        let mut out = Vec::new();
        for row in rows {
            let (d, state) = row.map_err(sql)?;
            out.push((id_of(&d)?, state));
        }
        Ok(out)
    }

    /// 改一台设备的信任状态（[state] = None：可信）。[since] 只在第一次记下时用（协议 3 的 `sync2_trust.since`）。
    /// 返回变没变。纯本机状态；改完要告诉派生层（`derive::Index::trust_changed`），被扣住的删除与清除才会重判。
    pub fn set_trust(
        &self,
        col: i64,
        device: &Id,
        state: Option<i64>,
        since: i64,
    ) -> Result<bool, String> {
        self.write(|| {
            if self.trust_of(col, device)? == state {
                return Ok(false);
            }
            match state {
                Some(s) if s == TRUST_PENDING || s == TRUST_REJECTED => self
                    .conn
                    .prepare_cached(
                        "INSERT INTO trust (col, device, state, since) VALUES (?1, ?2, ?3, ?4) \
                         ON CONFLICT (col, device) DO UPDATE SET state = excluded.state",
                    )
                    .map_err(sql)?
                    .execute(params![col, &device.0[..], s, since])
                    .map_err(sql)?,
                Some(s) => return Err(format!("gen4 store: bad trust state {s}")),
                None => self
                    .conn
                    .prepare_cached("DELETE FROM trust WHERE col = ?1 AND device = ?2")
                    .map_err(sql)?
                    .execute(params![col, &device.0[..]])
                    .map_err(sql)?,
            };
            Ok(true)
        })
    }

    /// 一台设备日志里 seq ≤ [upto] 的旧戳：承袭的修改（含原样件里的）与副本记录各自带的那个。先给操作上的、再给
    /// 副本记录上的，各按 seq 升序。派生层重建旧闭包用（设计 §3.4）。
    pub(crate) fn for_each_stamp(
        &self,
        col: i64,
        device: &Id,
        upto: u64,
        f: impl FnMut(u64, &HeritageStamp) -> Result<(), String>,
    ) -> Result<(), String> {
        self.for_each_stamp_in(col, device, 1, upto, f)
    }

    /// [Truth::for_each_stamp] 只走 seq 在 `[from, upto]` 里的那一段（按主键区间，不碰段外的行）：派生层从旧闭包的
    /// 检查点接着并（`derive.rs` [CLOSURE_STEP](super::derive::CLOSURE_STEP)）。
    pub(crate) fn for_each_stamp_in(
        &self,
        col: i64,
        device: &Id,
        from: u64,
        upto: u64,
        mut f: impl FnMut(u64, &HeritageStamp) -> Result<(), String>,
    ) -> Result<(), String> {
        let Some(dev) = self.dev_find(col, device)? else {
            return Ok(());
        };
        let from = from.max(1);
        if upto < from {
            return Ok(());
        }
        let (_, top) = k_range(dev);
        if from > k_seq(top) {
            return Ok(());
        }
        let lo = opk(dev, from)?;
        let hi = if upto >= k_seq(top) {
            top
        } else {
            opk(dev, upto)?
        };
        let mut stmt = self
            .conn
            .prepare_cached(
                "SELECT k, wall, logical, deps, kind, fmt, flags, body, aux, fp FROM ops                  WHERE k BETWEEN ?1 AND ?2 AND kind = ?3 ORDER BY k",
            )
            .map_err(sql)?;
        let rows = stmt
            .query_map(params![lo, hi, i64::from(KIND_EDIT)], op_row)
            .map_err(sql)?;
        for row in rows {
            let e = self.op_entry(row.map_err(sql)?)?;
            let body = match e.slot() {
                Some(slot) => applied_body(&slot),
                None => e.op().and_then(|op| op.body().ok()),
            };
            if let Some(Body4::Edit(Edit4 { stamp: Some(s), .. })) = body {
                f(e.id.seq, &s)?;
            }
        }
        let mut stmt = self
            .conn
            .prepare_cached(
                "SELECT k, kind, wall, logical, of_dev, of_seq, flags, stamp, fp FROM op_alias                  WHERE k BETWEEN ?1 AND ?2 AND stamp IS NOT NULL ORDER BY k",
            )
            .map_err(sql)?;
        let rows = stmt.query_map(params![lo, hi], alias_row).map_err(sql)?;
        for row in rows {
            let e = self.alias_entry(row.map_err(sql)?)?;
            if let SlotBody::Alias(Alias { stamp: Some(s), .. }) = &e.body {
                f(e.id.seq, s)?;
            }
        }
        Ok(())
    }

    /// 按 seq 升序走一台设备的日志（从 [from] 起）。[f] 里不要改正在走的这条日志。
    pub fn for_each(
        &self,
        col: i64,
        device: &Id,
        from: u64,
        f: impl FnMut(Entry) -> Result<(), String>,
    ) -> Result<(), String> {
        self.for_range(col, device, from, u64::MAX, f)
    }

    /// 按 seq 升序走一台设备日志里 `[from, to]` 这一段。[f] 里不要改正在走的这条日志。
    pub fn for_range(
        &self,
        col: i64,
        device: &Id,
        from: u64,
        to: u64,
        mut f: impl FnMut(Entry) -> Result<(), String>,
    ) -> Result<(), String> {
        let Some(dev) = self.dev_find(col, device)? else {
            return Ok(());
        };
        let from = from.max(1);
        if to < from {
            return Ok(());
        }
        let lo = opk(dev, from)?;
        let (_, all) = k_range(dev);
        let to = to.min(k_seq(all));
        let hi = opk(dev, to)?;
        // 起点在 [from] 之前、但盖到它的空洞区间也要走到。
        let run_lo = match self.run_at_or_before(dev, from)? {
            Some(run) if from <= run.end() => run.k,
            _ => lo,
        };
        let mut op_stmt = self
            .conn
            .prepare(
                "SELECT k, wall, logical, deps, kind, fmt, flags, body, aux, fp FROM ops WHERE k BETWEEN ?1 AND ?2 ORDER BY k",
            )
            .map_err(sql)?;
        let mut alias_stmt = self
            .conn
            .prepare(
                "SELECT k, kind, wall, logical, of_dev, of_seq, flags, stamp, fp FROM op_alias WHERE k BETWEEN ?1 AND ?2 ORDER BY k",
            )
            .map_err(sql)?;
        let mut void_stmt = self
            .conn
            .prepare(
                "SELECT k, n, flags, fps, chain FROM op_voids WHERE k BETWEEN ?1 AND ?2 ORDER BY k",
            )
            .map_err(sql)?;
        let mut ops = op_stmt.query_map(params![lo, hi], op_row).map_err(sql)?;
        let mut aliases = alias_stmt
            .query_map(params![lo, hi], alias_row)
            .map_err(sql)?;
        let mut voids = void_stmt
            .query_map(params![run_lo, hi], void_row)
            .map_err(sql)?;
        let mut o = ops.next().transpose().map_err(sql)?;
        let mut a = aliases.next().transpose().map_err(sql)?;
        let mut v = voids.next().transpose().map_err(sql)?;
        loop {
            let ko = o.as_ref().map(|r| r.k);
            let ka = a.as_ref().map(|r| r.k);
            let kv = v.as_ref().map(|r| r.k);
            let Some(min) = [ko, ka, kv].into_iter().flatten().min() else {
                return Ok(());
            };
            if ko == Some(min) {
                let row = o.take().expect("peeked row");
                o = ops.next().transpose().map_err(sql)?;
                f(self.op_entry(row)?)?;
            } else if ka == Some(min) {
                let row = a.take().expect("peeked row");
                a = aliases.next().transpose().map_err(sql)?;
                f(self.alias_entry(row)?)?;
            } else {
                let run = v.take().expect("peeked row");
                v = voids.next().transpose().map_err(sql)?;
                for seq in k_seq(run.k).max(from)..=run.end().min(to) {
                    f(self.void_entry(&run, seq)?)?;
                }
            }
        }
    }

    /// 核对一个集合的每条日志都是从 1 起、不重不漏的连续前缀，每个槽自洽。返回条数。
    pub fn audit(&self, col: i64) -> Result<u64, String> {
        let mut total = 0u64;
        for d in self.devices(col)? {
            let mut next = 1u64;
            self.for_each(col, &d.id, 1, |e| {
                if e.id.seq != next {
                    return Err(format!(
                        "gen4 store: {} log has {} where {next} should be",
                        d.id, e.id.seq
                    ));
                }
                if e.fp.is_some() != (d.kind == Some(DEV_HERITAGE)) {
                    return Err(format!(
                        "gen4 store: {}:{next} does not belong in this kind of log",
                        d.id
                    ));
                }
                if let Some(slot) = e.slot() {
                    slot.check()
                        .map_err(|m| format!("gen4 store: {}:{next} {m}", d.id))?;
                }
                next += 1;
                Ok(())
            })?;
            if next - 1 != d.last {
                return Err(format!(
                    "gen4 store: {} log ends at {} but {} was expected",
                    d.id,
                    next - 1,
                    d.last
                ));
            }
            total += d.last;
        }
        Ok(total)
    }

    // ------------------------------------------------------------ 写（内部）

    fn insert_op(
        &self,
        col: i64,
        dev: i64,
        op: &Op4,
        raw3: bool,
        fp: Option<&Fp>,
        tv: u32,
    ) -> Result<(), String> {
        let p = pack::pack_payload(op.kind, op.fmt, &op.payload, raw3, &mut N(self))?;
        let flags = p.flags | if raw3 { F_RAW3 } else { 0 } | tv_bits(tv);
        let deps = self.deps_id(col, &op.deps)?;
        self.conn
            .prepare_cached(
                "INSERT INTO ops (k, wall, logical, deps, kind, fmt, flags, body, aux, fp) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            )
            .map_err(sql)?
            .execute(params![
                opk(dev, op.id.seq)?,
                op.hlc.wall,
                op.hlc.logical,
                deps,
                op.kind,
                op.fmt,
                flags,
                p.body,
                p.aux,
                fp.map(|f| f.to_vec()),
            ])
            .map_err(sql)?;
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    fn insert_alias(
        &self,
        col: i64,
        dev: i64,
        seq: u64,
        a: &Alias,
        fp: &Fp,
        tv: u32,
        local: bool,
    ) -> Result<(), String> {
        let of_dev = self.dev(col, &a.of.device)?;
        let mut flags = tv_bits(tv) | if local { A_LOCAL } else { 0 };
        let stamp = match &a.stamp {
            None => None,
            Some(s) => {
                // 写时核对：内部化后读不回原值的，存线格式的规范字节。
                let packed = pack::pack_stamp(s, &mut N(self))?;
                if pack::unpack_stamp(&packed, &mut N(self)).as_ref() == Ok(s) {
                    Some(packed)
                } else {
                    flags |= A_STAMP_WIRE;
                    Some(s.encode())
                }
            }
        };
        self.conn
            .prepare_cached(
                "INSERT INTO op_alias (k, kind, wall, logical, of_dev, of_seq, flags, stamp, fp) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            )
            .map_err(sql)?
            .execute(params![
                opk(dev, seq)?,
                a.kind,
                a.wall,
                a.logical,
                of_dev,
                a.of.seq as i64,
                flags,
                stamp,
                fp.to_vec(),
            ])
            .map_err(sql)?;
        Ok(())
    }

    /// 写一个空洞区间，并与两侧同样标志的相邻区间合并。
    ///
    /// 原生日志的区间只记区间末的链值；别的设备的原生日志合并时，被合进区间内部的那几处区间末链值（左邻的末尾、本区间的末尾）记成链值
    /// 记号（`log_marks`），不随合并丢掉：清除只拿走内容，链值是公开的、算得出的事实，转发要按作者的切点重切段
    /// （`sync_state.rs` [Truth::recut_from_log]，交接 §33），切点可能正落在一次跨段的清除里面。[Truth::chain_known]
    /// 在空洞内部先查这些记号。承袭日志（`fps`）不记：那里的记号是切承袭段的切点。
    fn insert_void_run(
        &self,
        dev: i64,
        first: u64,
        n: u64,
        fps: Option<Vec<u8>>,
        chain: Option<Chain>,
        flags: i64,
    ) -> Result<(), String> {
        let mut k = opk(dev, first)?;
        let mut len = n;
        let mut fps = fps;
        let mut chain = chain.map(|c| c.to_vec());
        let mergeable = |run: &VoidRun, fps: &Option<Vec<u8>>| {
            run.flags == flags && run.fps.is_some() == fps.is_some()
        };
        // 只给别的设备的原生日志记：本机自己的段由本机按新的切点重签（`cmd/sync.rs`），用不着旧切点的链值；这样只
        // 动本机自己日志的清除（导出 / 导入往返）不多出导出流带不走的记号。
        let foreign = fps.is_none() && !self.is_self_dev(dev)?;
        if first > 1 {
            if let Some(left) = self.run_at_or_before(dev, first - 1)? {
                if left.end() + 1 == first && mergeable(&left, &fps) {
                    if foreign {
                        if let Some(c) = &left.chain {
                            self.put_mark(dev, left.end(), &chain_of(c)?)?;
                        }
                    }
                    self.delete_run(left.k)?;
                    k = left.k;
                    len += left.n;
                    fps = match (left.fps, fps) {
                        (Some(mut l), Some(r)) => {
                            l.extend_from_slice(&r);
                            Some(l)
                        }
                        _ => None,
                    };
                }
            }
        }
        if let Ok(rk) = opk(dev, first + n) {
            let right = self
                .conn
                .prepare_cached("SELECT k, n, flags, fps, chain FROM op_voids WHERE k = ?1")
                .map_err(sql)?
                .query_row([rk], void_row)
                .optional()
                .map_err(sql)?;
            if let Some(right) = right {
                if mergeable(&right, &fps) {
                    if foreign {
                        if let Some(c) = &chain {
                            self.put_mark(dev, first + n - 1, &chain_of(c)?)?;
                        }
                    }
                    self.delete_run(right.k)?;
                    len += right.n;
                    fps = match (fps, right.fps) {
                        (Some(mut l), Some(r)) => {
                            l.extend_from_slice(&r);
                            Some(l)
                        }
                        _ => None,
                    };
                    chain = right.chain;
                }
            }
        }
        self.conn
            .prepare_cached(
                "INSERT INTO op_voids (k, n, flags, fps, chain) VALUES (?1, ?2, ?3, ?4, ?5)",
            )
            .map_err(sql)?
            .execute(params![k, len as i64, flags, fps, chain])
            .map_err(sql)?;
        Ok(())
    }

    /// 设备下标 [dev] 是不是它所在集合的本机当前身份。
    fn is_self_dev(&self, dev: i64) -> Result<bool, String> {
        let row = self.dev_row(dev)?;
        Ok(self
            .self_identity(row.col)?
            .is_some_and(|me| me.device == row.id))
    }

    fn delete_run(&self, k: i64) -> Result<(), String> {
        self.conn
            .prepare_cached("DELETE FROM op_voids WHERE k = ?1")
            .map_err(sql)?
            .execute([k])
            .map_err(sql)?;
        Ok(())
    }

    /// 删掉一个操作号上的操作 / 原样件 / 副本记录行（空洞区间不动）。
    fn delete_at(&self, dev: i64, seq: u64) -> Result<(), String> {
        let k = opk(dev, seq)?;
        for q in [
            "DELETE FROM ops WHERE k = ?1",
            "DELETE FROM op_alias WHERE k = ?1",
        ] {
            self.conn
                .prepare_cached(q)
                .map_err(sql)?
                .execute([k])
                .map_err(sql)?;
        }
        Ok(())
    }

    fn store_slot(
        &self,
        col: i64,
        dev: i64,
        slot: &HeritageSlot,
        tv: u32,
        local: bool,
    ) -> Result<(), String> {
        match &slot.body {
            SlotBody::Op(op) => self.insert_op(col, dev, op, false, Some(&slot.fp), tv),
            SlotBody::Raw3(raw) => {
                let v = raw.to_v3();
                let op = Op4 {
                    id: v.id,
                    hlc: v.hlc,
                    deps: v.deps,
                    kind: v.kind,
                    fmt: v.schema,
                    payload: v.payload,
                };
                self.insert_op(col, dev, &op, true, Some(&slot.fp), tv)
            }
            SlotBody::Alias(a) => self.insert_alias(col, dev, slot.id.seq, a, &slot.fp, tv, local),
            SlotBody::Void => self.insert_void_run(
                dev,
                slot.id.seq,
                1,
                Some(slot.fp.to_vec()),
                None,
                tv_bits(tv) | if local { A_LOCAL } else { 0 },
            ),
        }
    }

    fn has_parked(&self, dev: i64) -> Result<bool, String> {
        if let Some(p) = self.dev_row(dev)?.parked {
            return Ok(p);
        }
        let (lo, hi) = k_range(dev);
        let p: bool = self
            .conn
            .prepare_cached("SELECT EXISTS(SELECT 1 FROM op_pending WHERE k BETWEEN ?1 AND ?2)")
            .map_err(sql)?
            .query_row(params![lo, hi], |r| r.get(0))
            .map_err(sql)?;
        self.with_dev(dev, |d| d.parked = Some(p))?;
        Ok(p)
    }

    /// 一个操作号落进了日志：同号的待投递行，链指纹相同的是确认（删掉），不同的是分叉的一支（挪进 `op_forks`）。
    fn settle_pending(&self, dev: i64, seq: u64, fp: &Fp) -> Result<(), String> {
        if !self.has_parked(dev)? {
            return Ok(());
        }
        let k = opk(dev, seq)?;
        self.conn
            .prepare_cached("DELETE FROM op_pending WHERE k = ?1 AND fp = ?2")
            .map_err(sql)?
            .execute(params![k, fp.to_vec()])
            .map_err(sql)?;
        self.conn
            .prepare_cached(
                "INSERT OR IGNORE INTO op_forks (k, fp, tv, slot) SELECT k, fp, tv, slot FROM op_pending WHERE k = ?1",
            )
            .map_err(sql)?
            .execute([k])
            .map_err(sql)?;
        self.conn
            .prepare_cached("DELETE FROM op_pending WHERE k = ?1")
            .map_err(sql)?
            .execute([k])
            .map_err(sql)?;
        self.with_dev(dev, |d| d.parked = None)
    }

    /// 记成分叉的另一支。与已存的同号同链指纹的那份矛盾 = false，什么都没写。
    fn put_fork(&self, dev: i64, slot: &HeritageSlot, tv: u32) -> Result<bool, String> {
        let k = opk(dev, slot.id.seq)?;
        let have = self
            .conn
            .prepare_cached("SELECT tv, slot FROM op_forks WHERE k = ?1 AND fp = ?2")
            .map_err(sql)?
            .query_row(params![k, slot.fp.to_vec()], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, Vec<u8>>(1)?))
            })
            .optional()
            .map_err(sql)?;
        let have = match have {
            Some((t, bytes)) => Some((slot_of(&bytes)?, t as u32)),
            None => None,
        };
        match merge_parked(have, slot, tv) {
            Merged::Keep => Ok(true),
            Merged::Conflict => Ok(false),
            Merged::Store(s, t) => {
                self.conn
                    .prepare_cached(
                        "INSERT OR REPLACE INTO op_forks (k, fp, tv, slot) VALUES (?1, ?2, ?3, ?4)",
                    )
                    .map_err(sql)?
                    .execute(params![k, s.fp.to_vec(), t, s.encode()])
                    .map_err(sql)?;
                Ok(true)
            }
        }
    }

    /// 一个操作号上见过的所有链指纹里，字节序最小的那个槽在日志里（文件头）：`op_forks` 里有比日志里那条更小的，
    /// 就对调。返回对调了没有。
    fn rebalance(&self, col: i64, dev: i64, seq: u64) -> Result<bool, String> {
        let k = opk(dev, seq)?;
        let least: Option<(Vec<u8>, i64, Vec<u8>)> = self
            .conn
            .prepare_cached("SELECT fp, tv, slot FROM op_forks WHERE k = ?1 ORDER BY fp LIMIT 1")
            .map_err(sql)?
            .query_row([k], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .optional()
            .map_err(sql)?;
        let Some((fp, tv, bytes)) = least else {
            return Ok(false);
        };
        let have = self
            .entry_at(dev, seq)?
            .ok_or_else(|| format!("gen4 store: no log entry under a fork at {seq}"))?;
        let have_slot = have
            .slot()
            .ok_or("gen4 store: heritage log holds a native entry")?;
        if fp.as_slice() >= have_slot.fp.as_slice() {
            return Ok(false);
        }
        let winner = slot_of(&bytes)?;
        match have.body {
            SlotBody::Void => self.remove_void_at(dev, seq)?,
            _ => self.delete_at(dev, seq)?,
        }
        self.conn
            .prepare_cached("DELETE FROM op_forks WHERE k = ?1 AND fp = ?2")
            .map_err(sql)?
            .execute(params![k, fp])
            .map_err(sql)?;
        self.conn
            .prepare_cached("INSERT INTO op_forks (k, fp, tv, slot) VALUES (?1, ?2, ?3, ?4)")
            .map_err(sql)?
            .execute(params![
                k,
                have_slot.fp.to_vec(),
                have.tv,
                have_slot.encode()
            ])
            .map_err(sql)?;
        // 这个 seq 上记着的完整链值是被换出去的那一支的。
        self.conn
            .prepare_cached("DELETE FROM log_marks WHERE dev = ?1 AND seq = ?2")
            .map_err(sql)?
            .execute(params![dev, seq as i64])
            .map_err(sql)?;
        self.store_slot(col, dev, &winner, tv as u32, false)?;
        Ok(true)
    }

    /// 把一个空洞区间里的 [seq] 这一格拿掉（两边剩下的各成一段）。只有承袭日志的空洞（逐格带链指纹）用得到。
    fn remove_void_at(&self, dev: i64, seq: u64) -> Result<(), String> {
        let run = self
            .run_at_or_before(dev, seq)?
            .filter(|r| r.end() >= seq)
            .ok_or_else(|| format!("gen4 store: no void run covers {seq}"))?;
        let fps = run
            .fps
            .as_ref()
            .ok_or("gen4 store: a native void run cannot be split")?;
        let first = k_seq(run.k);
        let cut = ((seq - first) * 8) as usize;
        if fps.len() as u64 != run.n * 8 {
            return Err("gen4 store: void run has too few fingerprints".to_owned());
        }
        self.delete_run(run.k)?;
        if seq > first {
            self.insert_void_run(
                dev,
                first,
                seq - first,
                Some(fps[..cut].to_vec()),
                None,
                run.flags,
            )?;
        }
        if run.end() > seq {
            self.insert_void_run(
                dev,
                seq + 1,
                run.end() - seq,
                Some(fps[cut + 8..].to_vec()),
                None,
                run.flags,
            )?;
        }
        Ok(())
    }

    fn heritage_dev(
        &self,
        col: i64,
        src: &Id,
        slot: &HeritageSlot,
        tv: u32,
    ) -> Result<i64, String> {
        slot.check()
            .map_err(|m| format!("gen4 store: slot {}:{} {m}", slot.id.device, slot.id.seq))?;
        if tv == 0 {
            return Err("gen4 store: translator version 0".to_owned());
        }
        let dev = self.dev(col, &slot.id.device)?;
        self.claim(dev, DEV_HERITAGE, Some(src))?;
        Ok(dev)
    }

    fn put_applied(&self, col: i64, dev: i64, slot: &HeritageSlot, tv: u32) -> Result<Put, String> {
        let last = self.last(dev)?;
        let seq = slot.id.seq;
        if seq > last + 1 {
            return Err(format!(
                "gen4 store: slot {}:{seq} leaves a gap after {last}",
                slot.id.device
            ));
        }
        if seq == last + 1 {
            self.store_slot(col, dev, slot, tv, false)?;
            self.with_dev(dev, |d| d.last = Some(seq))?;
            self.settle_pending(dev, seq, &slot.fp)?;
            return Ok(if self.rebalance(col, dev, seq)? {
                Put::Yielded
            } else {
                Put::Inserted
            });
        }
        let have = self
            .entry_at(dev, seq)?
            .ok_or_else(|| format!("gen4 store: {} log has a hole at {seq}", slot.id.device))?;
        let have_slot = have
            .slot()
            .ok_or("gen4 store: heritage log holds a native entry")?;
        match join_slots(&have_slot, slot) {
            Joined::Fork => {
                if !self.put_fork(dev, slot, tv)? {
                    return Ok(Put::Conflict);
                }
                Ok(if self.rebalance(col, dev, seq)? {
                    Put::Replaced
                } else {
                    Put::Fork
                })
            }
            Joined::One(_) if have_slot == *slot => {
                if tv > have.tv {
                    self.relabel(dev, seq, tv)?;
                }
                Ok(Put::Same)
            }
            // 秩不同：本机的槽只由本机自己推进。
            Joined::One(_) => Ok(Put::Kept),
            Joined::Conflict if tv > have.tv => {
                self.delete_at(dev, seq)?;
                self.store_slot(col, dev, slot, tv, have.local)?;
                Ok(Put::Replaced)
            }
            Joined::Conflict if tv < have.tv => Ok(Put::Kept),
            Joined::Conflict => Ok(Put::Conflict),
        }
    }

    /// 逐字节相同的槽由更高的 T 版本又转出了一遍：把标签抬上去（空洞没有内容，不抬）。
    fn relabel(&self, dev: i64, seq: u64, tv: u32) -> Result<(), String> {
        let k = opk(dev, seq)?;
        for q in [
            "UPDATE ops SET flags = (flags & 15) | ?2 WHERE k = ?1",
            "UPDATE op_alias SET flags = (flags & 15) | ?2 WHERE k = ?1",
        ] {
            self.conn
                .prepare_cached(q)
                .map_err(sql)?
                .execute(params![k, tv_bits(tv)])
                .map_err(sql)?;
        }
        Ok(())
    }

    // ------------------------------------------------------------ 写：承袭日志

    /// 收一个承袭槽（规则见文件头）。[src] = 这条旧日志的来源集合，[tv] = 转出它的 T 版本。
    pub fn put_heritage(
        &self,
        col: i64,
        src: &Id,
        slot: &HeritageSlot,
        tv: u32,
    ) -> Result<Put, String> {
        self.write(|| {
            let dev = self.heritage_dev(col, src, slot, tv)?;
            self.put_applied(col, dev, slot, tv)
        })
    }

    /// 收一个前面还缺的槽。已经在日志范围里的操作号按 [Truth::put_heritage] 的规则处理。
    pub fn put_pending(
        &self,
        col: i64,
        src: &Id,
        slot: &HeritageSlot,
        tv: u32,
        prev_fp: Option<Fp>,
    ) -> Result<Put, String> {
        self.write(|| {
            let dev = self.heritage_dev(col, src, slot, tv)?;
            if slot.id.seq <= self.last(dev)? {
                return self.put_applied(col, dev, slot, tv);
            }
            let k = opk(dev, slot.id.seq)?;
            let have = self
                .conn
                .prepare_cached("SELECT tv, slot, prev_fp FROM op_pending WHERE k = ?1 AND fp = ?2")
                .map_err(sql)?
                .query_row(params![k, slot.fp.to_vec()], |r| {
                    Ok((
                        r.get::<_, i64>(0)?,
                        r.get::<_, Vec<u8>>(1)?,
                        r.get::<_, Option<Vec<u8>>>(2)?,
                    ))
                })
                .optional()
                .map_err(sql)?;
            let (have, have_prev) = match have {
                Some((t, bytes, prev)) => (Some((slot_of(&bytes)?, t as u32)), prev),
                None => (None, None),
            };
            let have_prev = have_prev.as_deref().map(fp_of).transpose()?;
            if let (Some(a), Some(b)) = (have_prev, prev_fp) {
                if a != b {
                    // 说它接在两个不同的槽后面：矛盾，不落。
                    return Ok(Put::Conflict);
                }
            }
            let prev = prev_fp.or(have_prev);
            let merged = match merge_parked(have, slot, tv) {
                Merged::Conflict => return Ok(Put::Conflict),
                Merged::Keep => None,
                Merged::Store(s, t) => Some((s, t)),
            };
            if merged.is_some() || prev != have_prev {
                let (s, t) = match merged {
                    Some(m) => m,
                    None => {
                        // 槽没变，只是补上了前一环的链指纹。
                        self.conn
                            .prepare_cached("UPDATE op_pending SET prev_fp = ?3 WHERE k = ?1 AND fp = ?2")
                            .map_err(sql)?
                            .execute(params![k, slot.fp.to_vec(), prev.map(|f| f.to_vec())])
                            .map_err(sql)?;
                        return Ok(Put::Pending);
                    }
                };
                self.conn
                    .prepare_cached(
                        "INSERT OR REPLACE INTO op_pending (k, fp, prev_fp, tv, slot) VALUES (?1, ?2, ?3, ?4, ?5)",
                    )
                    .map_err(sql)?
                    .execute(params![
                        k,
                        s.fp.to_vec(),
                        prev.map(|f| f.to_vec()),
                        t,
                        s.encode()
                    ])
                    .map_err(sql)?;
                self.with_dev(dev, |d| d.parked = Some(true))?;
            }
            Ok(Put::Pending)
        })
    }

    /// 正好接在这台设备日志末尾、且验得出「前一环就是本机末尾那个槽」的待投递槽。交给调用方（同步轮）判断因果上
    /// 该不该投；投 = 再调 [Truth::put_heritage]。
    pub fn pending_ready(&self, col: i64, device: &Id) -> Result<Option<Parked>, String> {
        let Some(dev) = self.dev_find(col, device)? else {
            return Ok(None);
        };
        if !self.has_parked(dev)? {
            return Ok(None);
        }
        let last = self.last(dev)?;
        let tail_fp = if last == 0 {
            fingerprint(&CHAIN_ZERO)
        } else {
            self.entry_at(dev, last)?
                .and_then(|e| e.fp)
                .ok_or("gen4 store: heritage log tail has no fingerprint")?
        };
        let rows: Vec<(i64, Vec<u8>)> = {
            let mut stmt = self
                .conn
                .prepare_cached(
                    "SELECT tv, slot FROM op_pending WHERE k = ?1 AND prev_fp = ?2 ORDER BY fp",
                )
                .map_err(sql)?;
            let rows = stmt
                .query_map(params![opk(dev, last + 1)?, tail_fp.to_vec()], |r| {
                    Ok((r.get(0)?, r.get(1)?))
                })
                .map_err(sql)?;
            rows.collect::<rusqlite::Result<_>>().map_err(sql)?
        };
        match rows.as_slice() {
            [] => Ok(None),
            [(tv, bytes)] => Ok(Some(Parked {
                slot: slot_of(bytes)?,
                tv: *tv as u32,
                prev_fp: Some(tail_fp),
            })),
            // 两条不同的操作都声称接在同一个槽后面：那台旧设备从这里分叉了，哪一支都不自己投。
            _ => Ok(None),
        }
    }

    fn parked(&self, col: i64, table: &str, prev: &str) -> Result<Vec<Parked>, String> {
        let rows: Vec<(i64, Vec<u8>, Option<Vec<u8>>)> = {
            let mut stmt = self
                .conn
                .prepare_cached(&format!(
                    "SELECT p.tv, p.slot, {prev} FROM {table} p JOIN devs d ON d.dev = p.k >> 40 \
                     WHERE d.col = ?1 ORDER BY p.k, p.fp"
                ))
                .map_err(sql)?;
            let rows = stmt
                .query_map([col], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
                .map_err(sql)?;
            rows.collect::<rusqlite::Result<_>>().map_err(sql)?
        };
        rows.into_iter()
            .map(|(tv, bytes, prev)| {
                Ok(Parked {
                    slot: slot_of(&bytes)?,
                    tv: tv as u32,
                    prev_fp: prev.as_deref().map(fp_of).transpose()?,
                })
            })
            .collect()
    }

    /// 待投递的槽（按操作号、链指纹升序）。
    pub fn pending(&self, col: i64) -> Result<Vec<Parked>, String> {
        self.parked(col, "op_pending", "p.prev_fp")
    }

    /// 待投递的槽数：按设备主键区间数（[PENDING_COUNT_SQL]），不读、不解槽。收段每片收尾都报它，不能每片把整张
    /// `op_pending` 解一遍。
    pub fn pending_count(&self, col: i64) -> Result<u64, String> {
        let mut n = 0u64;
        for d in self.devices(col)? {
            let (lo, hi) = k_range(d.dev);
            let c: i64 = self
                .conn
                .prepare_cached(PENDING_COUNT_SQL)
                .map_err(sql)?
                .query_row(params![lo, hi], |r| r.get(0))
                .map_err(sql)?;
            n += c as u64;
        }
        Ok(n)
    }

    /// 分叉的另一支（链指纹与本机日志里同号的槽不同的槽）。
    pub fn forks(&self, col: i64) -> Result<Vec<Parked>, String> {
        self.parked(col, "op_forks", "NULL")
    }

    /// 承袭日志某处的完整原链值（承袭段头要首尾两处的）。必须与那个槽的链指纹相符。
    pub fn set_mark(&self, col: i64, device: &Id, seq: u64, chain: &Chain) -> Result<(), String> {
        self.write(|| {
            let dev = self
                .dev_find(col, device)?
                .ok_or_else(|| format!("gen4 store: no device {device}"))?;
            if self.dev_row(dev)?.kind != Some(DEV_HERITAGE) {
                return Err(format!("gen4 store: {device} has no heritage log"));
            }
            let fp = match self.entry(
                col,
                &OpId {
                    device: *device,
                    seq,
                },
            )? {
                Some(e) => e.fp,
                None => None,
            };
            if fp != Some(fingerprint(chain)) {
                return Err(format!(
                    "gen4 store: chain value for {device}:{seq} does not match its slot"
                ));
            }
            self.put_mark(dev, seq, chain)
        })
    }

    fn put_mark(&self, dev: i64, seq: u64, chain: &Chain) -> Result<(), String> {
        self.conn
            .prepare_cached(
                "INSERT OR REPLACE INTO log_marks (dev, seq, chain) VALUES (?1, ?2, ?3)",
            )
            .map_err(sql)?
            .execute(params![dev, seq as i64, chain.to_vec()])
            .map_err(sql)?;
        Ok(())
    }

    /// 一条日志上记着的链值（seq 升序）。
    pub fn marks(&self, col: i64, device: &Id) -> Result<Vec<(u64, Chain)>, String> {
        let Some(dev) = self.dev_find(col, device)? else {
            return Ok(Vec::new());
        };
        let rows: Vec<(i64, Vec<u8>)> = {
            let mut stmt = self
                .conn
                .prepare_cached("SELECT seq, chain FROM log_marks WHERE dev = ?1 ORDER BY seq")
                .map_err(sql)?;
            let rows = stmt
                .query_map([dev], |r| Ok((r.get(0)?, r.get(1)?)))
                .map_err(sql)?;
            rows.collect::<rusqlite::Result<_>>().map_err(sql)?
        };
        rows.into_iter()
            .map(|(seq, chain)| Ok((seq as u64, chain_of(&chain)?)))
            .collect()
    }

    // ------------------------------------------------------------ 写：本机推进槽

    /// 本机执行了一条 Purge、目标是 [target]：完整内容 → 空洞（`gen4::translate::purge_slot` 的落库版；原生日志的
    /// 操作同理，空洞记下该处的链值）。已经是空洞 / 副本记录、或本机没有这个操作号的不动。返回有没有变。
    ///
    /// 执行不执行一条 Purge 由调用方按本机的信任状态决定（设计 §3.2）；这里只管落库。
    ///
    /// **带盐的操作（Salts、Join）永远不清成空洞**（设计 §10 第 17 条）：空洞不带操作体，一台设备把它清掉，之后才
    /// 收到这一段的设备就少了这几个盐、别名表从此与别人不同。它们不属于任何实体，Purge 本来指不到；走到这里是调用方
    /// 的错，报错（整个事务回滚），不静默跳过。只有原生日志有这两种操作（承袭段拒收），副本记录（[Truth::advance_dedup]）
    /// 因此也碰不到它们。
    pub fn advance_purge(&self, col: i64, target: &OpId) -> Result<bool, String> {
        self.write(|| {
            let Some(dev) = self.dev_find(col, &target.device)? else {
                return Ok(false);
            };
            let Some(e) = self.entry(col, target)? else {
                return Ok(false);
            };
            if !e.is_whole() {
                return Ok(false);
            }
            if let Some(op) = e.op() {
                if op.kind == KIND_SALTS || op.kind == KIND_JOIN {
                    return Err(format!(
                        "gen4 store: {}:{} carries salts and is never purged",
                        target.device, target.seq
                    ));
                }
            }
            match e.fp {
                Some(fp) => {
                    self.delete_at(dev, target.seq)?;
                    self.insert_void_run(
                        dev,
                        target.seq,
                        1,
                        Some(fp.to_vec()),
                        None,
                        tv_bits(e.tv) | A_LOCAL,
                    )?;
                }
                None => {
                    // 别的设备的操作：挖空之前记下剔除记录（作者签名覆盖的那部分 + 清掉它的 Purge），本机以后转发这一段
                    // 时重切要它（`sync_state.rs` `recut_from_log`，`gen4/recut.rs`）。找不到管得到它的生效 Purge（直接
                    // 调本函数的测试与工具）就不记：这一段本机重切不出来，转发退回「缺」。
                    if let Some(op) = e.op() {
                        if !self.is_self_dev(dev)? {
                            if let Some(p) = self.purge_covering(col, op)? {
                                self.put_stub(col, &Stub::of(op, p))?;
                            }
                        }
                    }
                    let chain = self.chain_at_dev(dev, target.seq)?;
                    self.delete_at(dev, target.seq)?;
                    self.insert_void_run(dev, target.seq, 1, None, Some(chain), A_LOCAL)?;
                }
            }
            // 转发（`cmd/sync_relay.rs`，G8-7b）手里这条内容的副本：本机缓存的作者段换成本机签的重切件、已转发到各位置
            // 的件改成待删（由重切件同名重写或删掉；`sync_state.rs` [Truth::relay_purged]），同一个事务。
            self.relay_purged(col, &target.device, target.seq)?;
            // 字节层：原文还在空闲空间与 WAL 旧帧里，提交之后要收尾（`scrub.rs`）。同一个事务里记下欠着的收尾。
            super::scrub::mark_due(self.conn)?;
            self.voided.set(true);
            Ok(true)
        })
    }

    /// 本机生效的、管得到 [op] 的 Purge（操作号最小的那条）：目标在 [op] 的清除目标里（`gen4/op.rs`
    /// `purge_targets_v1`）、[op] 的作者写它时没见过、本机执行它（`purge_ix.state = 1`：落库了、作者受信）。派生层
    /// 判「已清除」用的是同一组条件（`weigh.rs`「彻底清除」），所以本机执行清除时（`Index::execute_purges` 之后）总找得到。
    fn purge_covering(&self, col: i64, op: &Op4) -> Result<Option<OpId>, String> {
        let mut best: Option<OpId> = None;
        for (kind, key) in purge_targets_v1(op) {
            let ks: Vec<i64> = {
                let mut stmt = self
                    .conn
                    .prepare_cached(
                        "SELECT k FROM purge_ix WHERE col = ?1 AND ekind = ?2 AND ent = ?3 AND state = 1",
                    )
                    .map_err(sql)?;
                let rows = stmt
                    .query_map(params![col, kind as i64, Ref::of(&key)], |r| r.get(0))
                    .map_err(sql)?;
                rows.collect::<rusqlite::Result<_>>().map_err(sql)?
            };
            for k in ks {
                let p = self.id_of_key(k)?;
                if purge_unseen_by(op, &p) && best.is_none_or(|b| p < b) {
                    best = Some(p);
                }
            }
        }
        Ok(best)
    }

    /// 本机执行了一条 Dedup、其中一对说 [target] 是 [of] 的副本：完整内容 → 副本记录（`gen4::translate::dedup_slot`
    /// 的落库版）。已经是空洞 / 副本记录、或本机没有这个操作号的不动。返回有没有变。只有承袭日志有副本。
    pub fn advance_dedup(&self, col: i64, target: &OpId, of: &OpId) -> Result<bool, String> {
        self.write(|| {
            let Some(dev) = self.dev_find(col, &target.device)? else {
                return Ok(false);
            };
            let Some(e) = self.entry(col, target)? else {
                return Ok(false);
            };
            if !e.is_whole() {
                return Ok(false);
            }
            let slot = e.slot().ok_or_else(|| {
                format!(
                    "gen4 store: {}:{} is a native op; only heritage ops have duplicates",
                    target.device, target.seq
                )
            })?;
            let next = dedup_slot(&slot, *of).map_err(|m| {
                format!("gen4 store: dedup of {}:{}: {m}", target.device, target.seq)
            })?;
            let SlotBody::Alias(a) = &next.body else {
                return Err("gen4 store: dedup did not produce a duplicate record".to_owned());
            };
            self.delete_at(dev, target.seq)?;
            self.insert_alias(col, dev, target.seq, a, &slot.fp, e.tv, true)?;
            Ok(true)
        })
    }

    // ------------------------------------------------------------ 写：原生日志

    fn set_tail(&self, dev: i64, seq: u64, chain: &Chain) -> Result<(), String> {
        self.conn
            .prepare_cached("UPDATE devs SET tail = ?2 WHERE dev = ?1")
            .map_err(sql)?
            .execute(params![dev, chain.to_vec()])
            .map_err(sql)?;
        self.with_dev(dev, |d| {
            d.tail = Some(*chain);
            d.last = Some(seq);
        })
    }

    /// 往一台设备的原生日志末尾追加一条操作（本机自己写的、或从原生段里收的）。返回该处的链值——收段的一侧拿它与
    /// 段里声明的链值比。
    pub fn append_native(&self, col: i64, op: &Op4) -> Result<Chain, String> {
        self.write(|| {
            // 太大的一条先给看得懂的报错（本机写入与导入都经这里；整笔回滚，什么都不落）。
            payload_within_cap(op).map_err(|m| format!("gen4 store: {m}; nothing was saved"))?;
            native_allowed(op)
                .map_err(|m| format!("gen4 store: {}:{} {m}", op.id.device, op.id.seq))?;
            if op.hlc.device != op.id.device || op.deps.get(&op.id.device) != 0 {
                return Err(format!(
                    "gen4 store: {}:{} envelope names the wrong device",
                    op.id.device, op.id.seq
                ));
            }
            let dev = self.dev(col, &op.id.device)?;
            self.claim(dev, DEV_NATIVE, None)?;
            let last = self.last(dev)?;
            if op.id.seq != last + 1 {
                return Err(format!(
                    "gen4 store: native op {}:{} does not follow {last}",
                    op.id.device, op.id.seq
                ));
            }
            let tail = self.dev_row(dev)?.tail.unwrap_or(CHAIN_ZERO);
            let chain = chain_next4(&tail, op);
            self.insert_op(col, dev, op, false, None, 1)?;
            self.set_tail(dev, op.id.seq, &chain)?;
            if op.id.seq % MARK_EVERY == 0 {
                self.put_mark(dev, op.id.seq, &chain)?;
            }
            Ok(chain)
        })
    }

    /// 往一台设备的原生日志末尾追加一段空洞（原生段里作者签出的空洞：条数 + 区间末的链值，附录 B 第 9 条）。
    pub fn append_native_void(
        &self,
        col: i64,
        device: &Id,
        n: u64,
        chain_after: &Chain,
    ) -> Result<(), String> {
        self.write(|| {
            if n == 0 {
                return Err("gen4 store: empty void run".to_owned());
            }
            let dev = self.dev(col, device)?;
            self.claim(dev, DEV_NATIVE, None)?;
            let last = self.last(dev)?;
            self.insert_void_run(dev, last + 1, n, None, Some(*chain_after), 0)?;
            self.set_tail(dev, last + n, chain_after)
        })
    }

    /// 原生日志空洞区间内部的一个链值记号（`.fushisrs` 流第 2 版导入，第五波；导出流见 `store/gen4/export.rs`）：[seq]
    /// 必须落在 [device] 原生日志里一个空洞区间的内部（不是区间末，那里的链值就是区间自己的），已有记号的不重记，返回
    /// 记没记。本机自己的日志不记（同 [Truth::insert_void_run]：本机的段按新切点重签，用不着旧切点的链值）。
    ///
    /// 记号与区间末的链值一样只能信来源（清除之后没有内容可以重算它），信任面与空洞的 `chain_after` 相同。
    pub fn land_void_mark(
        &self,
        col: i64,
        device: &Id,
        seq: u64,
        chain: &Chain,
    ) -> Result<bool, String> {
        self.write(|| {
            let dev = self
                .dev_find(col, device)?
                .ok_or_else(|| format!("gen4 store: no device {device}"))?;
            if self.dev_row(dev)?.kind != Some(DEV_NATIVE) {
                return Err(format!("gen4 store: {device} has no native log"));
            }
            let inside = self
                .run_at_or_before(dev, seq)?
                .is_some_and(|r| r.fps.is_none() && k_seq(r.k) <= seq && r.end() > seq);
            if !inside {
                return Err(format!(
                    "gen4 store: {device}:{seq} is not inside a void run of the native log"
                ));
            }
            if self.is_self_dev(dev)? || self.mark_at(dev, seq)?.is_some() {
                return Ok(false);
            }
            self.put_mark(dev, seq, chain)?;
            Ok(true)
        })
    }

    /// 原生日志在 [seq] 处的链值（0 = 链的起点）。空洞区间里只有区间末有链值。
    pub fn chain_at(&self, col: i64, device: &Id, seq: u64) -> Result<Chain, String> {
        if seq == 0 {
            return Ok(CHAIN_ZERO);
        }
        let dev = self
            .dev_find(col, device)?
            .ok_or_else(|| format!("gen4 store: no device {device}"))?;
        self.chain_at_dev(dev, seq)
    }

    /// 链值记号正好记在 [seq] 上的那个。
    fn mark_at(&self, dev: i64, seq: u64) -> Result<Option<Chain>, String> {
        self.conn
            .prepare_cached("SELECT chain FROM log_marks WHERE dev = ?1 AND seq = ?2")
            .map_err(sql)?
            .query_row(params![dev, seq as i64], |r| r.get::<_, Vec<u8>>(0))
            .optional()
            .map_err(sql)?
            .map(|c| chain_of(&c))
            .transpose()
    }

    /// 原生日志在 [seq] 处可比的链值：[seq] 落在本机空洞区间内部（不是区间末）、又没有合并时留下的记号 = None，那里
    /// 没有链值；其余同
    /// [Truth::chain_at]（不在日志里、不是原生日志等照样报错，不当成「比不了」）。
    pub fn chain_known(&self, col: i64, device: &Id, seq: u64) -> Result<Option<Chain>, String> {
        if seq == 0 {
            return Ok(Some(CHAIN_ZERO));
        }
        let dev = self
            .dev_find(col, device)?
            .ok_or_else(|| format!("gen4 store: no device {device}"))?;
        if self.dev_row(dev)?.kind == Some(DEV_NATIVE) && seq <= self.last(dev)? {
            if let Some(run) = self.run_at_or_before(dev, seq)? {
                if run.end() > seq {
                    // 空洞内部：合并区间时记下的区间末链值（[Truth::insert_void_run]）还在就有。
                    return self.mark_at(dev, seq);
                }
            }
        }
        self.chain_at_dev(dev, seq).map(Some)
    }

    fn chain_at_dev(&self, dev: i64, seq: u64) -> Result<Chain, String> {
        let row = self.dev_row(dev)?;
        if row.kind != Some(DEV_NATIVE) {
            return Err(format!("gen4 store: {} has no native log", row.id));
        }
        let last = self.last(dev)?;
        if seq == 0 || seq > last {
            return Err(format!("gen4 store: {} log has no entry {seq}", row.id));
        }
        if seq == last {
            if let Some(t) = row.tail {
                return Ok(t);
            }
        }
        let mark = self
            .conn
            .prepare_cached("SELECT seq, chain FROM log_marks WHERE dev = ?1 AND seq <= ?2 ORDER BY seq DESC LIMIT 1")
            .map_err(sql)?
            .query_row(params![dev, seq as i64], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, Vec<u8>>(1)?))
            })
            .optional()
            .map_err(sql)?;
        let (mut at, mut chain) = match mark {
            Some((s, c)) => (s as u64, chain_of(&c)?),
            None => (0, CHAIN_ZERO),
        };
        if let Some(run) = self.run_at_or_before(dev, seq)? {
            if run.end() > seq {
                return Err(format!(
                    "gen4 store: {}:{seq} is inside a void run; only its end has a chain value",
                    row.id
                ));
            }
            if run.end() > at {
                at = run.end();
                chain = chain_of(run.chain.as_deref().ok_or_else(|| {
                    "gen4 store: native void run without its chain value".to_owned()
                })?)?;
            }
        }
        for s in at + 1..=seq {
            let e = self
                .entry_at(dev, s)?
                .ok_or_else(|| format!("gen4 store: {} log has a hole at {s}", row.id))?;
            let op = e
                .op()
                .ok_or("gen4 store: native log holds something that is not an op")?;
            chain = chain_next4(&chain, op);
        }
        Ok(chain)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use proptest::prelude::*;

    use super::*;
    use crate::gen4::heritage::tests::slots;
    use crate::gen4::op::tests::{id, native_edit, op_of};
    use crate::gen4::op::{Body4, Edit4};
    use crate::gen4::translate::tests::arb_op3;
    use crate::gen4::translate::{purge_slot, translate};
    use crate::store::gen4::schema::open_in_memory;

    /// [slots] 用的旧设备。
    const OLD: u8 = 0x0d;
    const P: &str = "0193a1b2-0000-7000-8000-00000000beef";

    fn src() -> Id {
        id(0x5c)
    }

    fn oid(seq: u64) -> OpId {
        OpId {
            device: id(OLD),
            seq,
        }
    }

    pub(crate) fn bound(t: &Truth<'_>) -> i64 {
        t.tx(|t| t.bind(P, &id(0xc0), "dir")).unwrap()
    }

    fn put(t: &Truth<'_>, col: i64, slot: &HeritageSlot, tv: u32) -> Result<Put, String> {
        t.tx(|t| t.put_heritage(col, &src(), slot, tv))
    }

    fn all(t: &Truth<'_>, col: i64, device: &Id) -> Vec<Entry> {
        let mut out = Vec::new();
        t.for_each(col, device, 1, |e| {
            out.push(e);
            Ok(())
        })
        .unwrap();
        out
    }

    fn count(conn: &Connection, table: &str) -> i64 {
        conn.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
            .unwrap()
    }

    /// 同一个操作号、同一个链指纹、内容不同的另一条修改。
    fn other_edit(slot: &HeritageSlot, value: &str) -> HeritageSlot {
        let body = Body4::Edit(Edit4 {
            value: value.to_owned(),
            ..native_edit()
        });
        HeritageSlot::op(slot.fp, op_of(slot.id.device, slot.id.seq, &body))
    }

    #[test]
    fn every_kind_of_slot_reads_back_byte_for_byte() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let want = slots();
        for s in &want {
            assert_eq!(put(&t, col, s, 1), Ok(Put::Inserted));
        }
        // 另开一个会话读：不靠写入时的缓存。
        let t = Truth::new(&conn);
        let got = all(&t, col, &id(OLD));
        assert_eq!(got.len(), want.len());
        for (e, s) in got.iter().zip(&want) {
            assert_eq!(e.slot().unwrap().encode(), s.encode());
            assert_eq!((e.tv, e.local), (1, false));
            assert_eq!(t.entry(col, &s.id).unwrap().as_ref(), Some(e));
        }
        assert_eq!(t.audit(col).unwrap(), want.len() as u64);
        assert_eq!(t.last_of(col, &id(OLD)).unwrap(), 8);
        // 两个相邻的空洞存成一个区间；副本记录点名的设备登记了下标但没有日志。
        assert_eq!(
            (
                count(&conn, "ops"),
                count(&conn, "op_alias"),
                count(&conn, "op_voids")
            ),
            (4, 2, 1)
        );
        let devs = t.devices(col).unwrap();
        let old = devs.iter().find(|d| d.id == id(OLD)).unwrap();
        assert_eq!(
            (old.kind, old.src, old.last),
            (Some(DEV_HERITAGE), Some(src()), 8)
        );
        let named = devs.iter().find(|d| d.id == id(0xee)).unwrap();
        assert_eq!((named.kind, named.last), (None, 0));
        assert_eq!(t.applied(col).unwrap().0.len(), 1);
        // 从中间读起，包括从空洞区间的中间读起。
        for from in 1..=8u64 {
            let mut seqs = Vec::new();
            t.for_each(col, &id(OLD), from, |e| {
                seqs.push(e.id.seq);
                Ok(())
            })
            .unwrap();
            assert_eq!(seqs, (from..=8).collect::<Vec<_>>());
        }
        // 重放一遍是幂等的。
        for s in &want {
            assert_eq!(put(&t, col, s, 1), Ok(Put::Same));
        }
        assert_eq!(all(&t, col, &id(OLD)), got);
    }

    #[test]
    fn a_gap_is_refused_and_a_log_keeps_its_kind_and_source() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let s = slots();
        assert!(put(&t, col, &s[1], 1).unwrap_err().contains("leaves a gap"));
        assert_eq!(put(&t, col, &s[0], 1), Ok(Put::Inserted));
        assert!(put(&t, col, &s[2], 1).unwrap_err().contains("leaves a gap"));
        // 出错的那一笔整个回滚，会话还能用。
        assert_eq!(put(&t, col, &s[1], 1), Ok(Put::Inserted));
        // 同一台旧设备不能又属于另一个来源集合，也不能又有原生日志。
        let e = t
            .tx(|t| t.put_heritage(col, &id(0x5d), &s[2], 1))
            .unwrap_err();
        assert!(e.contains("another source collection"), "{e}");
        let native = op_of(id(OLD), 3, &Body4::Edit(native_edit()));
        let e = t.tx(|t| t.append_native(col, &native)).unwrap_err();
        assert!(e.contains("already has a heritage log"), "{e}");
        assert_eq!(t.last_of(col, &id(OLD)).unwrap(), 2);
        // 事务之外不许写。
        let e = t.put_heritage(col, &src(), &s[2], 1).unwrap_err();
        assert!(e.contains("outside a transaction"), "{e}");
    }

    #[test]
    fn a_received_void_or_duplicate_record_never_changes_a_whole_local_slot() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let s = slots();
        for x in &s {
            put(&t, col, x, 1).unwrap();
        }
        let before = all(&t, col, &id(OLD));
        // 本机完整，来的是空洞 / 副本记录：本机不动。
        let void = purge_slot(&s[0]);
        let dup = dedup_slot(
            &s[0],
            OpId {
                device: id(0xee),
                seq: 9,
            },
        )
        .unwrap();
        assert_eq!(put(&t, col, &void, 1), Ok(Put::Kept));
        assert_eq!(put(&t, col, &dup, 1), Ok(Put::Kept));
        // 本机是空洞（seq 6），来的是完整内容 / 副本记录：本机不动（内容已经没了；副本记录要本机自己应用 Dedup 才有）。
        let whole = other_edit(&s[5], "\"back\"");
        assert_eq!(put(&t, col, &whole, 1), Ok(Put::Kept));
        let dup6 = dedup_slot(
            &whole,
            OpId {
                device: id(0xee),
                seq: 9,
            },
        )
        .unwrap();
        assert_eq!(put(&t, col, &dup6, 1), Ok(Put::Kept));
        // 本机是副本记录（seq 4），来的是空洞：本机不动。
        assert_eq!(
            put(&t, col, &HeritageSlot::void(s[3].id, s[3].fp), 1),
            Ok(Put::Kept)
        );
        assert_eq!(all(&t, col, &id(OLD)), before);
        assert_eq!(count(&conn, "op_forks"), 0);
    }

    #[test]
    fn same_rank_and_different_bytes_is_settled_by_the_translator_version() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let s = slots();
        for x in &s {
            put(&t, col, x, 2).unwrap();
        }
        let other = other_edit(&s[0], "\"other\"");
        // 同一个 T 版本：异常，不落库（结果不是错误，会话照常能写）。
        assert_eq!(put(&t, col, &other, 2), Ok(Put::Conflict));
        assert_eq!(
            t.entry(col, &s[0].id).unwrap().unwrap().slot().unwrap(),
            s[0]
        );
        // 更低的版本：本机不动。
        assert_eq!(put(&t, col, &other, 1), Ok(Put::Kept));
        assert_eq!(
            t.entry(col, &s[0].id).unwrap().unwrap().slot().unwrap(),
            s[0]
        );
        // 更高的版本：换成来的。
        assert_eq!(put(&t, col, &other, 3), Ok(Put::Replaced));
        let e = t.entry(col, &s[0].id).unwrap().unwrap();
        assert_eq!((e.slot().unwrap(), e.tv), (other.clone(), 3));
        // 逐字节相同、版本更高：只抬标签。
        assert_eq!(put(&t, col, &s[1], 5), Ok(Put::Same));
        assert_eq!(t.entry(col, &s[1].id).unwrap().unwrap().tv, 5);
        assert_eq!(put(&t, col, &s[3], 5), Ok(Put::Same));
        assert_eq!(t.entry(col, &s[3].id).unwrap().unwrap().tv, 5);
        assert_eq!(t.audit(col).unwrap(), 8);
    }

    /// 分叉时谁在日志里只看链指纹：两支不管谁先到，日志与另一支都一样。被换出去的是空洞 / 副本记录也一样。
    #[test]
    fn the_log_under_a_fork_does_not_depend_on_which_branch_arrived_first() {
        let s = slots();
        let low = |x: &HeritageSlot, text: &str| {
            let mut b = other_edit(x, text);
            b.fp = [0; 8];
            b
        };
        // 另一支：操作号 1（本机是操作）、5（副本记录）、6（空洞区间的第一格）各有一条链指纹更小的。
        const AT: [usize; 3] = [0, 4, 5];
        let branch: Vec<HeritageSlot> = AT.iter().map(|&i| low(&s[i], "\"branch\"")).collect();
        let state = |order: &[&HeritageSlot]| {
            let conn = open_in_memory().unwrap();
            let t = Truth::new(&conn);
            let col = bound(&t);
            let mut puts = Vec::new();
            for x in order {
                let p = if x.id.seq > t.last_of(col, &id(OLD)).unwrap() + 1 {
                    t.tx(|t| t.put_pending(col, &src(), x, 1, None)).unwrap()
                } else {
                    put(&t, col, x, 1).unwrap()
                };
                puts.push(p);
            }
            // 待投递的补上之后也一样。
            while let Some(ready) = t
                .pending(col)
                .unwrap()
                .into_iter()
                .find(|p| p.slot.id.seq == t.last_of(col, &id(OLD)).unwrap() + 1)
            {
                put(&t, col, &ready.slot, ready.tv).unwrap();
            }
            assert_eq!(t.audit(col).unwrap(), s.len() as u64);
            (all(&t, col, &id(OLD)), t.forks(col).unwrap(), puts)
        };
        let main_first: Vec<&HeritageSlot> = s.iter().chain(&branch).collect();
        let branch_first: Vec<&HeritageSlot> = branch.iter().chain(&s).collect();
        let mixed: Vec<&HeritageSlot> = vec![
            &s[0], &branch[0], &s[1], &branch[1], &s[2], &s[3], &s[4], &branch[2], &s[5],
        ]
        .into_iter()
        .chain(&s[6..])
        .collect();
        let (log, forks, puts) = state(&main_first);
        // 链指纹更小的那三条进了日志，原来的三条成了另一支。
        for (b, i) in branch.iter().zip(AT) {
            assert_eq!(log[i].slot().unwrap(), *b);
            assert!(forks.iter().any(|f| f.slot == s[i]));
        }
        assert_eq!(forks.len(), 3);
        assert_eq!(&puts[s.len()..], [Put::Replaced; 3]);
        for order in [&branch_first, &mixed] {
            let (log2, forks2, puts2) = state(order);
            // 待投递的那几条链指纹更小：后到的同号槽接在末尾时让位。
            assert!(puts2.contains(&Put::Yielded));
            assert_eq!(log2, log);
            assert_eq!(forks2, forks);
        }
        // 来的那支不比本机的小：只记下，日志不动。
        let high: Vec<HeritageSlot> = s
            .iter()
            .take(2)
            .map(|x| {
                let mut b = other_edit(x, "\"high\"");
                b.fp = [0xff; 8];
                b
            })
            .collect();
        let with_high: Vec<&HeritageSlot> = main_first.iter().copied().chain(&high).collect();
        let (log3, forks3, puts3) = state(&with_high);
        assert_eq!(log3, log);
        assert_eq!(forks3.len(), 5);
        assert_eq!(&puts3[puts3.len() - 2..], [Put::Fork; 2]);
    }

    #[test]
    fn a_different_fingerprint_is_a_fork_and_both_branches_are_kept() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let s = slots();
        for x in &s {
            put(&t, col, x, 1).unwrap();
        }
        let before = all(&t, col, &id(OLD));
        let mut branch = other_edit(&s[0], "\"branch\"");
        branch.fp = [0xfb; 8];
        assert_eq!(put(&t, col, &branch, 1), Ok(Put::Fork));
        assert_eq!(put(&t, col, &branch, 1), Ok(Put::Fork));
        assert_eq!(all(&t, col, &id(OLD)), before);
        assert_eq!(
            t.forks(col).unwrap(),
            vec![Parked {
                slot: branch.clone(),
                tv: 1,
                prev_fp: None
            }]
        );
        // 分叉的那一支没有被本机推进过：同一支来了空洞，留靠后的。
        assert_eq!(put(&t, col, &purge_slot(&branch), 1), Ok(Put::Fork));
        assert_eq!(t.forks(col).unwrap()[0].slot, purge_slot(&branch));
        assert_eq!(put(&t, col, &branch, 1), Ok(Put::Fork));
        assert_eq!(t.forks(col).unwrap()[0].slot, purge_slot(&branch));
    }

    #[test]
    fn only_the_local_purge_and_dedup_advance_a_slot() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let s = slots();
        for x in &s {
            put(&t, col, x, 1).unwrap();
        }
        let of = OpId {
            device: id(0xee),
            seq: 77,
        };
        // seq 5（副本记录）旁边的 seq 6、7 是收来的空洞；把 seq 8、seq 1 清除，seq 2 认成副本。
        assert_eq!(t.tx(|t| t.advance_purge(col, &oid(8))), Ok(true));
        assert_eq!(t.tx(|t| t.advance_purge(col, &oid(1))), Ok(true));
        assert_eq!(t.tx(|t| t.advance_dedup(col, &oid(2), &of)), Ok(true));
        // 第二次、对空洞 / 副本记录、对没有的操作号：不动。
        assert_eq!(t.tx(|t| t.advance_purge(col, &oid(8))), Ok(false));
        assert_eq!(t.tx(|t| t.advance_purge(col, &oid(4))), Ok(false));
        assert_eq!(t.tx(|t| t.advance_dedup(col, &oid(6), &of)), Ok(false));
        assert_eq!(t.tx(|t| t.advance_dedup(col, &oid(2), &oid(3))), Ok(false));
        assert_eq!(t.tx(|t| t.advance_purge(col, &oid(9))), Ok(false));
        assert_eq!(
            t.tx(|t| t.advance_purge(
                col,
                &OpId {
                    device: id(0x99),
                    seq: 1
                }
            )),
            Ok(false)
        );
        let got = all(&t, col, &id(OLD));
        let want = [
            purge_slot(&s[0]),
            dedup_slot(&s[1], of).unwrap(),
            s[2].clone(),
            s[3].clone(),
            s[4].clone(),
            s[5].clone(),
            s[6].clone(),
            purge_slot(&s[7]),
        ];
        for (e, w) in got.iter().zip(&want) {
            assert_eq!(e.slot().unwrap().encode(), w.encode());
        }
        assert_eq!(
            got.iter().map(|e| e.local).collect::<Vec<_>>(),
            [true, true, false, false, false, false, false, true]
        );
        // 本机清出来的空洞与收来的空洞不并成一个区间（标志不同）：1、6–7、8 三个区间。
        assert_eq!(count(&conn, "op_voids"), 3);
        assert_eq!(t.audit(col).unwrap(), 8);
        // 原样件也能清除。
        assert_eq!(t.tx(|t| t.advance_purge(col, &oid(3))), Ok(true));
        assert_eq!(count(&conn, "ops"), 0);
    }

    #[test]
    fn a_dedup_that_protocol_3_would_fail_leaves_the_slot_alone() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        // 种类认识、载荷解不开的原样件：协议 3 的 `Op::duplicate` 在这里报错，应用那条 Dedup 的一轮整个失败。
        let raw = Raw3::of_v3(&v3::Op {
            id: oid(1),
            hlc: Hlc {
                wall: 1,
                logical: 0,
                device: id(OLD),
            },
            deps: Arc::new(Vv::new()),
            kind: v3::KIND_EDIT,
            schema: 1,
            payload: vec![0xff].into(),
            purged: false,
        });
        let slot = HeritageSlot::raw3([1; 8], raw);
        assert_eq!(put(&t, col, &slot, 1), Ok(Put::Inserted));
        let e = t
            .tx(|t| t.advance_dedup(col, &oid(1), &oid(2)))
            .unwrap_err();
        assert!(e.contains("dedup of"), "{e}");
        let got = t.entry(col, &oid(1)).unwrap().unwrap();
        assert_eq!((got.slot().unwrap(), got.local), (slot, false));
    }

    #[test]
    fn void_runs_merge_on_both_sides() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let whole: Vec<HeritageSlot> = (1..=7u64)
            .map(|seq| {
                HeritageSlot::op(
                    [seq as u8; 8],
                    op_of(id(OLD), seq, &Body4::Edit(native_edit())),
                )
            })
            .collect();
        for x in &whole {
            put(&t, col, x, 1).unwrap();
        }
        for seq in [2, 4, 6, 3, 5] {
            assert_eq!(t.tx(|t| t.advance_purge(col, &oid(seq))), Ok(true));
            assert_eq!(t.audit(col).unwrap(), 7);
        }
        assert_eq!(count(&conn, "op_voids"), 1);
        let (k, n, fps): (i64, i64, Vec<u8>) = conn
            .query_row("SELECT k, n, fps FROM op_voids", [], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })
            .unwrap();
        assert_eq!((k_seq(k), n), (2, 5));
        assert_eq!(fps, (2..=6u8).flat_map(|b| [b; 8]).collect::<Vec<_>>());
        let got = all(&t, col, &id(OLD));
        for (e, w) in got.iter().zip(&whole) {
            let want = if (2..=6).contains(&w.id.seq) {
                purge_slot(w)
            } else {
                w.clone()
            };
            assert_eq!(e.slot().unwrap(), want);
        }
        // 另开会话：末尾从表里算出来。
        let t = Truth::new(&conn);
        assert_eq!(t.last_of(col, &id(OLD)).unwrap(), 7);
        assert_eq!(t.tx(|t| t.advance_purge(col, &oid(7))), Ok(true));
        let t = Truth::new(&conn);
        assert_eq!(t.last_of(col, &id(OLD)).unwrap(), 7);
        assert_eq!(count(&conn, "op_voids"), 1);
    }

    /// [Truth::voids_within]（转发缓存拒收、不为转发拉原文、从日志重切都靠它，交接 §33）：区间各自截到查询范围；
    /// 查询范围的起点落在一个更早开始的空洞区间里（前导分支）、或正是被清除的段首，都要报出来。
    #[test]
    fn voids_within_reports_runs_cut_to_the_range_including_a_leading_one() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        for seq in 1..=7u64 {
            let slot = HeritageSlot::op(
                [seq as u8; 8],
                op_of(id(OLD), seq, &Body4::Edit(native_edit())),
            );
            put(&t, col, &slot, 1).unwrap();
        }
        for seq in [1, 3, 4] {
            assert_eq!(t.tx(|t| t.advance_purge(col, &oid(seq))), Ok(true));
        }
        let w = |a: u64, b: u64| t.voids_within(col, &id(OLD), a, b).unwrap();
        assert_eq!(w(1, 7), vec![(1, 1), (3, 4)]);
        assert_eq!(w(1, 1), vec![(1, 1)], "the segment's first op purged");
        assert_eq!(w(2, 7), vec![(3, 4)]);
        assert_eq!(w(4, 7), vec![(4, 4)], "a run that began before the range");
        assert_eq!(w(4, 4), vec![(4, 4)]);
        assert_eq!(w(5, 7), Vec::<(u64, u64)>::new());
        assert_eq!(w(2, 2), Vec::<(u64, u64)>::new());
        assert_eq!(
            t.voids_within(col, &id(0x77), 1, 7).unwrap(),
            Vec::<(u64, u64)>::new(),
            "an unknown device"
        );
    }

    #[test]
    fn pending_slots_wait_for_their_prefix_and_are_confirmed_by_fingerprint() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let s = slots();
        let pend = |slot: &HeritageSlot, prev: Option<Fp>| {
            t.tx(|t| t.put_pending(col, &src(), slot, 1, prev))
        };
        assert_eq!(put(&t, col, &s[0], 1), Ok(Put::Inserted));
        // 3（验不出前一环）、4（验得出接在 3 后面）、5 的一支分叉。
        assert_eq!(pend(&s[2], None), Ok(Put::Pending));
        assert_eq!(pend(&s[3], Some(s[2].fp)), Ok(Put::Pending));
        let mut branch = s[4].clone();
        branch.fp = [0xfb; 8];
        assert_eq!(pend(&branch, None), Ok(Put::Pending));
        assert_eq!(pend(&s[2], None), Ok(Put::Pending));
        assert_eq!(t.pending(col).unwrap().len(), 3);
        assert_eq!(t.last_of(col, &id(OLD)).unwrap(), 1);
        // 没有哪条正好接在末尾。
        assert_eq!(t.pending_ready(col, &id(OLD)).unwrap(), None);
        // 2 到了：3 正好接在末尾，但它验不出前一环，不自己投。
        assert_eq!(put(&t, col, &s[1], 1), Ok(Put::Inserted));
        assert_eq!(t.pending_ready(col, &id(OLD)).unwrap(), None);
        // 之后补上了「3 的前一环是 2」：可以投了。
        assert_eq!(pend(&s[2], Some(s[1].fp)), Ok(Put::Pending));
        let ready = t.pending_ready(col, &id(OLD)).unwrap().unwrap();
        assert_eq!(
            (ready.slot.clone(), ready.prev_fp),
            (s[2].clone(), Some(s[1].fp))
        );
        // 说它接在另一个槽后面：矛盾，不落。
        assert_eq!(pend(&s[2], Some([9; 8])), Ok(Put::Conflict));
        assert_eq!(put(&t, col, &ready.slot, ready.tv), Ok(Put::Inserted));
        // 3 落库的同时它的待投递行确认掉了；4 接着可以投。
        assert_eq!(t.pending(col).unwrap().len(), 2);
        let ready = t.pending_ready(col, &id(OLD)).unwrap().unwrap();
        assert_eq!(ready.slot, s[3]);
        assert_eq!(put(&t, col, &ready.slot, 1), Ok(Put::Inserted));
        // 5 经承袭段到达：链指纹不同的那条待投递是分叉的一支。
        assert_eq!(t.pending_ready(col, &id(OLD)).unwrap(), None);
        assert_eq!(put(&t, col, &s[4], 1), Ok(Put::Inserted));
        assert_eq!(t.pending(col).unwrap(), Vec::new());
        assert_eq!(
            t.forks(col).unwrap(),
            vec![Parked {
                slot: branch,
                tv: 1,
                prev_fp: None
            }]
        );
        // 已经在日志里的操作号再当待投递来：同指纹 = 残留。
        assert_eq!(pend(&s[4], None), Ok(Put::Same));
        assert_eq!(t.pending(col).unwrap(), Vec::new());
        // 第一条也可以是待投递来的：前一环是链的起点。
        let col2 = t.tx(|t| t.bind("other", &id(0xc1), "dir2")).unwrap();
        t.tx(|t| t.put_pending(col2, &src(), &s[0], 1, Some(fingerprint(&CHAIN_ZERO))))
            .unwrap();
        assert_eq!(t.pending_ready(col2, &id(OLD)).unwrap().unwrap().slot, s[0]);
        // 两个集合互不相干。
        assert_eq!(t.last_of(col2, &id(OLD)).unwrap(), 0);
        assert_eq!(t.last_of(col, &id(OLD)).unwrap(), 5);
    }

    #[test]
    fn marks_must_match_the_slot_they_name() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let s = slots();
        for x in &s {
            put(&t, col, x, 1).unwrap();
        }
        let mut chain = [0x77u8; 32];
        chain[..8].copy_from_slice(&s[7].fp);
        t.tx(|t| t.set_mark(col, &id(OLD), 8, &chain)).unwrap();
        // 空洞处也有链指纹。
        let mut at6 = [0x66u8; 32];
        at6[..8].copy_from_slice(&s[5].fp);
        t.tx(|t| t.set_mark(col, &id(OLD), 6, &at6)).unwrap();
        assert_eq!(t.marks(col, &id(OLD)).unwrap(), vec![(6, at6), (8, chain)]);
        let e = t.tx(|t| t.set_mark(col, &id(OLD), 7, &chain)).unwrap_err();
        assert!(e.contains("does not match its slot"), "{e}");
        let e = t.tx(|t| t.set_mark(col, &id(OLD), 9, &chain)).unwrap_err();
        assert!(e.contains("does not match its slot"), "{e}");
    }

    fn native(seq: u64, value: &str) -> Op4 {
        op_of(
            id(0xa1),
            seq,
            &Body4::Edit(Edit4 {
                value: value.to_owned(),
                ..native_edit()
            }),
        )
    }

    #[test]
    fn ops_that_carry_salts_are_never_purged() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let salts = op_of(id(0xa1), 1, &Body4::salts(["u1"]).unwrap());
        t.tx(|t| {
            t.append_native(col, &salts)?;
            t.append_native(col, &native(2, "\"x\""))
        })
        .unwrap();
        let target = |seq| OpId {
            device: id(0xa1),
            seq,
        };
        let e = t.tx(|t| t.advance_purge(col, &target(1))).unwrap_err();
        assert!(e.contains("never purged"), "{e}");
        // 事务回滚、会话已 reset：那一条还是完整内容，旁边的照常能清。
        assert!(t.entry(col, &target(1)).unwrap().unwrap().is_whole());
        assert_eq!(t.tx(|t| t.advance_purge(col, &target(2))), Ok(true));
        assert!(t.entry(col, &target(1)).unwrap().unwrap().is_whole());
    }

    #[test]
    fn a_native_log_chains_and_keeps_chaining_across_purged_ops() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let dev = id(0xa1);
        let n = MARK_EVERY + 40;
        let mut chains = vec![CHAIN_ZERO];
        t.tx(|t| {
            for seq in 1..=n {
                let op = native(seq, &format!("\"v{seq}\""));
                let want = chain_next4(chains.last().unwrap(), &op);
                assert_eq!(t.append_native(col, &op)?, want);
                chains.push(want);
            }
            Ok(())
        })
        .unwrap();
        let e = t
            .tx(|t| t.append_native(col, &native(n + 2, "\"x\"")))
            .unwrap_err();
        assert!(e.contains("does not follow"), "{e}");
        // 带旧戳的修改、Dedup 进不了原生日志。
        let stamped = op_of(
            dev,
            n + 1,
            &Body4::Edit(Edit4 {
                stamp: Some(crate::gen4::stamp::tests::typical()),
                ..native_edit()
            }),
        );
        assert!(t.tx(|t| t.append_native(col, &stamped)).is_err());
        let check = |t: &Truth<'_>| {
            for seq in [
                0,
                1,
                2,
                7,
                MARK_EVERY - 1,
                MARK_EVERY,
                MARK_EVERY + 1,
                n - 1,
                n,
            ] {
                assert_eq!(
                    t.chain_at(col, &dev, seq).unwrap(),
                    chains[seq as usize],
                    "{seq}"
                );
            }
        };
        check(&t);
        check(&Truth::new(&conn));
        assert_eq!(
            t.marks(col, &dev).unwrap(),
            vec![(MARK_EVERY, chains[MARK_EVERY as usize])]
        );
        let got = all(&t, col, &dev);
        assert_eq!(got.len() as u64, n);
        assert!(got.iter().all(|e| e.fp.is_none() && e.op().is_some()));
        assert_eq!(got[4].op().unwrap(), &native(5, "\"v5\""));
        // 清除中间的、末尾的、相邻的：链值不变，空洞里只有区间末有链值。
        for seq in [5, 6, n, 3] {
            assert_eq!(
                t.tx(|t| t.advance_purge(col, &OpId { device: dev, seq })),
                Ok(true)
            );
        }
        let t = Truth::new(&conn);
        for seq in [1, 2, 3, 4, 6, 7, 8, MARK_EVERY + 1, n - 1, n] {
            assert_eq!(
                t.chain_at(col, &dev, seq).unwrap(),
                chains[seq as usize],
                "{seq}"
            );
        }
        let e = t.chain_at(col, &dev, 5).unwrap_err();
        assert!(e.contains("inside a void run"), "{e}");
        assert_eq!(t.audit(col).unwrap(), n);
        assert_eq!(count(&conn, "op_voids"), 3);
        // 接着写：链从末尾（哪怕末尾是空洞）接上。
        let op = native(n + 1, "\"next\"");
        let want = chain_next4(&chains[n as usize], &op);
        assert_eq!(t.tx(|t| t.append_native(col, &op)), Ok(want));
        // 收来的空洞区间：条数 + 区间末的链值。
        let after = [0x42u8; 32];
        t.tx(|t| t.append_native_void(col, &dev, 3, &after))
            .unwrap();
        assert_eq!(t.last_of(col, &dev).unwrap(), n + 4);
        assert_eq!(t.chain_at(col, &dev, n + 4).unwrap(), after);
        let op = native(n + 5, "\"after the void\"");
        assert_eq!(
            t.tx(|t| t.append_native(col, &op)),
            Ok(chain_next4(&after, &op))
        );
        assert_eq!(Truth::new(&conn).audit(col).unwrap(), n + 5);
        // 原生日志没有副本。
        let e = t
            .tx(|t| {
                t.advance_dedup(
                    col,
                    &OpId {
                        device: dev,
                        seq: 1,
                    },
                    &oid(1),
                )
            })
            .unwrap_err();
        assert!(e.contains("native op"), "{e}");
    }

    #[test]
    fn bindings_are_one_to_one_and_salts_only_grow() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        assert_eq!(t.tx(|t| t.bind(P, &id(0xc0), "dir")), Ok(col));
        assert!(
            t.tx(|t| t.bind(P, &id(0xc1), "dir"))
                .unwrap_err()
                .contains("already bound")
        );
        assert!(
            t.tx(|t| t.bind("p2", &id(0xc0), "dir"))
                .unwrap_err()
                .contains("already bound")
        );
        let salts =
            |list: &[&str]| -> BTreeSet<String> { list.iter().map(|s| (*s).to_owned()).collect() };
        assert_eq!(t.tx(|t| t.set_salts(col, &salts(&["u2", "u1"]))), Ok(true));
        assert_eq!(t.tx(|t| t.set_salts(col, &salts(&["u1", "u2"]))), Ok(false));
        let b = t.binding_of(P).unwrap().unwrap();
        assert_eq!(
            (
                b.col,
                b.collection,
                b.dir.as_str(),
                b.salts.into_iter().collect::<Vec<_>>()
            ),
            (col, id(0xc0), "dir", vec!["u1".to_owned(), "u2".to_owned()])
        );
        assert_eq!(t.binding_of("nobody").unwrap(), None);
        // 没绑定的集合号收不了东西。
        let e = t
            .tx(|t| t.put_heritage(col + 9, &src(), &slots()[0], 1))
            .unwrap_err();
        assert!(e.contains("no collection"), "{e}");
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(64))]

        /// 任意旧操作转出来的槽，存进去读出来逐字节相同；任意一批本机推进之后仍是「转译 + 推进」的结果。
        #[test]
        fn any_translated_log_reads_back_byte_for_byte(
            ops in proptest::collection::vec(arb_op3(), 1..40),
            purge in proptest::collection::vec(any::<prop::sample::Index>(), 0..6),
        ) {
            let device = id(OLD);
            let mut want = Vec::new();
            for mut op in ops {
                let seq = want.len() as u64 + 1;
                op.id = OpId { device, seq };
                op.hlc.device = device;
                let chain = *blake3::hash(&seq.to_le_bytes()).as_bytes();
                if let Ok(slot) = translate(&op, &chain) {
                    want.push(slot);
                }
            }
            let conn = open_in_memory().unwrap();
            let t = Truth::new(&conn);
            let col = bound(&t);
            t.tx(|t| {
                for s in &want {
                    t.put_heritage(col, &src(), s, 1)?;
                }
                Ok(())
            }).unwrap();
            for ix in purge {
                if want.is_empty() {
                    break;
                }
                let i = ix.index(want.len());
                let changed = t.tx(|t| t.advance_purge(col, &want[i].id)).unwrap();
                prop_assert_eq!(changed, purge_slot(&want[i]) != want[i]);
                want[i] = purge_slot(&want[i]);
            }
            let t = Truth::new(&conn);
            let got = all(&t, col, &device);
            prop_assert_eq!(got.len(), want.len());
            for (e, s) in got.iter().zip(&want) {
                prop_assert_eq!(e.slot().unwrap().encode(), s.encode());
            }
            prop_assert_eq!(t.audit(col).unwrap(), want.len() as u64);
        }

        /// BUG-5137：[Truth::edit_read]（只解头部、字段值按需）与整条读法 `entry_by_key` + `derive::body_of` 逐字段
        /// 相同——带旧戳（存储时旧戳内部化）/ 不带、字段值大到压缩 / 不压、协议 3 原样件、别的种类、本机清成的空洞。
        #[test]
        fn edit_read_matches_the_full_decode(
            ops in proptest::collection::vec(arb_op3(), 0..20),
            edits in proptest::collection::vec(
                (crate::gen4::op::tests::arb_edit(), any::<bool>()), 0..20),
            order in any::<prop::sample::Index>(),
            purge in proptest::collection::vec(any::<prop::sample::Index>(), 0..4),
        ) {
            let device = id(OLD);
            let mut slots = Vec::new();
            for op in ops {
                let chain = *blake3::hash(&(slots.len() as u64).to_le_bytes()).as_bytes();
                if let Ok(slot) = translate(&op, &chain) {
                    slots.push(slot);
                }
            }
            for (mut ed, big) in edits {
                if big {
                    // 够长才走 zstd（`pack::ZSTD_MIN`）。
                    ed.value = serde_json::to_string(&"単語の例文。".repeat(40)).unwrap();
                }
                let o = op_of(device, 1, &Body4::Edit(ed));
                slots.push(HeritageSlot::op([3; 8], o));
            }
            // 两类交错，再按 seq 重新编号。
            let n = slots.len();
            if n > 0 {
                slots.rotate_left(order.index(n));
            }
            let mut want = Vec::new();
            for (i, mut s) in slots.into_iter().enumerate() {
                let seq = i as u64 + 1;
                s.id = OpId { device, seq };
                match &mut s.body {
                    SlotBody::Op(op) => {
                        op.id = s.id;
                        op.hlc.device = device;
                    }
                    SlotBody::Raw3(raw) => {
                        let mut v = raw.to_v3();
                        v.id = s.id;
                        v.hlc.device = device;
                        *raw = Raw3::of_v3(&v);
                    }
                    _ => {}
                }
                want.push(s);
            }
            let conn = open_in_memory().unwrap();
            let t = Truth::new(&conn);
            let col = bound(&t);
            t.tx(|t| {
                for s in &want {
                    t.put_heritage(col, &src(), s, 1)?;
                }
                Ok(())
            }).unwrap();
            for ix in purge {
                if want.is_empty() {
                    break;
                }
                let i = ix.index(want.len());
                t.tx(|t| t.advance_purge(col, &want[i].id)).unwrap();
            }
            let full = |k: i64| -> Result<Option<EditRead>, String> {
                let e = t.entry_by_key(k)?.ok_or("missing")?;
                let (wall, logical, deps) = match &e.body {
                    SlotBody::Op(op) => (op.hlc.wall, op.hlc.logical, op.deps.clone()),
                    SlotBody::Raw3(raw) => {
                        let v = raw.to_v3();
                        (v.hlc.wall, v.hlc.logical, v.deps)
                    }
                    _ => return Ok(None),
                };
                Ok(match super::super::derive::body_of(&e) {
                    Some(Body4::Edit(ed)) => {
                        let (head, value) = ed.into_parts();
                        Some(EditRead { id: e.id, wall, logical, deps, head, value: Some(value) })
                    }
                    _ => None,
                })
            };
            let mut edits_seen = 0;
            for s in &want {
                let k = t.key_of(col, &s.id).unwrap().unwrap();
                let whole = full(k).unwrap();
                edits_seen += usize::from(whole.is_some());
                prop_assert_eq!(t.edit_read(k, true).unwrap(), whole.clone());
                prop_assert_eq!(
                    t.edit_read(k, false).unwrap(),
                    whole.map(|w| EditRead { value: None, ..w })
                );
            }
            prop_assert!(edits_seen <= want.len());
        }
    }

    /// BUG-5137：[Truth::edit_read] 走到了存储的每一种形态（旧戳内部化、压缩、两者都有、原样件），读出的头部与值
    /// 与写进去的修改相同。
    #[test]
    fn edit_read_covers_every_stored_form() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let stamp = crate::gen4::stamp::tests::typical();
        let big = serde_json::to_string(&"単語の例文。".repeat(40)).unwrap();
        let edits = [
            Edit4 {
                stamp: Some(stamp.clone()),
                ..native_edit()
            },
            Edit4 {
                value: big.clone(),
                ..native_edit()
            },
            Edit4 {
                value: big,
                stamp: Some(stamp),
                ..native_edit()
            },
            native_edit(),
        ];
        t.tx(|t| {
            for (i, ed) in edits.iter().enumerate() {
                let o = op_of(id(OLD), i as u64 + 1, &Body4::Edit(ed.clone()));
                t.put_heritage(col, &src(), &HeritageSlot::op([i as u8; 8], o), 1)?;
            }
            Ok(())
        })
        .unwrap();
        let flags: Vec<i64> = conn
            .prepare("SELECT flags FROM ops ORDER BY k")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        assert_eq!(
            flags
                .iter()
                .map(|f| f & (pack::F_ZSTD | F_STAMP))
                .collect::<Vec<_>>(),
            [F_STAMP, pack::F_ZSTD, pack::F_ZSTD | F_STAMP, 0]
        );
        for (i, ed) in edits.iter().enumerate() {
            let k = t.key_of(col, &oid(i as u64 + 1)).unwrap().unwrap();
            let got = t.edit_read(k, true).unwrap().expect("an edit");
            let (head, value) = ed.clone().into_parts();
            assert_eq!((got.head, got.value), (head.clone(), Some(value)));
            assert_eq!(t.edit_read(k, false).unwrap().unwrap().value, None);
        }
        // 原样件：协议 3 的修改，经转译读出。
        let raw = v3::Op {
            id: oid(5),
            hlc: Hlc {
                wall: 9,
                logical: 2,
                device: id(OLD),
            },
            deps: Arc::new(Vv::new()),
            kind: v3::KIND_EDIT,
            schema: 1,
            payload: vec![0xff].into(),
            purged: false,
        };
        t.tx(|t| {
            t.put_heritage(
                col,
                &src(),
                &HeritageSlot::raw3([5; 8], Raw3::of_v3(&raw)),
                1,
            )
        })
        .unwrap();
        let k = t.key_of(col, &oid(5)).unwrap().unwrap();
        // 解不开的原样件不是修改（与 `body_of` 相同）。
        assert_eq!(t.edit_read(k, true), Ok(None));
        // 主键上什么都没有 = Err。
        let none = t.key_of(col, &oid(99)).unwrap().unwrap();
        assert!(t.edit_read(none, false).is_err());
    }

    #[test]
    fn a_peer_key_is_first_come_and_the_rest_merges() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let dev = id(0x71);
        assert_eq!(t.device_key(col, &dev), Ok(None));
        let first = Peer {
            device: dev,
            public: [7; 32],
            name: Some("phone".to_owned()),
            ext: None,
            head_gen: Some(3),
            first_seen: Some(100),
        };
        assert_eq!(t.tx(|t| t.set_peer(col, &first)), Ok(PeerPut::Inserted));
        assert_eq!(t.device_key(col, &dev), Ok(Some([7; 32])));
        assert_eq!(t.tx(|t| t.set_peer(col, &first)), Ok(PeerPut::Same));
        // 换公钥：拒绝、什么都不写。
        let impostor = Peer {
            public: [8; 32],
            name: Some("evil".to_owned()),
            ..first.clone()
        };
        assert_eq!(
            t.tx(|t| t.set_peer(col, &impostor)),
            Ok(PeerPut::KeyMismatch)
        );
        assert_eq!(t.peer(col, &dev).unwrap(), Some(first.clone()));
        // 同一个公钥：名字换、扩展补上、代号只升不降、第一次见到的时刻不变。
        let later = Peer {
            name: None,
            ext: Some("{\"os\":\"ios\"}".to_owned()),
            head_gen: Some(2),
            first_seen: Some(900),
            ..first.clone()
        };
        assert_eq!(t.tx(|t| t.set_peer(col, &later)), Ok(PeerPut::Updated));
        let got = t.peer(col, &dev).unwrap().unwrap();
        assert_eq!(
            (
                got.name.as_deref(),
                got.ext.as_deref(),
                got.head_gen,
                got.first_seen
            ),
            (Some("phone"), Some("{\"os\":\"ios\"}"), Some(3), Some(100))
        );
        // 别的集合里看不到；事务外写报错。
        assert_eq!(t.device_key(col + 1, &dev), Ok(None));
        assert!(
            t.set_peer(col, &first)
                .unwrap_err()
                .contains("outside a transaction")
        );
    }

    /// 缺口 G-1：同一个库文件上两个连接各有一个会话。B 在读过之后、A 又接着写了几条——B 的下一个事务必须看到 A
    /// 写的末尾与链值，而不是自己缓存里的旧值。
    #[test]
    fn every_outer_transaction_starts_from_what_other_connections_wrote() {
        let dir = crate::store::sync2::tests::tempdir::new("gen4-two-conns");
        let path = dir.0.join("srs4.db");
        let ca = crate::store::gen4::schema::open(&path).unwrap();
        let cb = crate::store::gen4::schema::open(&path).unwrap();
        let a = Truth::new(&ca);
        let b = Truth::new(&cb);
        let col = bound(&a);
        let dev = native(1, "\"x\"").id.device;
        a.tx(|t| {
            for seq in 1..=3 {
                t.append_native(col, &native(seq, "\"a\""))?;
            }
            Ok(())
        })
        .unwrap();
        // B 读过：缓存里是末尾 3。
        assert_eq!(b.tx(|t| t.last_of(col, &dev)), Ok(3));
        a.tx(|t| {
            for seq in 4..=5 {
                t.append_native(col, &native(seq, "\"a\""))?;
            }
            Ok(())
        })
        .unwrap();
        // B 的下一个事务第一次就接在 5 后面，链值接在 A 写的链上。
        let six = native(6, "\"b\"");
        let want = chain_next4(&a.tx(|t| t.chain_at(col, &dev, 5)).unwrap(), &six);
        assert_eq!(b.tx(|t| t.append_native(col, &six)), Ok(want));
        // A 那边同理：看到 B 写的第 6 条。
        assert_eq!(a.tx(|t| t.last_of(col, &dev)), Ok(6));
        assert_eq!(a.tx(|t| t.audit(col)), Ok(6));
        // 嵌套的事务不 reset：同一个外层事务里的缓存照用。
        b.tx(|t| {
            let seven = native(7, "\"b\"");
            t.append_native(col, &seven)?;
            t.tx(|t| t.append_native(col, &native(8, "\"b\"")))?;
            assert_eq!(t.last_of(col, &dev)?, 8);
            Ok(())
        })
        .unwrap();
    }

    /// 调用方自己 `BEGIN` 而没 reset：别的连接在缓存之后提交过，写入被 data_version 检测拦下、不落库、会话不毒化；
    /// reset 之后照常。
    #[test]
    fn a_caller_opened_transaction_without_reset_is_caught_on_write() {
        let dir = crate::store::sync2::tests::tempdir::new("gen4-dv-guard");
        let path = dir.0.join("srs4.db");
        let ca = crate::store::gen4::schema::open(&path).unwrap();
        let cb = crate::store::gen4::schema::open(&path).unwrap();
        let a = Truth::new(&ca);
        let b = Truth::new(&cb);
        let col = bound(&a);
        let dev = native(1, "\"x\"").id.device;
        a.tx(|t| t.append_native(col, &native(1, "\"a\"")).map(|_| ()))
            .unwrap();
        assert_eq!(b.tx(|t| t.last_of(col, &dev)), Ok(1));
        a.tx(|t| t.append_native(col, &native(2, "\"a\"")).map(|_| ()))
            .unwrap();
        // B 的缓存还停在末尾 1；自己开事务不 reset 就写。
        cb.execute_batch("BEGIN IMMEDIATE").unwrap();
        let e = b.append_native(col, &native(3, "\"b\"")).unwrap_err();
        assert!(e.contains("reset first"), "{e}");
        b.reset();
        b.append_native(col, &native(3, "\"b\"")).unwrap();
        cb.execute_batch("COMMIT").unwrap();
        assert_eq!(a.tx(|t| t.audit(col)), Ok(3));
        // 同一个连接自己的提交不算：B 接着自己开事务写，不 reset 也不报。
        cb.execute_batch("BEGIN IMMEDIATE").unwrap();
        b.append_native(col, &native(4, "\"b\"")).unwrap();
        cb.execute_batch("COMMIT").unwrap();
    }

    /// 缓存是在事务**外**填的（`last_of` 不经 [Truth::tx]）：一样记下 data_version。别的连接之后提交过，调用方自己
    /// `BEGIN` 不 reset 就写，被拦下、不落库。
    #[test]
    fn a_cache_filled_outside_a_transaction_is_also_guarded() {
        let dir = crate::store::sync2::tests::tempdir::new("gen4-dv-guard-autocommit");
        let path = dir.0.join("srs4.db");
        let ca = crate::store::gen4::schema::open(&path).unwrap();
        let cb = crate::store::gen4::schema::open(&path).unwrap();
        let a = Truth::new(&ca);
        let b = Truth::new(&cb);
        let col = bound(&a);
        let dev = native(1, "\"x\"").id.device;
        a.tx(|t| t.append_native(col, &native(1, "\"a\"")).map(|_| ()))
            .unwrap();
        // B 在自动提交状态下读：缓存里是设备下标与末尾 1。
        assert!(cb.is_autocommit());
        assert_eq!(b.last_of(col, &dev), Ok(1));
        a.tx(|t| t.append_native(col, &native(2, "\"a\"")).map(|_| ()))
            .unwrap();
        cb.execute_batch("BEGIN IMMEDIATE").unwrap();
        let e = b.append_native(col, &native(2, "\"b\"")).unwrap_err();
        assert!(e.contains("reset first"), "{e}");
        assert!(!e.contains("  "), "{e}");
        cb.execute_batch("ROLLBACK").unwrap();
        assert_eq!(a.tx(|t| t.audit(col)), Ok(2));
        assert_eq!(a.tx(|t| t.last_of(col, &dev)), Ok(2));
    }

    /// 子进程那一半：环境变量给了库路径才动作。在自己的连接上经 [Truth::tx] 追加原生操作 `FROM..=TO`，然后退出。
    #[test]
    fn truth_child_process_half() {
        let Ok(path) = std::env::var("FUSHI_TRUTH_CHILD_DB") else {
            return;
        };
        let seq = |k: &str| -> u64 { std::env::var(k).unwrap().parse().unwrap() };
        let (from, to) = (seq("FUSHI_TRUTH_CHILD_FROM"), seq("FUSHI_TRUTH_CHILD_TO"));
        let conn = crate::store::gen4::schema::open(std::path::Path::new(&path)).unwrap();
        let t = Truth::new(&conn);
        let col = t
            .tx(|t| Ok(t.binding_of(P)?.expect("bound by the parent").col))
            .unwrap();
        t.tx(|t| {
            for s in from..=to {
                t.append_native(col, &native(s, "\"child\""))?;
            }
            Ok(())
        })
        .unwrap();
        println!("TRUTH_CHILD appended {from}..={to}");
    }

    /// 缺口 G-1 的跨进程版：本进程的会话读过（缓存里是末尾 3 与它的链值），另一个进程经 [Truth::tx] 接着写了 4..=6
    /// 后退出。同一个会话的下一个 [Truth::tx] 追加第 7 条，必须接在子进程写的末尾和链值之后。
    #[test]
    fn every_outer_transaction_starts_from_what_another_process_wrote() {
        let dir = crate::store::sync2::tests::tempdir::new("gen4-two-procs");
        let path = dir.0.join("srs4.db");
        let conn = crate::store::gen4::schema::open(&path).unwrap();
        let t = Truth::new(&conn);
        let col = bound(&t);
        let dev = native(1, "\"x\"").id.device;
        t.tx(|t| {
            for s in 1..=3 {
                t.append_native(col, &native(s, "\"parent\""))?;
            }
            Ok(())
        })
        .unwrap();
        assert_eq!(t.tx(|t| t.last_of(col, &dev)), Ok(3));
        t.tx(|t| t.chain_at(col, &dev, 3)).unwrap();
        let out = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "store::gen4::truth::tests::truth_child_process_half",
                "--nocapture",
                "--test-threads=1",
            ])
            .env("FUSHI_TRUTH_CHILD_DB", &path)
            .env("FUSHI_TRUTH_CHILD_FROM", "4")
            .env("FUSHI_TRUTH_CHILD_TO", "6")
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert!(out.status.success(), "{stdout}");
        assert!(stdout.contains("TRUTH_CHILD appended 4..=6"), "{stdout}");
        // 期望值从另一个新开的连接上算，不经这个会话。
        let other = crate::store::gen4::schema::open(&path).unwrap();
        let fresh = Truth::new(&other);
        assert_eq!(fresh.tx(|t| t.last_of(col, &dev)), Ok(6));
        let seven = native(7, "\"parent\"");
        let want = chain_next4(&fresh.tx(|t| t.chain_at(col, &dev, 6)).unwrap(), &seven);
        assert_eq!(t.tx(|t| t.append_native(col, &seven)), Ok(want));
        assert_eq!(fresh.tx(|t| t.audit(col)), Ok(7));
    }
}
