//! 新设备收段的独立通道：先追加、后折叠（docs/specs/2026-11-03-srs-sync2-bootstrap-channel.md）。
//!
//! 逐条投递（transport.rs `Delivery::deliver_ready` → [super::project]）每收一条操作就读写一遍投影：读同寄存器的
//! 现存行、判清除 / 挂起、插入、记账，摘要触发器再把每行拼回原文哈希进桶。新设备从零收几十万条时这是大头（真实全量
//! 数据 68 万条：逐条投递 413 s，收段各片 279 s）。新设备的投影是空的，而收段期间的投影本来就要到收尾才完整（缓存推迟到收尾刷新），
//! 所以换个做法，结果与逐条投递逐表相同：
//!
//! 1. **追加**（收段的每一片，[Append]）：操作照常过链、因果、分叉校验（投递队列不变），只写进操作日志并记下投递
//!    顺序（`sync2_boot_order`：序号 + 折叠分区）。旧修改记录闭包（`sync2_legacy`）按 [super::note_legacy] 同一算法
//!    在内存里更新、每片写下；「复杂实体」的种子（有过 `deleted` 写入、被清除、带合成写入者的非标签旧记录）与移卡
//!    记录另存。
//! 2. **折叠**（收尾，[advance]）：分区逐个折：按投递顺序读出这个分区的操作；字段修改按实体一次交给
//!    `land_stored`（「依次到达」与逐条落同一判据）；复习日志与 `sync2_log_meta` 先到先得、`sync2_edit_ops` 后到者胜、
//!    服务器时刻取落库那几份的最小值（与逐条投递的 INSERT OR IGNORE / REPLACE / MIN 合并相同）；身份记录取规范文本
//!    最小者。算出的投影行按存储形态追加进暂存表 `sync2_boot_rows`，摘要按触发器同一个行哈希记增量
//!    （[super::digest::Deltas]）。
//! 3. **归并**（收尾，各分区折完之后，[merge]）：暂存的行按表、每步至多 [MERGE_CHUNK] 行写进投影（三张摘要表关掉
//!    主库触发器写），写过的暂存行同一步删掉。这几张表的键是散列 ID：按分区直接写，每个分区的提交都要把各表索引的
//!    大部分页重写进 WAL 一遍（真实全量数据 64 个分区折了 205 s）；按表成块写，一张表的索引留在页缓存里，每块只写
//!    一遍。
//! 4. **逐条**（收尾，归并之后）：标签、媒体、清除、检查点等，以及复杂实体上的一切，按投递顺序走生产的逐条
//!    投影（[super::project_body]）。它们与折叠写的行互不相交（各自的实体 / 寄存器），先后无关；要读折叠写的行
//!    （牌组的挂起判定读移进来的卡），所以在归并之后。
//!
//! 为什么复杂实体要逐条：删除的挂起判定（semantics.rs `evaluate_holds` / `should_hold`）读的是「到这一刻为止」碰过
//! 这个实体的操作，清除让之后到的旧写入当场清掉——都与投递顺序交错，不能折。移进复杂牌组的卡也算复杂（牌组的挂起
//! 判定要看移进来的卡），只有这一层传递（卡不会让别的实体变复杂）。
//!
//! 旧修改记录闭包：v2 写入的投影行要并上作者见过的旧记录闭包（[super::legacy_closure]）。折叠时按追加完的最终
//! `sync2_legacy` 算，与逐条投递时按「到达那一刻」算结果相同：作者见过某设备到 seq s，那台设备 s 以内的操作在它之前
//! 都已投递，两种算法都等于「那台设备 seq ≤ s 的旧记录之并」。唯一的例外是其中有旧记录后来被清除了（部分覆盖的那一支
//! 跳过已清除的载荷）——要同时有迁移进来的旧记录被清除、且 v2 写入只见过那台设备迁移操作的一部分，逐条投递在这种
//! 情形下本身也随到达顺序而变。
//!
//! 走不走通道：会话开始时（[begin]）这个 profile 是新设备第一次同步才走（[fresh]：本机只有开库时自己写下的内置
//! 身份记录，或什么都没有）。折叠完之前本机
//! 要写 / 会话外要投递，先把通道做完（[settle]，ffi.rs 分发器与 `channel_settle`、一次收完、导入），之后按逐条投递收。
//! 做完通道与收尾一样按片、每片一个事务（[settle]），不把整份投影塞进调用方的一笔事务。
//!
//! 开通道时投影里已有的行（BUG-4387）：真实的新设备不是空的——Dart 开库就写下内置身份记录（默认牌组、内置笔记
//! 类型，`SrsDbStore.ensureBuiltins`），每台设备各写一份、ID 相同，所以远端一定带着同 ID 的身份记录。[fresh] 保证
//! 这时本机除了这几行身份记录什么都没有：没有修改记录、日志、实体 → 操作索引、清除、挂起、标签（身份记录不进
//! 索引，`project_entity` 只写 `srs_entities`）。逐条投影里读「现存行」的地方因此只剩一处：`project_entity` 按 ID
//! 比内容（同内容不写、不同内容取规范文本小者）。折叠遇到投影里已有同 ID 行的身份记录就不折，挪到逐条区交给生产
//! 的 `project_entity`（[fold_part]）；同 ID 的身份记录总在同一区、逐条区按投递顺序，结果与逐条投递相同。内置实体
//! 上的修改（改名、改模板）照常折：它们的寄存器在本机是空的。折叠期间 `srs_entities` 不变（归并在全部分区折完
//! 之后，本机写入先 [settle]）。
//!
//! 信任（trust.rs）：第一次见到某台设备时按投影判「本机库里有没有用户的东西」，而 `plan` 不先做完通道。通道没做完
//! 时投影不全，所以这种时候先把通道做完再判（transport.rs `sync2_plan_at` 按片做，`note_new_device` 兜底）——之后
//! 这个 profile 按逐条投递收。

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::Arc;

use rusqlite::config::DbConfig;
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};

use super::digest::Deltas;
use super::transport::{CommitBudget, defer_cache_refresh, defer_replay};
use super::{Touched, canonical, snapshots, sql};
use crate::store::caches::Dirty;
use crate::store::prof;
use crate::sync2::dvv::Dvv;
use crate::sync2::hlc::Hlc;
use crate::sync2::id::Id;
use crate::sync2::op::{Body, EntKind, LegacyStamp, Op};
use crate::sync2::segment::Chain;
use crate::sync2::vv::{OpId, Vv};

/// 折叠分区数。一个分区在一个事务里折完（写锁里不能切开），锁内耗时与内存都约为全量的 1/PARTS（真实全量数据
/// 68 万条：桌面每区约 1 s）。
pub(crate) const PARTS: i64 = 64;
/// 逐条投影的操作（标签、媒体、清除……；折叠时发现落在复杂实体上的也挪进来，序号不变）。
const PART_ONE_BY_ONE: i64 = PARTS;

/// `sync2_boot.phase` 的四个取值（持久化值，不改号；schema.rs `V22_BOOT` 以这里为准）。各阶段 `cursor` 的含义见
/// [Boot::cursor]。
/// 追加：收段各片只写操作日志与投递顺序。
const PHASE_APPEND: i64 = 0;
/// 折叠：逐个分区算投影行进暂存表。
const PHASE_FOLD: i64 = 1;
/// 归并：暂存行按表成块写进投影。
const PHASE_MERGE: i64 = 2;
/// 逐条：复杂实体与不折叠的操作按投递顺序逐条投影。
const PHASE_ONE_BY_ONE: i64 = 3;

/// 通道的全部表：通道做完时这几张表里这个 profile 的行全删。
const BOOT_TABLES: [&str; 5] = [
    "sync2_boot_order",
    "sync2_boot_complex",
    "sync2_boot_moves",
    "sync2_boot_rows",
    "sync2_boot",
];

/// 逐条阶段一次读多少条。
const ONE_BY_ONE_CHUNK: i64 = 256;

/// 通道状态（`sync2_boot` 一行）。[cursor]：折叠阶段 = 下一个分区；归并阶段 = 下一张表（[TARGETS] 的下标）；逐条
/// 阶段 = 已投的最大序号。
struct Boot {
    phase: i64,
    next_rank: i64,
    cursor: i64,
}

fn boot(c: &Connection, profile: &str) -> Result<Option<Boot>, String> {
    c.prepare_cached(
        "SELECT phase, next_rank, cursor FROM sync2_boot WHERE profile_uid = srs_id(?1)",
    )
    .map_err(sql)?
    .query_row([profile], |r| {
        Ok(Boot {
            phase: r.get(0)?,
            next_rank: r.get(1)?,
            cursor: r.get(2)?,
        })
    })
    .optional()
    .map_err(sql)
}

