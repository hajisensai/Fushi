//! 新代分发器（规划 §2.2 S1；逐条接线清单见交接说明「分发器命令对照表」与「S1 接线设计」）：`ffsrs_store_sync2` 的每一条
//! JSON 命令到 `cmd/` 的新代实现。协议 3 的分发器（`store/legacy3`）只有 5 条冻结命令编进生产构建（换代迁移与整包备份读入用），
//! 其余臂只编进测试构建、给协议 3 的测试与对拍装置（G7-6）；`ffsrs_store_sync2` 不经它。
//!
//! # 命令的三种去向（[wiring]）
//!
//! - [Wiring::Wired]：接到新代实现（[run] 里有它的臂）。
//! - [Wiring::Unwired]：归别的模块接线（W3 合流后 G8-7b / G9-5 都已接完，眼下没有命令处于这一状态），报
//!   `kernel::UNWIRED` 开头的明确错误——不 panic、不回落到协议 3。
//! - [Wiring::Removed]：新代不需要（派生层随写入维护、没有收段通道、没有协议 3 的存储表示），报 `kernel::REMOVED` 开头的
//!   错误，调用方（Dart，G7-5）不再发。
//!
//! 协议 3 分发器里的每一条命令都必须在 [wiring] 里有去向（`ffi.rs` 的 `every_protocol_3_command_has_a_gen4_wiring` 按
//! 协议 3 分发器源码里的匹配臂逐条核对），标成接线的必须在 [run] 里有臂（同一个测试）。
//!
//! # 一条命令的形状
//!
//! - **按集合**：请求的 `profile` 经 `Truth::binding_of` 换成本机集合号；没绑定 = 明确报错（绑定由迁移或身份命令
//!   `identity` / `collection_adopt` 建，其余命令不顺手建，`cmd/identity.rs` 文件头「谁在什么时候建」）。本机状态行
//!   （`local_state*`）只按 profile 记，不要绑定。
//! - **改绑定的写**（`identity` 第一次建、`collection_join` / `collection_salts_add` / `collection_adopt`）：命令返回
//!   绑定变化，[write_binding] 在写事务**提交成功之后**把它放进回包的 `bindingChanged`；回滚就没有回包、事件丢掉
//!   （规划缺口 G-4）。
//! - **读**（读连接）：集合号的换算与命令本体在**同一个读快照**里（`cmd::snapshot`，命令自己的快照沿用它）。浏览与出卡
//!   例外：浏览会话要分清「在调用方的写事务里读」（`cmd/browse.rs` 文件头），出卡会话要在读快照的第一条读之前取走待重读
//!   id（`cmd/study.rs` 文件头），所以集合号先单独换算、命令自己开快照。
//! - **写**（写连接，[G4Core::write]）：集合号、命令本体（`cmd/writes*.rs`，自己开 SAVEPOINT）、请求带 `study` 时的排队
//!   （看得见这笔还没提交的写入）、本机状态行（`local.rs` [persist]，回包 `localRevision` / `localEpoch`）在**一个**
//!   `BEGIN IMMEDIATE` 事务里；任何一步出错整笔回滚。`apply` 的前置条件不成立（`stale`）什么都不写，也不推进修订号。
//! - **回包**：读命令与协议 3 逐键相同（各 `cmd/*` 文件头写了按规范 ID 的差别）；写命令是 G7-3b 的统一回包
//!   （`changed` / `purged` / `replayed` / `edits` / `nextSeq` / `settled`，协议 3 的 `marks` / `diagnostics` / `cache` 是
//!   投影表与 Dart 缓存镜像的落库细节，新代没有），外加 `localRevision` / `localEpoch` 与 `study`。
//!
//! # 常驻会话的失效
//!
//! - 进程内刷新键（`refresh_keys`，`refresh.rs`）：本机写命令提交之后按 `Session` 记的变化类别推进（[local_write]）；
//!   整层重建、改身份 / 别名 / 绑定的写、`local_state {reload}` 整份作废。
//!
//! - 浏览会话：按缓存层代号 `cache_gen` 自己对上（`cmd/browse.rs`），写入经派生层收尾记账，这里不用做什么。
//! - 统计原料缓存：键是 (集合, 统计指纹, 写入代数, 缓存层代号)；本进程每条写命令提交之后写入代数 +1，别的进程的写入
//!   由缓存层代号兜住。`stats_release` 丢掉。
//! - 出卡：常驻会话（`cmd/study.rs`，会话本体 `store/queue.rs`）靠 Primary 写连接上的临时触发器逐行记账（卡缓存行、日志
//!   索引、卡的修改、别名表的净变化），写锁放下时挪成已提交（`kernel.rs` `Writer` 的 `Drop`）；不经 `Session` 的写一样被
//!   触发器看见，这里不用做什么。Secondary 按刷新键印记整份重建（[run] 的 `study` 臂）。
//!
//! # C 直出入口（S1b）
//!
//! 逐卡重放与训练集的 C 入口（`ffsrs_store_history_states` / `_stat_projection` / `_optimizer_items` /
//! `_calibration_items` / `_rwkv_rows` / `_rwkv_log_tail`，`store/ffi.rs`）照旧解码输入页，经本文件末尾那一节换出集合号
//! （[direct_col]：页里带 profile 行就按它，否则按卡认集合）后调 `cmd/training.rs`，集合号与命令本体同一个读快照；
//! 输出布局与协议 3 逐字节相同（`cmd/dispatch_tests.rs` 经 C ABI 对拍）。

use rusqlite::OptionalExtension;
use serde_json::{Value, json};

use super::cache::{CACHE_RULES, CFG_KEY, RULES_KEY, RWKV_FILL_FROM, RWKV_FILL_KEY};
use super::cmd::{self, snapshot};
use super::derive::{Index, Ref, Settled};
use super::files::OpenMode;
use super::identity::BindingChanged;
use super::ingest::{Settle, ingest_settle};
use super::kernel::{G4Core, READ_ONLY, StatsEntry, removed, unwired};
use super::local;
use super::refresh::Tally;
use super::schema::sql;
use super::truth::Truth;
use crate::projection::{Alg, Day};
use crate::store::projections::RwkvRange;
use crate::sync2::op::EntKind;

