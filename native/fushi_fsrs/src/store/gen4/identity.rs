//! 身份（设计 §5.1、§5.4；规划 §1.6，G9-3）：绑定状态、并入（`Join`，种类 14）与改绑、外来数据该怎么认
//! （[adopt_foreign]）、派生表 `join_ix`。命令外壳（`collection_join` / `collection_salts_add` / `collection_adopt` /
//! `binding_set` 等）在 `cmd/identity.rs`（G9-4），绑定变化由那里交给分发器在提交后发。
//!
//! # 并入的方向（D27）
//!
//! 两个集合 A、B 被确认为同一个库时，**位置目录名较大的并入较小的**（按 UTF-8 字节比；目录名相同而集合标识不同是坏
//! 数据，报错）。设 B 并入 A：
//!
//! - 本机绑着 B（[Truth::join]，或 [adopt_foreign] 里对方目录名更小）：在本机原生日志里写
//!   `Join{from: B, dir: B 的目录名, 盐表: B 现在的盐集合}`，同一个事务里把本机集合号改绑到 A（[Truth::rebind]）。
//!   集合号、操作、信任、暂扣、本机身份都不动——操作号全局唯一，B 的操作原样归到 A 名下（设计 §5.4 第 2 条）。
//! - 本机绑着 A（[adopt_foreign] 里对方目录名更大）：写 `Join{from: B, dir, 盐表: 调用方给的 B 的盐}`，绑定不动。
//!
//! 两台设备同时从两边发起，结果都是「绑在 A、A 里有一条 from = B 的 Join」，盐集合相同（测试
//! `both_sides_converge_whichever_initiates`）。写 Join 的一侧负责把 B 的盐整份带上（`from` / `dir` 不算盐，
//! `gen4::op` 文件头「盐集合」）。
//!
//! # 事务、崩溃与并发
//!
//! [Truth::join] 与 [adopt_foreign] 各自是一个事务（[Truth::tx]，可以嵌在调用方的事务里，那时是一个 SAVEPOINT）：
//! Join 操作、链尾、`self_.hlc`、改绑、派生层（`salt_ix` / `join_ix` / 别名表 / 缓存）一起提交或一起不落。
//! 任何一步报错整笔回滚（测试 `a_failure_after_the_join_is_written_rolls_everything_back`、
//! `a_crash_mid_join_commits_nothing`）。它们自己开 [Index]、收尾用 [ingest_settle]：调用方手里同一个集合的 [Index]
//! 若攒着没收的批，先收掉再调这里。
//!
//! 判定（同一个集合 / 已经并入过 / 要不要写）在事务里、从库里现读：另一个连接先提交了同一次并入，这边就答
//! `Same` / `AlreadyJoined`，不会写第二条 Join（测试 `two_connections_adopt_the_same_foreign_collection_once`）。
//! 新代下只有主进程写（D10），这里不另加锁。
//!
//! # 绑定变化的事件（规划缺口 G-4）
//!
//! 内核在 `join` / `bind` **提交后**往事件流发 `binding_changed{profile}`，Dart 的 `SrsDbStore.onBindingChanged()`
//! 据此让缓存的四个 ID 失效。这一层在事务里，不知道最外层什么时候提交，也还没有事件流可发（内核的事件流随 S1 / G9-4
//! 接线）：凡是改了绑定（集合标识、目录名或盐集合）的结果都带一个 [BindingChanged]，由命令层在最外层提交成功之后发出；
//! 回滚了就丢掉。这是对规划 §1.6「`Truth::join` 结束时发 `binding_changed`」的有意偏离，已写回规划 §1.6 / 缺口 G-4。
//!
//! 命令层取事件一律经 [AdoptOutcome::binding_changed] / [JoinWritten::changed]，不逐个分支拆；「带事件 ⇔ 绑定真的变了」
//! 对每个结论都成立（测试 `every_outcome_reports_a_binding_change_exactly_when_the_binding_changed`），漏发只可能出在
//! 命令层没在提交后发——G9-4 对每个改绑定的命令要有对应测试。
//!
//! # 空集合可换绑（G9-5，规划 §6 合并条件）
//!
//! 全新 profile 在第一次 `identity`（打开 profile）时就建了集合并绑定（G9-4 定案 1），之后 [adopt_foreign] 遇到另一个
//! 集合只能并入：本机目录名较小时按 D27 是对方并入本机，别的设备看到 `Join` 还要再确认一次（D25）——「新设备加入已有
//! 集合」在 app 里走不到设计 §5.4 第 5 条的「先加入」。所以：确认之后，本机这个集合若是**空集合**
//! （`discard.rs` [disposable]：日志只有本机身份写的 `Salts`、没有别的设备、从没发布到任何位置），同一个事务里丢掉它
//! （[discard_collection]）、把 profile 直接绑到对方，结论 [AdoptOutcome::Bound]，不写 `Join`；本机身份由命令层在对方
//! 集合里重建（`cmd/identity.rs` `collection_adopt`）。派生层配置（`derive_cfg`：Dart 按 profile 给的缓存配置）照搬到
//! 新集合号。不是空集合的照旧按 D27 并入。没确认之前一律 `NeedsConfirm`、什么都不动（与以前相同）。
//!
//! **只在 D27 的方向上换绑**（G9-5 第二轮复核）：只有本机目录名**更大**（D27 本来就是本机并入对方、改绑到对方）时
//! 空集合才直接换绑；本机目录名更小时即使是空集合也照 D27 写 `Join` 让对方并入本机。这样换绑的结果与 D27 完全一致
//! （都落在目录名较小的那个集合），只是省掉那条 `Join`：两台都是空集合的设备互相确认，一边换绑、一边吸收，收敛到
//! 同一个集合，不会交叉换绑（测试 `two_empty_collections_converge_whichever_initiates`）。新 profile 的目录名是它
//! 自己的 uid（UUIDv7，按时间递增）：「新设备加入已有集合」的常见情形本机目录名更大，照样换绑、不用别的设备再确认。
//!
//! # 方向固定的吸收（[absorb_foreign]）
//!
//! 迁移带过来的半截并入收尾（`cmd/profile_data.rs` `profile_merge_commit`）不走 [adopt_foreign]：用户当初在关联页
//! 选定的目标就是 `to`，`to` 的集合是用户别的设备在用的那个，**绝不改绑**。[absorb_foreign] 不按 D27 定方向、不做
//! 空集合换绑：一律在 `to` 的日志里写 `Join{from: 被并入的集合}`、`to` 的集合标识与目录名不变（测试
//! `cmd/profile_data_tests.rs` 的 `finishing_a_half_done_merge_never_rebinds_the_target`）。
//!
//! # 已经并入过
//!
//! `join_ix(col, k, src, dir)`：日志里每条 `Join` 一行（被并入的集合标识、它的目录名；盐在 `salt_ix`）。派生表：
//! [Index::add] / [Index::remove] 逐条维护，[Index::rebuild_all] 重建（逐行相同）。「算不算数」与盐集合同一个口径：
//! 作者是本机**信任的**设备（[JoinRow::trusted]，读时现判，所以信任变了不用重算这张表）。`Join` 不会被清成空洞
//! （`Truth::advance_purge` 拒绝），别的设备传来的空洞没有操作体、不进这张表。

use std::cmp::Ordering;
use std::collections::BTreeSet;

use rusqlite::params;

use super::derive::{Index, Settled};
use super::discard::{discard_collection, disposable};
use super::ingest::{Settle, ingest_settle};
use super::native::Native;
use super::schema::sql;
use super::truth::{Binding, Truth};
use crate::gen4::op::{Body4, Join4, SALTS_MAX};
use crate::sync2::id::Id;
use crate::sync2::segment::Chain;
use crate::sync2::vv::OpId;

/// 绑定变了：命令层在最外层事务提交之后发 `binding_changed{profile}`（文件头「绑定变化的事件」）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BindingChanged {
    pub profile: String,
    pub col: i64,
}

/// `join_ix` 的一行：日志里的一条 `Join`。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JoinRow {
    /// 这条 `Join` 的操作号（作者 = 写它的设备）。
    pub op: OpId,
    /// 被并入的集合标识。
    pub from: Id,
    /// 它的位置目录名。
    pub dir: String,
    /// 它带的盐表（按字节升序）。
    pub salts: Vec<String>,
    /// 作者是本机信任的设备：只有这样的 `Join` 算数（与盐集合同口径，设计 §5.1）。
    pub trusted: bool,
}