fn set_boot(c: &Connection, profile: &str, b: &Boot) -> Result<(), String> {
    c.prepare_cached("INSERT OR REPLACE INTO sync2_boot (profile_uid, phase, next_rank, cursor) VALUES (srs_id(?1), ?2, ?3, ?4)")
        .map_err(sql)?
        .execute(params![profile, b.phase, b.next_rank, b.cursor])
        .map_err(sql)?;
    Ok(())
}

/// 这个 profile 有没有进行中的通道（任何阶段）。
pub(crate) fn active(c: &Connection, profile: &str) -> Result<bool, String> {
    Ok(boot(c, profile)?.is_some())
}

/// 新设备第一次同步：这个 profile 在本机只有开库时自己写下的内置身份记录（或什么都没有）——没有用户数据，也没收过
/// 别的设备的操作。以前要求操作日志与投影全空，而 Dart `SrsDbStore.open` 在任何同步之前就写下内置身份记录
/// （`ensureBuiltins`），生产里这条判据恒为假、通道从不打开（BUG-4387）。
///
/// 三条全成立才算：
/// 1. 投影里没有用户的东西（[super::trust::library_fresh]：没有复习日志、没有修改记录，身份记录的载荷全带 `builtin`
///    键——只有 `srs_builtin.dart` `srsBuiltinEntities` 写这个键），也没有不认识的事件，本机没换过身份；
/// 2. 操作日志里每一条都是**本机当前身份**写的**身份记录**；
/// 3. 这些操作与投影里的身份记录行一一对应：同一个 ID、同样的种类与内容。
///
/// 凭什么区分内置实体与用户数据——三样一起：来源设备（没有别的设备的操作 = 没收过）、操作种类（改名、改模板、删除、
/// 复习、标签、媒体、清除、还原点都是别的种类的操作：身份记录不可变，用户对内置实体的任何改动都另是一条操作，所以
/// 改过内置牌组名 / 内置笔记类型模板的不算新设备）、内容标记（`builtin`：用户自建的牌组 / 笔记类型没有）。不靠 ID
/// 清单：内核只知道默认牌组的 ID，内置笔记类型的 ID 只有 Dart 知道，以后加内置类型也不用改这里。第 3 条挡掉不经
/// 操作日志的投影行（v2 之前的旧库还没迁移）。拿不准的一律不算（只是照旧逐条投递）。
fn fresh(c: &Connection, profile: &str) -> Result<bool, String> {
    if !super::trust::library_fresh(c, profile)? {
        return Ok(false);
    }
    let untouched: bool = c
        .query_row(
            "SELECT NOT EXISTS (SELECT 1 FROM srs_unknown_events WHERE profile_uid = srs_id(?1)) \
               AND NOT EXISTS (SELECT 1 FROM sync2_devices WHERE profile_uid = srs_id(?1) AND frozen != 0)",
            [profile],
            |r| r.get(0),
        )
        .map_err(sql)?;
    if !untouched {
        return Ok(false);
    }
    // 身份记录行：ID → (种类, 载荷)。上面已判过全是内置的，只有几行。
    let mut rows: BTreeMap<String, (String, String)> = c
        .prepare_cached("SELECT srs_idt(id) AS id, kind, payload_json FROM srs_entities WHERE profile_uid = srs_id(?1)")
        .map_err(sql)?
        .query_map([profile], |r| Ok((r.get(0)?, (r.get(1)?, r.get(2)?))))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    // 操作日志至多读「行数 + 1」条：多出一条就不是一一对应（老设备的日志有几十万条，不整表数）。
    let ops: Vec<(Vec<u8>, i64)> = c
        .prepare_cached("SELECT device, seq FROM sync2_ops WHERE profile_uid = srs_id(?1) LIMIT ?2")
        .map_err(sql)?
        .query_map(params![profile, rows.len() as i64 + 1], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    if ops.len() != rows.len() {
        return Ok(false);
    }
    if ops.is_empty() {
        return Ok(true);
    }
    let own: Option<Vec<u8>> = c
        .prepare_cached("SELECT device FROM sync2_self WHERE profile_uid = srs_id(?1)")
        .map_err(sql)?
        .query_row([profile], |r| r.get(0))
        .optional()
        .map_err(sql)?;
    for (device, seq) in ops {
        if own.as_ref() != Some(&device) {
            return Ok(false);
        }
        let id = OpId {
            device: Id(device.try_into().map_err(|_| "bad device".to_string())?),
            seq: seq as u64,
        };
        let Some(Ok(Body::Entity { kind, id, data })) =
            super::load_op(c, profile, &id)?.map(|op| op.body())
        else {
            return Ok(false);
        };
        let d: Value = serde_json::from_str(&data).unwrap_or(Value::Null);
        match rows.remove(&id.text()) {
            Some((k, payload)) if k == kind.wire() && payload == canonical(&d) => {}
            _ => return Ok(false),
        }
    }
    Ok(rows.is_empty())
}

/// 收段会话开始（transport.rs `sync2_ingest_begin`；[w] 是写连接，不在调用方的事务里）：通道还在追加阶段（上一个
/// 会话被打断）就接着追加；没有通道而这个 profile 是新的就开一个；折叠 / 归并 / 逐条做到一半（收尾被打断）先按片
/// 做完（[settle]，每片一个事务），这次按逐条投递收。返回这个会话走不走通道。
pub(crate) fn begin(
    w: &Connection,
    profile: &str,
    settled: &mut dyn FnMut(&Touched),
) -> Result<bool, String> {
    if boot(w, profile)?.is_some_and(|b| b.phase != PHASE_APPEND) {
        settle(w, profile, settled)?;
    }
    super::in_savepoint(w, |c| match boot(c, profile)? {
        Some(b) if b.phase == PHASE_APPEND => Ok(true),
        // [settle] 做完才返回、出错就报错：走到这里只能是有人在上面那次 settle 之后又开了通道。
        Some(_) => Err("sync2 channel: still folding after settle".to_owned()),
        None if fresh(c, profile)? && !forced_off() => {
            set_boot(
                c,
                profile,
                &Boot {
                    phase: PHASE_APPEND,
                    next_rank: 0,
                    cursor: 0,
                },
            )?;
            Ok(true)
        }
        None => Ok(false),
    })
}

// ---------------------------------------------------------------- 追加

/// 一台设备的旧修改记录闭包（`sync2_legacy` 一行）在内存里的样子。
struct LegacyRow {
    upto: i64,
    d: Dvv,
    dirty: bool,
}

/// 追加阶段的投递（transport.rs `Delivery` 持有，会话跨片复用）：依赖向量行号、旧修改记录闭包的缓存与下一个序号。
pub(crate) struct Append {
    next_rank: i64,
    deps: HashMap<Vec<u8>, i64>,
    legacy: BTreeMap<Id, LegacyRow>,
}

impl Append {
    /// 这个 profile 的通道在追加阶段就载入，否则 None（按逐条投递）。
    pub(crate) fn load(c: &Connection, profile: &str) -> Result<Option<Append>, String> {
        Ok(match boot(c, profile)? {
            Some(b) if b.phase == PHASE_APPEND => Some(Append {
                next_rank: b.next_rank,
                deps: HashMap::new(),
                legacy: BTreeMap::new(),
            }),
            _ => None,
        })
    }

    /// 一条已过链与因果校验的远端操作：写进操作日志，记下投递顺序与它的分区（逐条投递的 `insert_op` + `project`）。
    pub(crate) fn append(
        &mut self,
        c: &Connection,
        profile: &str,
        op: &Op,
        chain: &Chain,
        now: i64,
    ) -> Result<(), String> {
        let bytes = op.deps.encode();
        let deps = match self.deps.get(&bytes) {
            Some(&d) => d,
            None => {
                let d = super::intern_deps(c, &bytes)?;
                self.deps.insert(bytes, d);
                d
            }
        };
        {
            let _p = prof::span("append.op_log");
            super::insert_op_at(c, profile, op, chain, now, deps)?;
        }
        let _p = prof::span("append.order");
        let part = match op.body().map_err(|e| e.to_string())? {
            Body::Edit(e) => {
                if let Some(l) = &e.legacy {
                    self.note_legacy(c, profile, &op.id.device, op.id.seq, l)?;
                }
                let ent = e.entity.text();
                let tags = e.kind == EntKind::Note && e.key == "tags";
                let synthetic = e
                    .legacy
                    .as_ref()
                    .is_some_and(|l| super::is_synthetic_writer(&l.writer));
                if e.key == "deleted" || (synthetic && !tags) {
                    seed(c, profile, e.kind.wire(), &ent)?;
                }
                if e.kind == EntKind::Card && e.key == "deck" {
                    if let Ok(Value::String(d)) = serde_json::from_str::<Value>(&e.value) {
                        c.prepare_cached("INSERT OR IGNORE INTO sync2_boot_moves (profile_uid, deck, card) VALUES (srs_id(?1), srs_id(?2), srs_id(?3))")
                            .map_err(sql)?
                            .execute(params![profile, d, ent])
                            .map_err(sql)?;
                    }
                }
                // 整列表标签走 OR-Set（[super::project_edit_noted] 的标签分支），不进寄存器折叠。
                if tags {
                    PART_ONE_BY_ONE
                } else {
                    part_of(e.kind.wire(), &ent)
                }
            }
            Body::Log(l) => part_of("log", &l.id.text()),
            // 同一 ID 的身份记录按 ID 归区（[super::project_entity] 只按 ID 比，不看种类）。
            Body::Entity { id, .. } => part_of("entity", &id.text()),
            Body::Purge { kind, entity } => {
                seed(c, profile, kind.wire(), &entity.text())?;
                PART_ONE_BY_ONE
            }
            // 副本骨架（dedup.rs）：旧戳在这里记进闭包（逐条投递的 `project_body` 同一算法），逐条区里不再记。
            Body::Duplicate {
                legacy: Some(l), ..
            } => {
                self.note_legacy(c, profile, &op.id.device, op.id.seq, &l)?;
                PART_ONE_BY_ONE
            }
            _ => PART_ONE_BY_ONE,
        };
        c.prepare_cached("INSERT INTO sync2_boot_order (profile_uid, part, rank, device, seq) VALUES (srs_id(?1), ?2, ?3, ?4, ?5)")
            .map_err(sql)?
            .execute(params![profile, part, self.next_rank, op.id.device.0.to_vec(), op.id.seq as i64])
            .map_err(sql)?;
        self.next_rank += 1;
        Ok(())
    }

    /// [super::note_legacy] 同一算法，行在内存里（[Append::checkpoint] 写回）。
    fn note_legacy(
        &mut self,
        c: &Connection,
        profile: &str,
        device: &Id,
        seq: u64,
        l: &LegacyStamp,
    ) -> Result<(), String> {
        let mut d = match self.legacy.remove(device) {
            Some(r) => r.d,
            None => super::stored_legacy(c, profile, device)?
                .map(|(_, d)| d)
                .unwrap_or_default(),
        };
        d.merge(&Dvv::parse(&l.ctx_json));
        if !super::is_synthetic_writer(&l.writer) {
            d.add(&l.writer, l.seq);
        }
        d.drop_writers(crate::registers::SYNTHETIC_WRITER_PREFIX);
        self.legacy.insert(
            *device,
            LegacyRow {
                upto: seq as i64,
                d,
                dirty: true,
            },
        );
        Ok(())
    }

    /// 一片收尾（与投递同一事务，transport.rs `Delivery::checkpoint`）：旧修改记录闭包与下一个序号写下。
    pub(crate) fn checkpoint(&mut self, c: &Connection, profile: &str) -> Result<(), String> {
        for (device, r) in self.legacy.iter_mut().filter(|(_, r)| r.dirty) {
            c.prepare_cached("INSERT OR REPLACE INTO sync2_legacy (profile_uid, device, upto, ctx) VALUES (srs_id(?1), ?2, ?3, ?4)")
                .map_err(sql)?
                .execute(params![profile, device.0.to_vec(), r.upto, r.d.to_json().to_string()])
                .map_err(sql)?;
            r.dirty = false;
        }
        c.prepare_cached("UPDATE sync2_boot SET next_rank = ?2 WHERE profile_uid = srs_id(?1)")
            .map_err(sql)?
            .execute(params![profile, self.next_rank])
            .map_err(sql)?;
        Ok(())
    }
}

/// 复杂实体的种子。
fn seed(c: &Connection, profile: &str, kind: &str, entity: &str) -> Result<(), String> {
    c.prepare_cached("INSERT OR IGNORE INTO sync2_boot_complex (profile_uid, kind, entity) VALUES (srs_id(?1), ?2, srs_id(?3))")
        .map_err(sql)?
        .execute(params![profile, kind, entity])
        .map_err(sql)?;
    Ok(())
}

/// 折叠分区：同一个实体（寄存器、身份记录）/ 同一条日志的操作总在同一区。FNV-1a，跨版本稳定（分区号在追加时
/// 写进表里，折叠只读表）。
fn part_of(kind: &str, key: &str) -> i64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in kind.bytes().chain(std::iter::once(0)).chain(key.bytes()) {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    (h % PARTS as u64) as i64
}

// ---------------------------------------------------------------- 折叠 + 逐条

/// 收尾推进通道（transport.rs 的 `ingest_finish` / `replay_pending`，以及 [settle]）：追加阶段转入折叠，逐个分区折，
/// 再按投递顺序逐条投其余的，做到 [budget] 用完（一个分区不切开）。返回（做完了没有, 这一次的投影变化）；投影变化
/// 要刷新的缓存与要重放的卡已记进待刷新 / 待重放集合，交回的 [Touched] 只给计数（[counts_only]）。没有通道 = 做完了。
pub(crate) fn advance(
    c: &Connection,
    profile: &str,
    budget: &mut CommitBudget<'_>,
) -> Result<(bool, Touched), String> {
    let mut t = Touched::default();
    let done = advance_into(c, profile, budget, &mut t)?;
    defer_replay(c, profile, &t.cards)?;
    let mut dirty = Dirty::default();
    dirty.notes.extend(std::mem::take(&mut t.marks.notes));
    dirty.cards.extend(std::mem::take(&mut t.marks.cards));
    dirty
        .note_types
        .extend(std::mem::take(&mut t.marks.note_types));
    for (kind, id) in &t.entities_changed {
        match kind.as_str() {
            "note" => dirty.notes.insert(id.clone()),
            "card" => dirty.cards.insert(id.clone()),
            "notetype" => dirty.note_types.insert(id.clone()),
            _ => false,
        };
    }
    // 通道只在新设备上开（本机还没有缓存行）：全部记进待刷新集合，收尾按块刷。
    defer_cache_refresh(c, profile, dirty, false)?;
    t.cards.clear();
    Ok((done, t))
}

fn advance_into(
    c: &Connection,
    profile: &str,
    budget: &mut CommitBudget<'_>,
    t: &mut Touched,
) -> Result<bool, String> {
    let Some(mut b) = boot(c, profile)? else {
        return Ok(true);
    };
    if b.phase == PHASE_APPEND {
        close_append(c, profile)?;
        b.phase = PHASE_FOLD;
        b.cursor = 0;
        set_boot(c, profile, &b)?;
    }
    while b.phase == PHASE_FOLD {
        if b.cursor >= PARTS {
            b.phase = PHASE_MERGE;
            b.cursor = 0;
            set_boot(c, profile, &b)?;
            break;
        }
        let n = fold_part(c, profile, b.cursor, t)?;
        b.cursor += 1;
        set_boot(c, profile, &b)?;
        if !budget.spend(n) {
            return Ok(false);
        }
    }
    while b.phase == PHASE_MERGE {
        if b.cursor as usize >= TARGETS.len() {
            b.phase = PHASE_ONE_BY_ONE;
            b.cursor = -1;
            set_boot(c, profile, &b)?;
            break;
        }
        let (n, done) = merge(c, profile, b.cursor as usize)?;
        if done {
            b.cursor += 1;
            set_boot(c, profile, &b)?;
        }
        if !budget.spend(n) {
            return Ok(false);
        }
    }
    let _p = prof::span("one_by_one");
    loop {
        let batch = read_ops(
            c,
            "b.part = ?2 AND b.rank > ?3 ORDER BY b.rank LIMIT ?4",
            params![profile, PART_ONE_BY_ONE, b.cursor, ONE_BY_ONE_CHUNK],
        )?;
        if batch.is_empty() {
            for table in BOOT_TABLES {
                c.execute(
                    &format!("DELETE FROM {table} WHERE profile_uid = srs_id(?1)"),
                    [profile],
                )
                .map_err(sql)?;
            }
            return Ok(true);
        }
        for (rank, op, now) in batch {
            if !budget.take() {
                set_boot(c, profile, &b)?;
                return Ok(false);
            }
            match op.body().map_err(|e| e.to_string())? {
                // 旧修改记录闭包在追加时已记。
                Body::Edit(e) => super::project_edit_noted(c, profile, &op, &e, now, true, t)?,
                Body::Duplicate { .. } => {}
                body => super::project_body(c, profile, &op, body, now, true, t)?,
            }
            b.cursor = rank;
        }
        set_boot(c, profile, &b)?;
    }
}

/// 追加阶段结束：移进复杂牌组的卡也算复杂（一层：卡不会让别的实体变复杂）。
fn close_append(c: &Connection, profile: &str) -> Result<(), String> {
    let _moved = c
        .execute(
            "INSERT OR IGNORE INTO sync2_boot_complex (profile_uid, kind, entity) \
         SELECT m.profile_uid, 'card', m.card FROM sync2_boot_moves m JOIN sync2_boot_complex x \
           ON x.profile_uid = m.profile_uid AND x.kind = 'deck' AND x.entity = m.deck \
         WHERE m.profile_uid = srs_id(?1)",
            [profile],
        )
        .map_err(sql)?;
    #[cfg(test)]
    cover(3, _moved);
    c.execute(
        "DELETE FROM sync2_boot_moves WHERE profile_uid = srs_id(?1)",
        [profile],
    )
    .map_err(sql)?;
    Ok(())
}

/// 按投递顺序读通道里的操作：（序号, 操作, 收到时刻）。收到时刻是追加时那一片的 `now`，逐条投递在同一片里拿它写
/// 投影（服务器时刻行的 `received_at`、冲突时刻），这里照用。
fn read_ops(
    c: &Connection,
    filter: &str,
    args: impl rusqlite::Params,
) -> Result<Vec<(i64, Op, i64)>, String> {
    type Raw = (
        i64,
        Vec<u8>,
        i64,
        i64,
        i64,
        i64,
        i64,
        i64,
        Vec<u8>,
        bool,
        Option<String>,
        Option<i64>,
        i64,
        i64,
    );
    let raw: Vec<Raw> = c
        .prepare_cached(&format!(
            "SELECT b.rank, o.device, o.seq, o.wall, o.logical, o.deps, o.kind, o.schema, o.payload, o.purged, o.sc, o.sc_at, o.pz, o.received_at \
             FROM sync2_boot_order b JOIN sync2_ops o ON o.profile_uid = b.profile_uid AND o.device = b.device AND o.seq = b.seq \
             WHERE b.profile_uid = srs_id(?1) AND {filter}"
        ))
        .map_err(sql)?
        .query_map(args, |r| {
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get(2)?,
                r.get(3)?,
                r.get(4)?,
                r.get(5)?,
                r.get(6)?,
                r.get(7)?,
                r.get(8)?,
                r.get::<_, i64>(9)? != 0,
                r.get(10)?,
                r.get(11)?,
                r.get(12)?,
                r.get(13)?,
            ))
        })
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    let mut deps: HashMap<i64, Arc<Vv>> = HashMap::new();
    let mut out = Vec::with_capacity(raw.len());
    for (
        rank,
        device,
        seq,
        wall,
        logical,
        dep,
        kind,
        schema,
        payload,
        purged,
        sc,
        sc_at,
        pz,
        received,
    ) in raw
    {
        let device = Id(device.try_into().map_err(|_| "bad device".to_string())?);
        let vv = match deps.get(&dep) {
            Some(v) => Arc::clone(v),
            None => {
                let bytes: Vec<u8> = c
                    .prepare_cached("SELECT vv FROM sync2_deps WHERE id = ?1")
                    .map_err(sql)?
                    .query_row([dep], |r| r.get(0))
                    .map_err(sql)?;
                let v = Arc::new(
                    Vv::read(&mut crate::sync2::codec::Reader::new(&bytes))
                        .map_err(|e| e.to_string())?,
                );
                deps.insert(dep, Arc::clone(&v));
                v
            }
        };
        let payload = snapshots::unpack_payload(c, payload, sc, sc_at, pz)?;
        let op = Op {
            id: OpId {
                device,
                seq: seq as u64,
            },
            hlc: Hlc {
                wall,
                logical: logical as u32,
                device,
            },
            deps: vv,
            kind: kind as u16,
            schema: schema as u16,
            payload: payload.into(),
            purged,
        };
        out.push((rank, op, received));
    }
    Ok(out)
}