/// 一条命令在新代里的去向（模块文件头）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Wiring {
    Wired,
    /// 归哪个模块接线。
    Unwired(&'static str),
    /// 为什么不需要。
    Removed(&'static str),
}

/// 改投影、读完整投影之类的旧机制在新代里不存在的统一原因。
const NO_CHANNEL: &str =
    "gen4 has no ingest channel: received segments land in the truth layer directly";
const P3_REPR: &str = "a protocol 3 storage detail; the implementation is deleted with G7-6";
const NO_DIGEST_BUCKETS: &str = "gen4 has no digest buckets to bisect: the semantic digest is one hash over the derived layer (Index::digest)";
const NO_OBSOLETE_ACK: &str = "gen4 `obsolete` keeps no to-delete list: it decides from this round's listing, so failed deletes are simply offered again";
const NO_P3_MERGE: &str = "gen4 starts no protocol 3 style profile merges: linking another collection is `collection_adopt` / `collection_join`; a merge left half done before the switch is finished by `profile_merge_commit`";
const NO_REHEARSAL: &str =
    "the pre-migration rehearsal only makes sense before the generation switch; G7-6 deletes it";

/// [op] 的去向；不认识的命令 = None。
pub fn wiring(op: &str) -> Option<Wiring> {
    use Wiring::*;
    Some(match op {
        // 库级
        "read_lib" | "wal_checkpoint" | "bulk_cache" => Wired,
        // 读
        "read" | "card_columns" | "stats_report" | "stats_recall" | "stats_rows"
        | "stats_release" | "anki_resolve" | "anki_notes_info" | "lineages" | "history"
        | "conflicts" | "checkpoints" | "undo_check" | "plan_restore" | "binding_get"
        | "profile_footprint" | "status" | "study" | "local_state" | "preview" => Wired,
        // 每实体视图（G10-2：协议 3 没有对应命令；远程复习 V2 的主机搬它，线上形状见 `cmd/views.rs` 文件头）
        "entity_views" => Wired,
        // 进程内刷新键（S1c，`refresh.rs`）
        "refresh_keys" => Wired,
        // 浏览会话
        "browse_query" | "browse_rows" | "browse_ids" | "browse_targets" | "browse_close"
        | "browse_stats" | "browse_counts" | "browse_sources" | "anki_find" | "anki_dupes"
        | "anki_tags" => Wired,
        // 本机写命令（带本机状态行）
        "apply" | "import_drafts" | "change" | "note_fields_if" | "merge_notes" | "sched"
        | "deck_delete" | "resolve" | "purge" | "checkpoint" | "restore" | "trust" | "dedup"
        | "digest_heal" => Wired,
        // 其余写
        "device_info" | "device_hint" | "local_state_ensure" | "local_anchor"
        | "cache_config_set" | "refresh_caches" | "rebuild_caches" | "rwkv_last_fill" => Wired,
        // 纯加解密（不碰库）
        "seal" | "open" | "seal_file" | "open_file" | "derive_key" => Wired,
        // 媒体回收（`cmd/media_gc.rs`）：待回收集合存在本机状态行里，存活引用读缓存层。
        "media_gc_queue" | "media_gc_collect" | "media_live_refs" => Wired,
        // 身份（G9-4，`cmd/identity.rs`）
        "identity" | "binding_set" => Wired,
        // 身份：新代才有的命令（协议 3 没有对应物，规划 §1.6）
        "collection_info"
        | "collection_join"
        | "collection_salts_add"
        | "collection_adopt"
        | "canonical_ids"
        | "key_evidence"
        | "divergence" => Wired,
        // 彻底清除的字节层收尾状态（`scrub.rs`；新代才有，协议 3 没有字节层收尾）
        "scrub_state" => Wired,
        // 互联 host 按位置目录名找 profile（G10-4，`cmd/identity.rs` `profile_of_dir`；不针对单个 profile）
        "profile_of_dir" => Wired,
        // profile 数据（G9-5，`cmd/profile_data.rs`）：清除、无主扫描、链接记的集合、迁移带过来的半截并入的收尾。
        "profile_uids"
        | "orphan_sweep_done"
        | "meta_set_edit"
        | "profile_purge"
        | "profile_merge_commit" => Wired,
        "profile_merge_mark" => Removed(NO_P3_MERGE),
        // 同步一轮（G8-7，`cmd/sync.rs`）
        "location_root" | "plan" | "ingest" | "ingest_finish" | "outbox" | "outbox_ack"
        | "head" | "obsolete" | "retire" | "rotate" | "location_sealed" | "location_seal"
        | "digest" => Wired,
        // 移除位置（G8-7c，`cmd/sync.rs` `location_forget`；新代才有的命令）
        "location_forget" => Wired,
        "ingest_yield" | "ingest_commit" | "ingest_batch" | "ingest_prepare" | "replay_pending" => {
            Removed(NO_CHANNEL)
        }
        // 收段会话（G8-7b）：只在会话期间把 RWKV 刷新键攒住（`refresh.rs` `rwkv_held`），没有收段通道。
        "ingest_begin" | "ingest_end" => Wired,
        "digest_buckets" => Removed(NO_DIGEST_BUCKETS),
        "obsolete_ack" => Removed(NO_OBSOLETE_ACK),
        // 旧身份目录清理（G8-7b，`cmd/sync.rs` `obsolete_former`）
        "obsolete_former" => Wired,
        // 媒体同步（G8-7b，`cmd/media_sync.rs`；清单收发是新代才有的命令）
        "media_known"
        | "media_record"
        | "media_hash"
        | "media_scan"
        | "media_landed"
        | "media_doomed"
        | "media_manifests"
        | "media_manifest_ingest"
        | "media_manifest_build"
        | "media_manifest_published" => Wired,
        // 旧根接手与承袭上传（G8-7b，`cmd/sync_oldroot.rs`）
        "oldroot_scan" | "oldroot_ingest" | "heritage_plan" | "heritage_outbox"
        | "heritage_ack" => Wired,
        // 转发（FRL4，G8-7b，`cmd/sync_relay.rs`）：收段时留下的作者段原文（`relay_segs`）装成中继件发到缺它的位置。
        "relay_outbox" | "relay_ack" => Wired,
        // 导入 / 导出（G11-3，`cmd/fushisrs.rs`）
        "import" | "export" => Wired,
        // 整包备份里换代之前的复习数据读入（G11-4，`cmd/backup.rs`；新代才有的命令）
        "legacy_backup_import" => Wired,
        // 新代不需要
        "channel_settle" => Removed(NO_CHANNEL),
        "migrate"
        | "replay_all"
        | "legacy_dots"
        | "backfill_dupe_norms"
        | "backfill_tag_sources"
        | "backfill_source_keys"
        | "edits_rewrite_repr" => Removed(P3_REPR),
        "gen4_rehearse" | "gen4_rehearsal_report" | "gen4_rehearse_cancel" => Removed(NO_REHEARSAL),
        _ => return None,
    })
}

/// 一条 JSON 命令（`ffsrs_store_sync2` 的唯一入口）。
pub fn dispatch(
    c: &G4Core,
    req: &Value,
    blobs: &mut Vec<Vec<u8>>,
    files: &mut cmd::Files,
) -> Result<Value, String> {
    let op = req
        .get("op")
        .and_then(Value::as_str)
        .ok_or("sync2: missing op")?;
    match wiring(op) {
        None => Err(format!("unknown sync2 op {op}")),
        Some(Wiring::Unwired(owner)) => Err(unwired(op, owner)),
        Some(Wiring::Removed(why)) => Err(removed(op, why)),
        Some(Wiring::Wired) => {
            let out = run(c, op, req, blobs, files);
            // 审计版的库：这条命令跑过的语句里有没有拿 UUID 文本当 ID 的（`id_audit.rs`）；有就报错，不交回包。
            #[cfg(feature = "id_audit")]
            super::id_audit::take(None)?;
            out
        }
    }
}

/// 标成接线却没有臂的命令报的错（[run] 的兜底；测试按它核对）。
pub(crate) const NO_ARM: &str = "gen4 dispatch: marked wired but has no arm";

/// 改投影的命令：Dart 只能在本副本的独占区里发、按顺序吸收回包（`SrsDbStore.kSrsSync2ProjectingOps` 与它同一组，
/// 守卫 `srs_read_only_executor_guard_test.dart`）。= 走 [local_write] 的本机写命令，加上不经 `Session` 落真相、
/// 回包同样改投影的 `import` 与同步一轮的 `ingest` / `ingest_finish` / `retire`。协议 3 的收段通道命令
/// （`ingest_batch` / `ingest_commit` / `replay_pending`）新代没有（[Wiring::Removed]），不在这里。
pub const PROJECTING_OPS: &[&str] = &[
    "apply",
    "import_drafts",
    "change",
    "note_fields_if",
    "merge_notes",
    "sched",
    "deck_delete",
    "retire",
    "ingest",
    "ingest_finish",
    "import",
    "resolve",
    "trust",
    "purge",
    "checkpoint",
    "restore",
    "dedup",
    "digest_heal",
];

fn str_of<'a>(req: &'a Value, k: &str) -> Result<&'a str, String> {
    req.get(k)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("sync2: missing {k}"))
}

fn int_of(req: &Value, k: &str) -> Result<i64, String> {
    req.get(k)
        .and_then(Value::as_i64)
        .ok_or_else(|| format!("sync2: missing {k}"))
}

/// profile → 本机集合号（`Truth::binding_of`）。
fn col_of(t: &Truth<'_>, profile: &str) -> Result<i64, String> {
    Ok(t.binding_of(profile)?
        .ok_or_else(|| {
            format!(
                "gen4: profile {profile} has no collection on this device (bindings are created by migration or the \
                 identity command)"
            )
        })?
        .col)
}