/// 一次并入写下了什么。
#[derive(Clone, Debug, PartialEq)]
pub struct JoinWritten {
    pub col: i64,
    /// 那条 `Join` 的操作号与链值。
    pub op: OpId,
    pub chain: Chain,
    /// 写进去的 `Join`。
    pub join: Join4,
    /// 本机改绑了（本机原来的集合并入对方）；false = 对方并入本机，绑定的集合不变。
    pub rebound: bool,
    /// 写完之后的绑定。
    pub binding: Binding,
    pub settled: Settled,
    /// 绑定变了（文件头「绑定变化的事件」）。
    pub changed: Option<BindingChanged>,
}

/// 外来数据声明的身份：导入的 `.fushisrs` 第 2 版清单、整包备份、位置上读到的 `meta.json` + 盐（设计 §5.4 第 6 条）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Foreign {
    /// 集合标识。
    pub collection: Id,
    /// 位置目录名：这个集合在位置上的目录名（它 `meta.json` 所在的那一级），**不是**备份 / 导出文件里记的旧 profile
    /// uid。同一个集合在另一个旧 uid 下的备份（设计 §5.4 第 6 条「只写 Salts」）要这样构造：`collection` = 清单里的
    /// 集合标识、`dir` = 它的位置目录名、旧 uid 放进 `salts`；把旧 uid 当 `dir` 传进来，同一个集合会因目录名不一致被
    /// 拒（坏数据），而不是补盐（测试 `a_backup_under_an_old_uid_passes_the_uid_as_a_salt`）。G11-3 / G11-4 照此构造。
    pub dir: String,
    /// 它的盐集合（可以为空：从位置上看到、还没读到它的操作时）。
    pub salts: BTreeSet<String>,
}

/// [adopt_foreign] 的结论。判据只在这一处写（规划 §1.1：同一个集合 / 另一个集合 / 已经并入过）。
#[derive(Clone, Debug, PartialEq)]
pub enum AdoptOutcome {
    /// 就是本机这个集合，对方的盐本机都已算数：什么都没写。
    Same,
    /// 对方是早已并入本机这个集合的集合（日志里有受信作者写的 from = 它的 `Join`），盐也都算数：什么都没写。
    AlreadyJoined,
    /// 另一个集合，调用方还没拿到用户的确认（BUG-4011 / D25：确认之前不绑定、不并入）：什么都没写。
    NeedsConfirm,
    /// 这个 profile 还没绑过集合，或绑着的是空集合（文件头「空集合可换绑」，那个空集合同一个事务里丢掉）：确认后直接
    /// 绑到对方（设计 §5.4 第 5 条「先加入」）。没有写任何操作；[col] 是新的本机集合号。[carry]：换绑丢掉的空集合里
    /// 本机声明过、对方还不算数的盐（只在换绑时非空）：命令层建好本机身份后在对方集合里另写一条 `Salts` 带过去
    /// （`cmd/identity.rs` `collection_adopt`），用户确认过的旧 uid 不随空集合丢掉。
    Bound {
        col: i64,
        changed: BindingChanged,
        carry: BTreeSet<String>,
    },
    /// 并入了（方向见文件头）。本机改绑到对方之后，对方带来的、本机还不算数的盐另写一条 `Salts`（[salts]）。
    Joined {
        written: JoinWritten,
        salts: Option<OpId>,
    },
    /// 同一个集合（或早已并入的集合），带来了本机还不算数的盐：写了一条 `Salts`，只含那几个。
    SaltsAdded {
        op: OpId,
        settled: Settled,
        changed: Option<BindingChanged>,
    },
}

impl AdoptOutcome {
    /// 这次认下来改没改绑定（文件头「绑定变化的事件」）：命令层在最外层事务提交成功之后，对返回 `Some` 的发
    /// `binding_changed{profile}`。所有结论都经这里取，不在命令层逐个分支拆（拆漏一个，Dart 缓存的四个 ID 就会过期）。
    pub fn binding_changed(&self) -> Option<&BindingChanged> {
        match self {
            AdoptOutcome::Same | AdoptOutcome::AlreadyJoined | AdoptOutcome::NeedsConfirm => None,
            AdoptOutcome::Bound { changed, .. } => Some(changed),
            AdoptOutcome::Joined { written, .. } => written.changed.as_ref(),
            AdoptOutcome::SaltsAdded { changed, .. } => changed.as_ref(),
        }
    }
}

// ------------------------------------------------------------ join_ix

impl Index<'_, '_> {
    /// `touch` 遇到一条 `Join` 时调（`derive.rs`）：进日志记一行，拿走删掉。重建时同样经这里。
    pub(super) fn join_row(&mut self, k: i64, j: &Join4, add: bool) -> Result<(), String> {
        let conn = self.t.conn();
        if add {
            conn.prepare_cached(
                "INSERT OR REPLACE INTO join_ix (col, k, src, dir) VALUES (?1, ?2, ?3, ?4)",
            )
            .map_err(sql)?
            .execute(params![self.col, k, j.from.0.as_slice(), j.dir])
            .map_err(sql)?;
        } else {
            conn.prepare_cached("DELETE FROM join_ix WHERE col = ?1 AND k = ?2")
                .map_err(sql)?
                .execute(params![self.col, k])
                .map_err(sql)?;
        }
        Ok(())
    }