/// 一条字段修改的到达（投影行在折叠时按最终的旧修改记录闭包算，见文件头）。
struct Arrival {
    eid: String,
    text: String,
    writer: String,
    seq: i64,
    key: String,
    server: Option<i64>,
    now: i64,
}

/// 一条要写的复习日志投影行。
struct LogRow {
    card: String,
    kind: String,
    rating: Option<i64>,
    at: i64,
    rtype: String,
    origin: String,
    dur: i64,
    text: String,
}

/// 一个分区折完写进投影（一个事务里：调用方的 savepoint）。返回处理的操作条数。
fn fold_part(c: &Connection, profile: &str, part: i64, t: &mut Touched) -> Result<usize, String> {
    let p_read = prof::span("fold.read");
    let ops = read_ops(c, "b.part = ?2 ORDER BY b.rank", params![profile, part])?;
    drop(p_read);
    let n = ops.len();
    let complex: HashSet<(String, String)> = c
        .prepare_cached("SELECT kind, srs_idt(entity) AS entity FROM sync2_boot_complex WHERE profile_uid = srs_id(?1)")
        .map_err(sql)?
        .query_map([profile], |r| Ok((r.get(0)?, r.get(1)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    let is_complex = |kind: &str, id: &str| complex.contains(&(kind.to_owned(), id.to_owned()));

    let mut groups: BTreeMap<(EntKind, String), Vec<Arrival>> = BTreeMap::new();
    // id → (种类, 规范记录, payload_json, created_at)
    let mut entities: BTreeMap<String, (EntKind, String, String, i64)> = BTreeMap::new();
    let mut logs: BTreeMap<String, LogRow> = BTreeMap::new();
    type Meta = (String, Option<String>, i64, Option<i64>, Vec<u8>, i64);
    let mut log_meta: BTreeMap<String, Meta> = BTreeMap::new();
    let mut edit_ops: BTreeMap<String, (Vec<u8>, i64)> = BTreeMap::new();
    let mut ent_ops: BTreeMap<(&'static str, String, Vec<u8>, i64), String> = BTreeMap::new();
    // 服务器时刻行：id → (最小服务器时刻, 第一次落库那一片的 now)。
    let mut stamps: BTreeMap<String, (i64, i64)> = BTreeMap::new();
    let stamp = |m: &mut BTreeMap<String, (i64, i64)>, id: &str, s: i64, now: i64| {
        let e = m.entry(id.to_owned()).or_insert((s, now));
        e.0 = e.0.min(s);
    };
    let mut deferred: Vec<(i64, Vec<u8>, i64)> = Vec::new();

    let p_rows = prof::span("fold.rows");
    for (rank, op, now) in &ops {
        let dev = op.id.device.0.to_vec();
        let seq = op.id.seq as i64;
        match op.body().map_err(|e| e.to_string())? {
            Body::Edit(e) => {
                let ent = e.entity.text();
                if is_complex(e.kind.wire(), &ent) || (e.kind == EntKind::Note && e.key == "tags") {
                    deferred.push((*rank, dev, seq));
                    continue;
                }
                let (eid, v) = super::edit_row(c, profile, op, &e)?;
                // `sync2_edit_ops`：INSERT OR REPLACE（后到者胜）；实体 → 操作索引：INSERT OR IGNORE。
                edit_ops.insert(eid.clone(), (dev.clone(), seq));
                ent_ops
                    .entry((e.kind.wire(), ent.clone(), dev.clone(), seq))
                    .or_insert_with(|| e.key.clone());
                if e.kind == EntKind::Card && e.key == "deck" {
                    if let Ok(Value::String(d)) = serde_json::from_str::<Value>(&e.value) {
                        ent_ops
                            .entry(("deck", d, dev.clone(), seq))
                            .or_insert_with(|| "#move".to_owned());
                    }
                }
                groups.entry((e.kind, ent)).or_default().push(Arrival {
                    eid,
                    text: canonical(&v),
                    writer: v["w"].as_str().unwrap_or_default().to_owned(),
                    seq: v["s"].as_i64().unwrap_or(0),
                    key: e.key.clone(),
                    server: e.legacy.as_ref().and_then(|l| l.server_time),
                    now: *now,
                });
            }
            Body::Log(l) => {
                let card = l.card.text();
                let note = l.note.as_ref().map(|n| n.text());
                if is_complex("card", &card)
                    || note.as_deref().is_some_and(|n| is_complex("note", n))
                {
                    deferred.push((*rank, dev, seq));
                    continue;
                }
                let lid = l.id.text();
                let (intent, arg) = super::intent_code(&l.intent);
                log_meta
                    .entry(lid.clone())
                    .or_insert_with(|| (card.clone(), note.clone(), intent, arg, dev.clone(), seq));
                ent_ops
                    .entry(("card", card.clone(), dev.clone(), seq))
                    .or_insert_with(|| "#log".to_owned());
                if let Some(n) = &note {
                    ent_ops
                        .entry(("note", n.clone(), dev.clone(), seq))
                        .or_insert_with(|| "#log".to_owned());
                }
                if !logs.contains_key(&lid) {
                    let row = super::log_row(profile, op, &l);
                    if let Some(s) = l.legacy_server_time {
                        stamp(&mut stamps, &lid, s, *now);
                    }
                    t.cards.insert(card.clone());
                    t.marks.log(&card);
                    logs.insert(
                        lid,
                        LogRow {
                            card,
                            kind: l.kind.clone(),
                            rating: l.rating,
                            at: l.at,
                            rtype: l.rtype.clone(),
                            origin: l.origin.clone(),
                            dur: l.dur,
                            text: canonical(&row),
                        },
                    );
                }
            }
            Body::Entity { kind, id, data } => {
                let idt = id.text();
                // 投影里已有这个 ID 的行（开通道前本机写下的内置身份记录，见文件头）：不折，交给生产的
                // `project_entity` 比内容。查法与它相同（只按 ID，不分 profile、不分种类）。
                let taken = c
                    .prepare_cached("SELECT 1 FROM srs_entities WHERE id = srs_id(?1)")
                    .map_err(sql)?
                    .exists([&idt])
                    .map_err(sql)?;
                #[cfg(test)]
                cover(4, usize::from(taken));
                if taken || is_complex(kind.wire(), &idt) {
                    deferred.push((*rank, dev, seq));
                    continue;
                }
                // `project_entity`：同 ID 内容不同取规范文本小者。
                let d: Value = serde_json::from_str(&data).unwrap_or(Value::Null);
                let rec = canonical(&json!({"id": idt, "p": profile, "k": kind.wire(), "d": d}));
                let write = match entities.get(&idt) {
                    None => true,
                    Some(old) if old.1 == rec => false,
                    Some(old) => {
                        t.diagnostics
                            .push(format!("entity {idt}: same id, different content"));
                        rec < old.1
                    }
                };
                if write {
                    t.marks.entity(kind, &idt);
                    entities.insert(
                        idt,
                        (
                            kind,
                            rec,
                            canonical(&d),
                            d["createdAt"].as_i64().unwrap_or(0),
                        ),
                    );
                }
            }
            // 追加时已分进逐条那一区；表里有就说明分区规则变过，照逐条投。
            _ => deferred.push((*rank, dev, seq)),
        }
    }

    #[cfg(test)]
    {
        cover(0, n - deferred.len());
        cover(1, deferred.len());
    }

    drop(p_rows);
    let p_land = prof::span("fold.land");
    // 寄存器：同一实体的到达按投递顺序一次落（`land_edit` 逐条落的同一判据）。
    let mut deltas = Deltas::default();
    let mut edits: Vec<(String, EntKind, String, String, String, i64, String)> = Vec::new();
    for ((kind, ent), arrs) in groups {
        let items: Vec<crate::registers::StoredEdit<'_>> = arrs
            .iter()
            .map(|a| (a.text.as_str(), a.server, None))
            .collect();
        let (landed, deleted) = crate::registers::land_stored(&items, 0)?;
        let gone: HashSet<usize> = deleted.iter().flatten().copied().collect();
        for (i, a) in arrs.into_iter().enumerate() {
            if !landed.get(i).copied().unwrap_or(false) {
                continue;
            }
            if let Some(s) = a.server {
                stamp(&mut stamps, &a.eid, s, a.now);
            }
            if kind == EntKind::Card {
                if let Some(p) = a.key.strip_prefix("historyFrom/") {
                    t.cards.insert(ent.clone());
                    t.cards.insert(p.to_owned());
                }
            }
            t.marks.edit(kind, &ent, &a.key);
            if gone.contains(&i) {
                // 逐条投影时落了又被后到的支配删掉：桶行照样建出来。
                deltas.touch(profile, &a.eid);
                #[cfg(test)]
                cover(2, 1);
            } else {
                edits.push((a.eid, kind, ent.clone(), a.key, a.writer, a.seq, a.text));
            }
        }
    }
    edits.sort_by(|a, b| a.0.cmp(&b.0));
    drop(p_land);

    let p_stage = prof::span("fold.stage_rows");
    // 投影行按存储形态追加进暂存表（列序见 [TARGETS]），归并时按表成块写进投影（[merge]）。
    let mut s = stage(c, T_ENTITY, 4, "srs_id(?1), ?2, ?3, ?4")?;
    for (id, (kind, _, payload, created)) in &entities {
        s.execute(rusqlite::named_params! {"?1": id, "?2": kind.wire(), "?3": payload, "?4": created, "?20": profile}).map_err(sql)?;
        deltas.add(profile, b'e', id, &format!("{}{payload}", kind.wire()));
    }
    let mut s = stage(
        c,
        T_EDIT,
        7,
        "srs_id(?1), ?3, srs_id(?4), ?5, srs_id(?6), ?7, srs_edit_pack(?8, ?1, ?20, ?3, ?4, ?5, ?6, ?7)",
    )?;
    for (eid, kind, ent, key, writer, seq, text) in &edits {
        s.execute(rusqlite::named_params! {"?1": eid, "?3": kind.wire(), "?4": ent, "?5": key, "?6": writer, "?7": seq, "?8": text, "?20": profile})
            .map_err(sql)?;
        deltas.add(profile, b'f', eid, text);
    }
    let mut s = stage(
        c,
        T_LOG,
        9,
        "srs_id(?1), srs_id(?3), ?4, ?5, ?6, ?7, ?8, ?9, srs_log_pack(?10, ?1, ?20, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
    )?;
    for (lid, r) in &logs {
        s.execute(rusqlite::named_params! {
            "?1": lid, "?3": r.card, "?4": r.kind, "?5": r.rating, "?6": r.at, "?7": r.rtype, "?8": r.origin, "?9": r.dur, "?10": r.text, "?20": profile
        })
        .map_err(sql)?;
        deltas.add(profile, b'l', lid, &r.text);
    }
    drop(p_stage);
    let p_digest = prof::span("fold.digest");
    deltas.write(c)?;
    drop(p_digest);

    let _p_index = prof::span("fold.stage_index");
    let mut s = stage(c, T_STAMP, 3, "srs_id(?1), ?2, ?3")?;
    for (id, (server, now)) in &stamps {
        s.execute(rusqlite::named_params! {"?1": id, "?2": server, "?3": now, "?20": profile})
            .map_err(sql)?;
    }
    let mut s = stage(c, T_EDIT_OP, 3, "srs_id(?1), ?2, ?3")?;
    for (eid, (d, sq)) in &edit_ops {
        s.execute(rusqlite::named_params! {"?1": eid, "?2": d, "?3": sq, "?20": profile})
            .map_err(sql)?;
    }
    let mut s = stage(c, T_ENT_OP, 5, "?1, srs_id(?2), ?3, ?4, ?5")?;
    for ((kind, ent, d, sq), what) in &ent_ops {
        s.execute(rusqlite::named_params! {"?1": kind, "?2": ent, "?3": d, "?4": sq, "?5": what, "?20": profile}).map_err(sql)?;
    }
    let mut s = stage(
        c,
        T_LOG_META,
        7,
        "srs_id(?1), srs_id(?2), srs_id(?3), ?4, ?5, ?6, ?7",
    )?;
    for (lid, (card, note, intent, arg, d, sq)) in &log_meta {
        s.execute(rusqlite::named_params! {"?1": lid, "?2": card, "?3": note, "?4": intent, "?5": arg, "?6": d, "?7": sq, "?20": profile})
            .map_err(sql)?;
    }
    let mut s = c
        .prepare_cached("INSERT INTO sync2_boot_order (profile_uid, part, rank, device, seq) VALUES (srs_id(?1), ?2, ?3, ?4, ?5)")
        .map_err(sql)?;
    for (rank, d, sq) in &deferred {
        s.execute(params![profile, PART_ONE_BY_ONE, rank, d, sq])
            .map_err(sql)?;
    }
    c.execute(
        "DELETE FROM sync2_boot_order WHERE profile_uid = srs_id(?1) AND part = ?2",
        params![profile, part],
    )
    .map_err(sql)?;
    Ok(n)
}

/// 折叠写的投影表，按归并顺序（暂存表 `sync2_boot_rows` 的 `tbl` = 下标）：（目标表与列, 暂存的列, 关掉摘要
/// 触发器写）。暂存的列按 [fold_part] 写入的顺序 `c1, c2, …`。
const TARGETS: [(&str, &str, bool); 7] = [
    (
        "srs_entities (id, profile_uid, kind, payload_json, created_at)",
        "c1, profile_uid, c2, c3, c4",
        true,
    ),
    (
        "srs_field_edits (id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, jslim)",
        "c1, profile_uid, c2, c3, c4, c5, c6, c7",
        true,
    ),
    (
        "srs_review_logs (id, profile_uid, card_id, kind, rating, occurred_at, review_type, origin, duration_ms, jslim)",
        "c1, profile_uid, c2, c3, c4, c5, c6, c7, c8, c9",
        true,
    ),
    (
        "srs_event_local (event_id, profile_uid, outbox_seq, server_time, received_at)",
        "c1, profile_uid, NULL, c2, c3",
        false,
    ),
    (
        "sync2_edit_ops (edit_id, profile_uid, device, seq)",
        "c1, profile_uid, c2, c3",
        false,
    ),
    (
        "sync2_ent_ops (profile_uid, kind, entity, device, seq, what)",
        "profile_uid, c1, c2, c3, c4, c5",
        false,
    ),
    (
        "sync2_log_meta (log_id, profile_uid, card_id, note_id, intent, arg, device, seq)",
        "c1, profile_uid, c2, c3, c4, c5, c6, c7",
        false,
    ),
];
/// 各表归并的计时名（[prof]）。
const MERGE_SPANS: [&str; 7] = [
    "merge.entities",
    "merge.field_edits",
    "merge.review_logs",
    "merge.event_local",
    "merge.edit_ops",
    "merge.ent_ops",
    "merge.log_meta",
];
const T_ENTITY: usize = 0;
const T_EDIT: usize = 1;
const T_LOG: usize = 2;
const T_STAMP: usize = 3;
const T_EDIT_OP: usize = 4;
const T_ENT_OP: usize = 5;
const T_LOG_META: usize = 6;

/// 暂存一种投影行的插入语句：[n] 列 `c1..cn` 依次取 [values]（profile 是 `?20`：大于各表用到的编号，与它们不撞号）。
fn stage<'c>(
    c: &'c Connection,
    tbl: usize,
    n: usize,
    values: &str,
) -> Result<rusqlite::CachedStatement<'c>, String> {
    let cols: Vec<String> = (1..=n).map(|i| format!("c{i}")).collect();
    c.prepare_cached(&format!(
        "INSERT INTO sync2_boot_rows (profile_uid, tbl, {}) VALUES (srs_id(?20), {tbl}, {values})",
        cols.join(", ")
    ))
    .map_err(sql)
}

/// 归并一步最多写多少行（一步一个事务）。提交前 WAL 要装下这一步写的全部页：一张大表一次写完，WAL 涨到几百 MB
/// （真实全量数据 418 MB，PASSIVE 检查点不截短文件）；步子越小，散列键索引页被重写的遍数越多。
#[cfg(any(not(test), srs_probe))]
const MERGE_CHUNK: i64 = 65_536;
/// 测试里压到很小：一张表分几步归并、中间可以被打断。冷启动探针（`--cfg srs_probe`）用生产值。
#[cfg(all(test, not(srs_probe)))]
const MERGE_CHUNK: i64 = 4;

/// 归并一步（一个事务：调用方的 savepoint）：这张表最早暂存的至多 [MERGE_CHUNK] 行写进投影，同时删掉这些暂存行
/// （腾出的页给之后的步子复用，库文件不随暂存涨；删掉的就是做过的，中途被杀也接得上）。各分区写的键互不相同
/// （实体、日志、修改按分区归属），直接插入。返回（写的行数, 这张表归并完了没有）。
fn merge(c: &Connection, profile: &str, tbl: usize) -> Result<(usize, bool), String> {
    let (target, cols, digest) = TARGETS[tbl];
    let _p = prof::span(MERGE_SPANS[tbl]);
    let last: Option<i64> = c
        .prepare_cached("SELECT rowid FROM sync2_boot_rows WHERE profile_uid = srs_id(?1) AND tbl = ?2 ORDER BY rowid LIMIT 1 OFFSET ?3")
        .map_err(sql)?
        .query_row(params![profile, tbl as i64, MERGE_CHUNK - 1], |r| r.get(0))
        .optional()
        .map_err(sql)?;
    let upto = last.unwrap_or(i64::MAX);
    let q = merge_sql(target, cols);
    let touched = RowTriggerOff::new(c, tbl)?;
    let n = if digest {
        let triggers = DigestTriggersOff::new(c)?;
        let n = c
            .execute(&q, params![profile, tbl as i64, upto])
            .map_err(sql)?;
        triggers.restore()?;
        n
    } else {
        c.execute(&q, params![profile, tbl as i64, upto])
            .map_err(sql)?
    };
    touched.restore(profile, tbl, upto)?;
    c.prepare_cached(
        "DELETE FROM sync2_boot_rows WHERE profile_uid = srs_id(?1) AND tbl = ?2 AND rowid <= ?3",
    )
    .map_err(sql)?
    .execute(params![profile, tbl as i64, upto])
    .map_err(sql)?;
    Ok((n, last.is_none()))
}

/// [merge] 的写入语句。
fn merge_sql(target: &str, cols: &str) -> String {
    format!("INSERT INTO {target} SELECT {cols} {STAGED}")
}

/// 测试：[merge] 写的表有几张。
#[cfg(test)]
pub(crate) const MERGED_TABLES: usize = TARGETS.len();

/// 测试：[merge] 写第 [tbl] 张表的语句的 `EXPLAIN` 操作码。[as_merged] 时在归并的条件下看（行触发器拿掉、摘要
/// 触发器关着，看完照 [merge] 的做法恢复），否则原样（触发器都在）。
#[cfg(test)]
pub(crate) fn merge_plan(
    c: &Connection,
    profile: &str,
    tbl: usize,
    as_merged: bool,
) -> Result<Vec<String>, String> {
    let (target, cols, digest) = TARGETS[tbl];
    let explain = || -> Result<Vec<String>, String> {
        let mut s = c
            .prepare(&format!("EXPLAIN {}", merge_sql(target, cols)))
            .map_err(sql)?;
        let unbound = std::iter::repeat_n(rusqlite::types::Null, s.parameter_count());
        let ops: Result<Vec<String>, rusqlite::Error> = s
            .query_map(rusqlite::params_from_iter(unbound), |r| {
                r.get::<_, String>(1)
            })
            .map_err(sql)?
            .collect();
        ops.map_err(sql)
    };
    if !as_merged {
        return explain();
    }
    let touched = RowTriggerOff::new(c, tbl)?;
    let ops = if digest {
        let triggers = DigestTriggersOff::new(c)?;
        let ops = explain()?;
        triggers.restore()?;
        ops
    } else {
        explain()?
    };
    // 没有暂存行：只把触发器装回去。
    touched.restore(profile, tbl, -1)?;
    Ok(ops)
}

/// 暂存表里一张表到某个 rowid 为止的行（?1 = profile, ?2 = 表的下标, ?3 = rowid 上界）。
const STAGED: &str =
    "FROM sync2_boot_rows WHERE profile_uid = srs_id(?1) AND tbl = ?2 AND rowid <= ?3";

/// 归并的目标表里，写连接上装着「插入一行登记一个待重读」的 TEMP 触发器的那几张（queue.rs [TRIGGERS]：复习队列 /
/// 浏览会话）：（[TARGETS] 下标, 触发器名, 对暂存的这一块行做同样登记的一条查询）。
///
/// 目标表上只要有行触发器，SQLite 的 `INSERT … SELECT` 就先把 SELECT 的结果整份物化进一张临时表、再从临时表逐行
/// 插（insert.c：触发器可能读到正在写的表）；临时表超过页缓存就落临时文件。归并一块几万行、每行带着整份载荷
/// （笔记字段的修改记录一行可以几 KB），等于把这一块多写、多读一遍。归并这几张表时先把触发器拿掉、写完按同一批行
/// 成块登记、再装回去（[RowTriggerOff]）：登记的是同一批 (种类, profile, id)，登记本身是往一个集合里加，与顺序无关。
/// 都在调用方的 savepoint 里，中途失败连同触发器一起回滚。
///
/// `merge_statements_never_materialize_their_rows` 按 `EXPLAIN` 核对每张表的写入语句都不开临时表（以后给哪张表加了
/// 行触发器而这里没跟上会红），`merging_registers_the_same_rows_as_the_row_triggers` 核对登记的集合与触发器逐行
/// 登记的相同。
const ROW_TRIGGERS: [(usize, &str, &str); 3] = [
    (
        T_EDIT,
        "srs_browse_edit_ins",
        "SELECT srs_study_touch(2, profile_uid, c3) FROM sync2_boot_rows \
         WHERE profile_uid = srs_id(?1) AND tbl = ?2 AND rowid <= ?3 AND c2 = 'note'",
    ),
    (
        T_LOG,
        "srs_study_log_ins",
        "SELECT srs_study_touch(1, profile_uid, c1) FROM sync2_boot_rows \
         WHERE profile_uid = srs_id(?1) AND tbl = ?2 AND rowid <= ?3",
    ),
    (
        T_STAMP,
        "srs_browse_stamp_ins",
        "SELECT srs_study_touch(2, f.profile_uid, f.entity_id) FROM sync2_boot_rows b \
         JOIN main.srs_field_edits f ON f.id = b.c1 \
         WHERE b.profile_uid = srs_id(?1) AND b.tbl = ?2 AND b.rowid <= ?3 AND b.c2 IS NOT NULL \
           AND f.entity_kind = 'note'",
    ),
];

/// 归并一张表期间拿掉它的插入行触发器（[ROW_TRIGGERS]）；[RowTriggerOff::restore] 按写进去的那批行成块登记并把
/// 触发器装回去。这条连接上没装触发器（没有复习队列的连接）或这张表没有行触发器时什么也不做。
///
/// 中途出错时调用方的 savepoint 回滚会连触发器一起恢复（TEMP 库的结构改动也在事务里）；丢弃守卫时仍再装一次
/// （`IF NOT EXISTS`），不把「触发器还在不在」押在调用方一定回滚上——少了它复习队列 / 浏览就再也看不到新写的行。
struct RowTriggerOff<'a> {
    c: &'a Connection,
    /// 拿掉了触发器、还没装回去时：对写进去的那批行做同样登记的查询。
    touch: Option<&'static str>,
}

impl<'a> RowTriggerOff<'a> {
    fn new(c: &'a Connection, tbl: usize) -> Result<Self, String> {
        let Some(&(_, name, touch)) = ROW_TRIGGERS.iter().find(|t| t.0 == tbl) else {
            return Ok(RowTriggerOff { c, touch: None });
        };
        let installed: bool = c
            .prepare_cached(
                "SELECT EXISTS (SELECT 1 FROM sqlite_temp_master WHERE type = 'trigger' AND name = ?1)",
            )
            .map_err(sql)?
            .query_row([name], |r| r.get(0))
            .map_err(sql)?;
        if !installed {
            return Ok(RowTriggerOff { c, touch: None });
        }
        c.execute_batch(&format!("DROP TRIGGER temp.{name}"))
            .map_err(sql)?;
        Ok(RowTriggerOff {
            c,
            touch: Some(touch),
        })
    }

    fn restore(mut self, profile: &str, tbl: usize, upto: i64) -> Result<(), String> {
        let Some(touch) = self.touch else {
            return Ok(());
        };
        {
            let mut s = self.c.prepare(touch).map_err(sql)?;
            let mut rows = s.query(params![profile, tbl as i64, upto]).map_err(sql)?;
            while rows.next().map_err(sql)?.is_some() {}
        }
        self.c
            .execute_batch(crate::store::queue::TRIGGERS)
            .map_err(sql)?;
        // 装回去成功才算恢复：失败时丢弃守卫还会再试一次。
        self.touch = None;
        Ok(())
    }
}

impl Drop for RowTriggerOff<'_> {
    fn drop(&mut self) {
        if self.touch.is_some() {
            let _ = self.c.execute_batch(crate::store::queue::TRIGGERS);
        }
    }
}

