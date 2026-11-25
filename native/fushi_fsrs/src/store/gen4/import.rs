//! 把一份协议 3 的库的操作日志灌进新代库的真相层（设计 §6.1 的「转译 + 落库」那一步的存储部分）。
//!
//! 旧库只读（`legacy.rs` 的读入器逐条验链、逐条转译），新库这边：
//!
//! - 已应用的操作 → 承袭日志的槽（[Truth::put_heritage]）；每 [HERITAGE_MARK_EVERY] 条与末尾各记一个完整原链值，
//!   之后切承袭段要用（段头带区间首尾的完整原链值）。
//! - 待投递的操作 → 待投递的槽（[Truth::put_pending]）。能在协议 3 的口径下验出「紧接在上一条之后」的带上前一环的
//!   链指纹（之后可以按链指纹核对着投递），验不出的不带（等同号的槽经承袭段到达再确认）——这是协议 3 「投递时才核对
//!   链值」在过界之后的落点（设计 §10 第 12 条）。
//!
//! 本机状态里只有设备信任跟着过来（`sync2_trust` → `trust`）：哪些删除与清除不执行由它定，丢了它迁移前后的投影就
//! 不一样。
//!
//! 这里只建真相；派生表由 `rebuild_all` 从真相建。整个过程可重放：同一份旧库再灌一遍，每个槽都是「已有」。
//! 迁移流程本身（备份、对拍、切换文件）是 G7 的事。
//!
//! # 导入与旧备份读入（G11-2，规划 §1.9）
//!
//! 并入一个**正在用的**集合（还原 = 空库 + 并入、合并还原 = 并入，D34），与迁移灌入（往临时文件里分批灌）不同：
//!
//! - [import_ops] / [import_ops_from]：`.fushisrs` 第 2 版的内核流 `FSRS4EXP`（导出在 `export.rs`）；来源可以是任何
//!   [Read]（G11-3 的导入命令直接读文件，内存不随文件大小增长）。命令层（`cmd/fushisrs.rs`）在同一个事务里先认领
//!   （`identity::adopt_foreign`）、记清单带的设备公钥（[import_peers]，缺口 G-12）、本机身份分叉了先换身份
//!   （[own_fork_point]），再调它。
//! - [import_v1]：`.fushisrs` 第 1 版的内核流 `FSRS2EXP`（协议 3，冻结读入器 `legacy_export.rs`），逐条转译进承袭日志。
//! - [import_backup]：旧整包备份 / 服务端备份里的协议 3 `srs.db`（调用方用冻结代码在临时副本上备好），与迁移灌入共用
//!   同一份逐设备转译（`land_legacy`）。
//!
//! 三者同一套保证：**一个事务**落真相、收派生层（[ingest_settle]，[Settle::Rebuild]），格式不认识 / 坏数据 / 另一个
//! 集合 / 与本机矛盾一律报可读的错、一条都不落（不半读）；崩溃 = 没发生过；同一份再导一遍什么都不改（槽幂等、链值
//! 逐格核对），所以中断之后重来不产生重复。测试在 `import_tests.rs`。

use std::collections::{BTreeMap, BTreeSet};
use std::io::Read;

use rusqlite::Connection;

use super::carry::{legacy_peers, legacy_self};
use super::derive::{Index, Settled};
use super::fork::ForkScan;
use super::ingest::{Settle, ingest_settle};
use super::legacy::{self, Placement};
use super::legacy_export::{for_each_v1, v1_collection};
use super::schema::sql;
use super::sync_state::AuthorVersion;
use super::truth::{DEV_HERITAGE, DEV_NATIVE, Peer, PeerPut, Put, Truth};
use crate::gen4::export::{Export4Reader, ExportHeader, ExportItem, ExportKind, sniff};
use crate::gen4::heritage::{Fp, HeritageSlot, SlotBody, fingerprint};
use crate::gen4::op::chain_next4;
use crate::gen4::recut::Stub;
use crate::gen4::segment::{NativeHeader, NativeItem};
use crate::gen4::translate::{T_VERSION, translate};
use crate::store::sync2::collection_of;
use crate::sync2::id::Id;
use crate::sync2::segment::{CHAIN_ZERO, Chain, chain_next};
use crate::sync2::vv::OpId;

/// 承袭日志每隔这么多条记一个完整原链值。
pub const HERITAGE_MARK_EVERY: u64 = 4096;

/// 一次灌入的计数。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Imported {
    pub devices: u64,
    /// 旧库里已应用的操作数。
    pub applied: u64,
    /// 旧库里待投递的操作数（不含与已应用同号同链值的残留行）。
    pub pending: u64,
    /// 其中验得出前一环的。
    pub pending_linked: u64,
    /// 转出的槽，按形态。
    pub ops: u64,
    pub raw: u64,
    pub alias: u64,
    pub voids: u64,
    /// 落库的结果，按 [Put]。
    pub inserted: u64,
    pub same: u64,
    pub kept: u64,
    pub replaced: u64,
    pub forks: u64,
    pub parked: u64,
    /// 带过来的「还没信任的设备」。
    pub untrusted: u64,
    /// 新记下的设备公钥（只有旧备份读入 [import_backup] 搬 `sync2_devices`；迁移灌入由 `carry.rs` 搬，这里是 0）。
    pub peers: u64,
}

/// 把 [profile] 在旧库 [src] 里的全部操作灌进 [truth] 的集合 [col]。[batch] 条提交一次（不能在事务里调）。
///
/// 出错时当前这一批回滚、已提交的批留着（重跑会接着来，已有的槽幂等）。
pub fn import_legacy(
    src: &Connection,
    profile: &str,
    truth: &Truth<'_>,
    col: i64,
    batch: u64,
) -> Result<Imported, String> {
    import_legacy_checked(src, profile, truth, col, batch, &mut || Ok(()))
}

/// [import_legacy]，每批提交之前先问一次 [check]：它报错就把这一批回滚、整个灌入报那个错（干跑的中断，`dryrun.rs`）。
pub fn import_legacy_checked(
    src: &Connection,
    profile: &str,
    truth: &Truth<'_>,
    col: i64,
    batch: u64,
    check: &mut dyn FnMut() -> Result<(), String>,
) -> Result<Imported, String> {
    let dst = truth.conn();
    if !dst.is_autocommit() {
        return Err("gen4 import: must not run inside a transaction".to_owned());
    }
    let blockers = legacy::preflight(src, profile)?;
    if !blockers.is_empty() {
        return Err(format!(
            "gen4 import: the legacy library is not ready: {}",
            blockers.join("; ")
        ));
    }
    let mut out = Imported::default();
    dst.execute_batch("BEGIN IMMEDIATE").map_err(sql)?;
    // 自己开的最外层事务：缓存可能是开事务之前的（truth.rs「会话与事务」）。批与批之间（COMMIT; BEGIN）不 reset：
    // 迁移的临时文件只有这个连接写，真有别人插进来写，写入时的 data_version 检测会报错。
    truth.reset();
    let done = (|| -> Result<(), String> {
        let mut in_batch = 0u64;
        land_legacy(src, profile, truth, col, &mut out, &mut || {
            in_batch += 1;
            if in_batch >= batch.max(1) {
                check()?;
                dst.execute_batch("COMMIT; BEGIN IMMEDIATE").map_err(sql)?;
                in_batch = 0;
            }
            Ok(())
        })?;
        for (device, state, since) in legacy::untrusted(src, profile)? {
            truth.set_trust(col, &device, Some(state), since)?;
            out.untrusted += 1;
        }
        Ok(())
    })();
    match done {
        Ok(()) => {
            dst.execute_batch("COMMIT").map_err(sql)?;
            Ok(out)
        }
        Err(e) => {
            let _ = dst.execute_batch("ROLLBACK");
            truth.reset();
            Err(e)
        }
    }
}