    /// 这个集合日志里的全部 `Join`，按操作主键升序；[JoinRow::trusted] 按本机现在的信任状态判。
    pub fn joins(&mut self) -> Result<Vec<JoinRow>, String> {
        let rows: Vec<(i64, Vec<u8>, String)> = {
            let mut stmt = self
                .t
                .conn()
                .prepare_cached("SELECT k, src, dir FROM join_ix WHERE col = ?1 ORDER BY k")
                .map_err(sql)?;
            let rows = stmt
                .query_map([self.col], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
                .map_err(sql)?;
            rows.collect::<Result<_, _>>().map_err(sql)?
        };
        let mut out = Vec::with_capacity(rows.len());
        for (k, src, dir) in rows {
            let op = self.t.id_of_key(k)?;
            let salts: Vec<String> = {
                let mut stmt = self
                    .t
                    .conn()
                    .prepare_cached(
                        "SELECT salt FROM salt_ix WHERE col = ?1 AND k = ?2 ORDER BY salt",
                    )
                    .map_err(sql)?;
                let rows = stmt
                    .query_map(params![self.col, k], |r| r.get::<_, String>(0))
                    .map_err(sql)?;
                rows.collect::<Result<_, _>>().map_err(sql)?
            };
            let from: [u8; 16] = src
                .as_slice()
                .try_into()
                .map_err(|_| format!("gen4 identity: bad collection id in join_ix ({k})"))?;
            let trusted = !self.distrusts(&op.device)?;
            out.push(JoinRow {
                op,
                from: Id(from),
                dir,
                salts,
                trusted,
            });
        }
        Ok(out)
    }

    /// 本机现在算数的盐（受信作者的带盐操作之并）。与 `alias.rs` 的 `settle_salts` 同一个并，只读、不改缓存——
    /// [adopt_foreign] 答「什么都没写」的那几种结论时不能顺手写库。
    pub(crate) fn trusted_salts(&mut self) -> Result<BTreeSet<String>, String> {
        let rows: Vec<(String, i64)> = {
            let mut stmt = self
                .t
                .conn()
                .prepare_cached("SELECT salt, k FROM salt_ix WHERE col = ?1")
                .map_err(sql)?;
            let rows = stmt
                .query_map([self.col], |r| Ok((r.get(0)?, r.get(1)?)))
                .map_err(sql)?;
            rows.collect::<Result<_, _>>().map_err(sql)?
        };
        let mut out = BTreeSet::new();
        for (salt, k) in rows {
            let op = self.t.id_of_key(k)?;
            if !self.distrusts(&op.device)? {
                out.insert(salt);
            }
        }
        Ok(out)
    }

    /// 本机信任的作者写过 from = [collection] 的 `Join`。
    pub(crate) fn joined(&mut self, collection: &Id) -> Result<bool, String> {
        Ok(self
            .joins()?
            .iter()
            .any(|j| j.trusted && j.from == *collection))
    }
}

// ------------------------------------------------------------ 并入

/// 「谁并入谁」（D27）：[a] 的目录名比 [b] 大 = [a] 并入 [b]（`Greater`）。目录名相同而集合不同报错。
fn direction(a: &Binding, b_collection: &Id, b_dir: &str) -> Result<Ordering, String> {
    match a.dir.as_bytes().cmp(b_dir.as_bytes()) {
        Ordering::Equal => Err(format!(
            "gen4 identity: collections {} and {b_collection} share the location directory {}",
            a.collection, a.dir
        )),
        o => Ok(o),
    }
}

fn check_dir(dir: &str) -> Result<(), String> {
    if dir.is_empty() {
        return Err("gen4 identity: empty location directory".to_owned());
    }
    Ok(())
}

fn join_body(from: Id, dir: &str, salts: &BTreeSet<String>) -> Result<Join4, String> {
    if salts.len() > SALTS_MAX {
        return Err(format!(
            "gen4 identity: a join carries at most {SALTS_MAX} salts, got {}",
            salts.len()
        ));
    }
    Ok(Join4 {
        from,
        dir: dir.to_owned(),
        // BTreeSet<String> 按字节升序、无重复：正是盐表要的形状。
        salts: salts.iter().cloned().collect(),
    })
}

fn changed(before: &Binding, after: &Binding) -> Option<BindingChanged> {
    (before != after).then(|| BindingChanged {
        profile: after.profile.clone(),
        col: after.col,
    })
}

fn binding_or_err(t: &Truth<'_>, col: i64) -> Result<Binding, String> {
    t.binding(col)?
        .ok_or_else(|| format!("gen4 identity: no collection {col}"))
}

/// 本机集合 [b] 并入 (into_collection, into_dir)：写 `Join{from: b, dir: b.dir, 盐表: salts}`、改绑。不收尾。
fn join_into(
    t: &Truth<'_>,
    ix: &mut Index<'_, '_>,
    b: &Binding,
    into_collection: &Id,
    into_dir: &str,
    salts: &BTreeSet<String>,
    now: i64,
) -> Result<(OpId, Chain, Join4), String> {
    let join = join_body(b.collection, &b.dir, salts)?;
    let mut n = Native::open(t, b.col)?;
    let (op, chain) = n.write(ix, Body4::Join(join.clone()), now)?;
    t.rebind(b.col, into_collection, into_dir)?;
    // 位置目录换了：各位置媒体「在不在」从头对账（`media.rs` 调用方契约）。
    super::media::forget_all(t, b.col)?;
    Ok((op, chain, join))
}

/// 对方集合并入本机集合 [b]：写 `Join{from: foreign}`，绑定不动。不收尾。
fn absorb(
    t: &Truth<'_>,
    ix: &mut Index<'_, '_>,
    b: &Binding,
    foreign: &Foreign,
    now: i64,
) -> Result<(OpId, Chain, Join4), String> {
    let join = join_body(foreign.collection, &foreign.dir, &foreign.salts)?;
    let mut n = Native::open(t, b.col)?;
    let (op, chain) = n.write(ix, Body4::Join(join.clone()), now)?;
    Ok((op, chain, join))
}

impl Truth<'_> {
    /// 本机集合 [col] 并入集合 [into_collection]（位置目录名 [into_dir]）：在本机原生日志里写一条
    /// `Join{from: 本机现在的集合, dir: 本机现在的目录名, 盐表: 本机现在算数的盐}`，同一个事务里改绑到对方
    /// （文件头「并入的方向」）。[now] 是写入时刻（毫秒，内核不读系统时钟）。
    ///
    /// 拒绝（什么都不写）：本机已经绑在对方上；方向反了（对方目录名更大——应当由对方并入本机，走 [adopt_foreign]）；
    /// 目录名相同；对方已经绑在本机别的 profile 上；本机在这个集合里还没有身份。
    pub fn join(
        &self,
        col: i64,
        into_collection: &Id,
        into_dir: &str,
        now: i64,
    ) -> Result<JoinWritten, String> {
        check_dir(into_dir)?;
        self.tx(|t| {
            let before = binding_or_err(t, col)?;
            if before.collection == *into_collection {
                return Err(format!(
                    "gen4 identity: collection {col} is already bound to {into_collection}"
                ));
            }
            if direction(&before, into_collection, into_dir)? == Ordering::Less {
                return Err(format!(
                    "gen4 identity: {} sorts before {into_dir}, so {into_collection} joins this \
                     collection, not the other way round (D27)",
                    before.dir
                ));
            }
            if let Some(o) = t.binding_of_collection(into_collection)? {
                return Err(format!(
                    "gen4 identity: collection {into_collection} is already bound to profile {}",
                    o.profile
                ));
            }
            let mut ix = Index::new(t, col);
            let salts = ix.trusted_salts()?;
            let (op, chain, join) =
                join_into(t, &mut ix, &before, into_collection, into_dir, &salts, now)?;
            let settled = ingest_settle(t, &mut ix, col, Settle::Incremental)?;
            let binding = binding_or_err(t, col)?;
            Ok(JoinWritten {
                col,
                op,
                chain,
                join,
                rebound: true,
                changed: changed(&before, &binding),
                binding,
                settled,
            })
        })
    }
}

/// profile [profile] 遇到一份声明了身份 [foreign] 的外来数据（导入、还原、位置上发现的集合）时该怎么认，必要时写下来
/// （[AdoptOutcome]）。[confirmed] = 调用方已经问过用户「是不是同一个库」并得到肯定（BUG-4011 / D25）。
///
/// 判定顺序：profile 没绑过 → 确认后直接绑；同一个集合 → 补盐；日志里有受信的 from = 对方的 `Join` → 补盐；对方绑在
/// 本机别的 profile 上 → 报错（同机两个 profile 不能是同一个集合，设计 §5.1）；没确认 → `NeedsConfirm`；确认了、本机
/// 集合是空集合、且 D27 的方向是本机并入对方 → 丢掉它、直接绑到对方（文件头「空集合可换绑」）；否则按 D27 的方向并入。同一个集合而目录名不同、或两个集合目录名相同，是坏数据，报错、什么都不写。
///
/// [foreign] 的 `dir` 必须是位置目录名（`meta.json` 所在的那一级），旧 profile uid 只能进 `salts`（[Foreign::dir]）。
/// 绑定变了的结论经 [AdoptOutcome::binding_changed] 取事件，由命令层在最外层提交后发。
///
/// 本机在这个集合里还没有身份、而结论要写操作时报错（写操作要作者）。
pub fn adopt_foreign(
    t: &Truth<'_>,
    profile: &str,
    foreign: &Foreign,
    confirmed: bool,
    now: i64,
) -> Result<AdoptOutcome, String> {
    if profile.is_empty() {
        return Err("gen4 identity: empty profile uid".to_owned());
    }
    check_dir(&foreign.dir)?;
    if foreign.salts.len() > SALTS_MAX {
        return Err(format!(
            "gen4 identity: at most {SALTS_MAX} salts, got {}",
            foreign.salts.len()
        ));
    }
    t.tx(|t| {
        let Some(before) = t.binding_of(profile)? else {
            if let Some(o) = t.binding_of_collection(&foreign.collection)? {
                return Err(format!(
                    "gen4 identity: collection {} is already bound to profile {}",
                    foreign.collection, o.profile
                ));
            }
            if !confirmed {
                return Ok(AdoptOutcome::NeedsConfirm);
            }
            let col = t.bind(profile, &foreign.collection, &foreign.dir)?;
            return Ok(AdoptOutcome::Bound {
                col,
                changed: BindingChanged {
                    profile: profile.to_owned(),
                    col,
                },
                carry: BTreeSet::new(),
            });
        };
        let col = before.col;
        let mut ix = Index::new(t, col);
        let have = ix.trusted_salts()?;
        let extra: BTreeSet<String> = foreign.salts.difference(&have).cloned().collect();
        let ours = if before.collection == foreign.collection {
            if before.dir != foreign.dir {
                return Err(format!(
                    "gen4 identity: collection {} is in directory {}, not {}",
                    before.collection, before.dir, foreign.dir
                ));
            }
            Some(AdoptOutcome::Same)
        } else if ix.joined(&foreign.collection)? {
            Some(AdoptOutcome::AlreadyJoined)
        } else {
            None
        };
        if let Some(quiet) = ours {
            if extra.is_empty() {
                return Ok(quiet);
            }
            return add_salts(t, &mut ix, &before, &extra, now);
        }
        if let Some(o) = t.binding_of_collection(&foreign.collection)? {
            return Err(format!(
                "gen4 identity: collection {} is already bound to profile {}",
                foreign.collection, o.profile
            ));
        }
        let dir = direction(&before, &foreign.collection, &foreign.dir)?;
        if !confirmed {
            return Ok(AdoptOutcome::NeedsConfirm);
        }
        if dir == Ordering::Greater && disposable(t, col)? {
            // 空集合可换绑（文件头「空集合可换绑」）：只在 D27 本来就是本机改绑到对方的方向上，丢掉本机这个空集合、
            // 直接绑到对方，不写 Join。反方向照 D27 吸收，两台空集合设备互相确认时不会交叉换绑。
            return rebind_empty(t, profile, col, foreign, &have);
        }
        let (rebound, (op, chain, join), salts) = if dir == Ordering::Greater {
            // 本机的目录名更大：本机并入对方。本机的盐整份带进 Join；对方的盐本机还不算数的，改绑后另写一条 Salts。
            let wrote = join_into(
                t,
                &mut ix,
                &before,
                &foreign.collection,
                &foreign.dir,
                &have,
                now,
            )?;
            let salts = Native::open(t, col)?.write_salts(&mut ix, &extra, now)?;
            (true, wrote, salts)
        } else {
            (false, absorb(t, &mut ix, &before, foreign, now)?, None)
        };
        let settled = ingest_settle(t, &mut ix, col, Settle::Incremental)?;
        let binding = binding_or_err(t, col)?;
        Ok(AdoptOutcome::Joined {
            written: JoinWritten {
                col,
                op,
                chain,
                join,
                rebound,
                changed: changed(&before, &binding),
                binding,
                settled,
            },
            salts,
        })
    })
}