/// 关掉这条连接上主库的触发器（摘要桶，digest.rs）；[DigestTriggersOff::restore] 或出错丢弃时打开。TEMP 触发器
/// （复习队列 / 浏览的待重读，queue.rs）不受这个开关影响，照常触发。
///
/// 切换这个开关会让这条连接上全部预编译语句失效（SQLite `sqlite3ExpirePreparedStatements`）：下次执行时自动重编译，
/// 但**正执行到一半**的语句再往下走会直接报错。只在归并一张表的写入前后切，那时写连接上没有执行中的语句。
struct DigestTriggersOff<'a> {
    c: &'a Connection,
    on: bool,
}

impl<'a> DigestTriggersOff<'a> {
    fn new(c: &'a Connection) -> Result<Self, String> {
        c.set_db_config(DbConfig::SQLITE_DBCONFIG_ENABLE_TRIGGER, false)
            .map_err(sql)?;
        Ok(DigestTriggersOff { c, on: false })
    }

    fn restore(mut self) -> Result<(), String> {
        self.c
            .set_db_config(DbConfig::SQLITE_DBCONFIG_ENABLE_TRIGGER, true)
            .map_err(sql)?;
        // 打开成功才算恢复：失败时丢弃守卫还会再试一次。
        self.on = true;
        Ok(())
    }
}