/// 把 [profile] 在旧库 [src] 里的全部操作逐设备转译、落进 [truth] 的集合 [col]（迁移灌入与旧备份读入共用的一份）。
/// 每落一条调一次 [step]（迁移在那里分批提交）。不管事务、不碰信任。
fn land_legacy(
    src: &Connection,
    profile: &str,
    truth: &Truth<'_>,
    col: i64,
    out: &mut Imported,
    step: &mut dyn FnMut() -> Result<(), String>,
) -> Result<(), String> {
    let source = collection_of(profile);
    for d in legacy::devices(src, profile)? {
        out.devices += 1;
        // 上一条读到的操作与它的链值（验「紧接在上一条之后」用）；链的起点是 seq 0、全零。
        let mut prev: (u64, Chain) = (0, CHAIN_ZERO);
        let mut tail: Option<(u64, Chain)> = None;
        legacy::for_each_op(src, profile, &d.device, |op, chain, placement| {
            let slot = translate(op, chain)
                .map_err(|m| format!("gen4 import: {}:{} {m}", op.id.device, op.id.seq))?;
            match &slot.body {
                SlotBody::Op(_) => out.ops += 1,
                SlotBody::Raw3(_) => out.raw += 1,
                SlotBody::Alias(_) => out.alias += 1,
                SlotBody::Void => out.voids += 1,
            }
            let put = match placement {
                Placement::Applied => {
                    out.applied += 1;
                    let put = truth.put_heritage(col, &source, &slot, T_VERSION)?;
                    if !matches!(put, Put::Fork | Put::Yielded | Put::Conflict) {
                        if op.id.seq % HERITAGE_MARK_EVERY == 0 {
                            truth.set_mark(col, &d.device, op.id.seq, chain)?;
                        }
                        tail = Some((op.id.seq, *chain));
                    }
                    put
                }
                Placement::Pending => {
                    out.pending += 1;
                    let linked = (prev.0 + 1 == op.id.seq && chain_next(&prev.1, op) == *chain)
                        .then(|| fingerprint(&prev.1));
                    if linked.is_some() {
                        out.pending_linked += 1;
                    }
                    truth.put_pending(col, &source, &slot, T_VERSION, linked)?
                }
            };
            prev = (op.id.seq, *chain);
            match put {
                Put::Inserted => out.inserted += 1,
                Put::Same => out.same += 1,
                Put::Kept => out.kept += 1,
                Put::Replaced => out.replaced += 1,
                Put::Fork | Put::Yielded => out.forks += 1,
                Put::Pending => out.parked += 1,
                // 一份旧库自己转出两份互相矛盾的槽：转译或旧库有问题，整批停下（回滚这一批）。
                Put::Conflict => {
                    return Err(format!(
                        "gen4 import: {}:{} contradicts what is already stored",
                        op.id.device, op.id.seq
                    ));
                }
            }
            step()
        })?;
        if let Some((seq, chain)) = tail {
            // 末尾那一条若让位给了分叉的另一支（同号、链指纹更小的待投递槽），这个链值就不是日志里那一条的：不记。
            mark_if_logged(truth, col, &d.device, seq, &chain)?;
        }
    }
    Ok(())
}

/// [seq] 处日志里那个槽的链指纹就是 [chain] 的，才把它记成链值记号（让位给分叉另一支的、还在待投递的不记）。
fn mark_if_logged(
    truth: &Truth<'_>,
    col: i64,
    device: &Id,
    seq: u64,
    chain: &Chain,
) -> Result<bool, String> {
    if seq == 0 {
        return Ok(false);
    }
    let id = OpId {
        device: *device,
        seq,
    };
    if truth.entry(col, &id)?.and_then(|e| e.fp) != Some(fingerprint(chain)) {
        return Ok(false);
    }
    truth.set_mark(col, device, seq, chain)?;
    Ok(true)
}

// ---------------------------------------------------------------- 导入与旧备份读入（G11-2）

/// 集合 [col] 认作「自己的历史」的协议 3 集合标识：协议 3 的集合是 `collection_of(uid)`（`store/sync2/mod.rs`），所以
/// 是本集合标识本身、位置目录名（存量集合的目录名就是旧 uid）、算数的盐（旧 uid）、被它并入过的集合（及其目录名）、
/// 已经灌进来的承袭日志的来源集合。旧 `.fushisrs` / 旧备份的集合不在这里面 = 另一个集合，拒绝（D34）；同一个集合在
/// 另一个旧 uid 下的数据，由调用方先经 `identity::adopt_foreign` 把那个 uid 写成盐（设计 §5.4 第 6 条），再导入。
fn legacy_sources(t: &Truth<'_>, col: i64) -> Result<BTreeSet<Id>, String> {
    let binding = t
        .binding(col)?
        .ok_or_else(|| format!("gen4 import: no collection {col}"))?;
    let mut out = BTreeSet::from([binding.collection, collection_of(&binding.dir)]);
    out.extend(binding.salts.iter().map(|s| collection_of(s)));
    for j in Index::new(t, col).joins()? {
        out.insert(j.from);
        out.insert(collection_of(&j.dir));
        out.extend(j.salts.iter().map(|s| collection_of(s)));
    }
    out.extend(t.devices(col)?.into_iter().filter_map(|d| d.src));
    Ok(out)
}

/// 协议 4 内核流（`FSRS4EXP`）的头里可以出现的集合：本集合与被它并入过的（与收段同口径，`receive.rs`「集合」）。
fn native_sources(t: &Truth<'_>, col: i64) -> Result<BTreeSet<Id>, String> {
    let binding = t
        .binding(col)?
        .ok_or_else(|| format!("gen4 import: no collection {col}"))?;
    let mut out = BTreeSet::from([binding.collection]);
    out.extend(Index::new(t, col).joins()?.into_iter().map(|j| j.from));
    Ok(out)
}

/// 记下一台设备的公钥（导入流里带的）。本机身份：必须就是本机的公钥。别的设备：先到先得，已经记过另一个公钥就是
/// 冒名 / 坏数据，整个导入拒绝。
fn learn_key(
    t: &Truth<'_>,
    col: i64,
    me: Option<(Id, [u8; 32])>,
    device: &Id,
    public: [u8; 32],
) -> Result<bool, String> {
    if let Some((mine, key)) = me {
        if mine == *device {
            if key != public {
                return Err(format!(
                    "gen4 import: the file carries another public key for this device ({device})"
                ));
            }
            return Ok(false);
        }
    }
    let put = t.set_peer(
        col,
        &Peer {
            device: *device,
            public,
            name: None,
            ext: None,
            head_gen: None,
            first_seen: None,
        },
    )?;
    match put {
        PeerPut::KeyMismatch => Err(format!(
            "gen4 import: device {device} is already known with another public key"
        )),
        PeerPut::Inserted => Ok(true),
        PeerPut::Updated | PeerPut::Same => Ok(false),
    }
}

/// 本机已有的分叉另一支：(设备, seq, 链指纹) → (槽的规范字节, T 版本)。[Truth::put_heritage] 对已存着的另一支同样答
/// [Put::Fork]，计数时拿它分出「新的分叉」与「已有的」（再导一遍不算改动）。
type KnownForks = BTreeMap<([u8; 16], u64, Fp), (Vec<u8>, u32)>;

fn known_forks(t: &Truth<'_>, col: i64) -> Result<KnownForks, String> {
    Ok(t.forks(col)?
        .into_iter()
        .map(|p| {
            (
                (p.slot.id.device.0, p.slot.id.seq, p.slot.fp),
                (p.slot.encode(), p.tv),
            )
        })
        .collect())
}

/// 落一个承袭槽并计数。
fn put_slot(
    t: &Truth<'_>,
    col: i64,
    src: &Id,
    slot: &HeritageSlot,
    tv: u32,
    forks: &KnownForks,
    out: &mut ImportedOps,
) -> Result<(), String> {
    let put = t.put_heritage(col, src, slot, tv)?;
    if put == Put::Fork
        && forks.get(&(slot.id.device.0, slot.id.seq, slot.fp)) == Some(&(slot.encode(), tv))
    {
        out.slots_same += 1;
        return Ok(());
    }
    tally_put(out, put, &slot.id)
}

fn tally_put(out: &mut ImportedOps, put: Put, id: &OpId) -> Result<(), String> {
    match put {
        Put::Inserted | Put::Yielded => out.slots_inserted += 1,
        Put::Same => out.slots_same += 1,
        Put::Kept => out.slots_kept += 1,
        Put::Replaced => out.slots_replaced += 1,
        Put::Fork => out.slots_forked += 1,
        // 流里的日志从 1 起连续，不会前面缺；真出现说明真相层与流对不上。
        Put::Pending => {
            return Err(format!(
                "gen4 import: {}:{} landed as pending although its log is contiguous",
                id.device, id.seq
            ));
        }
        // 来路数据与本机已有的自相矛盾（同号同链指纹、同 T 版本而内容不同）：不半收，整个导入停下。
        Put::Conflict => {
            return Err(format!(
                "gen4 import: {}:{} contradicts what is already stored",
                id.device, id.seq
            ));
        }
    }
    Ok(())
}