/// 同一个集合 / 早已并入的集合带来了本机还不算数的盐 [extra]（非空）：写一条只含它们的 `Salts`、收尾。
fn add_salts(
    t: &Truth<'_>,
    ix: &mut Index<'_, '_>,
    before: &Binding,
    extra: &BTreeSet<String>,
    now: i64,
) -> Result<AdoptOutcome, String> {
    let col = before.col;
    let op = Native::open(t, col)?
        .write_salts(ix, extra, now)?
        .ok_or_else(|| {
            "gen4 identity: salts the collection does not count are already in the local log"
                .to_owned()
        })?;
    let settled = ingest_settle(t, ix, col, Settle::Incremental)?;
    let after = binding_or_err(t, col)?;
    Ok(AdoptOutcome::SaltsAdded {
        op,
        settled,
        changed: changed(before, &after),
    })
}

/// 方向固定地把 [foreign] 并进 [profile] 绑着的集合（文件头「方向固定的吸收」）：只给半截并入的收尾用
/// （`cmd/profile_data.rs` `profile_merge_commit`，用户当初已经确认过并入，这里不再问）。[profile] 的集合标识与目录名
/// **绝不改变**：不按 D27 比目录名、不做空集合换绑，一律写 `Join{from: foreign}`。
///
/// 结论只有三种：[foreign] 早已并入、盐也都算数 → `AlreadyJoined`；早已并入、带来新盐 → `SaltsAdded`；否则 `Joined`
/// （`rebound` 恒为 false）。拒绝（什么都不写）：[profile] 没绑定（调用方先按打开 profile 的口径建，`identity`）；
/// [foreign] 就是 [profile] 的集合；[foreign] 还绑在本机别的 profile 上（调用方先丢掉它）；两个集合目录名相同（坏数据，
/// 同 D27）；本机在 [profile] 的集合里还没有身份。
pub fn absorb_foreign(
    t: &Truth<'_>,
    profile: &str,
    foreign: &Foreign,
    now: i64,
) -> Result<AdoptOutcome, String> {
    check_dir(&foreign.dir)?;
    if foreign.salts.len() > SALTS_MAX {
        return Err(format!(
            "gen4 identity: at most {SALTS_MAX} salts, got {}",
            foreign.salts.len()
        ));
    }
    t.tx(|t| {
        let before = t
            .binding_of(profile)?
            .ok_or_else(|| format!("gen4 identity: profile {profile} has no collection"))?;
        if before.collection == foreign.collection {
            return Err(format!(
                "gen4 identity: {} is already the collection of profile {profile}",
                foreign.collection
            ));
        }
        direction(&before, &foreign.collection, &foreign.dir)?;
        let col = before.col;
        let mut ix = Index::new(t, col);
        let have = ix.trusted_salts()?;
        let extra: BTreeSet<String> = foreign.salts.difference(&have).cloned().collect();
        if ix.joined(&foreign.collection)? {
            if extra.is_empty() {
                return Ok(AdoptOutcome::AlreadyJoined);
            }
            return add_salts(t, &mut ix, &before, &extra, now);
        }
        if let Some(o) = t.binding_of_collection(&foreign.collection)? {
            return Err(format!(
                "gen4 identity: collection {} is already bound to profile {}",
                foreign.collection, o.profile
            ));
        }
        let (op, chain, join) = absorb(t, &mut ix, &before, foreign, now)?;
        let settled = ingest_settle(t, &mut ix, col, Settle::Incremental)?;
        let binding = binding_or_err(t, col)?;
        Ok(AdoptOutcome::Joined {
            written: JoinWritten {
                col,
                op,
                chain,
                join,
                rebound: false,
                changed: changed(&before, &binding),
                binding,
                settled,
            },
            salts: None,
        })
    })
}

/// [derive_cfg] 换绑时带过去的派生层配置（缓存配置等：只取决于 profile，与集合无关）。
pub(crate) const DERIVE_CFG_OF_SQL: &str =
    "SELECT key, value FROM derive_cfg WHERE col = ?1 ORDER BY key";