impl Drop for DigestTriggersOff<'_> {
    fn drop(&mut self) {
        if !self.on {
            let _ = self
                .c
                .set_db_config(DbConfig::SQLITE_DBCONFIG_ENABLE_TRIGGER, true);
        }
    }
}

/// [settle] 一片的预算：与收尾同一个片长（[CommitBudget::timed]），一个分区 / 一块归并 / 一段逐条各自提交。
#[cfg(any(not(test), srs_probe))]
fn settle_budget() -> CommitBudget<'static> {
    CommitBudget::timed(super::transport::COMMIT_SLICE)
}

/// 测试里按条数切（切点确定、小世界也切成好几片）。
#[cfg(all(test, not(srs_probe)))]
fn settle_budget() -> CommitBudget<'static> {
    CommitBudget::ops(3)
}

/// 把通道做完：本机要写、会话外要投递之前（ffi.rs 分发器与 `channel_settle`、一次收完、导入、带分叉的收尾、并入
/// 提交），以及新会话开始时上一次的收尾没做完（[begin]）。[w] 是写连接，**不在调用方的事务里**。
///
/// 与收尾（`ingest_finish` / `replay_pending`）同样按片：每片一个 SAVEPOINT，没有外层事务时就是一次提交——WAL 只装
/// 一片（一个分区 / 至多 [MERGE_CHUNK] 行的一块归并）写的页，失败只回滚这一片，已做的留着、下次接着做。以前整段
/// 在调用方的一个事务里做完：整份投影（真实全量数据约 1.1 GB）落进同一笔事务，WAL 要装下全部页，失败整段回滚、
/// 下一条写命令又从头重做。
///
/// 每片提交后把这一片落进投影的变化交给 [settled]：这些片没有自己的回包，Dart 那一侧按内容 / 视图 / RWKV 刷新信号
/// 记的缓存（牌组树、profile 修改记录、分数表）不知道投影变了。调用方把它们攒在内核里，随这个 profile 的下一条命令
/// 的回包交回（[crate::store::SrsCore::note_settled] / `take_settled`）。中途出错时已提交的片已经交过了。
///
/// 写连接上开着事务（`is_autocommit` 为假）时中途提交不了，只能在那笔事务里一次做完：这是兜底。写连接上唯一能
/// 跨调用留着的事务是旧库搬迁（`legacy_open`），搬迁期间不该有这个 profile 的命令进来，正常路径走不到这里。
///
/// 之后这个 profile 按逐条投递收；会话里缓存的投递队列（带着追加状态）作废重载（一开始就作废：做了一片之后出错，
/// 通道也已不在追加阶段）。要刷新的缓存与要重放的卡留在待刷新 / 待重放集合里，与逐条投递收段途中一样等收尾。
pub(crate) fn settle(
    w: &Connection,
    profile: &str,
    settled: &mut dyn FnMut(&Touched),
) -> Result<(), String> {
    if !active(w, profile)? {
        return Ok(());
    }
    super::transport::bump_delivery_epoch();
    if !w.is_autocommit() {
        let (_, t) = super::in_savepoint(w, |c| {
            settle_slice(c, profile, &mut CommitBudget::unlimited())
        })?;
        settled(&t);
        return Ok(());
    }
    loop {
        #[cfg(test)]
        if FAIL_SETTLE_AT.with(|f| f.get()) == Some(SETTLE_SLICES.with(|s| s.get())) {
            return Err("sync2 channel: injected settle failure".to_owned());
        }
        let (done, t) = super::in_savepoint(w, |c| settle_slice(c, profile, &mut settle_budget()))?;
        settled(&t);
        #[cfg(test)]
        SETTLE_SLICES.with(|s| s.set(s.get() + 1));
        if done {
            return Ok(());
        }
    }
}

