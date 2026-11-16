//! 新代分发器（规划 §2.2 S1；逐条接线清单见交接说明「分发器命令对照表」与「S1 接线设计」）：`ffsrs_store_sync2` 的每一条
//! JSON 命令到 `cmd/` 的新代实现。协议 3 的分发器（`store/ffi.rs` `sync2_dispatch`）原样留着给协议 3 的测试与对拍装置，
//! 生产入口不再调它（G7-6 删）。
//!
//! # 命令的三种去向（[wiring]）
//!
//! - [Wiring::Wired]：接到新代实现（[run] 里有它的臂）。
//! - [Wiring::Unwired]：归别的模块接线（G8-7 同步、G9-5 并入、G11-3 导入导出、G7-4f 预览、S1 后续的媒体回收），报
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
//! - **读**（读连接）：集合号的换算与命令本体在**同一个读快照**里（`cmd::snapshot`，命令自己的快照沿用它）。浏览例外：
//!   浏览会话要分清「在调用方的写事务里读」（`cmd/browse.rs` 文件头），所以集合号先单独换算、命令自己开快照。
//! - **写**（写连接，[G4Core::write]）：集合号、命令本体（`cmd/writes*.rs`，自己开 SAVEPOINT）、请求带 `study` 时的排队
//!   （看得见这笔还没提交的写入）、本机状态行（`local.rs` [persist]，回包 `localRevision` / `localEpoch`）在**一个**
//!   `BEGIN IMMEDIATE` 事务里；任何一步出错整笔回滚。`apply` 的前置条件不成立（`stale`）什么都不写，也不推进修订号。
//! - **回包**：读命令与协议 3 逐键相同（各 `cmd/*` 文件头写了按规范 ID 的差别）；写命令是 G7-3b 的统一回包
//!   （`changed` / `purged` / `replayed` / `edits` / `nextSeq` / `settled`，协议 3 的 `marks` / `diagnostics` / `cache` 是
//!   投影表与 Dart 缓存镜像的落库细节，新代没有），外加 `localRevision` / `localEpoch` 与 `study`。
//!
//! # 常驻会话的失效
//!
//! - 浏览会话：按缓存层代号 `cache_gen` 自己对上（`cmd/browse.rs`），写入经派生层收尾记账，这里不用做什么。
//! - 统计原料缓存：键是 (集合, 统计指纹, 写入代数, 缓存层代号)；本进程每条写命令提交之后写入代数 +1，别的进程的写入
//!   由缓存层代号兜住。`stats_release` 丢掉。
//! - 出卡：`cmd/study.rs` 每条命令在一个读快照里现读（不常驻，见交接说明「S1 接线设计」的取舍），没有要失效的。

use rusqlite::OptionalExtension;
use serde_json::{Value, json};

use super::cache::CFG_KEY;
use super::cmd::{self, snapshot};
use super::derive::{Index, Settled};
use super::identity::BindingChanged;
use super::ingest::{Settle, ingest_settle};
use super::kernel::{G4Core, StatsEntry, removed, unwired};
use super::local;
use super::schema::sql;
use super::truth::Truth;
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
const NO_PENDING: &str =
    "gen4 keeps the derived layer current on every write; there is nothing pending to refresh";
const NO_CHANNEL: &str =
    "gen4 has no ingest channel: received segments land in the truth layer directly";
const P3_REPR: &str = "a protocol 3 storage detail; the implementation is deleted with G7-6";
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
        | "profile_footprint" | "status" | "study" | "local_state" => Wired,
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
        | "cache_config_set" | "refresh_caches" | "rebuild_caches" => Wired,
        // 纯加解密（不碰库）
        "seal" | "open" | "open_v1" | "seal_file" | "open_file" | "derive_key" => Wired,
        // 媒体回收：待回收集合的新代存处与存活引用的新代读法还没接（交接说明「S1 接线设计」未完成项）。
        "media_gc_queue" | "media_gc_collect" | "media_live_refs" => {
            Unwired("S1 follow-up (media GC)")
        }
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
        // profile 并入 / 清除 / 旧 uid 集合
        "profile_uids"
        | "orphan_sweep_done"
        | "profile_merge_mark"
        | "profile_merge_commit"
        | "meta_set_edit"
        | "profile_purge" => Unwired("G9-5"),
        // 同步一轮与调度
        "ingest_yield" | "ingest_commit" | "ingest" | "ingest_begin" | "ingest_batch"
        | "ingest_prepare" | "ingest_end" | "ingest_finish" | "replay_pending" | "outbox"
        | "outbox_ack" | "head" | "plan" | "relay_outbox" | "relay_ack" | "obsolete"
        | "obsolete_former" | "obsolete_ack" | "digest" | "digest_buckets" | "retire"
        | "rotate" | "location_sealed" | "location_seal" | "media_known" | "media_record"
        | "media_hash" | "media_scan" | "media_landed" | "media_bind_unbound" | "media_doomed" => {
            Unwired("G8-7")
        }
        // 导入 / 导出
        "import" | "export" => Unwired("G11-3"),
        // 评分预览
        "preview" => Unwired("G7-4f (pending merge)"),
        // 新代不需要
        "refresh_keys" => Removed(NO_PENDING),
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
        Some(Wiring::Wired) => run(c, op, req, blobs, files),
    }
}