/// [import_ops] / [import_v1] 的计数。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ImportedOps {
    /// 流里的原生日志 / 承袭日志条数（第 1 版流：设备抬头数）。
    pub native_logs: u64,
    pub heritage_logs: u64,
    /// 原生日志：新落的操作、本机已有（同一条链上）的 seq、新落的空洞区间。
    pub native_landed: u64,
    pub native_known: u64,
    pub voids_landed: u64,
    /// 承袭槽（含分叉的另一支），按真相层的落库结果。
    pub slots_inserted: u64,
    pub slots_same: u64,
    pub slots_kept: u64,
    pub slots_replaced: u64,
    pub slots_forked: u64,
    /// 新记的链值记号（含重记的）。
    pub marks: u64,
    /// 新记下的原生日志空洞内部链值记号（流的第 2 版，第五波）。
    pub void_marks: u64,
    /// 第一次记下的设备公钥。
    pub peers: u64,
    /// 记下的转发材料（流的第 3 版）：作者签名版本（含换成空洞更多的那份）与剔除记录。本机状态，不算「改了什么」
    /// （[ImportedOps::unchanged]）。
    pub relay_versions: u64,
    pub relay_stubs: u64,
    /// 没记的转发材料（第六波安全复核）：作者公钥本机不知道 / 作者签名验不过 / 不属于所在那条日志的作者签名版本，
    /// 与没有任何验过的版本担保的剔除记录。文件不可信，这些只计数、不落库。
    pub relay_skipped: u64,
    /// 收尾时派生层的收法统计。
    pub settled: Settled,
}

impl ImportedOps {
    /// 这次导入什么都没改（同一份再导一遍）。
    pub fn unchanged(&self) -> bool {
        self.native_landed == 0
            && self.voids_landed == 0
            && self.void_marks == 0
            && self.slots_inserted == 0
            && self.slots_replaced == 0
            && self.slots_forked == 0
            && self.peers == 0
    }
}

/// 一条原生日志的落库进度（[import_ops] 内部）。
struct NativeRun {
    device: Id,
    /// 本机这条日志在导入开始时的末尾。
    local_last: u64,
    /// 流里下一项的第一个 seq，与流在它前一格的链值。
    next: u64,
    chain: Chain,
}

/// 读入 `.fushisrs` 第 2 版的内核流（`FSRS4EXP`），并入集合 [col]（D34：还原 = 空库 + 并入，合并还原 = 并入）。
///
/// - 整个导入是**一个事务**（嵌进调用方的事务时是一个保存点）：格式不认识、截断、坏流、集合不对、与本机矛盾，
///   一律报错回滚，一条都不落（不半读）；中途崩溃 = 没发生过。同一份再导一遍什么都不改（每个槽都是已有），所以中断
///   之后重来不会多出任何东西。
/// - 头里的集合必须是本集合或被它并入过的集合（与收段同口径）；另一个集合的包由命令层先经
///   `identity::adopt_foreign`（用户确认、写 `Join`）再导入（G11-3）。
/// - 原生日志：本机已有的部分逐格比链值（本机那格在空洞内部时比不了，跳过）——不等 = 作者的日志与本机的分叉了
///   （克隆、回滚过的设备），整个导入拒绝，交给身份分叉处理（G8-6）；本机已有的完整操作不因流里是空洞而被清掉
///   （本机的槽只由本机自己的清除推进）。接在末尾之后的照流落库（[Truth::append_native] / [Truth::append_native_void]）。
/// - 承袭日志：逐槽按真相层的落库规则（[Truth::put_heritage]），分叉的另一支照样落；记号只记日志里链指纹相符的。
/// - 流里没有本机状态：信任不动（没见过的设备按「信任」，与迁移灌入的口径相同；用户亲手选的文件）。
///
/// 收尾 [ingest_settle]（[Settle::Rebuild]：流按设备排、不按因果排，不能逐条告诉索引）。
///
/// 事务：在事务外调时自己开 `BEGIN IMMEDIATE`（[Truth::tx_immediate]）——导入先读本机状态、再写一大片，延迟事务碰上
/// 别的连接并发提交会 `SQLITE_BUSY_SNAPSHOT` 整笔失败；嵌进调用方的事务时，拿锁的口径归调用方（命令层要么在事务外调，
/// 要么自己用 `BEGIN IMMEDIATE` 开最外层）。
///
/// 内存口径（G11-3 定案）：解码只走**一遍**（边读边落，坏在中途也是整笔回滚）。来源是 [Read]（[import_ops_from]，
/// 导入命令直接读文件），内存只有一个解压读窗口与一项、外加本机设备 / 分叉清单，不随文件大小增长；[import_ops] 是
/// 内存切片的便利形（测试、整包备份里已经在内存的流）。
pub fn import_ops(t: &Truth<'_>, col: i64, bytes: &[u8]) -> Result<ImportedOps, String> {
    import_ops_from(t, col, open_ops_stream(bytes)?)
}

/// 第 2 版流头的集合 [collection] 是不是集合 [col] 自己的（本集合或被它并入过的）：[import_ops_from] 的判据；导入命令的
/// 预检（`cmd/fushisrs.rs`）也经这里，两处不各写一份。
pub fn check_stream_collection(t: &Truth<'_>, col: i64, collection: &Id) -> Result<(), String> {
    if !native_sources(t, col)?.contains(collection) {
        return Err(format!(
            "gen4 import: this file belongs to another collection ({collection})"
        ));
    }
    Ok(())
}

/// 第 1 版流 [bytes] 的集合是不是集合 [col] 认作自己历史的（[legacy_sources]）：[import_v1] 的判据，预检同上。
pub fn check_v1_collection(t: &Truth<'_>, col: i64, bytes: &[u8]) -> Result<(), String> {
    let collection =
        v1_collection(bytes).map_err(|e| format!("gen4 import: unreadable export ({e})"))?;
    if !legacy_sources(t, col)?.contains(&collection) {
        return Err(format!(
            "gen4 import: this file belongs to another collection ({collection})"
        ));
    }
    Ok(())
}

/// 打开一条来自任意 [Read] 的 `FSRS4EXP` 流（[import_ops_from] / [own_fork_point] 的输入）。不认魔数（含协议 3 的
/// `FSRS2EXP`）、版本、标志位都拒；分辨第 1 版与第 2 版用 `crate::gen4::export::sniff_reader`。
pub fn open_ops_reader<'s, R: Read>(
    src: R,
) -> Result<(Export4Reader<'s, R>, ExportHeader), String> {
    Export4Reader::open_reader(src).map_err(|e| format!("gen4 import: unreadable export ({e})"))
}