/// [settle] 的一片：[advance]，这一片落进投影的变化在同一个 SAVEPOINT 里记进本机状态行的修订号——这里没有回包
/// 可带（收段命令自己推进通道时并进它的结果，[absorb]），不记的话这些事件就从不推进修订号（自动备份据它判断
/// 「有没有变动」）。返回通道做完了没有，以及这一片落进投影的变化。
fn settle_slice(
    c: &Connection,
    profile: &str,
    budget: &mut CommitBudget<'_>,
) -> Result<(bool, Touched), String> {
    let (done, t) = advance(c, profile, budget)?;
    crate::store::local_state::advance_revision(c, profile, &t)?;
    Ok((done, t))
}

/// 通道自己做完的片（[settle]）攒下的投影变化，等这个 profile 的下一条命令带回 Dart。只留 Dart 要的那几样：推进
/// 内容 / 视图 / RWKV 刷新信号的计数、可见性变了的实体、被彻底清除的实体。要刷新的缓存行不在这里（留在待刷新集合里
/// 等收尾）。
#[derive(Default, Debug)]
pub(crate) struct Settled {
    landed: u64,
    content: u64,
    view: u64,
    rwkv: u64,
    changed: std::collections::BTreeSet<(String, String)>,
    purged: std::collections::BTreeSet<(String, String)>,
}