/// 读命令：集合号与命令本体同一个读快照。
fn read_col<T>(
    c: &G4Core,
    profile: &str,
    f: impl FnOnce(&Truth<'_>, i64) -> Result<T, String>,
) -> Result<T, String> {
    c.read(|t| snapshot(t, |t| f(t, col_of(t, profile)?)))
}

/// 写命令（不带本机状态行）。
fn write_col(
    c: &G4Core,
    profile: &str,
    f: impl FnOnce(&Truth<'_>, i64) -> Result<Value, String>,
) -> Result<Value, String> {
    c.write(|t| f(t, col_of(t, profile)?))
}

/// 可能改绑定的写命令（模块文件头）：[f] 返回回包与绑定变化；写事务提交成功之后才把变化放进回包的
/// `bindingChanged`（`{"profile": uid}`）。[G4Core::write] 报错（含提交失败、命令中途 panic 被回滚）就没有回包，
/// 事件随之丢掉。
fn write_binding(
    c: &G4Core,
    f: impl FnOnce(&Truth<'_>) -> Result<(Value, Option<BindingChanged>), String>,
) -> Result<Value, String> {
    let (mut v, changed) = c.write(f)?;
    if let Some(ch) = changed {
        v["bindingChanged"] = json!({"profile": ch.profile});
    }
    Ok(v)
}

/// `identity`：身份已在就是一次读（读连接的快照，不排写锁，同协议 3 `sync2_identity`）；没有才进写事务建
/// （`cmd/identity.rs` 文件头「谁在什么时候建」），在事务里重查一遍，并发的两个调用方只建一份。Secondary 上没有身份
/// 报只读（[G4Core::write]）。
fn identity(c: &G4Core, profile: &str, req: &Value) -> Result<Value, String> {
    if let Some(v) = c.read(|t| cmd::identity::identity_read(t, profile))? {
        return Ok(v);
    }
    let now = req
        .get("now")
        .and_then(Value::as_i64)
        .ok_or("identity: missing now")?;
    write_binding(c, |t| cmd::identity::identity_ensure(t, profile, now))
}

/// 本机写命令：命令本体 → 请求带 `study` 时排队 → 本机状态行，一个事务（模块文件头）。提交之后按命令落下的变化
/// 类别（回包里 `Session` 记的 [Tally]，在这里取走、不交给 Dart）推进进程内刷新计数（`refresh.rs`）；`apply {remote}`
/// 落了东西算一次合并（RWKV 分数表整表重查）。
fn local_write(
    c: &G4Core,
    profile: &str,
    req: &Value,
    f: impl FnOnce(&Truth<'_>, i64) -> Result<Value, String>,
) -> Result<Value, String> {
    let mut v = local_write_tx(c, profile, req, f)?;
    let tally = Tally::take(&mut v);
    let merged = req.get("op").and_then(Value::as_str) == Some("apply")
        && req.get("remote") == Some(&Value::Bool(true));
    c.refresh_note(profile, tally, merged);
    Ok(v)
}

/// 不经 `Session` 落真相的写（`import`、同步一轮的 `ingest` / `ingest_finish` / `retire` / `rotate`）提交之后：回包里
/// 命令放的 [Tally]（真有改动时是整份作废）取走、推进进程内刷新计数（`refresh.rs` 文件头「谁推进」）。
/// `legacy_backup_import`：先在新代库的写锁之外用冻结的协议 3 代码备好副本，再在一个写事务里认领 + 旧备份读入 + 本机
/// 状态行；绑定变了提交后进回包。Secondary 直接报只读（不白备副本）。[before_land] 在备好副本之后、进写事务之前跑
/// （分发器给空操作；测试在这里插入并发的写，钉住 `cmd/backup.rs` [cmd::backup::LOCAL_IDENTITY_MOVED] 的核对）。
pub(crate) fn legacy_backup_import(
    c: &G4Core,
    profile: &str,
    req: &Value,
    before_land: &dyn Fn(&G4Core) -> Result<(), String>,
) -> Result<Value, String> {
    if c.mode() == OpenMode::Secondary {
        return Err(READ_ONLY.to_owned());
    }
    let anchor = crate::store::local_state::anchor_of(req)?;
    // 副本身份的本机秘密（cmd/backup.rs `seed_scratch_identity`）：一个读快照取目标集合的本机签名钥匙种子。profile 还没
    // 绑定（覆盖还原的空库）时先定好落库时要建的本机身份（cmd/identity.rs [PendingSelf]），拿它的种子：落库之前就有身份，
    // 还原之后第一次合并同一份旧输入照样全是已有的槽（第五波 G9 身份收尾）。读快照与落库之间身份若被别的命令建了，落库
    // 那一笔核对出来、整条命令失败（[cmd::backup::land]）。
    let bound = c.read(|t| {
        snapshot(t, |t| match t.binding_of(profile)? {
            Some(b) => Ok(Some(t.self_identity(b.col)?.map(|s| s.sk))),
            None => Ok(None),
        })
    })?;
    // 已绑定、已有本机身份：认领若走「空集合可换绑」，对方集合里重建的本机身份沿用现有钥匙种子（[PendingSelf::carrying]），
    // 否则现生成的钥匙与派生副本身份用的秘密对不上。
    let now = int_of(req, "now")?;
    let pending = match bound {
        None => Some(cmd::identity::PendingSelf::generate(profile, now)),
        Some(Some(sk)) => Some(cmd::identity::PendingSelf::carrying(profile, now, sk)),
        Some(None) => None,
    };
    let secret = match (&bound, &pending) {
        (Some(sk), _) => *sk,
        (None, Some(p)) => Some(*p.seed()),
        (None, None) => None,
    };
    let prepared = cmd::backup::prepare(req, secret.as_ref(), c.dir())?;
    let src = super::dryrun::open_legacy(&prepared.db)?;
    before_land(c)?;
    let v = write_binding(c, |t| {
        cmd::backup::land(
            t,
            profile,
            req,
            &prepared,
            &src,
            anchor.as_ref(),
            pending.as_ref(),
            secret.as_ref(),
            &|t| col_of(t, profile),
        )
    })?;
    Ok(noted(c, profile, v))
}

fn noted(c: &G4Core, profile: &str, mut v: Value) -> Value {
    let tally = Tally::take(&mut v);
    c.refresh_note(profile, tally, false);
    v
}

/// [local_write] 的事务部分。
fn local_write_tx(
    c: &G4Core,
    profile: &str,
    req: &Value,
    f: impl FnOnce(&Truth<'_>, i64) -> Result<Value, String>,
) -> Result<Value, String> {
    let anchor = crate::store::local_state::anchor_of(req)?;
    c.write(|t| {
        let col = col_of(t, profile)?;
        let mut v = f(t, col)?;
        if v.get("stale") == Some(&Value::Bool(true)) {
            return Ok(v);
        }
        if let Some(s) = req.get("study").filter(|s| s.is_object()) {
            let queued = cmd::study::study(t, &c.study, col, s, None)?;
            v["study"] = queued;
        }
        local::persist(t, profile, anchor.as_ref(), &mut v)?;
        Ok(v)
    })
}

/// `apply` 一类命令的输入（第一个字节块：输入项的 JSON 数组）。
fn items_of(blobs: &[Vec<u8>]) -> Result<Vec<Value>, String> {
    let input = std::str::from_utf8(blobs.first().ok_or("apply: missing input")?)
        .map_err(|e| e.to_string())?;
    crate::store::sync2::parse_apply_input(input)
}

/// 一次收尾有没有改动派生层的任何东西（`refresh_caches` 收了东西才作废刷新键）。
fn settled_anything(s: &Settled) -> bool {
    [
        s.registers,
        s.entities,
        s.logs,
        s.closures,
        s.purged,
        s.holds,
        s.notes,
        s.media,
        s.aliases,
        s.digests,
        s.cache_notes,
        s.cache_cards,
        s.cache_stats,
    ]
    .iter()
    .any(|n| *n > 0)
}

fn settled_json(s: &Settled) -> Value {
    json!({"cacheNotes": s.cache_notes, "cacheCards": s.cache_cards, "cacheStats": s.cache_stats})
}

/// 已接线的命令（[wiring] = [Wiring::Wired]）。
fn run(
    c: &G4Core,
    op: &str,
    req: &Value,
    blobs: &mut Vec<Vec<u8>>,
    files: &mut cmd::Files,
) -> Result<Value, String> {
    // 不针对单个 profile 的命令。
    match op {
        "read_lib" => return c.read(|t| cmd::reads::run_lib(t, req, files)),
        "wal_checkpoint" => return c.wal_checkpoint(),
        "bulk_cache" => {
            let depth = c.bulk(req.get("on") == Some(&Value::Bool(true)))?;
            return Ok(json!({"depth": depth}));
        }
        "seal" | "open" | "seal_file" | "open_file" | "derive_key" => {
            return crate::store::ffi::crypto_command(op, req, blobs, files);
        }
        // profile 数据（G9-5，`cmd/profile_data.rs`）：不针对单个 profile 的几条。
        "profile_uids" => return c.read(cmd::profile_data::profile_uids),
        "profile_of_dir" => return c.read(|t| cmd::identity::profile_of_dir(t, req)),
        // 只删本机状态行与写完成标记：不碰真相与派生层，不推进写入代数。
        "orphan_sweep_done" => {
            return c.write_local(|t| cmd::profile_data::orphan_sweep_done(t, req));
        }
        "meta_set_edit" => {
            return if cmd::profile_data::meta_set_read_only(req) {
                c.read(|t| snapshot(t, |t| cmd::profile_data::meta_set_edit(t, req)))
            } else {
                c.write_local(|t| cmd::profile_data::meta_set_edit(t, req))
            };
        }
        // 半截并入的收尾：`from` 的集合并进 `to`（可能改绑 `to`），两边按刷新键记的缓存整份作废。
        "profile_merge_commit" => {
            let v = write_binding(c, |t| cmd::profile_data::profile_merge_commit(t, req))?;
            for k in ["from", "to"] {
                if let Some(p) = req.get(k).and_then(Value::as_str) {
                    c.refresh_invalidate(p);
                }
            }
            return Ok(v);
        }
        _ => {}
    }
    let profile = str_of(req, "profile")?;
    Ok(match op {
        // ------------------------------------------------------------ 读
        "read" => read_col(c, profile, |t, col| cmd::reads::run(t, col, req, files))?,
        "card_columns" => {
            let bytes = read_col(c, profile, |t, col| cmd::columns::card_columns(t, col, req))?;
            files.push(("columns".to_owned(), bytes));
            json!({})
        }
        "anki_resolve" => read_col(c, profile, |t, col| cmd::columns::anki_resolve(t, col, req))?,
        "anki_notes_info" => read_col(c, profile, |t, col| {
            cmd::columns::anki_notes_info(t, col, req)
        })?,
        "stats_report" | "stats_recall" | "stats_rows" => stats(c, profile, op, req)?,
        "stats_release" => {
            *c.stats.lock().unwrap_or_else(|e| e.into_inner()) = None;
            json!({})
        }
        "lineages" => {
            let cards: Vec<String> = req
                .get("cards")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect();
            json!(read_col(c, profile, |t, col| cmd::lineage::lineages(
                t, col, &cards
            ))?)
        }
        "history" => {
            let kind = str_of(req, "kind")?;
            let kind =
                EntKind::parse(kind).ok_or_else(|| format!("history: unknown kind {kind}"))?;
            let entity = str_of(req, "entity")?;
            read_col(c, profile, |t, col| {
                cmd::history::history(t, col, kind, entity)
            })?
        }
        "entity_views" => read_col(c, profile, |t, col| {
            cmd::views::entity_views_cmd(t, col, req)
        })?,
        "conflicts" => read_col(c, profile, cmd::center::conflicts)?,
        "checkpoints" => read_col(c, profile, cmd::center::checkpoints)?,
        "undo_check" => read_col(c, profile, |t, col| cmd::center::undo_check(t, col, req))?,
        "plan_restore" => read_col(c, profile, |t, col| {
            cmd::writes_restore::plan_restore(t, col, req)
        })?,
        "binding_get" => read_col(c, profile, cmd::profile::binding_get)?,
        // 没有集合的 profile 数出全 0（不报 has no collection，见 `profile_footprint_of`）。
        "profile_footprint" => c.read(|t| cmd::profile::profile_footprint_of(t, profile))?,
        "status" => read_col(c, profile, cmd::writes_local::status)?,
        // 集合号在读快照之外先读：出卡会话要在这次读事务的第一条读之前取走待重读 id（`cmd/study.rs` 文件头）。Secondary
        // 没有写连接的触发器，会话按刷新键印记判库变没变（`refresh.rs` Secondary 的键）。
        "study" => c.read(|t| {
            let col = col_of(t, profile)?;
            let stamp = match c.mode() {
                OpenMode::Primary => None,
                OpenMode::Secondary => Some(super::refresh::secondary_key(t, "", profile)?),
            };
            cmd::study::study(t, &c.study, col, req, stamp.as_deref())
        })?,
        "local_state" => {
            // `reload: true`：调用方（Dart 命令失败后的重读）要丢掉它按刷新键记的一切（协议 3 同口径）。
            if req.get("reload") == Some(&Value::Bool(true)) {
                c.refresh_invalidate(profile);
            }
            c.read(|t| snapshot(t, |t| local::read(t, profile)))?
        }
        "refresh_keys" => c.refresh_keys(profile)?,
        "preview" => {
            let card = str_of(req, "card")?;
            let note = req.get("note").and_then(Value::as_str);
            let (now, utc_off, rollover) = (
                int_of(req, "now")?,
                int_of(req, "utcOff")?,
                int_of(req, "rollover")?,
            );
            read_col(c, profile, |t, col| {
                cmd::preview::preview(t, col, card, note, now, utc_off, rollover)
            })?
        }
        // ------------------------------------------------------------ 媒体回收（本机状态 + 读缓存层，不推进修订号）
        // 只写本机状态行，不推进写入代数（`G4Core::write_local`）：后台按游标分批回收，每批都推进会让统计原料缓存白白失效。
        "media_gc_queue" => c.write_local(|t| cmd::media_gc::queue(t, profile, req))?,
        "media_gc_collect" => c.write_local(|t| cmd::media_gc::collect(t, profile, req))?,
        "media_live_refs" => {
            let after = int_of(req, "aliveAfter")?;
            c.read(|t| snapshot(t, |t| cmd::media_gc::live_refs_json(t, profile, after)))?
        }
        // `{due, error}`：`due` = 有清除提交了、磁盘上的旧字节还没抹干净；`error` = 上一次收尾出错的原因（空间不够等；
        // 没有 = null），UI 据此提示用户（`scrub.rs`「没做成怎么办」）。整个库一份，与 profile 无关。
        "scrub_state" => c.read(|t| {
            snapshot(t, |t| {
                let (due, error) = super::scrub::state(t.conn())?;
                Ok(json!({"due": due, "error": error}))
            })
        })?,
        "collection_info" => read_col(c, profile, |t, col| {
            cmd::identity::collection_info(t, col, req)
        })?,
        "canonical_ids" => read_col(c, profile, |t, col| {
            cmd::identity::canonical_ids(t, col, req)
        })?,
        "key_evidence" => read_col(c, profile, |t, col| {
            cmd::identity::key_evidence(t, col, req)
        })?,
        "divergence" => read_col(c, profile, cmd::identity::divergence)?,
        // ------------------------------------------------------------ 浏览会话
        "browse_query" | "browse_rows" | "browse_ids" | "browse_targets" | "browse_close"
        | "browse_stats" | "browse_counts" | "browse_sources" | "anki_find" | "anki_dupes"
        | "anki_tags" => {
            let r = c.reader()?;
            let t = c.truth(&r);
            // 集合号单独换算（模块文件头「读」）：浏览命令自己开快照，会话靠它分清是不是在写事务里读。
            let col = col_of(&t, profile)?;
            let mut b = c.browse.lock().unwrap_or_else(|e| e.into_inner());
            b.run(&t, col, op, req, files)?
        }
        // ------------------------------------------------------------ 本机写命令
        "apply" => {
            let items = items_of(blobs)?;
            local_write(c, profile, req, |t, col| {
                cmd::writes::apply(t, col, req, &items)
            })?
        }
        "import_drafts" => {
            let items = items_of(blobs)?;
            local_write(c, profile, req, |t, col| {
                cmd::writes::import_drafts(t, col, req, &items)
            })?
        }
        "change" => {
            let items = items_of(blobs)?;
            local_write(c, profile, req, |t, col| {
                cmd::writes_intent::change(t, col, req, &items)
            })?
        }
        "note_fields_if" => {
            let items = items_of(blobs)?;
            local_write(c, profile, req, |t, col| {
                cmd::writes_intent::note_fields_if(t, col, req, &items)
            })?
        }
        "merge_notes" => local_write(c, profile, req, |t, col| {
            cmd::writes_intent::merge_notes(t, col, req)
        })?,
        "sched" => local_write(c, profile, req, |t, col| {
            cmd::writes_intent::sched(t, col, req)
        })?,
        "deck_delete" => local_write(c, profile, req, |t, col| {
            cmd::writes_intent::deck_delete(t, col, req)
        })?,
        "resolve" => local_write(c, profile, req, |t, col| cmd::writes::resolve(t, col, req))?,
        "purge" => local_write(c, profile, req, |t, col| cmd::writes::purge(t, col, req))?,
        "checkpoint" => local_write(c, profile, req, |t, col| {
            cmd::writes::checkpoint(t, col, req)
        })?,
        "restore" => local_write(c, profile, req, |t, col| {
            cmd::writes_restore::restore(t, col, req)
        })?,
        "trust" => local_write(c, profile, req, |t, col| {
            cmd::writes_local::trust(t, col, req)
        })?,
        "dedup" => local_write(c, profile, req, cmd::writes_local::dedup)?,
        "digest_heal" => local_write(c, profile, req, |t, col| {
            cmd::writes_local::digest_heal(t, col, req)
        })?,
        // ------------------------------------------------------------ 身份（cmd/identity.rs）
        // 改身份 / 别名 / 绑定的写：提交之后按刷新键记的缓存整份作废（`refresh.rs` 文件头「谁推进」）。`identity` 只在
        // 这次真的建了绑定时作废（已在 = 一次读，每轮同步都走）。
        "identity" => {
            let v = identity(c, profile, req)?;
            if v.get("bindingChanged").is_some() {
                c.refresh_invalidate(profile);
            }
            v
        }
        "binding_set" => {
            let v = write_col(c, profile, |t, col| cmd::identity::binding_set(t, col, req))?;
            c.refresh_invalidate(profile);
            v
        }
        "collection_join" => {
            let v = write_binding(c, |t| {
                cmd::identity::collection_join(t, col_of(t, profile)?, req)
            })?;
            c.refresh_invalidate(profile);
            v
        }
        "collection_salts_add" => {
            let v = write_binding(c, |t| {
                cmd::identity::collection_salts_add(t, col_of(t, profile)?, req)
            })?;
            c.refresh_invalidate(profile);
            v
        }
        // 不要已有绑定：profile 还没绑过时确认后直接绑（「先加入」）。
        "collection_adopt" => {
            let v = write_binding(c, |t| cmd::identity::collection_adopt(t, profile, req))?;
            c.refresh_invalidate(profile);
            v
        }
        // ------------------------------------------------------------ profile 数据（cmd/profile_data.rs）
        // 删 profile 时清它的集合（可带 `collection` 核对确认的就是它）与本机状态行。
        "profile_purge" => {
            let v = c.write(|t| cmd::profile_data::profile_purge(t, profile, req))?;
            c.refresh_invalidate(profile);
            v
        }
        // ------------------------------------------------------------ 导入 / 导出（cmd/fushisrs.rs）
        // 导出：一个读快照（读连接，不排写锁）。
        "export" => read_col(c, profile, |t, col| {
            cmd::fushisrs::export(t, col, req, files)
        })?,
        // 导入：认领（可能改绑定）+ 落真相 + 本机状态行，一个写事务；绑定变了提交后进回包。
        "import" => {
            let anchor = crate::store::local_state::anchor_of(req)?;
            let src = cmd::fushisrs::Source::of(req, blobs)?;
            let v = write_binding(c, |t| {
                cmd::fushisrs::import(t, profile, req, &src, anchor.as_ref(), &|t| {
                    col_of(t, profile)
                })
            })?;
            noted(c, profile, v)
        }
        // 换代之前的整包备份 / 事件备份（cmd/backup.rs）：先在新代库的写锁之外用冻结的协议 3 代码备好副本，再在一个写事务
        // 里认领 + 旧备份读入 + 本机状态行；绑定变了提交后进回包。Secondary 直接报只读（不白备副本）。
        "legacy_backup_import" => legacy_backup_import(c, profile, req, &|_| Ok(()))?,
        // ------------------------------------------------------------ 同步一轮（cmd/sync.rs）
        "location_root" => {
            c.write_local(|t| cmd::sync::location_root(t, col_of(t, profile)?, req, blobs, files))?
        }
        "plan" => c.write_local(|t| cmd::sync::plan(t, col_of(t, profile)?, req, blobs))?,
        "ingest" => {
            let key = cmd::sync::key_of(req)?;
            let v = c.write(|t| {
                cmd::sync::ingest(t, col_of(t, profile)?, profile, req, blobs, key.as_ref())
            })?;
            noted(c, profile, v)
        }
        "ingest_begin" => {
            c.refresh_hold(profile);
            json!({})
        }
        "ingest_end" => {
            c.refresh_release(profile);
            json!({})
        }
        "ingest_finish" => {
            let now = int_of(req, "now")?;
            let v = c.write(|t| cmd::sync::ingest_finish(t, col_of(t, profile)?, profile, now))?;
            noted(c, profile, v)
        }
        "outbox" => {
            let key = cmd::sync::key_of(req)?;
            c.write_local(|t| cmd::sync::outbox(t, col_of(t, profile)?, req, key.as_ref(), files))?
        }
        "outbox_ack" => c.write_local(|t| cmd::sync::outbox_ack(t, col_of(t, profile)?, req))?,
        // 先在读快照上判「这一轮什么都不用写」（内容没变、摘要记录没变、`last_ok` 够新），是就不开写事务。
        "head" => match read_col(c, profile, |t, col| cmd::sync::head_unchanged(t, col, req))? {
            Some(v) => v,
            None => c.write_local(|t| cmd::sync::head(t, col_of(t, profile)?, req, files))?,
        },
        "obsolete" => read_col(c, profile, |t, col| cmd::sync::obsolete(t, col, req))?,
        // 语义摘要（head 带的那一份，`Index::digest`）：两台设备同一版本向量下应当相同，测试与诊断拿它比收敛。
        "digest" => read_col(c, profile, |t, col| {
            Ok(json!({"digest": Index::new(t, col).digest()?}))
        })?,
        "retire" => {
            let v = c.write(|t| cmd::sync::retire(t, col_of(t, profile)?, profile, req))?;
            noted(c, profile, v)
        }
        "rotate" => {
            let now = int_of(req, "now")?;
            let v = c.write(|t| cmd::sync::rotate(t, col_of(t, profile)?, profile, now))?;
            noted(c, profile, v)
        }
        "location_sealed" => {
            read_col(c, profile, |t, col| cmd::sync::location_sealed(t, col, req))?
        }
        "location_seal" => {
            c.write_local(|t| cmd::sync::location_seal(t, col_of(t, profile)?, req, blobs))?
        }
        // 位置配置是设备级的：每个集合都忘（不只发命令的 profile 的，见 `location_forget_everywhere`）。
        "location_forget" => c.write_local(|t| cmd::sync::location_forget_everywhere(t, req))?,
        // ------------------------------------------------------------ 转发（cmd/sync_relay.rs）
        "relay_outbox" => {
            let key = cmd::sync::key_of(req)?;
            read_col(c, profile, |t, col| {
                cmd::sync_relay::relay_outbox(t, col, req, key.as_ref(), files)
            })?
        }
        "relay_ack" => {
            c.write_local(|t| cmd::sync_relay::relay_ack(t, col_of(t, profile)?, req))?
        }
        "obsolete_former" => {
            read_col(c, profile, |t, col| cmd::sync::obsolete_former(t, col, req))?
        }
        // ------------------------------------------------------------ 旧根接手（cmd/sync_oldroot.rs）
        "oldroot_scan" => read_col(c, profile, |t, col| {
            cmd::sync_oldroot::oldroot_scan(t, col, req)
        })?,
        "oldroot_ingest" => {
            let key = cmd::sync::key_of(req)?;
            let v = c.write(|t| {
                cmd::sync_oldroot::oldroot_ingest(
                    t,
                    col_of(t, profile)?,
                    profile,
                    req,
                    blobs,
                    key.as_ref(),
                )
            })?;
            noted(c, profile, v)
        }
        "heritage_plan" => read_col(c, profile, |t, col| {
            cmd::sync_oldroot::heritage_plan(t, col, req)
        })?,
        "heritage_outbox" => {
            let key = cmd::sync::key_of(req)?;
            read_col(c, profile, |t, col| {
                cmd::sync_oldroot::heritage_outbox(t, col, req, blobs, key.as_ref(), files)
            })?
        }
        "heritage_ack" => {
            c.write_local(|t| cmd::sync_oldroot::heritage_ack(t, col_of(t, profile)?, req))?
        }
        // ------------------------------------------------------------ 媒体同步（cmd/media_sync.rs）
        "media_hash" => {
            let root = str_of(req, "root")?.to_owned();
            let names: Vec<String> = req
                .get("names")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect();
            // 缓存行在一个读快照里读；读文件、算哈希在锁外。
            let cached = read_col(c, profile, |t, col| {
                cmd::media_sync::hash_cached(t, col, &names)
            })?;
            cmd::media_sync::hash_files(&root, &names, &cached)
        }
        "media_scan" => {
            let v = c.write(|t| cmd::media_sync::scan(t, col_of(t, profile)?, req))?;
            noted(c, profile, v)
        }
        "media_landed" => {
            let now = int_of(req, "now")?;
            // 文件的 stat 在进写事务之前做完。
            let (items, stats) = cmd::media_sync::landed_items(req)?;
            let v =
                c.write(|t| cmd::media_sync::landed(t, col_of(t, profile)?, &items, &stats, now))?;
            noted(c, profile, v)
        }
        "media_doomed" => read_col(c, profile, |t, col| cmd::media_sync::doomed(t, col, req))?,
        "media_known" => read_col(c, profile, |t, col| cmd::media_sync::known(t, col, req))?,
        "media_record" => {
            c.write_local(|t| cmd::media_sync::record(t, col_of(t, profile)?, req))?
        }
        "media_manifests" => {
            read_col(c, profile, |t, col| cmd::media_sync::manifests(t, col, req))?
        }
        "media_manifest_ingest" => {
            let present: Vec<bool> = req
                .get("present")
                .and_then(Value::as_array)
                .ok_or("media_manifest_ingest: missing present")?
                .iter()
                .map(|v| v == &Value::Bool(true))
                .collect();
            c.write_local(|t| {
                cmd::media_sync::manifest_ingest(t, col_of(t, profile)?, req, blobs, &present)
            })?
        }
        "media_manifest_build" => {
            c.write_local(|t| cmd::media_sync::manifest_build(t, col_of(t, profile)?, req, files))?
        }
        "media_manifest_published" => {
            let blob = blobs
                .first()
                .ok_or("media_manifest_published: missing manifest")?
                .clone();
            c.write_local(|t| {
                cmd::media_sync::manifest_published(t, col_of(t, profile)?, req, &blob)
            })?
        }
        // ------------------------------------------------------------ 其余写
        "device_info" => write_col(c, profile, |t, col| {
            cmd::writes_local::device_info(t, col, req)
        })?,
        // 不针对集合（补充名按设备记），不要绑定。
        "device_hint" => c.write(|t| cmd::writes_local::device_hint(t, req))?,
        "local_state_ensure" => {
            let since = req.get("limitUnitSince").and_then(Value::as_i64);
            c.write(|t| local::ensure(t, profile, since))?
        }
        "local_anchor" => {
            let anchor =
                crate::store::local_state::anchor_of(req)?.ok_or("local_anchor: missing anchor")?;
            c.write(|t| local::set_anchor(t, profile, &anchor))?;
            json!({})
        }
        "cache_config_set" => {
            let caches = req.get("caches").ok_or("sync2: missing caches")?.clone();
            // 先按缓存层同一份解析核对：坏了不写。
            crate::store::caches::CacheConfig::parse(&caches)?;
            let now = req
                .get("now")
                .and_then(Value::as_i64)
                .ok_or("cache_config_set: missing now")?;
            // 注册配置与默认牌组不变式的开库自愈（[cmd::writes_intent::revive_default_deck]，BUG-5209）同一个事务：
            // 复活写了就照本机写命令推进本机状态行（[local::persist]），回包放在 `revive` 下（它的 `changed` 是实体
            // 列表，与这里的 `changed` 布尔不同义）。复活那笔写的 [Tally] 与本机写命令一样提交后取走推进刷新计数
            // （[local_write]），不交给 Dart。
            let (v, tally) = c.write(|t| {
                let col = col_of(t, profile)?;
                let mut v = cache_config_set(t, col, &caches)?;
                let mut revive = cmd::writes_intent::revive_default_deck(t, col, now)?;
                let mut tally = Tally::default();
                if revive["revived"] == Value::Bool(true) {
                    local::persist(t, profile, None, &mut revive)?;
                    tally = Tally::take(&mut revive);
                    v["revive"] = revive;
                }
                Ok((v, tally))
            })?;
            // 改了配置 = 派生层整层重建：按刷新键记的缓存整份作废。
            if v["changed"] == Value::Bool(true) {
                c.refresh_invalidate(profile);
            }
            c.refresh_note(profile, tally, false);
            v
        }
        "rwkv_last_fill" => {
            // 分批回填 `rwkv_last` 的一步（BUG-5547，`cmd/training.rs`）：只写缓存层的这张表与回填游标，别的缓存行与
            // 刷新键都不动（`rwkv_last` 只有 RWKV 末条读它，回填出的值与填完之后读到的相同），不作废宿主缓存。
            let limit = req
                .get("limit")
                .and_then(Value::as_u64)
                .ok_or("rwkv_last_fill: missing limit")? as usize;
            c.write(|t| cmd::training::rwkv_last_fill(t, col_of(t, profile)?, limit))?
        }
        "refresh_caches" | "rebuild_caches" => {
            let mode = if op == "rebuild_caches" {
                Settle::Rebuild
            } else {
                Settle::Incremental
            };
            let (v, moved) = c.write(|t| {
                let col = col_of(t, profile)?;
                let st = ingest_settle(t, &mut Index::new(t, col), col, mode)?;
                let moved = op == "rebuild_caches" || settled_anything(&st);
                Ok((json!({"settled": settled_json(&st)}), moved))
            })?;
            if moved {
                c.refresh_invalidate(profile);
            }
            v
        }
        _ => return Err(format!("{NO_ARM}: {op}")),
    })
}

/// `cache_config_set`：缓存配置（内置笔记类型的代码默认值、默认牌组：只有 Dart 知道）是派生层的输入，存在
/// `derive_cfg`（与迁移写下的是同一个键）。值与库里的相同（按 JSON 值比，键序无关）就什么都不做；变了就写下并按
/// `Settle::Rebuild` 整个重建派生层（缓存行按新配置重算），同一个事务。配置没变、但缓存层不是按当前推导口径物化的
/// （`derive_cfg` 的 [RULES_KEY] 不等于 [CACHE_RULES]，`cache.rs`）也整层重建一次——例外是 [RWKV_FILL_FROM]
/// （与当前口径只差 `rwkv_last`，BUG-5547）：只记下当前修订号与回填游标 [RWKV_FILL_KEY]，表由宿主分批回填
/// （`rwkv_last_fill`），不在这一个写事务里整层重建。回包 `{changed, settled?, rwkvLastFill?}`：
/// `changed` = 派生层重建过（宿主据它作废按刷新键记的缓存）；`rwkvLastFill: true` = 回填还没做完（刚就地升级，或上次
/// 没填完），宿主接着填。请求要带 `now`：分发处在同一个事务里接着做默认牌组
/// 不变式的自愈（[cmd::writes_intent::revive_default_deck]），写了时回包另带 `revive`（那笔写的统一回包 + 本机状态行的
/// `localRevision` / `localEpoch`，宿主照本机写命令接）。
///
/// 协议 3 回 `{from, to, current, cache}`（缓存推导口径的版本升级与 Dart 缓存镜像的写入清单）：新代的推导口径版本只有
/// 「当前 / 不是当前」两态（落后了就整层重建，派生层是真相的纯函数），回包改了形状，G7-5 对应改。
pub(crate) fn cache_config_set(t: &Truth<'_>, col: i64, caches: &Value) -> Result<Value, String> {
    let old: Option<Value> = t
        .derive_cfg(col, CFG_KEY)?
        .and_then(|text| serde_json::from_str(&text).ok());
    let rules = t.derive_cfg(col, RULES_KEY)?;
    if old.as_ref() == Some(caches) {
        if rules == Some(CACHE_RULES.to_string()) {
            // 上次就地升级留下的回填没做完（被杀 / 关库）：回包照样带上，宿主接着填。
            return Ok(if t.derive_cfg(col, RWKV_FILL_KEY)?.is_some() {
                json!({"changed": false, "rwkvLastFill": true})
            } else {
                json!({"changed": false})
            });
        }
        if RWKV_FILL_FROM.is_some_and(|from| rules == Some(from.to_string())) {
            // 与当前口径只差 `rwkv_last`（BUG-5547）：不整层重建，记下当前修订号与回填游标，表由宿主分批填。别的缓存行
            // 一行没变，`changed` 仍是 false（宿主不必作废按刷新键记的缓存）。
            t.set_derive_cfg(col, RULES_KEY, Some(&CACHE_RULES.to_string()))?;
            t.set_derive_cfg(col, RWKV_FILL_KEY, Some(""))?;
            return Ok(json!({"changed": false, "rwkvLastFill": true}));
        }
    }
    t.set_derive_cfg(col, CFG_KEY, Some(&crate::store::sync2::canonical(caches)))?;
    let st = ingest_settle(t, &mut Index::new(t, col), col, Settle::Rebuild)?;
    Ok(json!({"changed": true, "settled": settled_json(&st)}))
}

/// [cache_mark] 执行的语句（查询计划测试用同一份）。
pub(crate) const CACHE_MARK_SQL: &str = "SELECT gen, floor FROM cache_gen WHERE col = ?1";

/// 缓存层代号（`cache_gen` 的 `(gen, floor)`，没有行 = (0, 0)）。
fn cache_mark(t: &Truth<'_>, col: i64) -> Result<(i64, i64), String> {
    Ok(t.conn()
        .prepare_cached(CACHE_MARK_SQL)
        .map_err(sql)?
        .query_row([col], |r| Ok((r.get(0)?, r.get(1)?)))
        .optional()
        .map_err(sql)?
        .unwrap_or((0, 0)))
}

/// `stats_report` / `stats_recall` / `stats_rows`：原料按 (集合, 统计指纹, 写入代数, 缓存层代号) 缓存在命令层（模块文件头），
/// 换范围 / 牌组只重算聚合。原料、请求里 ID 的归一、代号都在同一个读快照里。
fn stats(c: &G4Core, profile: &str, op: &str, req: &Value) -> Result<Value, String> {
    let key = req
        .get("key")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    // 写入代数在开快照之前取：读的途中有写入提交，下次一定重读。
    let writes = c.writes.load(std::sync::atomic::Ordering::SeqCst);
    c.read(|t| {
        snapshot(t, |t| {
            let col = col_of(t, profile)?;
            let canon = cmd::stats::canon_req(&Index::new(t, col), req)?;
            let mark = cache_mark(t, col)?;
            let hit = c
                .stats
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .as_ref()
                .filter(|e| e.col == col && e.key == key && e.writes == writes && e.mark == mark)
                .map(|e| std::sync::Arc::clone(&e.snap));
            let snap = match hit {
                Some(s) => s,
                None => {
                    let s = std::sync::Arc::new(cmd::stats::snapshot_of(t, col)?);
                    *c.stats.lock().unwrap_or_else(|e| e.into_inner()) = Some(StatsEntry {
                        col,
                        key: key.clone(),
                        writes,
                        mark,
                        snap: std::sync::Arc::clone(&s),
                    });
                    s
                }
            };
            match op {
                "stats_report" => crate::store::stats::report_of(&snap, &canon),
                "stats_recall" => crate::store::stats::recall_of(&snap, &canon),
                _ => crate::store::stats::rows_of(&snap, &canon),
            }
        })
    })
}

// ---------------------------------------------------------------------- C 直出入口（逐卡重放与训练集）

/// 一个集合都对不上时用的集合号（[direct_col]）：`collections.col` 是从 1 起分配的整数主键，0 不属于任何集合，派生层
/// 里没有它的行——在它上面算出的结果就是「这些卡都不存在」的形状（与协议 3 不存在的卡同形）。
const NO_COLLECTION: i64 = 0;

/// [direct_col] 列出这个文件里的全部集合（`collections` 只有绑定数那么几行）。
pub(crate) const COLLECTIONS_SQL: &str = "SELECT col FROM collections ORDER BY col";

/// [direct_col] 判「集合 ?1 里请求的卡（?2：`cmd::Sel::ids` 同一种 JSON 列表，原值 ID）有没有哪张有历史」，一个集合
/// 一条语句：每个 ID 先按这个集合的别名表归一（`alias_ix` 主键，同 `Index::canonical`），再展开成别名类（规范 ID 与
/// `alias_canon` 一段，同 `Index::class_of`），类里任何成员有卡上的日志（`log_ix` 主键前缀 `(col, card)`）或卡自己的
/// 修改（前身链接等，`reg_ix` 主键前缀 `(col, ekind = ?3, ent)`）就算。以前逐卡在 Rust 里点查（每张卡归一、取成员、
/// 每个成员一次存在性查询），多集合文件里每个无关集合都要把全部卡走一遍：N+1。查询计划测试用同一份。
pub(crate) const HOLDS_ANY_CARD_SQL: &str = "WITH req(id) AS (\
       SELECT CASE value ->> 0 WHEN 1 THEN unhex(value ->> 1) ELSE value ->> 1 END FROM json_each(?2)), \
     canon(c) AS (\
       SELECT coalesce((SELECT a.canon FROM alias_ix a WHERE a.col = ?1 AND a.id = req.id), req.id) FROM req), \
     cls(m) AS (\
       SELECT c FROM canon \
       UNION ALL SELECT a.id FROM canon CROSS JOIN alias_ix a WHERE a.col = ?1 AND a.canon = canon.c AND a.canon != a.id) \
     SELECT EXISTS(SELECT 1 FROM cls WHERE \
       EXISTS(SELECT 1 FROM log_ix WHERE col = ?1 AND card = cls.m) \
       OR EXISTS(SELECT 1 FROM reg_ix WHERE col = ?1 AND ekind = ?3 AND ent = cls.m))";

/// [HOLDS_ANY_CARD_SQL] 的 ?2：请求里全部卡的原值 ID（`Sel::ids` 的编码，SQL 里还原成存储形）。
fn card_list(groups: &[Vec<String>]) -> String {
    let list: Vec<Value> = groups
        .iter()
        .flatten()
        .map(|card| match cmd::ref_of(card) {
            Ref::Uuid(b) => json!([1, cmd::hex(&b)]),
            Ref::Text(s) => json!([0, s]),
        })
        .collect();
    Value::Array(list).to_string()
}

/// C 直出入口按哪个集合读（在调用方的读快照里）。协议 3 的这些入口按全局唯一的卡 ID 读、不分 profile，输入页里
/// `history_states` / `stat_projection` / `optimizer_items` / `calibration_items` / `rwkv_rows` 模式 0 没有 profile 行
/// （Dart 这一段不改；G7-5 可以补上 `[-1, profile]` 行）。规则：
///
/// - 页里有 profile 行：按它的绑定（没绑定 = 明确报错，同 `ffsrs_store_sync2` 的命令）。
/// - 没有：文件里只有一个集合就是它（通常的情形：一个 profile 目录一个 profile）；一个都没有 = [NO_COLLECTION]；有几个
///   时按请求里的卡认——卡（归一后的类里任何成员）在哪个集合里有日志或修改就是哪个。全都对不上 = [NO_COLLECTION]
///   （这些卡在哪儿都没有历史，结果与「卡不存在」相同）；对上不止一个 = 明确报错（分不清该读谁的历史，不拼两份）。
///   迁移来的多 profile 库里协议 3 的实体本来就只属于一个 profile，按卡认不会撞。
pub(super) fn direct_col(
    t: &Truth<'_>,
    profile: Option<&str>,
    groups: &[Vec<String>],
) -> Result<i64, String> {
    if let Some(p) = profile {
        return col_of(t, p);
    }
    let cols: Vec<i64> = t
        .conn()
        .prepare_cached(COLLECTIONS_SQL)
        .map_err(sql)?
        .query_map([], |r| r.get(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    match cols.as_slice() {
        [] => return Ok(NO_COLLECTION),
        [one] => return Ok(*one),
        _ => {}
    }
    let list = card_list(groups);
    let mut holds = t.conn().prepare_cached(HOLDS_ANY_CARD_SQL).map_err(sql)?;
    let mut hits: Vec<i64> = Vec::new();
    for &col in &cols {
        let found: bool = holds
            .query_row(rusqlite::params![col, list, EntKind::Card as i64], |r| {
                r.get(0)
            })
            .map_err(sql)?;
        if found {
            hits.push(col);
        }
    }
    match hits.as_slice() {
        [] => Ok(NO_COLLECTION),
        [one] => Ok(*one),
        _ => Err(format!(
            "gen4: the cards of this request have history in {} collections; pass the profile row ([-1, profile])",
            hits.len()
        )),
    }
}

/// 一条 C 直出命令：集合号的换算与命令本体在同一个读快照里。
fn direct<T>(
    c: &G4Core,
    profile: Option<&str>,
    groups: &[Vec<String>],
    f: impl FnOnce(&Truth<'_>, i64) -> Result<T, String>,
) -> Result<T, String> {
    c.read(|t| snapshot(t, |t| f(t, direct_col(t, profile, groups)?)))
}

/// `ffsrs_store_history_states`（`cmd/training.rs`，输出同协议 3）。
pub fn history_states(
    c: &G4Core,
    profile: Option<&str>,
    groups: &[Vec<String>],
) -> Result<Vec<u8>, String> {
    direct(c, profile, groups, |t, col| {
        cmd::training::history_states(t, col, groups)
    })
}

/// `ffsrs_store_stat_projection`。
pub fn stat_projection(
    c: &G4Core,
    profile: Option<&str>,
    groups: &[Vec<String>],
) -> Result<Vec<u8>, String> {
    direct(c, profile, groups, |t, col| {
        cmd::training::stat_projection(t, col, groups)
    })
}

/// `ffsrs_store_optimizer_items`。
pub fn optimizer_items(
    c: &G4Core,
    profile: Option<&str>,
    groups: &[Vec<String>],
    ids: &[i64],
    alg: Alg,
    day: &Day,
) -> Result<Vec<u8>, String> {
    direct(c, profile, groups, |t, col| {
        cmd::training::optimizer_items(t, col, groups, ids, alg, day)
    })
}

/// `ffsrs_store_calibration_items`。
pub fn calibration_items(
    c: &G4Core,
    profile: Option<&str>,
    groups: &[Vec<String>],
    ids: &[i64],
    alg: Alg,
    day: &Day,
) -> Result<Vec<u8>, String> {
    direct(c, profile, groups, |t, col| {
        cmd::training::calibration_items(t, col, groups, ids, alg, day)
    })
}

/// `ffsrs_store_rwkv_rows` 模式 0（逐卡）。
pub fn rwkv_cards(
    c: &G4Core,
    profile: Option<&str>,
    groups: &[Vec<String>],
    ids: &[i64],
    day: &Day,
) -> Result<Vec<u8>, String> {
    direct(c, profile, groups, |t, col| {
        cmd::training::rwkv_cards(t, col, groups, ids, day)
    })
}

/// `ffsrs_store_rwkv_rows` 模式 2（末条：每张卡最后一条保留评分，读缓存层的 `rwkv_last`）。
pub fn rwkv_last(
    c: &G4Core,
    profile: Option<&str>,
    groups: &[Vec<String>],
) -> Result<Vec<u8>, String> {
    let cards: Vec<String> = groups.iter().filter_map(|g| g.first().cloned()).collect();
    if cards.len() != groups.len() {
        return Err("rwkv: empty card group".into());
    }
    direct(c, profile, groups, |t, col| {
        cmd::training::rwkv_last(t, col, &cards)
    })
}

/// `ffsrs_store_rwkv_rows` 模式 1（回放；页里一定有 profile 行，协议 3 同样要它）。
pub fn rwkv_replay(
    c: &G4Core,
    profile: &str,
    groups: &[Vec<String>],
    ids: &[i64],
    day: &Day,
    since: i64,
    range: RwkvRange,
) -> Result<Vec<u8>, String> {
    read_col(c, profile, |t, col| {
        cmd::training::rwkv_replay(t, col, groups, ids, day, since, range)
    })
}

/// `ffsrs_store_rwkv_log_tail`（页里一定有 profile 行）。
pub fn rwkv_log_tail(
    c: &G4Core,
    profile: &str,
    since: i64,
    with_rows: bool,
    incremental: bool,
) -> Result<Vec<u8>, String> {
    read_col(c, profile, |t, col| {
        cmd::training::rwkv_log_tail(t, col, since, with_rows, incremental)
    })
}

/// 测试用：统计原料缓存此刻有没有一份、是哪个写入代数读的。
#[cfg(test)]
pub(crate) fn stats_cached(c: &G4Core) -> Option<u64> {
    c.stats
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_ref()
        .map(|e| e.writes)
}

#[cfg(test)]
mod tests {
    use super::{PROJECTING_OPS, Wiring, wiring};

    /// [PROJECTING_OPS] 里每条都接了线，且每条走 [super::local_write] 的命令都在里面（漏一条，Dart 就可能在独占区外
    /// 发它、回包里的投影变化接不上）。
    #[test]
    fn projecting_ops_are_wired_and_cover_every_local_write() {
        for op in PROJECTING_OPS {
            assert_eq!(wiring(op), Some(Wiring::Wired), "{op}");
        }
        let src = include_str!("dispatch.rs").replace("\r\n", "\n");
        let body = &src[src.find("\nfn run(").expect("run")..];
        let body = &body[..body.find("\n}\n").expect("end of run")];
        let mut arm: Vec<&str> = Vec::new();
        let mut local: Vec<&str> = Vec::new();
        for line in body.lines() {
            let t = line.trim_start();
            if line.starts_with("        \"") {
                arm = t
                    .split("=>")
                    .next()
                    .unwrap_or("")
                    .split('|')
                    .map(|x| x.trim().trim_matches('"'))
                    .filter(|x| !x.is_empty())
                    .collect();
            }
            if t.contains("local_write(c, profile, req,") {
                local.extend(arm.iter().copied());
            }
        }
        assert!(local.len() >= 14, "{local:?}");
        for op in &local {
            assert!(
                PROJECTING_OPS.contains(op),
                "{op} writes through local_write"
            );
        }
    }
}