/// 「空集合可换绑」（[adopt_foreign] 的确认之后、本机集合 [col] 是 [disposable] 时）：同一个事务里丢掉 [col]
/// （[discard_collection]）、把 [profile] 绑到对方（[Truth::bind]），派生层配置（`derive_cfg`，Dart 按 profile 给的缓存
/// 配置）照搬到新集合号。结论 `Bound`：本机身份由命令层在对方集合里重建（`cmd/identity.rs` `collection_adopt`），不写
/// `Join`、别的设备不用再确认（规划 §6 / D25）。[have] 是空集合算数的盐（空集合里只有本机写的 `Salts`，都是本机声明
/// 的）：对方不算数的那几个放进 `carry`，由命令层在对方集合里补写。
fn rebind_empty(
    t: &Truth<'_>,
    profile: &str,
    col: i64,
    foreign: &Foreign,
    have: &BTreeSet<String>,
) -> Result<AdoptOutcome, String> {
    let cfg: Vec<(String, String)> = {
        let mut stmt = t.conn().prepare_cached(DERIVE_CFG_OF_SQL).map_err(sql)?;
        let rows = stmt
            .query_map([col], |r| Ok((r.get(0)?, r.get(1)?)))
            .map_err(sql)?;
        rows.collect::<Result<_, _>>().map_err(sql)?
    };
    discard_collection(t, col)?;
    let fresh = t.bind(profile, &foreign.collection, &foreign.dir)?;
    for (key, value) in &cfg {
        t.set_derive_cfg(fresh, key, Some(value))?;
    }
    Ok(AdoptOutcome::Bound {
        col: fresh,
        changed: BindingChanged {
            profile: profile.to_owned(),
            col: fresh,
        },
        carry: have.difference(&foreign.salts).cloned().collect(),
    })
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::*;
    use crate::gen4::op::tests::id;
    use crate::store::gen4::derive::tests::{assert_rebuild_is_identity, native, op};
    use crate::store::gen4::native::tests::{me, ready};
    use crate::store::gen4::schema::{open, open_in_memory};
    use crate::store::gen4::truth::{BindStage, BindState, TRUST_REJECTED};

    const NOW: i64 = 1_800_000_000_000;
    /// `truth::tests::bound` 绑的 profile、集合、目录名。
    const P: &str = "0193a1b2-0000-7000-8000-00000000beef";
    const P2: &str = "0193a1b2-0000-7000-8000-00000000f00d";
    const OURS: u8 = 0xc0;
    const OUR_DIR: &str = "dir";

    fn salts(xs: &[&str]) -> BTreeSet<String> {
        xs.iter().map(|s| s.to_string()).collect()
    }

    fn foreign(c: u8, dir: &str, s: &[&str]) -> Foreign {
        Foreign {
            collection: id(c),
            dir: dir.to_owned(),
            salts: salts(s),
        }
    }

    /// 本机身份声明一批盐（迁移第 6 步那条 Salts）。
    fn declare(t: &Truth<'_>, col: i64, s: &[&str]) {
        t.tx(|t| {
            let mut ix = Index::new(t, col);
            Native::open(t, col)?.write_salts(&mut ix, &salts(s), NOW)?;
            ingest_settle(t, &mut ix, col, Settle::Incremental).map(|_| ())
        })
        .unwrap();
    }

    /// 本机身份写一条修改（不是 `Salts`）：集合有了实质内容、不再是「空集合」（[disposable]），确认后照常 `Join`
    /// 而不是换绑（G9-5）。
    fn substantive(t: &Truth<'_>, col: i64) {
        t.tx(|t| {
            let mut ix = Index::new(t, col);
            let mut n = Native::open(t, col)?;
            n.write(&mut ix, crate::store::gen4::native::tests::edit("x"), NOW)?;
            n.finish(&mut ix).map(|_| ())
        })
        .unwrap();
    }

    fn joins(t: &Truth<'_>, col: i64) -> Vec<JoinRow> {
        Index::new(t, col).joins().unwrap()
    }

    fn audit(t: &Truth<'_>, col: i64) -> u64 {
        t.tx(|t| t.audit(col)).unwrap()
    }

    fn body(t: &Truth<'_>, col: i64, o: &OpId) -> Body4 {
        t.entry(col, o)
            .unwrap()
            .unwrap()
            .op()
            .unwrap()
            .body()
            .unwrap()
    }

    fn adopt(t: &Truth<'_>, f: &Foreign, confirmed: bool) -> Result<AdoptOutcome, String> {
        adopt_foreign(t, P, f, confirmed, NOW)
    }

    /// 派生表与绑定之外的东西都没动：日志条数、绑定、绑定状态、派生表逐行。
    fn snapshot(t: &Truth<'_>, col: i64) -> (u64, Option<Binding>, Option<BindState>, Vec<String>) {
        (
            audit(t, col),
            t.binding(col).unwrap(),
            t.binding_state(col).unwrap(),
            crate::store::gen4::derive::tests::dump(t.conn(), col),
        )
    }

    // ------------------------------------------------------------ 绑定状态

    /// 绑定状态逐步与协议 3 的 `binding_set` / `binding_get` 回包相同（只进不退；规划 §1.6「形状不变」）。
    #[test]
    fn binding_state_moves_like_protocol_3() {
        let dir = crate::store::sync2::tests::tempdir::new("gen4-binding-parity");
        let old = crate::store::SrsCore::open(&dir.0.join("srs.db")).unwrap();
        let p3 = crate::store::sync2::tests::P;
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        let new_json = |t: &Truth<'_>| -> Value {
            json!({"binding": t.binding_state(col).unwrap().map(|s| s.json())})
        };
        assert_eq!(new_json(&t), old.binding_get(p3).unwrap());
        let steps = [
            ("provisional", "loc-a", 1),
            ("provisional", "loc-b", 2),
            ("settled", "loc-a", 3),
            ("settled", "loc-b", 4),
            ("provisional", "loc-c", 5),
        ];
        for (state, via, at) in steps {
            let want = old.binding_set(p3, state, via, at).unwrap();
            let got = t
                .tx(|t| t.settle_binding(col, BindStage::of_text(state).unwrap(), via, at))
                .unwrap();
            assert_eq!(json!({"binding": got.json()}), want, "{state} {via}");
            assert_eq!(new_json(&t), old.binding_get(p3).unwrap(), "{state} {via}");
        }
        assert_eq!(
            t.binding_state(col),
            Ok(Some(BindState {
                stage: BindStage::Settled,
                via: "loc-a".into(),
                at: 3
            }))
        );
    }

    /// 读认不出的状态值当作没有记录；没有这个集合报错；写在事务外拒绝。
    #[test]
    fn binding_state_edges() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        assert_eq!(t.binding_state(col), Ok(None));
        conn.execute("UPDATE collections SET state = 9, via = 'x', at = 1", [])
            .unwrap();
        assert_eq!(t.binding_state(col), Ok(None));
        assert!(t.binding_state(col + 1).is_err());
        assert!(
            t.settle_binding(col, BindStage::Settled, "x", 1)
                .unwrap_err()
                .contains("outside a transaction")
        );
        for s in [BindStage::Provisional, BindStage::Settled] {
            assert_eq!(BindStage::of_code(s.code()), Some(s));
            assert_eq!(BindStage::of_text(s.text()), Some(s));
        }
        assert_eq!(BindStage::of_text("bound"), None);
    }

    // ------------------------------------------------------------ join

    /// 本机（目录名 "dir"）并入目录名更小的 A：写一条 Join（from = 本机原来的集合、带本机算数的盐），改绑到 A；
    /// 集合号、本机身份、绑定状态不动；派生表认得这条 Join；重建逐行相同。
    #[test]
    fn join_rebinds_and_writes_one_join_with_the_old_identity_and_salts() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        declare(&t, col, &["u-b", "u-old"]);
        t.tx(|t| t.settle_binding(col, BindStage::Provisional, "loc", 7))
            .unwrap();
        let w = t.join(col, &id(0xa0), "a-dir", NOW + 1).unwrap();
        assert_eq!(
            w.op,
            OpId {
                device: me(),
                seq: 2
            }
        );
        assert!(w.rebound);
        assert_eq!(
            w.join,
            Join4 {
                from: id(OURS),
                dir: OUR_DIR.into(),
                salts: vec!["u-b".into(), "u-old".into()],
            }
        );
        assert_eq!(body(&t, col, &w.op), Body4::Join(w.join.clone()));
        assert_eq!(t.chain_at(col, &me(), 2), Ok(w.chain));
        let b = t.binding(col).unwrap().unwrap();
        assert_eq!((b.collection, b.dir.as_str()), (id(0xa0), "a-dir"));
        assert_eq!(b.profile, P);
        assert_eq!(b.salts, salts(&["u-b", "u-old"]));
        assert_eq!(w.binding, b);
        assert_eq!(
            w.changed,
            Some(BindingChanged {
                profile: P.into(),
                col
            })
        );
        assert_eq!(t.self_identity(col).unwrap().unwrap().device, me());
        assert_eq!(t.binding_state(col).unwrap().unwrap().via, "loc");
        assert_eq!(
            joins(&t, col),
            vec![JoinRow {
                op: w.op,
                from: id(OURS),
                dir: OUR_DIR.into(),
                salts: vec!["u-b".into(), "u-old".into()],
                trusted: true,
            }]
        );
        assert_eq!(audit(&t, col), 2);
        assert_rebuild_is_identity(&t, col);
        assert_eq!(joins(&t, col).len(), 1);
    }

    /// 拒绝的几种（方向反了、已经在对方、目录名相同、空目录名、对方绑在别的 profile、没有本机身份、没有这个集合）：
    /// 报错，日志、绑定、绑定状态、派生表都不动，会话照常能用。
    #[test]
    fn join_refusals_write_nothing() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        declare(&t, col, &["u"]);
        let other = t.tx(|t| t.bind(P2, &id(0xb0), "b-dir")).unwrap();
        let before = snapshot(&t, col);
        let cases: [(&Id, &str, &str); 5] = [
            (&id(0xa0), "zzz", "D27"),
            (&id(OURS), "a", "already bound"),
            (&id(0xa0), OUR_DIR, "share the location directory"),
            (&id(0xa0), "", "empty location directory"),
            (&id(0xb0), "b-dir", "already bound to profile"),
        ];
        for (c, d, why) in cases {
            let e = t.join(col, c, d, NOW).unwrap_err();
            assert!(e.contains(why), "{d}: {e}");
            assert_eq!(snapshot(&t, col), before, "{d}");
        }
        // 别的 profile 那个集合没有本机身份。
        assert!(
            t.join(other, &id(0xa0), "a", NOW)
                .unwrap_err()
                .contains("no local identity")
        );
        assert!(
            t.join(999, &id(0xa0), "a", NOW)
                .unwrap_err()
                .contains("no collection")
        );
        assert_eq!(snapshot(&t, col), before);
        let w = t.join(col, &id(0xa0), "a", NOW).unwrap();
        assert_eq!(w.op.seq, 2);
    }

    /// Join 已经写进日志之后改绑失败：整笔回滚——日志、链尾、时钟、`salt_ix` / `join_ix`、绑定都不留；同一个会话
    /// 接着并入，seq 不跳号。
    #[test]
    fn a_failure_after_the_join_is_written_rolls_everything_back() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        declare(&t, col, &["u"]);
        let before = snapshot(&t, col);
        let hlc = t.self_identity(col).unwrap().unwrap().hlc;
        conn.execute_batch(
            "CREATE TEMP TRIGGER no_rebind BEFORE UPDATE OF collection ON collections \
             BEGIN SELECT RAISE(ABORT, 'rebind blocked'); END;",
        )
        .unwrap();
        let e = t.join(col, &id(0xa0), "a", NOW + 5).unwrap_err();
        assert!(e.contains("rebind blocked"), "{e}");
        assert_eq!(snapshot(&t, col), before);
        assert_eq!(t.self_identity(col).unwrap().unwrap().hlc, hlc);
        conn.execute_batch("DROP TRIGGER no_rebind").unwrap();
        let w = t.join(col, &id(0xa0), "a", NOW + 5).unwrap();
        assert_eq!(w.op.seq, 2);
        assert_rebuild_is_identity(&t, col);
    }

    /// 子进程那一半：在自己开的事务里并入，不提交就退出（等于写到一半被杀）。
    #[test]
    fn identity_child_process_half() {
        let Ok(path) = std::env::var("FUSHI_IDENTITY_CHILD_DB") else {
            return;
        };
        let conn = open(std::path::Path::new(&path)).unwrap();
        let col: i64 = conn
            .query_row("SELECT col FROM self_", [], |r| r.get(0))
            .unwrap();
        let t = Truth::new(&conn);
        conn.execute_batch("BEGIN IMMEDIATE").unwrap();
        t.reset();
        t.join(col, &id(0xa0), "a", NOW + 10).unwrap();
        assert_eq!(t.binding(col).unwrap().unwrap().collection, id(0xa0));
        println!("IDENTITY_CHILD joined, exiting without commit");
        std::process::exit(0);
    }

    /// 崩溃：另一个进程并入到一半退出。重开之后绑定、日志都停在最后一次提交，接着并入照常。
    #[test]
    fn a_crash_mid_join_commits_nothing() {
        let dir = crate::store::sync2::tests::tempdir::new("gen4-identity-crash");
        let path = dir.0.join("srs4.db");
        let col = {
            let conn = open(&path).unwrap();
            let t = Truth::new(&conn);
            let col = ready(&t);
            declare(&t, col, &["u"]);
            col
        };
        let out = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "store::gen4::identity::tests::identity_child_process_half",
                "--nocapture",
                "--test-threads=1",
            ])
            .env("FUSHI_IDENTITY_CHILD_DB", &path)
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert!(out.status.success(), "{stdout}");
        assert!(stdout.contains("IDENTITY_CHILD joined"), "{stdout}");
        let conn = open(&path).unwrap();
        let t = Truth::new(&conn);
        let b = t.binding(col).unwrap().unwrap();
        assert_eq!((b.collection, b.dir.as_str()), (id(OURS), OUR_DIR));
        assert_eq!(audit(&t, col), 1);
        assert!(joins(&t, col).is_empty());
        let w = t.join(col, &id(0xa0), "a", NOW + 20).unwrap();
        assert_eq!(w.op.seq, 2);
        assert_rebuild_is_identity(&t, col);
    }

    // ------------------------------------------------------------ adopt_foreign

    /// 没绑过的 profile：没确认不绑；确认了直接绑到对方（不写操作）；对方已经绑在别的 profile 上报错。
    #[test]
    fn an_unbound_profile_binds_only_after_confirmation() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let f = foreign(0xa0, "a", &["u-a"]);
        assert_eq!(adopt(&t, &f, false), Ok(AdoptOutcome::NeedsConfirm));
        assert_eq!(t.binding_of(P), Ok(None));
        let got = adopt(&t, &f, true).unwrap();
        let AdoptOutcome::Bound { col, changed, .. } = got else {
            panic!("{got:?}");
        };
        assert_eq!(
            changed,
            BindingChanged {
                profile: P.into(),
                col
            }
        );
        let b = t.binding(col).unwrap().unwrap();
        assert_eq!(
            (b.collection, b.dir.as_str(), b.profile.as_str()),
            (id(0xa0), "a", P)
        );
        assert_eq!(audit(&t, col), 0);
        // 同一个集合不能再给第二个 profile。
        let e = adopt_foreign(&t, P2, &f, true, NOW).unwrap_err();
        assert!(e.contains("already bound to profile"), "{e}");
        assert_eq!(t.binding_of(P2), Ok(None));
        // 再认一次：就是这个集合。对方的盐要写成 Salts，可本机在这个集合里还没有身份：报错，不悄悄丢掉。
        assert_eq!(
            adopt(&t, &foreign(0xa0, "a", &[]), true),
            Ok(AdoptOutcome::Same)
        );
        assert!(
            adopt(&t, &f, true)
                .unwrap_err()
                .contains("no local identity")
        );
        assert_eq!(audit(&t, col), 0);
        assert!(adopt_foreign(&t, "", &f, true, NOW).is_err());
    }

    /// 同一个集合：盐都算数 = Same、什么都不写；带来新盐 = 一条只含新盐的 Salts；目录名不一致报错。
    #[test]
    fn the_same_collection_only_adds_salts() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        declare(&t, col, &["u1"]);
        let before = snapshot(&t, col);
        assert_eq!(
            adopt(&t, &foreign(OURS, OUR_DIR, &["u1"]), false),
            Ok(AdoptOutcome::Same)
        );
        assert_eq!(
            adopt(&t, &foreign(OURS, OUR_DIR, &[]), true),
            Ok(AdoptOutcome::Same)
        );
        assert_eq!(snapshot(&t, col), before);
        let e = adopt(&t, &foreign(OURS, "elsewhere", &[]), true).unwrap_err();
        assert!(e.contains("not elsewhere"), "{e}");
        let got = adopt(&t, &foreign(OURS, OUR_DIR, &["u1", "u2"]), false).unwrap();
        let AdoptOutcome::SaltsAdded { op, changed, .. } = got else {
            panic!("{got:?}");
        };
        assert_eq!(op.seq, 2);
        assert_eq!(body(&t, col, &op), Body4::salts(["u2"]).unwrap());
        assert_eq!(
            changed,
            Some(BindingChanged {
                profile: P.into(),
                col
            })
        );
        assert_eq!(t.binding(col).unwrap().unwrap().salts, salts(&["u1", "u2"]));
        assert_eq!(
            adopt(&t, &foreign(OURS, OUR_DIR, &["u2"]), true),
            Ok(AdoptOutcome::Same)
        );
        assert_rebuild_is_identity(&t, col);
    }

    /// 另一个集合、目录名比本机大：没确认什么都不写；确认后它并入本机（Join 带它的盐，绑定不动）；之后再认它 =
    /// AlreadyJoined，带来新盐 = SaltsAdded。
    #[test]
    fn a_larger_foreign_collection_joins_this_one() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        declare(&t, col, &["u1"]);
        substantive(&t, col);
        let f = foreign(0xe0, "zz-dir", &["u-z"]);
        let before = snapshot(&t, col);
        assert_eq!(adopt(&t, &f, false), Ok(AdoptOutcome::NeedsConfirm));
        assert_eq!(snapshot(&t, col), before);
        let got = adopt(&t, &f, true).unwrap();
        let AdoptOutcome::Joined {
            written: w,
            salts: None,
        } = got
        else {
            panic!("{got:?}");
        };
        assert!(!w.rebound);
        assert_eq!(
            w.join,
            Join4 {
                from: id(0xe0),
                dir: "zz-dir".into(),
                salts: vec!["u-z".into()]
            }
        );
        assert_eq!(body(&t, col, &w.op), Body4::Join(w.join.clone()));
        let b = t.binding(col).unwrap().unwrap();
        assert_eq!((b.collection, b.dir.as_str()), (id(OURS), OUR_DIR));
        assert_eq!(b.salts, salts(&["u-z", "u1"]));
        assert_eq!(
            w.changed,
            Some(BindingChanged {
                profile: P.into(),
                col
            })
        );
        assert_eq!(adopt(&t, &f, false), Ok(AdoptOutcome::AlreadyJoined));
        let got = adopt(&t, &foreign(0xe0, "zz-dir", &["u-z", "u-z2"]), false).unwrap();
        let AdoptOutcome::SaltsAdded { op, .. } = got else {
            panic!("{got:?}");
        };
        assert_eq!(body(&t, col, &op), Body4::salts(["u-z2"]).unwrap());
        assert_eq!(audit(&t, col), 4, "Salts、修改、Join、补盐");
        assert_rebuild_is_identity(&t, col);
    }

    /// 另一个集合、目录名比本机小：确认后本机并入它（改绑；Join 带本机的盐；它的盐另写一条 Salts）；之后再认它 =
    /// Same，再认本机原来的集合（比如并入之前的备份）= AlreadyJoined。
    #[test]
    fn this_collection_joins_a_smaller_foreign_one() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        declare(&t, col, &["u1"]);
        substantive(&t, col);
        let f = foreign(0xa0, "a-dir", &["u-a", "u1"]);
        let got = adopt(&t, &f, true).unwrap();
        let AdoptOutcome::Joined {
            written: w,
            salts: Some(s),
        } = got
        else {
            panic!("{got:?}");
        };
        assert!(w.rebound);
        assert_eq!(
            w.join,
            Join4 {
                from: id(OURS),
                dir: OUR_DIR.into(),
                salts: vec!["u1".into()]
            }
        );
        assert_eq!((w.op.seq, s.seq), (3, 4), "第 2 条是让集合不空的那条修改");
        assert_eq!(body(&t, col, &s), Body4::salts(["u-a"]).unwrap());
        let b = t.binding(col).unwrap().unwrap();
        assert_eq!((b.collection, b.dir.as_str()), (id(0xa0), "a-dir"));
        assert_eq!(b.salts, salts(&["u-a", "u1"]));
        assert_eq!(w.binding, b);
        assert_eq!(adopt(&t, &f, false), Ok(AdoptOutcome::Same));
        assert_eq!(
            adopt(&t, &foreign(OURS, OUR_DIR, &["u1"]), false),
            Ok(AdoptOutcome::AlreadyJoined)
        );
        assert_rebuild_is_identity(&t, col);
    }

    /// 坏数据与冲突：两个集合目录名相同、对方绑在本机别的 profile 上、盐太多——报错、什么都不写。
    #[test]
    fn conflicting_foreign_identities_are_refused() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        t.tx(|t| t.bind(P2, &id(0xb0), "b-dir")).unwrap();
        let before = snapshot(&t, col);
        let e = adopt(&t, &foreign(0xa0, OUR_DIR, &[]), true).unwrap_err();
        assert!(e.contains("share the location directory"), "{e}");
        let e = adopt(&t, &foreign(0xb0, "b-dir", &[]), true).unwrap_err();
        assert!(e.contains("already bound to profile"), "{e}");
        let e = adopt(&t, &foreign(0xa0, "", &[]), true).unwrap_err();
        assert!(e.contains("empty location directory"), "{e}");
        let many = Foreign {
            collection: id(0xa0),
            dir: "a".into(),
            salts: (0..=SALTS_MAX).map(|i| format!("{i:06}")).collect(),
        };
        assert!(adopt(&t, &many, true).unwrap_err().contains("at most"));
        assert_eq!(snapshot(&t, col), before);
    }

    /// 同一个集合在另一个旧 uid 下的备份（设计 §5.4 第 6 条）：旧 uid 当盐传进来 = 只写一条 Salts；把旧 uid 错当成
    /// 目录名传进来 = 坏数据、报错、什么都不写（[Foreign::dir] 的约定，G11-3 / G11-4 照此构造）。
    #[test]
    fn a_backup_under_an_old_uid_passes_the_uid_as_a_salt() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        declare(&t, col, &["u1"]);
        const OLD_UID: &str = "0193a1b2-0000-7000-8000-0000000000aa";
        let before = snapshot(&t, col);
        let e = adopt(&t, &foreign(OURS, OLD_UID, &[]), true).unwrap_err();
        assert!(e.contains("is in directory"), "{e}");
        assert_eq!(snapshot(&t, col), before);
        let got = adopt(&t, &foreign(OURS, OUR_DIR, &[OLD_UID]), false).unwrap();
        let AdoptOutcome::SaltsAdded { op, .. } = got else {
            panic!("{got:?}");
        };
        assert_eq!(body(&t, col, &op), Body4::salts([OLD_UID]).unwrap());
        assert_eq!(
            t.binding(col).unwrap().unwrap().salts,
            salts(&[OLD_UID, "u1"])
        );
        assert_rebuild_is_identity(&t, col);
    }

    /// 「带事件 ⇔ 绑定真的变了」对每个结论都成立（文件头「绑定变化的事件」，复核：规划要求 join 结束时发事件，这里
    /// 改为结果里带，命令层照 [AdoptOutcome::binding_changed] 发）。逐个走遍 7 种结论形态和 [Truth::join]，比较调用
    /// 前后这个 profile 的绑定：变了就必须带 `Some`（漏了 Dart 缓存过期），没变就必须是 `None`；带的 profile / col
    /// 就是这个绑定的。
    #[test]
    fn every_outcome_reports_a_binding_change_exactly_when_the_binding_changed() {
        use std::collections::BTreeSet as Set;
        fn kind(o: &AdoptOutcome) -> &'static str {
            match o {
                AdoptOutcome::Same => "same",
                AdoptOutcome::AlreadyJoined => "already",
                AdoptOutcome::NeedsConfirm => "confirm",
                AdoptOutcome::Bound { .. } => "bound",
                AdoptOutcome::Joined { written, .. } if written.rebound => "joined-rebound",
                AdoptOutcome::Joined { .. } => "joined-absorbed",
                AdoptOutcome::SaltsAdded { .. } => "salts",
            }
        }
        fn check(t: &Truth<'_>, f: Foreign, confirmed: bool, seen: &mut Set<&'static str>) {
            let before = t.binding_of(P).unwrap();
            let got = adopt(t, &f, confirmed).unwrap();
            let after = t.binding_of(P).unwrap();
            let ev = got.binding_changed();
            assert_eq!(ev.is_some(), before != after, "{got:?}");
            if let Some(ev) = ev {
                let after = after.unwrap();
                assert_eq!((ev.profile.as_str(), ev.col), (P, after.col), "{got:?}");
            }
            seen.insert(kind(&got));
        }
        let mut seen = Set::new();

        // 没绑过的 profile：没确认、确认后直接绑。
        let fresh = open_in_memory().unwrap();
        let t0 = Truth::new(&fresh);
        check(&t0, foreign(0xa0, "a", &["u-a"]), false, &mut seen);
        check(&t0, foreign(0xa0, "a", &["u-a"]), true, &mut seen);

        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        declare(&t, col, &["u1"]);
        substantive(&t, col);
        check(&t, foreign(OURS, OUR_DIR, &["u1"]), false, &mut seen);
        check(&t, foreign(OURS, OUR_DIR, &["u1", "u2"]), false, &mut seen);
        check(&t, foreign(0xe0, "zz-dir", &["u-z"]), false, &mut seen);
        check(&t, foreign(0xe0, "zz-dir", &["u-z"]), true, &mut seen);
        check(&t, foreign(0xe0, "zz-dir", &["u-z"]), false, &mut seen);
        check(
            &t,
            foreign(0xe0, "zz-dir", &["u-z", "u-z2"]),
            false,
            &mut seen,
        );
        check(&t, foreign(0x0b, "b-dir", &["u-b"]), true, &mut seen);
        assert_eq!(
            seen,
            Set::from([
                "same",
                "already",
                "confirm",
                "bound",
                "joined-rebound",
                "joined-absorbed",
                "salts",
            ])
        );

        // Truth::join 同口径。
        let before = t.binding(col).unwrap();
        let w = t.join(col, &id(0x01), "a", NOW).unwrap();
        let after = t.binding(col).unwrap();
        assert_ne!(before, after);
        assert_eq!(
            w.changed,
            Some(BindingChanged {
                profile: P.into(),
                col
            })
        );
    }

    /// 不受信的作者写的 Join 不算「已经并入过」（与盐集合同口径）：列出来但 trusted = false，本机确认后照样写自己的
    /// Join；放行那个作者后两条都算数。
    #[test]
    fn an_untrusted_join_does_not_count() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        let stranger = id(0x21);
        let theirs = Body4::Join(Join4 {
            from: id(0xe0),
            dir: "zz".into(),
            salts: vec!["u-z".into()],
        });
        t.tx(|t| {
            t.set_trust(col, &stranger, Some(TRUST_REJECTED), NOW)?;
            let mut ix = Index::new(t, col);
            ix.trust_changed();
            native(t, &mut ix, col, &op(0x21, 1, 10, &[], &theirs));
            ingest_settle(t, &mut ix, col, Settle::Incremental).map(|_| ())
        })
        .unwrap();
        let rows = joins(&t, col);
        assert_eq!(rows.len(), 1);
        assert!(!rows[0].trusted);
        assert_eq!(rows[0].salts, vec!["u-z".to_owned()]);
        assert!(t.binding(col).unwrap().unwrap().salts.is_empty());
        let f = foreign(0xe0, "zz", &["u-z"]);
        assert_eq!(adopt(&t, &f, false), Ok(AdoptOutcome::NeedsConfirm));
        let got = adopt(&t, &f, true).unwrap();
        assert!(matches!(got, AdoptOutcome::Joined { .. }), "{got:?}");
        assert_eq!(adopt(&t, &f, false), Ok(AdoptOutcome::AlreadyJoined));
        t.tx(|t| {
            t.set_trust(col, &stranger, None, NOW)?;
            let mut ix = Index::new(t, col);
            ix.trust_changed();
            ingest_settle(t, &mut ix, col, Settle::Incremental).map(|_| ())
        })
        .unwrap();
        assert!(joins(&t, col).iter().all(|j| j.trusted));
        assert_rebuild_is_identity(&t, col);
    }

    /// D27：B（目录名 "b"）与 A（目录名 "a"）两边各自发起，结果相同——都绑在 A、日志里都有 from = B 的 Join、盐集合
    /// 相同。
    #[test]
    fn both_sides_converge_whichever_initiates() {
        let (ca, cb) = (open_in_memory().unwrap(), open_in_memory().unwrap());
        let (ta, tb) = (Truth::new(&ca), Truth::new(&cb));
        let bind = |t: &Truth<'_>, c: u8, dir: &str| -> i64 {
            let col = t.tx(|t| t.bind(P, &id(c), dir)).unwrap();
            t.tx(|t| t.create_self(col, &id(c ^ 0x0f), &[3; 32], None, NOW))
                .unwrap();
            col
        };
        let col_a = bind(&ta, 0xa0, "a");
        let col_b = bind(&tb, 0xb0, "b");
        declare(&ta, col_a, &["ua"]);
        declare(&tb, col_b, &["ub"]);
        substantive(&ta, col_a);
        substantive(&tb, col_b);
        // B 这边认 A、A 这边认 B：各自只知道对方的集合标识、目录名与盐。
        let from_b = adopt(&tb, &foreign(0xa0, "a", &["ua"]), true).unwrap();
        let from_a = adopt(&ta, &foreign(0xb0, "b", &["ub"]), true).unwrap();
        let (AdoptOutcome::Joined { written: wb, .. }, AdoptOutcome::Joined { written: wa, .. }) =
            (from_b, from_a)
        else {
            panic!("both should join");
        };
        assert!(wb.rebound && !wa.rebound);
        for (t, col) in [(&ta, col_a), (&tb, col_b)] {
            let b = t.binding(col).unwrap().unwrap();
            assert_eq!((b.collection, b.dir.as_str()), (id(0xa0), "a"));
            assert_eq!(b.salts, salts(&["ua", "ub"]));
            let rows = joins(t, col);
            assert_eq!(rows.len(), 1);
            assert_eq!((rows[0].from, rows[0].dir.as_str()), (id(0xb0), "b"));
            assert_eq!(rows[0].salts, vec!["ub".to_owned()]);
        }
    }

    /// 两台都是空集合的设备互相确认（G9-5 第二轮复核）：空集合只在 D27 的方向上换绑——B（目录名大）换绑到 A、不写
    /// Join；A（目录名小）照 D27 吸收 B、绑定不动。两边都落在 A，不会交叉换绑。
    #[test]
    fn two_empty_collections_converge_whichever_initiates() {
        let (ca, cb) = (open_in_memory().unwrap(), open_in_memory().unwrap());
        let (ta, tb) = (Truth::new(&ca), Truth::new(&cb));
        let bind = |t: &Truth<'_>, c: u8, dir: &str| -> i64 {
            let col = t.tx(|t| t.bind(P, &id(c), dir)).unwrap();
            t.tx(|t| t.create_self(col, &id(c ^ 0x0f), &[3; 32], None, NOW))
                .unwrap();
            col
        };
        let col_a = bind(&ta, 0xa0, "a");
        let col_b = bind(&tb, 0xb0, "b");
        declare(&ta, col_a, &["ua"]);
        declare(&tb, col_b, &["ub"]);
        assert!(disposable(&ta, col_a).unwrap() && disposable(&tb, col_b).unwrap());
        let from_b = adopt(&tb, &foreign(0xa0, "a", &["ua"]), true).unwrap();
        let from_a = adopt(&ta, &foreign(0xb0, "b", &["ub"]), true).unwrap();
        assert!(matches!(from_b, AdoptOutcome::Bound { .. }), "{from_b:?}");
        let AdoptOutcome::Joined { written: wa, .. } = from_a else {
            panic!("A absorbs B: {from_a:?}");
        };
        assert!(!wa.rebound);
        let a = ta.binding(col_a).unwrap().unwrap();
        assert_eq!((a.collection, a.dir.as_str()), (id(0xa0), "a"));
        let b = tb.binding_of(P).unwrap().unwrap();
        assert_eq!((b.collection, b.dir.as_str()), (id(0xa0), "a"));
    }

    /// 两个连接（各自一个缓存过的会话）先后认同一个外来集合：只写一条 Join，后到的从库里看到已经并入。两个线程在
    /// 文件库上同时认也一样。
    #[test]
    fn two_connections_adopt_the_same_foreign_collection_once() {
        let dir = crate::store::sync2::tests::tempdir::new("gen4-identity-race");
        let path = dir.0.join("srs4.db");
        let col = {
            let conn = open(&path).unwrap();
            let t = Truth::new(&conn);
            let col = ready(&t);
            substantive(&t, col);
            col
        };
        let (c1, c2) = (open(&path).unwrap(), open(&path).unwrap());
        let (t1, t2) = (Truth::new(&c1), Truth::new(&c2));
        // 两边都先把缓存填上。
        assert_eq!(t1.binding(col).unwrap(), t2.binding(col).unwrap());
        let big = foreign(0xe0, "zz", &["u-z"]);
        assert!(matches!(
            adopt(&t1, &big, true),
            Ok(AdoptOutcome::Joined { .. })
        ));
        assert_eq!(adopt(&t2, &big, true), Ok(AdoptOutcome::AlreadyJoined));
        let small = foreign(0x0a, "0", &[]);
        assert!(matches!(
            adopt(&t2, &small, true),
            Ok(AdoptOutcome::Joined { .. })
        ));
        assert_eq!(adopt(&t1, &small, true), Ok(AdoptOutcome::Same));
        assert_eq!(audit(&t1, col), 3, "修改 + 一条 Join");
        drop(t1);
        drop(t2);
        drop(c1);
        drop(c2);

        let race = |c: u8, d: &'static str| {
            let path = path.clone();
            std::thread::spawn(move || {
                let conn = open(&path).unwrap();
                conn.busy_timeout(std::time::Duration::from_secs(30))
                    .unwrap();
                let t = Truth::new(&conn);
                conn.execute_batch("BEGIN IMMEDIATE").unwrap();
                t.reset();
                let r = adopt(&t, &foreign(c, d, &["u-r"]), true);
                conn.execute_batch(if r.is_ok() { "COMMIT" } else { "ROLLBACK" })
                    .unwrap();
                r.unwrap()
            })
        };
        let (a, b) = (race(0xf0, "zzz"), race(0xf0, "zzz"));
        let mut got = [a.join().unwrap(), b.join().unwrap()];
        got.sort_by_key(|o| matches!(o, AdoptOutcome::AlreadyJoined));
        assert!(matches!(got[0], AdoptOutcome::Joined { .. }), "{got:?}");
        assert_eq!(got[1], AdoptOutcome::AlreadyJoined);
        let conn = open(&path).unwrap();
        let t = Truth::new(&conn);
        assert_eq!(audit(&t, col), 4, "修改 + 两条 Join");
        assert_eq!(
            joins(&t, col).iter().filter(|j| j.from == id(0xf0)).count(),
            1
        );
        assert_rebuild_is_identity(&t, col);
    }

    /// 一条 Join 进出日志时 `join_ix` 跟着增删（逐条维护与重建同一个口径）。
    #[test]
    fn join_ix_follows_add_and_remove() {
        let conn = open_in_memory().unwrap();
        let t = Truth::new(&conn);
        let col = ready(&t);
        let theirs = op(
            0x21,
            1,
            10,
            &[],
            &Body4::Join(Join4 {
                from: id(0xe0),
                dir: "zz".into(),
                salts: vec![],
            }),
        );
        t.tx(|t| {
            let mut ix = Index::new(t, col);
            native(t, &mut ix, col, &theirs);
            assert_eq!(ix.joins()?.len(), 1);
            let e = t.entry(col, &theirs.id)?.unwrap();
            ix.remove(&e)?;
            assert!(ix.joins()?.is_empty());
            ix.add(&e)?;
            ix.settle().map(|_| ())
        })
        .unwrap();
        assert_eq!(joins(&t, col).len(), 1);
        assert_rebuild_is_identity(&t, col);
    }
}