impl Settled {
    pub(crate) fn absorb(&mut self, t: &Touched) {
        self.landed += t.marks.landed;
        self.content += t.marks.content;
        self.view += t.marks.view;
        self.rwkv += t.marks.rwkv;
        self.changed.extend(t.entities_changed.iter().cloned());
        self.purged.extend(t.purged.iter().cloned());
    }

    pub(crate) fn merge(&mut self, o: Settled) {
        self.landed += o.landed;
        self.content += o.content;
        self.view += o.view;
        self.rwkv += o.rwkv;
        self.changed.extend(o.changed);
        self.purged.extend(o.purged);
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.landed == 0 && self.changed.is_empty() && self.purged.is_empty()
    }

    /// 与改投影命令的回包同形的那几个键（Dart `_absorbProjection` 直接读）：
    /// `{"marks": {"landed", "content", "view", "rwkv"}, "changed": [[kind, id]], "purged": [[kind, id]]}`。
    pub(crate) fn to_json(&self) -> serde_json::Value {
        let pairs = |s: &std::collections::BTreeSet<(String, String)>| {
            s.iter()
                .map(|(k, e)| serde_json::json!([k, e]))
                .collect::<Vec<_>>()
        };
        serde_json::json!({
            "marks": {
                "landed": self.landed,
                "content": self.content,
                "view": self.view,
                "rwkv": self.rwkv,
            },
            "changed": pairs(&self.changed),
            "purged": pairs(&self.purged),
        })
    }
}