/// [import_ops] 的一般形：流已由 [open_ops_reader]（或切片的 `open_ops_stream`）打开、读过头。
pub fn import_ops_from<R: Read>(
    t: &Truth<'_>,
    col: i64,
    opened: (Export4Reader<'_, R>, ExportHeader),
) -> Result<ImportedOps, String> {
    let (mut reader, header) = opened;
    t.tx_immediate(|t| {
        check_stream_collection(t, col, &header.collection)?;
        let me = t.self_identity(col)?.map(|s| (s.device, s.public()));
        let kinds: BTreeMap<Id, (Option<i64>, Option<Id>)> = t
            .devices(col)?
            .into_iter()
            .map(|d| (d.id, (d.kind, d.src)))
            .collect();
        let forks = known_forks(t, col)?;
        let mut out = ImportedOps::default();
        let mut native: Option<NativeRun> = None;
        // 链尾之后的转发材料属于哪台设备（流的第 3 版；刚写完的那条原生日志）。
        let mut relay_of: Option<Id> = None;
        // 这条日志的转发材料先攒着，整条读完（下一条日志开始 / 流读完）再验签落库（[land_relay]）：剔除记录排在作者
        // 签名版本后面，验版本要用到它们。
        let mut relay = RelayBuf::default();
        // 当前承袭日志：(设备, 来源集合, 这条日志的记号)。
        let mut heritage: Option<(Id, Id, Vec<(u64, Chain)>)> = None;
        let finish_heritage = |h: &mut Option<(Id, Id, Vec<(u64, Chain)>)>,
                               out: &mut ImportedOps|
         -> Result<(), String> {
            if let Some((device, _, marks)) = h.take() {
                for (seq, chain) in marks {
                    if mark_if_logged(t, col, &device, seq, &chain)? {
                        out.marks += 1;
                    }
                }
            }
            Ok(())
        };
        while let Some(item) = reader.next_item().map_err(|e| stream_refused(&e))? {
            match item {
                ExportItem::NativeLog {
                    device,
                    public,
                    count: _,
                } => {
                    finish_heritage(&mut heritage, &mut out)?;
                    land_relay(t, col, me, relay_of.take(), &mut relay, &mut out)?;
                    if let Some((Some(kind), _)) = kinds.get(&device) {
                        if *kind != DEV_NATIVE {
                            return Err(format!(
                                "gen4 import: {device} is a heritage log here but a native log in the file"
                            ));
                        }
                    }
                    if let Some(public) = public {
                        if learn_key(t, col, me, &device, public)? {
                            out.peers += 1;
                        }
                    }
                    out.native_logs += 1;
                    native = Some(NativeRun {
                        device,
                        local_last: t.last_of(col, &device)?,
                        next: 1,
                        chain: CHAIN_ZERO,
                    });
                }
                ExportItem::NativeOp(op) => {
                    let run = native.as_mut().ok_or("gen4 import: op outside a native log")?;
                    let seq = run.next;
                    let after = chain_next4(&run.chain, &op);
                    if seq <= run.local_last {
                        compare_native(t, col, &run.device, seq, &after)?;
                        out.native_known += 1;
                    } else {
                        if seq == run.local_last + 1 {
                            compare_native(t, col, &run.device, seq - 1, &run.chain)?;
                        }
                        let landed = t.append_native(col, &op)?;
                        if landed != after {
                            return Err(format!(
                                "gen4 import: {}:{seq} chained differently from the file",
                                run.device
                            ));
                        }
                        out.native_landed += 1;
                    }
                    run.next = seq + 1;
                    run.chain = after;
                }
                ExportItem::NativeVoid {
                    n,
                    chain_after,
                    marks,
                } => {
                    let run = native.as_mut().ok_or("gen4 import: void outside a native log")?;
                    let (start, end) = (run.next, run.next + n - 1);
                    if start <= run.local_last + 1 {
                        // 前一环（这一段之前的那一格）必须与本机的接得上；区间末在本机日志里的，末尾的链值也要相等。
                        compare_native(t, col, &run.device, start - 1, &run.chain)?;
                        if end <= run.local_last {
                            compare_native(t, col, &run.device, end, &chain_after)?;
                        }
                    }
                    if end > run.local_last {
                        // 越过本机末尾：只落多出来的那一截（本机已有的完整操作不因此被清掉）。
                        let from = start.max(run.local_last + 1);
                        t.append_native_void(col, &run.device, end - from + 1, &chain_after)?;
                        out.voids_landed += 1;
                    }
                    out.native_known += run.local_last.min(end).saturating_sub(start - 1);
                    // 区间内部的链值记号（第 2 版）：本机在那一格有链值就必须相同（与上面的区间末同一条判断）；本机那里也是
                    // 空洞内部、没有记号的才记下（[Truth::land_void_mark]）。
                    for (seq, chain) in &marks {
                        match t.chain_known(col, &run.device, *seq)? {
                            Some(_) => compare_native(t, col, &run.device, *seq, chain)?,
                            None => {
                                if t.land_void_mark(col, &run.device, *seq, chain)? {
                                    out.void_marks += 1;
                                }
                            }
                        }
                    }
                    run.next = end + 1;
                    run.chain = chain_after;
                }
                ExportItem::NativeTail(_) => {
                    land_relay(t, col, me, relay_of.take(), &mut relay, &mut out)?;
                    relay_of = native.take().map(|r| r.device);
                }
                ExportItem::NativeRelay { .. } => {}
                ExportItem::AuthorVersion { header, sig, voids } => {
                    relay_of.ok_or("gen4 import: author version outside a native log")?;
                    relay
                        .versions
                        .push(AuthorVersion { header, sig, voids });
                }
                ExportItem::Stub(stub) => {
                    relay_of.ok_or("gen4 import: stub outside a native log")?;
                    relay.stubs.push(stub);
                }
                ExportItem::HeritageLog {
                    source, device, ..
                } => {
                    finish_heritage(&mut heritage, &mut out)?;
                    land_relay(t, col, me, relay_of.take(), &mut relay, &mut out)?;
                    match kinds.get(&device) {
                        Some((Some(kind), _)) if *kind != DEV_HERITAGE => {
                            return Err(format!(
                                "gen4 import: {device} is a native log here but a heritage log in the file"
                            ));
                        }
                        Some((_, Some(src))) if *src != source => {
                            return Err(format!(
                                "gen4 import: the heritage log of {device} comes from {src} here but from {source} in the file"
                            ));
                        }
                        _ => {}
                    }
                    out.heritage_logs += 1;
                    heritage = Some((device, source, Vec::new()));
                }
                ExportItem::Mark { seq, chain } => {
                    let (_, _, marks) = heritage
                        .as_mut()
                        .ok_or("gen4 import: mark outside a heritage log")?;
                    marks.push((seq, chain));
                }
                ExportItem::Slot { t_version, slot } => {
                    let (_, source, _) = heritage
                        .as_ref()
                        .ok_or("gen4 import: slot outside a heritage log")?;
                    put_slot(t, col, source, &slot, t_version, &forks, &mut out)?;
                }
            }
        }
        finish_heritage(&mut heritage, &mut out)?;
        land_relay(t, col, me, relay_of.take(), &mut relay, &mut out)?;
        out.settled = settle_imported(t, col)?;
        Ok(out)
    })
}

/// 一条原生日志链尾之后的转发材料（流的第 3 版），整条读完再交 [land_relay]。
#[derive(Default)]
struct RelayBuf {
    versions: Vec<AuthorVersion>,
    stubs: Vec<Stub>,
}

/// 落一条原生日志（作者 [device]）的转发材料。文件不可信（第六波安全复核），所以：
///
/// - 作者签名版本：段头的作者必须是这条日志的作者；拿本机记着的这位作者的公钥（`peers`，导入流里同一设备撞上另一把
///   公钥时整笔已经拒了）、本机日志（这条日志此时已灌完）与剔除记录拼出全部项，**作者签名验得过才记**
///   （[Truth::vouch_author_version]）；记的时候照旧只换成空洞更多的那份（[Truth::note_author_version]）——验过的
///   才有资格替换本机已有的行，没验过的一律不碰本机。
/// - 剔除记录：属于这位作者、本机这一格是空洞、**被某个验过的版本的作者签名担保**（拼项时用到了它，即它的信封、载荷
///   哈希与清除目标正是作者签过的那条）才记，而且**本机已有的不换**（[Truth::put_stub_if_absent]；拼项时本机已有的
///   优先，文件里那条与本机不同就担保不了）。
/// - 本机自己的日志不记（收段同口径，`receive.rs`）。
///
/// 没记的计入 [ImportedOps::relay_skipped]，不报错（材料只是本机以后替作者重切用的缓存，缺了重切退回「缺」）。
fn land_relay(
    t: &Truth<'_>,
    col: i64,
    me: Option<(Id, [u8; 32])>,
    device: Option<Id>,
    buf: &mut RelayBuf,
    out: &mut ImportedOps,
) -> Result<(), String> {
    let RelayBuf { versions, stubs } = std::mem::take(buf);
    let Some(device) = device else {
        return Ok(());
    };
    if me.is_some_and(|(m, _)| m == device) {
        return Ok(());
    }
    // 候选剔除记录：这位作者的、本机这一格是空洞的；同一 seq 只认文件里的第一条。本机已经有这一格的剔除记录：
    // 不动（不算跳过，再导一遍同一份文件不报跳过）。
    let mut extra: BTreeMap<u64, Stub> = BTreeMap::new();
    for s in stubs {
        let id = s.id();
        if id.device == device && t.stub_at(col, &device, id.seq)?.is_some() {
            continue;
        }
        if id.device != device
            || !t.entry(col, &id)?.is_some_and(|e| e.op().is_none())
            || extra.contains_key(&id.seq)
        {
            out.relay_skipped += 1;
            continue;
        }
        extra.insert(id.seq, s);
    }
    let mut vouched: BTreeSet<u64> = BTreeSet::new();
    for v in versions {
        if v.header.device != device {
            out.relay_skipped += 1;
            continue;
        }
        match t.vouch_author_version(col, &v, &extra)? {
            Some(used) => {
                vouched.extend(used);
                t.note_author_version(col, &v)?;
                out.relay_versions += 1;
            }
            None => out.relay_skipped += 1,
        }
    }
    for (seq, s) in extra {
        if !vouched.contains(&seq) {
            out.relay_skipped += 1;
        } else if t.put_stub_if_absent(col, &s)? {
            out.relay_stubs += 1;
        }
    }
    Ok(())
}

/// 读流时的拒收理由：一条操作超过载荷上限（[crate::gen4::op::ERR_OP_TOO_LARGE]）单独说清楚（文件本身没坏，是这一条
/// 太大，Dart 导入页按它给专门的提示），其余按坏流报。两种都是整笔回滚、什么都没导入。
fn stream_refused(e: &str) -> String {
    match e.find(crate::gen4::op::ERR_OP_TOO_LARGE) {
        Some(at) => format!("gen4 import: {}; nothing was imported", &e[at..]),
        None => format!("gen4 import: corrupt export ({e})"),
    }
}

/// 灌入的收尾：从真相整个重建派生层（[Settle::Rebuild]），再把派生层判成「已清除」的操作在真相层落成空洞（同
/// `cmd/writes.rs` 的 `finish`、`receive.rs` 的收尾，[Index::execute_purges]）。灌进来的 `Purge` 由此在同一个事务里
/// 生效，不留到下一条写命令；落了空洞的会话提交之后由内核做字节层收尾（`scrub.rs`）。
fn settle_imported(t: &Truth<'_>, col: i64) -> Result<Settled, String> {
    let mut ix = Index::new(t, col);
    let settled = ingest_settle(t, &mut ix, col, Settle::Rebuild)?;
    ix.execute_purges()?;
    Ok(settled)
}

/// 本机这台设备原生日志在 [seq] 处的链值与流里的比：本机那格在空洞内部（没有链值）时比不了，不算分叉。
fn compare_native(
    t: &Truth<'_>,
    col: i64,
    device: &Id,
    seq: u64,
    want: &Chain,
) -> Result<(), String> {
    match t.chain_known(col, device, seq)? {
        Some(have) if have != *want => Err(format!(
            "gen4 import: the log of device {device} in the file diverges from this library at seq {seq} \
             (a cloned or rolled-back device); nothing was imported"
        )),
        _ => Ok(()),
    }
}

/// 只按语法读完整条 `FSRS4EXP` 流（不碰库），返回头。协议 3 的流（`FSRS2EXP`）与不认识的东西给出可读的拒绝理由。
/// 给想在动手之前先验文件的调用方用（[import_ops] 自己不再先读一遍：坏流在事务里同样整笔拒绝）。
pub fn check_ops_stream(bytes: &[u8]) -> Result<ExportHeader, String> {
    let (mut reader, header) = open_ops_stream(bytes)?;
    while reader
        .next_item()
        .map_err(|e| stream_refused(&e))?
        .is_some()
    {}
    Ok(header)
}

/// [own_fork_point] 每攒这么多项喂一次 [ForkScan]（内存不随本机日志长度增长）。
const FORK_SCAN_CHUNK: usize = 4096;

/// 流里本机当前身份那条原生日志的一块（[own_fork_point] 内部）。
struct ForkChunk {
    /// 这一块第一项的 seq 与它前一格的链值。
    first: u64,
    prev: Chain,
    /// 走到的 seq 与那一格的链值。
    seq: u64,
    chain: Chain,
    items: Vec<NativeItem>,
}

impl ForkChunk {
    fn new() -> ForkChunk {
        ForkChunk {
            first: 1,
            prev: CHAIN_ZERO,
            seq: 0,
            chain: CHAIN_ZERO,
            items: Vec::new(),
        }
    }

    fn flush(
        &mut self,
        t: &Truth<'_>,
        col: i64,
        scan: &mut ForkScan,
        collection: Id,
        device: Id,
    ) -> Result<(), String> {
        if self.items.is_empty() {
            return Ok(());
        }
        let h = NativeHeader {
            encrypted: false,
            collection,
            device,
            first: self.first,
            last: self.seq,
            prev_chain: self.prev,
            last_chain: self.chain,
        };
        scan.feed(t, col, &h, &self.items)?;
        self.items.clear();
        self.first = self.seq + 1;
        self.prev = self.chain;
        Ok(())
    }
}

/// 导入之前看流里**本机当前身份**的原生日志与本机日志分没分叉（G11-3；协议 3 `import_on` 的「包里有本机身份的操作时
/// 先换身份」，§7.3）。只读，按块喂 G8-6 的 [ForkScan]（与位置上发现分叉同一个判据）：
///
/// - 流里没有本机身份的日志、或它是本机日志的前缀：None，照常导入；
/// - 两边在某个 seq 上不同（数据目录被拷过、从旧备份还原后两边都写过），或流里比本机长（另一个安装接着写了）：
///   `Some(keep)` = 两边确认相同的最大 seq。调用方先 `Truth::rotate_identity(col, keep, now)`（本机 `keep` 之后的操作以
///   新身份重签发、旧身份冻结在 `keep`），再导入：流里旧身份 `keep` 之后的操作按普通设备接在冻结点后面。
///
/// 本机还没有身份（不会发生在已绑定的 profile 上）也是 None。读到本机那条日志的末尾就停，不读流的其余部分。
pub fn own_fork_point<R: Read>(
    t: &Truth<'_>,
    col: i64,
    opened: (Export4Reader<'_, R>, ExportHeader),
) -> Result<Option<u64>, String> {
    let Some(me) = t.self_identity(col)? else {
        return Ok(None);
    };
    let (mut reader, header) = opened;
    let mut scan = ForkScan::new(t, col)?;
    let mut mine: Option<ForkChunk> = None;
    while let Some(item) = reader.next_item().map_err(|e| stream_refused(&e))? {
        match item {
            ExportItem::NativeLog { device, .. } if device == me.device => {
                mine = Some(ForkChunk::new());
            }
            ExportItem::NativeOp(op) => {
                if let Some(c) = mine.as_mut() {
                    c.chain = chain_next4(&c.chain, &op);
                    c.seq += 1;
                    c.items.push(NativeItem::Op(op));
                }
            }
            ExportItem::NativeVoid { n, chain_after, .. } => {
                if let Some(c) = mine.as_mut() {
                    c.seq += n;
                    c.chain = chain_after;
                    c.items.push(NativeItem::Void {
                        count: n,
                        chain_after,
                    });
                }
            }
            ExportItem::NativeTail(_) => {
                if let Some(mut c) = mine.take() {
                    c.flush(t, col, &mut scan, header.collection, me.device)?;
                    // 每台设备在流里只有一条原生日志：本机的读完就够了。
                    break;
                }
            }
            _ => {}
        }
        if let Some(c) = mine.as_mut() {
            if c.items.len() >= FORK_SCAN_CHUNK {
                c.flush(t, col, &mut scan, header.collection, me.device)?;
            }
        }
    }
    Ok(scan.fork_point())
}

/// 认出 `FSRS4EXP` 流、读头：协议 3 的流（`FSRS2EXP`）与不认识的东西给出可读的拒绝理由。
fn open_ops_stream(bytes: &[u8]) -> Result<(Export4Reader<'_>, ExportHeader), String> {
    match sniff(bytes) {
        Ok(ExportKind::V4) => {}
        Ok(ExportKind::V1) => {
            return Err(
                "gen4 import: this is a version 1 (.fushisrs from protocol 3) stream; read it with the legacy importer"
                    .to_owned(),
            );
        }
        Err(e) => return Err(format!("gen4 import: not a Fushi SRS export ({e})")),
    }
    Export4Reader::open(bytes).map_err(|e| format!("gen4 import: unreadable export ({e})"))
}

/// 读入 `.fushisrs` 第 1 版的内核流（协议 3 的 `FSRS2EXP`，冻结读入器 `legacy_export.rs`），逐条转译（T）成承袭槽，
/// 并入集合 [col]。与 [import_ops] 同一套保证：一个事务、坏数据整个拒绝、再导一遍什么都不改。
///
/// - 包头的集合必须是本集合历史里的协议 3 集合（[legacy_sources]）：另一个集合的第 1 版包继续拒绝（D34）。
/// - 每台设备的操作从 seq 1 起连续（读入器核对），全部是作者已应用的前缀（协议 3 的导出只写这些），所以全部按
///   [Truth::put_heritage] 落：本机已有的按落库规则，其余接在末尾。每 [HERITAGE_MARK_EVERY] 条与每台设备的末尾记链值。
/// - 包里带的设备公钥记进 `peers`（与迁移灌入 `sync2_devices` 同口径）；已记过另一个公钥 = 坏数据，拒绝。
pub fn import_v1(t: &Truth<'_>, col: i64, bytes: &[u8]) -> Result<ImportedOps, String> {
    match sniff(bytes) {
        Ok(ExportKind::V1) => {}
        Ok(ExportKind::V4) => {
            return Err(
                "gen4 import: this is a version 2 (FSRS4EXP) stream; read it with import_ops"
                    .to_owned(),
            );
        }
        Err(e) => return Err(format!("gen4 import: not a Fushi SRS export ({e})")),
    }
    t.tx_immediate(|t| {
        check_v1_collection(t, col, bytes)?;
        let kinds: BTreeMap<Id, (Option<i64>, Option<Id>)> = t
            .devices(col)?
            .into_iter()
            .map(|d| (d.id, (d.kind, d.src)))
            .collect();
        let me = t.self_identity(col)?.map(|s| (s.device, s.public()));
        let forks = known_forks(t, col)?;
        let mut out = ImportedOps::default();
        // 当前设备与它最后一条的 (seq, 链值)：换设备 / 读完时记末尾的链值。
        let mut cur: Option<(Id, u64, Chain)> = None;
        let mut seen_keys: BTreeSet<Id> = BTreeSet::new();
        let stats = for_each_v1(bytes, |source, device, public, op, chain| {
            if cur.as_ref().map(|c| c.0) != Some(*device) {
                if let Some((d, seq, c)) = cur.take() {
                    if mark_if_logged(t, col, &d, seq, &c)? {
                        out.marks += 1;
                    }
                }
                match kinds.get(device) {
                    Some((Some(kind), _)) if *kind != DEV_HERITAGE => {
                        return Err(format!(
                            "gen4 import: {device} is a native log here but an old device in the file"
                        ));
                    }
                    Some((_, Some(src))) if src != source => {
                        return Err(format!(
                            "gen4 import: the heritage log of {device} comes from {src} here but from {source} in the file"
                        ));
                    }
                    _ => {}
                }
                if seen_keys.insert(*device) && public.len() == 32 {
                    let key: [u8; 32] = public.try_into().expect("checked length");
                    if learn_key(t, col, me, device, key)? {
                        out.peers += 1;
                    }
                }
            }
            let slot = translate(op, chain)
                .map_err(|m| format!("gen4 import: {}:{} {m}", op.id.device, op.id.seq))?;
            put_slot(t, col, source, &slot, T_VERSION, &forks, &mut out)?;
            if op.id.seq % HERITAGE_MARK_EVERY == 0 && mark_if_logged(t, col, device, op.id.seq, chain)? {
                out.marks += 1;
            }
            cur = Some((*device, op.id.seq, *chain));
            Ok(())
        })
        .map_err(|e| {
            if e.starts_with("gen4 ") {
                e
            } else {
                format!("gen4 import: corrupt version 1 export ({e})")
            }
        })?;
        if let Some((d, seq, c)) = cur.take() {
            if mark_if_logged(t, col, &d, seq, &c)? {
                out.marks += 1;
            }
        }
        // 没有操作的设备抬头也算进来（读入器不为它们回调）。
        out.heritage_logs = stats.devices;
        out.settled = settle_imported(t, col)?;
        Ok(out)
    })
}

/// 旧备份（协议 3 的整包备份 / 服务端备份里的 `srs.db`）读入：把 [profile] 在旧库 [src] 里的操作转译进集合 [col]
/// （设计 §5.4 第 6 条、§6.3「旧 `.fushisrs` / 旧备份里的复习数据」）。
///
/// [src] 必须是调用方用冻结代码在**临时副本**上备好的协议 3 库（G7-6 的 `open_legacy_scratch`：跑完 schema 阶梯、补上
/// 备份剥掉的 `sync2_self`、旧事件包成操作、去重作业做完）。这里只核对、不代做：[legacy::preflight] 有一项不齐就拒绝，
/// 原因逐条列出，什么都不写。
///
/// - 一个事务（不像迁移那样分批提交）：落进的是正在用的集合，派生层必须与真相同一个事务收好；崩溃 = 没发生过，
///   重来与一次做完相同（已有的槽幂等）。
/// - 旧 uid 的集合必须是本集合历史里的（[legacy_sources]），否则拒绝。
/// - 待投递的旧操作照迁移的口径进 `op_pending`（备份快照本来就剥掉了它们，通常没有）。
/// - 信任：只为本机**从没见过**的设备带上备份里的「待确认 / 已拒绝」（保守：不执行它的删除，用户之后可以放行）；
///   本机已有日志或已有信任状态的设备不动——本机的信任是本机的决定，旧备份不能改它。
/// - 设备公钥与名字：`sync2_devices` → `peers`（[backup_peers]，与迁移同一份整理），同一个事务。
/// - 事务外调时自己开 `BEGIN IMMEDIATE`（同 [import_ops]）。
pub fn import_backup(
    src: &Connection,
    profile: &str,
    t: &Truth<'_>,
    col: i64,
) -> Result<Imported, String> {
    let blockers = legacy::preflight(src, profile)?;
    if !blockers.is_empty() {
        return Err(format!(
            "gen4 import: the backup library is not ready (prepare it with the frozen reader first): {}",
            blockers.join("; ")
        ));
    }
    t.tx_immediate(|t| {
        if !legacy_sources(t, col)?.contains(&collection_of(profile)) {
            return Err(format!(
                "gen4 import: profile {profile} in the backup belongs to another collection"
            ));
        }
        let untrusted = legacy::untrusted(src, profile)?;
        let unknown: Vec<(Id, i64, i64)> = {
            let mut v = Vec::new();
            for (device, state, since) in untrusted {
                if t.last_of(col, &device)? == 0 && t.trust_of(col, &device)?.is_none() {
                    v.push((device, state, since));
                }
            }
            v
        };
        let mut out = Imported::default();
        land_legacy(src, profile, t, col, &mut out, &mut || Ok(()))?;
        for (device, state, since) in unknown {
            t.set_trust(col, &device, Some(state), since)?;
            out.untrusted += 1;
        }
        out.peers = backup_peers(src, profile, t, col)?;
        settle_imported(t, col)?;
        Ok(out)
    })
}

/// 旧备份里的设备公钥与名字（`sync2_devices` → `peers`，与迁移的 `carry.rs` 同一份整理 [legacy_peers]）。协议 3 段的
/// 收段（`receive.rs`）与承袭段的上传者核对（`inherit.rs`）都要它：漏了，覆盖还原（空库 + 并入，D34）之后位置上的
/// 协议 3 段会因为不认识签名者一直暂缓——协议 3 整文件替换时 `sync2_devices` 是保留的。
///
/// - 公钥先到先得：本机已记过另一个公钥 = 冒名 / 坏数据，整个读入拒绝（与 [learn_key] 同口径）；文件里的设备就是本机
///   当前身份时，公钥必须就是本机的（相同则不进 `peers`，本机的公钥在 `self_`）。
/// - 名字 / 扩展信息只补空缺：本机已有的是本机后来从 head 学到的，比备份新，不拿旧值盖它。
/// - 备份副本自己的 `sync2_self`：快照剥掉了它（`store/mod.rs` 的 `snapshot_into`），副本里的是备副本时现补的临时
///   身份。它一条都没写过时（通常如此）不带——没签过任何段，公钥用不上，带了只会在设备清单里多一台不存在的设备；
///   写过（备副本时把旧事件包成了它的操作）就和别的设备一样带，它在承袭日志里确有其名。
///
/// 返回新记下的设备数。
fn backup_peers(src: &Connection, profile: &str, t: &Truth<'_>, col: i64) -> Result<u64, String> {
    let me = t.self_identity(col)?.map(|s| (s.device, s.public()));
    let scratch = legacy_self(src, profile)?
        .filter(|s| s.last == 0)
        .map(|s| s.device);
    let (peers, _) = legacy_peers(src, profile)?;
    let peers = peers
        .into_iter()
        .filter(|p| Some(p.device) != scratch)
        .collect();
    land_peers(t, col, me, peers, "backup")
}

/// 记下 `.fushisrs` 第 2 版清单带的设备（缺口 G-12，G11-3 定案：`FSRS4EXP` 的承袭日志抬头不带公钥，协议 3 设备的公钥
/// 放在清单的 `peers` 里随文件走，格式不升版本）。与旧备份读入（[backup_peers]）同一口径：公钥先到先得、冲突整个拒绝、
/// 本机身份必须是本机的公钥、名字 / 扩展信息只补空缺。在调用方的事务里调（导入命令与 [import_ops_from] 同一个事务）。
///
/// 返回新记下的设备数。
pub fn import_peers(t: &Truth<'_>, col: i64, peers: Vec<Peer>) -> Result<u64, String> {
    let me = t.self_identity(col)?.map(|s| (s.device, s.public()));
    land_peers(t, col, me, peers, "file")
}

/// [backup_peers] / [import_peers] 共用的落库（[what] 只进报错文本）。
fn land_peers(
    t: &Truth<'_>,
    col: i64,
    me: Option<(Id, [u8; 32])>,
    peers: Vec<Peer>,
    what: &str,
) -> Result<u64, String> {
    let mut learned = 0u64;
    for mut peer in peers {
        if let Some((mine, key)) = me {
            if mine == peer.device {
                if key != peer.public {
                    return Err(format!(
                        "gen4 import: the {what} carries another public key for this device ({mine})"
                    ));
                }
                continue;
            }
        }
        if let Some(cur) = t.peer(col, &peer.device)? {
            if cur.name.is_some() {
                peer.name = None;
            }
            if cur.ext.is_some() {
                peer.ext = None;
            }
        }
        match t.set_peer(col, &peer)? {
            PeerPut::KeyMismatch => {
                return Err(format!(
                    "gen4 import: device {} is already known with another public key",
                    peer.device
                ));
            }
            PeerPut::Inserted => learned += 1,
            PeerPut::Updated | PeerPut::Same => {}
        }
    }
    Ok(learned)
}

#[cfg(test)]
#[path = "import_tests.rs"]
mod import_tests;

#[cfg(test)]
mod tests {
    use std::time::Instant;

    use serde_json::{Value, json};

    use super::*;
    use crate::gen4::heritage::HeritageSlot;
    use crate::gen4::translate::SlotSet;
    use crate::store::gen4::legacy::tests::{
        T0, device, device_id, migrate, pair, peak_mem_mb, read_all, sample,
    };
    use crate::store::gen4::schema::{open, open_in_memory, table_bytes};
    use crate::store::sync2::tests::{Bucket, DAY, Device, P, edit, legacy_library, tempdir};
    use crate::sync2::id::Id;

    fn bind(t: &Truth<'_>) -> i64 {
        t.tx(|t| t.bind(P, &collection_of(P), P)).unwrap()
    }

    fn import(d: &Device, t: &Truth<'_>, col: i64, batch: u64) -> Result<Imported, String> {
        let w = d.core.writer().unwrap();
        import_legacy(&w, P, t, col, batch)
    }

    /// 新库里的全部槽（主支），并成集合。
    fn stored(t: &Truth<'_>, col: i64) -> SlotSet {
        let mut set = SlotSet::new();
        for d in t.devices(col).unwrap() {
            t.for_each(col, &d.id, 1, |e| {
                set.insert(e.slot().expect("heritage slot"))
                    .map_err(|e| e.to_string())
            })
            .unwrap();
        }
        set
    }

    #[test]
    fn a_legacy_library_lands_slot_for_slot_and_twice_is_once() {
        let (a, b, _) = pair();
        let (want, pending, _) = read_all(&a);
        assert!(pending.is_empty());
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bind(&t);
        // 批很小：中途提交过很多次。
        let got = import(&a, &t, col, 3).unwrap();
        assert_eq!(got.applied as usize, want.len());
        assert_eq!((got.inserted, got.same, got.pending), (got.applied, 0, 0));
        assert_eq!(got.ops + got.raw + got.alias + got.voids, got.applied);
        assert_eq!(stored(&t, col), want);
        assert_eq!(t.audit(col).unwrap(), got.applied);
        // 每条日志的末尾记了完整原链值，且与末尾那个槽的链指纹相符（set_mark 自己核对）。
        for d in t.devices(col).unwrap().iter().filter(|d| d.last > 0) {
            assert_eq!(d.src, Some(collection_of(P)));
            let marks = t.marks(col, &d.id).unwrap();
            assert_eq!(marks.last().map(|m| m.0), Some(d.last));
        }
        // 再灌一遍、把另一台收全了的设备的库也灌进来：全是「已有」。
        for d in [&a, &b] {
            let again = import(d, &Truth::new(&conn), col, 1000).unwrap();
            assert_eq!((again.inserted, again.same), (0, got.applied));
        }
        assert_eq!(stored(&Truth::new(&conn), col), want);
    }

    #[test]
    fn a_library_that_purged_does_not_take_content_away_from_one_that_has_not() {
        let (a, b, mut bucket) = pair();
        let (whole, _, _) = read_all(&b);
        a.core.sync2_purge(P, "note", "N1", T0 + 2 * DAY).unwrap();
        a.sync(&mut bucket, "loc", T0 + 2 * DAY);
        let (purged, _, _) = read_all(&a);
        assert_ne!(whole, purged);
        // 先灌没清除的（b），再灌清除过的（a）：b 有的操作号本机不动；a 多出来的（Purge 操作本身）接上。
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bind(&t);
        import(&b, &t, col, 1000).unwrap();
        let again = import(&a, &t, col, 1000).unwrap();
        assert!(again.kept > 0 && again.inserted > 0, "{again:?}");
        let got = stored(&t, col);
        for s in whole.iter() {
            assert!(got.iter().any(|x| x == s), "{:?} changed", s.id);
        }
        assert_eq!(got.len(), purged.len());
        // 反过来（本机还没有这些槽）：收什么留什么。
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bind(&t);
        import(&a, &t, col, 1000).unwrap();
        let again = import(&b, &t, col, 1000).unwrap();
        assert!(again.kept > 0 && again.inserted == 0, "{again:?}");
        assert_eq!(stored(&t, col), purged);
    }

    #[test]
    fn pending_ops_stay_pending_and_deliver_in_chain_order() {
        let (a, b) = (device(), device());
        let mut bucket = Bucket::default();
        for i in 0..6 {
            let at = T0 + i * 600_000;
            a.apply(at, vec![edit("note", "N1", "f/x", json!(format!("a{i}")))]);
            a.sync(&mut bucket, "loc", at);
            b.sync(&mut bucket, "loc", at);
            b.apply(
                at + 1,
                vec![edit("note", "N1", "f/x", json!(format!("b{i}")))],
            );
            b.sync(&mut bucket, "loc", at + 1);
            a.sync(&mut bucket, "loc", at + 1);
        }
        // 新设备只拿到 b 的段：b 的操作依赖 a 的，投不了，进待投递（与 legacy.rs 的同名情形相同）。
        let now = T0 + 9 * DAY;
        let c = device();
        c.core.sync2_identity(P, now).unwrap();
        let heads: Vec<Vec<u8>> = bucket
            .0
            .iter()
            .filter(|(k, _)| k.contains("/head-"))
            .map(|(_, v)| v.clone())
            .collect();
        let plan = c.core.sync2_plan(P, &heads).unwrap();
        let b_dev = device_id(&b);
        let files: Vec<Vec<u8>> = plan["fetch"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|f| f["files"].as_array().unwrap().iter())
            .map(|n| n.as_str().unwrap())
            .filter(|n| n.contains(&b_dev.text()))
            .map(|n| bucket.0[n].clone())
            .collect();
        let out: Value =
            serde_json::from_str(&c.core.sync2_ingest(P, &files, None, now).unwrap()).unwrap();
        let (_, pending, _) = read_all(&c);
        assert!(!pending.is_empty(), "{out}");

        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bind(&t);
        let got = import(&c, &t, col, 1000).unwrap();
        assert_eq!(got.pending as usize, pending.len());
        assert_eq!(got.parked, got.pending);
        // 它们从 b 的第一条起一条接一条，协议 3 的链逐条验得出。
        assert_eq!(got.pending_linked, got.pending);
        let parked = t.pending(col).unwrap();
        assert_eq!(
            parked
                .iter()
                .map(|p| p.slot.clone())
                .collect::<Vec<HeritageSlot>>(),
            pending
        );
        // 待投递的不在日志里；逐条按链指纹核对着投（因果上该不该投是同步轮的事，这里只验存储一侧接得上）。
        let mut delivered = 0;
        while let Some(p) = t.pending_ready(col, &b_dev).unwrap() {
            assert_eq!(
                t.tx(|t| t.put_heritage(col, &collection_of(P), &p.slot, p.tv)),
                Ok(Put::Inserted)
            );
            delivered += 1;
        }
        assert_eq!(delivered, pending.len());
        assert_eq!(t.pending(col).unwrap(), Vec::new());
        // 投完之后 b 的日志与 b 自己库里转出来的那一段逐槽相同。
        let (author, _, _) = read_all(&b);
        let mut mine = Vec::new();
        t.for_each(col, &b_dev, 1, |e| {
            mine.push(e.slot().unwrap());
            Ok(())
        })
        .unwrap();
        let theirs: Vec<HeritageSlot> = author
            .iter()
            .filter(|s| s.id.device == b_dev)
            .take(mine.len())
            .cloned()
            .collect();
        assert_eq!(mine, theirs);
        assert_eq!(t.audit(col).unwrap() as usize, mine.len());
    }

    #[test]
    fn a_library_that_is_not_fully_on_protocol_3_is_refused_and_nothing_lands() {
        // 还有旧事件没包成操作的库过不了 preflight。
        let d = Device::new("g6raw");
        legacy_library(&d);
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = bind(&t);
        {
            let w = d.core.writer().unwrap();
            let e = import_legacy(&w, P, &t, col, 100).unwrap_err();
            assert!(e.contains("not ready"), "{e}");
            assert_eq!(t.devices(col).unwrap(), Vec::new());
            // 在事务里调也拒绝。
            let e = t.tx(|t| import_legacy(&w, P, t, col, 100)).unwrap_err();
            assert!(e.contains("inside a transaction"), "{e}");
        }
        // 在旧代码上把迁移与去重作业做完之后就能灌：迁移出来的旧修改带旧戳，旧戳摘出来另存、读回逐字节相同。
        migrate(&d);
        for _ in 0..1000 {
            if d.core.sync2_dedup(P, T0).unwrap()["done"] == json!(true) {
                break;
            }
        }
        let (want, _, stats) = read_all(&d);
        assert!(stats.stamps >= 2, "{stats:?}");
        let got = import(&d, &t, col, 100).unwrap();
        assert_eq!(got.inserted as usize, want.len());
        assert_eq!(stored(&t, col), want);
        let stamped: i64 = conn
            .query_row(
                "SELECT (SELECT COUNT(*) FROM ops WHERE flags & 4) + (SELECT COUNT(*) FROM op_alias WHERE stamp IS NOT NULL)",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(stamped as u64, stats.stamps);
        assert!(
            conn.query_row("SELECT COUNT(*) FROM writers", [], |r| r.get::<_, i64>(0))
                .unwrap()
                > 0
        );
    }

    #[test]
    fn the_two_generations_refuse_each_others_files() {
        // 新代文件被协议 3 的内核当成自己的库打开：报「比本版本新」，文件里的表不变。
        let dir = tempdir::new("g6file");
        let path = dir.0.join("srs4.db");
        {
            let conn = open(&path).unwrap();
            let t = Truth::new(&conn);
            let col = bind(&t);
            let (a, _, _) = pair();
            import(&a, &t, col, 1000).unwrap();
        }
        let tables = |p: &std::path::Path| -> Vec<String> {
            let c = Connection::open(p).unwrap();
            let mut stmt = c
                .prepare("SELECT name FROM sqlite_schema ORDER BY name")
                .unwrap();
            let rows = stmt.query_map([], |r| r.get(0)).unwrap();
            rows.map(Result::unwrap).collect()
        };
        let before = tables(&path);
        let e = match crate::store::SrsCore::open(&path) {
            Ok(_) => panic!("the protocol 3 kernel opened a generation 4 file"),
            Err(e) => e,
        };
        assert!(e.contains("newer than this build"), "{e}");
        assert_eq!(tables(&path), before);
        let conn = open(&path).unwrap();
        let t = Truth::new(&conn);
        let col = t.binding_of(P).unwrap().unwrap().col;
        assert!(t.audit(col).unwrap() > 0);
        // 协议 3 的库被当成新代文件打开：拒绝，什么都不建。
        let old = Device::new("g6old");
        let old_path = old._dir.0.join("srs.db");
        let before = tables(&old_path);
        let e = open(&old_path).unwrap_err();
        assert!(e.contains("not a generation 4 library"), "{e}");
        assert_eq!(tables(&old_path), before);
    }

    /// 在真实库的私有拷贝上把全部旧操作灌进一个新代文件：体积（分表）、耗时、峰值内存，然后逐槽读回与转译结果比。
    ///
    /// `FUSHI_GEN4_SAMPLE_DB=<srs.db 的私有拷贝> [FUSHI_GEN4_OUT=<新文件放哪>] cargo test --release --lib gen4_sample_import -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn gen4_sample_import() {
        let Some(src) = sample() else {
            println!("FUSHI_GEN4_SAMPLE_DB not set");
            return;
        };
        let keep = std::env::var("FUSHI_GEN4_OUT").ok();
        let dir = tempdir::new("g6sample");
        let path = match &keep {
            Some(p) => std::path::PathBuf::from(p),
            None => dir.0.join("srs4.db"),
        };
        for suffix in ["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
        }
        let (ws0, commit0) = peak_mem_mb();
        println!("SAMPLE import start peak_working_set_mb {ws0:.0} peak_commit_mb {commit0:.0}");
        let dst = open(&path).unwrap();
        let t = Truth::new(&dst);
        let started = Instant::now();
        let mut cols = Vec::new();
        for profile in legacy::profiles(&src).unwrap() {
            let col = t
                .tx(|t| t.bind(&profile, &collection_of(&profile), &profile))
                .unwrap();
            let got = import_legacy(&src, &profile, &t, col, 20_000).unwrap();
            println!("SAMPLE import profile {profile} {got:?}");
            cols.push((profile, col, got));
        }
        let import_s = started.elapsed().as_secs_f64();
        let (ws1, commit1) = peak_mem_mb();
        dst.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)")
            .unwrap();
        let checkpoint_s = started.elapsed().as_secs_f64() - import_s;
        let file = std::fs::metadata(&path).unwrap().len();
        println!(
            "SAMPLE import elapsed_s {import_s:.1} checkpoint_s {checkpoint_s:.1} file_bytes {file} peak_working_set_mb {ws1:.0} peak_commit_mb {commit1:.0}"
        );
        for (name, bytes) in table_bytes(&dst) {
            println!("SAMPLE table {name} {bytes}");
        }
        for table in [
            "ops",
            "op_alias",
            "op_voids",
            "op_deps",
            "writers",
            "snapshots",
            "log_marks",
            "op_pending",
            "op_forks",
            "devs",
        ] {
            let n: i64 = dst
                .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
                .unwrap();
            println!("SAMPLE rows {table} {n}");
        }
        for (what, q) in [
            (
                "ops_zstd",
                "SELECT COUNT(*), COALESCE(SUM(LENGTH(body)), 0) FROM ops WHERE flags & 2",
            ),
            (
                "ops_stamp",
                "SELECT COUNT(*), COALESCE(SUM(LENGTH(aux)), 0) FROM ops WHERE flags & 4",
            ),
            (
                "ops_snap",
                "SELECT COUNT(*), COALESCE(SUM(LENGTH(aux)), 0) FROM ops WHERE flags & 8",
            ),
            (
                "ops_body",
                "SELECT COUNT(*), COALESCE(SUM(LENGTH(body)), 0) FROM ops",
            ),
            (
                "alias_stamp",
                "SELECT COUNT(*), COALESCE(SUM(LENGTH(stamp)), 0) FROM op_alias WHERE stamp IS NOT NULL",
            ),
            (
                "alias_stamp_wire",
                "SELECT COUNT(*), COALESCE(SUM(LENGTH(stamp)), 0) FROM op_alias WHERE flags & 2",
            ),
            (
                "writers",
                "SELECT COUNT(*), COALESCE(SUM(LENGTH(name)), 0) FROM writers",
            ),
            (
                "snapshots",
                "SELECT COUNT(*), COALESCE(SUM(LENGTH(body)), 0) FROM snapshots",
            ),
            (
                "deps",
                "SELECT COUNT(*), COALESCE(SUM(LENGTH(bytes)), 0) FROM op_deps",
            ),
        ] {
            let (n, bytes): (i64, i64) = dst
                .query_row(q, [], |r| Ok((r.get(0)?, r.get(1)?)))
                .unwrap();
            println!("SAMPLE {what} rows {n} bytes {bytes}");
        }
        // 以下是探针自己的开销（核对），不是灌入的一部分：重新转译一遍，逐槽与新库里读出来的比。
        let started = Instant::now();
        let t = Truth::new(&dst);
        let (mut same, mut diff, mut parked_same) = (0u64, 0u64, 0u64);
        for (profile, col, got) in &cols {
            assert_eq!(t.audit(*col).unwrap(), got.applied);
            let parked = t.pending(*col).unwrap();
            for d in legacy::devices(&src, profile).unwrap() {
                let device: Id = d.device;
                legacy::for_each_op(&src, profile, &device, |op, chain, placement| {
                    let want = translate(op, chain).map_err(str::to_owned)?;
                    match placement {
                        Placement::Applied => {
                            let have = t.entry(*col, &want.id)?.and_then(|e| e.slot());
                            if have.as_ref().map(HeritageSlot::encode) == Some(want.encode()) {
                                same += 1;
                            } else {
                                diff += 1;
                            }
                        }
                        Placement::Pending => {
                            if parked.iter().any(|p| p.slot == want) {
                                parked_same += 1;
                            } else {
                                diff += 1;
                            }
                        }
                    }
                    Ok(())
                })
                .unwrap();
            }
        }
        let (ws2, commit2) = peak_mem_mb();
        println!(
            "SAMPLE verify slots_same {same} pending_same {parked_same} different {diff} elapsed_s {:.1} peak_working_set_mb {ws2:.0} peak_commit_mb {commit2:.0}",
            started.elapsed().as_secs_f64()
        );
        assert_eq!(diff, 0);
        if keep.is_some() {
            println!("SAMPLE kept {}", path.display());
        }
    }
}