/// 标成接线却没有臂的命令报的错（[run] 的兜底；测试按它核对）。
pub(crate) const NO_ARM: &str = "gen4 dispatch: marked wired but has no arm";

fn str_of<'a>(req: &'a Value, k: &str) -> Result<&'a str, String> {
    req.get(k)
        .and_then(Value::as_str)
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

/// 本机写命令：命令本体 → 请求带 `study` 时排队 → 本机状态行，一个事务（模块文件头）。
fn local_write(
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
            let queued = cmd::study::study(t, col, s)?;
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
        "seal" | "open" | "open_v1" | "seal_file" | "open_file" | "derive_key" => {
            return crate::store::ffi::crypto_command(op, req, blobs, files);
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
        "conflicts" => read_col(c, profile, cmd::center::conflicts)?,
        "checkpoints" => read_col(c, profile, cmd::center::checkpoints)?,
        "undo_check" => read_col(c, profile, |t, col| cmd::center::undo_check(t, col, req))?,
        "plan_restore" => read_col(c, profile, |t, col| {
            cmd::writes_restore::plan_restore(t, col, req)
        })?,
        "binding_get" => read_col(c, profile, cmd::profile::binding_get)?,
        "profile_footprint" => read_col(c, profile, cmd::profile::profile_footprint)?,
        "status" => read_col(c, profile, cmd::writes_local::status)?,
        "study" => read_col(c, profile, |t, col| cmd::study::study(t, col, req))?,
        "local_state" => c.read(|t| snapshot(t, |t| local::read(t, profile)))?,
        "collection_info" => read_col(c, profile, cmd::identity::collection_info)?,
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
            let t = Truth::new(&r);
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
        "identity" => identity(c, profile, req)?,
        "binding_set" => write_col(c, profile, |t, col| cmd::identity::binding_set(t, col, req))?,
        "collection_join" => write_binding(c, |t| {
            cmd::identity::collection_join(t, col_of(t, profile)?, req)
        })?,
        "collection_salts_add" => write_binding(c, |t| {
            cmd::identity::collection_salts_add(t, col_of(t, profile)?, req)
        })?,
        // 不要已有绑定：profile 还没绑过时确认后直接绑（「先加入」）。
        "collection_adopt" => {
            write_binding(c, |t| cmd::identity::collection_adopt(t, profile, req))?
        }
        // ------------------------------------------------------------ 其余写
        "device_info" => write_col(c, profile, |t, col| {
            cmd::writes_local::device_info(t, col, req)
        })?,
        // 不针对集合（补充名按设备记），不要绑定。
        "device_hint" => c.write(|t| cmd::writes_local::device_hint(t, req))?,
        "local_state_ensure" => c.write(|t| local::ensure(t, profile))?,
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
            write_col(c, profile, |t, col| cache_config_set(t, col, &caches))?
        }
        "refresh_caches" | "rebuild_caches" => {
            let mode = if op == "rebuild_caches" {
                Settle::Rebuild
            } else {
                Settle::Incremental
            };
            write_col(c, profile, |t, col| {
                let st = ingest_settle(t, &mut Index::new(t, col), col, mode)?;
                Ok(json!({"settled": settled_json(&st)}))
            })?
        }
        _ => return Err(format!("{NO_ARM}: {op}")),
    })
}

/// `cache_config_set`：缓存配置（内置笔记类型的代码默认值、默认牌组：只有 Dart 知道）是派生层的输入，存在
/// `derive_cfg`（与迁移写下的是同一个键）。值与库里的相同（按 JSON 值比，键序无关）就什么都不做；变了就写下并按
/// `Settle::Rebuild` 整个重建派生层（缓存行按新配置重算），同一个事务。回包 `{changed, settled?}`。
///
/// 协议 3 回 `{from, to, current, cache}`（缓存推导口径的版本升级与 Dart 缓存镜像的写入清单）：新代没有缓存推导口径版本
/// （派生层是真相的纯函数，换口径 = 新的 schema / 重建），回包改了形状，G7-5 对应改。
fn cache_config_set(t: &Truth<'_>, col: i64, caches: &Value) -> Result<Value, String> {
    let old: Option<Value> = t
        .derive_cfg(col, CFG_KEY)?
        .and_then(|text| serde_json::from_str(&text).ok());
    if old.as_ref() == Some(caches) {
        return Ok(json!({"changed": false}));
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

/// 测试用：统计原料缓存此刻有没有一份、是哪个写入代数读的。
#[cfg(test)]
pub(crate) fn stats_cached(c: &G4Core) -> Option<u64> {
    c.stats
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_ref()
        .map(|e| e.writes)
}