/// [advance] 交回的投影变化并进调用方这一次的结果（计数相加、集合取并）。
pub(crate) fn absorb(t: &mut Touched, o: Touched) {
    t.marks.notes.extend(o.marks.notes);
    t.marks.cards.extend(o.marks.cards);
    t.marks.note_types.extend(o.marks.note_types);
    t.marks.landed += o.marks.landed;
    t.marks.content += o.marks.content;
    t.marks.view += o.marks.view;
    t.marks.rwkv += o.marks.rwkv;
    t.dominated.extend(o.dominated);
    t.cards.extend(o.cards);
    t.entities_changed.extend(o.entities_changed);
    t.purged.extend(o.purged);
    t.diagnostics.extend(o.diagnostics);
}

impl crate::store::SrsCore {
    /// 分发器（ffi.rs）在会改投影 / 依赖完整投影的命令之前调：这个 profile 有没做完的收段通道就按片做完（[settle]）。没有任何通道时只读内存里的标记（[SrsCore::channel_live]），
    /// 不拿写锁、不查表——只读命令（`digest` 等）不因此排在写锁后面。
    pub(crate) fn sync2_channel_settle(&self, profile: &str) -> Result<(), String> {
        if !self.channel_live.load(std::sync::atomic::Ordering::SeqCst) {
            return Ok(());
        }
        let w = self.writer()?;
        self.settle_channel_on(&w, profile)
    }

    /// [Self::sync2_channel_settle]，调用方已持写连接 [w]（不在事务里时按片提交，见 [settle]）。
    pub(crate) fn settle_channel_on(&self, w: &Connection, profile: &str) -> Result<(), String> {
        if !self.channel_live.load(std::sync::atomic::Ordering::SeqCst) {
            return Ok(());
        }
        settle(w, profile, &mut |t| self.note_settled(profile, t))?;
        self.recheck_channel_live(w)
    }

    /// 通道自己做完的一片落进投影的变化：攒着，等 [profile] 的下一条命令带回 Dart（[Self::take_settled]）。什么都没
    /// 落的片不记。
    pub(crate) fn note_settled(&self, profile: &str, t: &Touched) {
        let mut one = Settled::default();
        one.absorb(t);
        if one.is_empty() {
            return;
        }
        // 只是几个计数与 ID：panic 毒化过照常用。
        self.settled
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .entry(profile.to_owned())
            .or_default()
            .merge(one);
    }

    /// 取走 [profile] 攒下的通道变化（[Self::note_settled]），连同**此刻**库里的修订号与纪元（已提交快照；通道的片在
    /// 自己的 SAVEPOINT 里推进过修订号，Dart 手里的还是推进之前的）：
    /// `{"marks", "changed", "purged", "localRevision", "localEpoch"}`。没有攒下的 → None。
    ///
    /// 分发器在命令**成功**、回包是对象、且请求带了 `settled: true` 时调（ffi.rs `sync2_dispatch`）：不吸收回包的
    /// 调用方不会把它取走丢掉。读修订号失败（库正被关）就放回去不带，留给下一条命令。
    pub(crate) fn take_settled(&self, profile: &str) -> Option<serde_json::Value> {
        let pending = self
            .settled
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(profile)?;
        let state = self.read_visible(|c| crate::store::local_state::read(c, profile));
        let state = match state {
            Ok(s) if s["exists"] == serde_json::json!(true) => s,
            _ => {
                self.settled
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .entry(profile.to_owned())
                    .or_default()
                    .merge(pending);
                return None;
            }
        };
        let mut v = pending.to_json();
        v["localRevision"] = state["revision"].clone();
        v["localEpoch"] = state["epoch"].clone();
        Some(v)
    }

    /// [profile] 的数据整份删了（`profile_purge` / 并入提交）：攒下的通道变化没有人要了。
    pub(crate) fn forget_settled(&self, profile: &str) {
        self.settled
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(profile);
    }

    /// 收段会话开了通道（[begin] 返回真）：之后的命令要先看通道。
    pub(crate) fn note_channel_live(&self) {
        self.channel_live
            .store(true, std::sync::atomic::Ordering::SeqCst);
    }

    /// 已提交的状态里还有没有任何 profile 的通道，按它重置标记。只在写连接不在事务里时清：事务里删掉的通道行可能
    /// 随回滚回来，标记宁可多留（多一次查表）也不能先清。
    pub(crate) fn recheck_channel_live(&self, w: &Connection) -> Result<(), String> {
        if w.is_autocommit() {
            let any: bool = w
                .query_row("SELECT EXISTS (SELECT 1 FROM sync2_boot)", [], |r| r.get(0))
                .map_err(sql)?;
            self.channel_live
                .store(any, std::sync::atomic::Ordering::SeqCst);
        }
        Ok(())
    }

    /// 这个 profile 有没有进行中的通道（`identity` 回报给 Dart；诊断 / 测试用）。
    pub(crate) fn sync2_channel_active(&self, profile: &str) -> Result<bool, String> {
        if !self.channel_live.load(std::sync::atomic::Ordering::SeqCst) {
            return Ok(false);
        }
        self.read_visible(|c| active(c, profile))
    }
}

// ---------------------------------------------------------------- 测试

#[cfg(test)]
thread_local! {
    static OFF: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    static COVER: std::cell::Cell<[usize; 5]> = const { std::cell::Cell::new([0; 5]) };
    /// [settle] 提交过的片数（[SETTLE_SLICES]，[take_settle_slices] 清零后从 0 数）到这个值时报错（测试：中途失败只丢那一片）。
    static FAIL_SETTLE_AT: std::cell::Cell<Option<usize>> = const { std::cell::Cell::new(None) };
    /// [settle] 按片提交的累计片数。
    static SETTLE_SLICES: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

/// 测试：之后的 [settle] 做到第 [at] 片时报错（None = 不注入）。
#[cfg(test)]
pub(crate) fn fail_settle_at(at: Option<usize>) {
    FAIL_SETTLE_AT.with(|f| f.set(at));
}

/// 测试：[settle] 按片提交过的片数，取走清零。
#[cfg(test)]
pub(crate) fn take_settle_slices() -> usize {
    SETTLE_SLICES.with(|s| s.replace(0))
}

/// 测试：[f] 里开的收段会话不走通道（逐条投递的对照组，tests_channel.rs）。
#[cfg(test)]
pub(crate) fn sequential<T>(f: impl FnOnce() -> T) -> T {
    OFF.with(|o| o.set(true));
    let r = f();
    OFF.with(|o| o.set(false));
    r
}

#[cfg(test)]
fn forced_off() -> bool {
    OFF.with(|o| o.get())
}

#[cfg(not(test))]
fn forced_off() -> bool {
    false
}

#[cfg(test)]
fn cover(k: usize, n: usize) {
    COVER.with(|c| {
        let mut v = c.get();
        v[k] += n;
        c.set(v);
    });
}

/// 测试：各分支走过几次——（折叠的操作, 挪去逐条的操作, 折叠里落了又被支配的, 移进复杂牌组的卡, 投影里已有同 ID 行
/// 的身份记录），取走清零。
#[cfg(test)]
pub(crate) fn take_coverage() -> [usize; 5] {
    COVER.with(|c| c.replace([0; 5]))
}
