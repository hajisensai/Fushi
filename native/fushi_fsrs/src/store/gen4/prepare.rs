//! 迁移前提补完（G7-2b；设计 §6.1「前提」，交接说明 §9.5 第 1、2 条）：`gen4_migrate_run` 拿到换代锁之后、核对前提
//! 之前，用**冻结的协议 3 代码**把旧库还没做完的协议 3 收尾做完。
//!
//! # 为什么在这里补
//!
//! 协议 3 的这些收尾原本由 app 驱动：开库时 `identity` + `migrate`（旧行包成操作，`sync2/mod.rs` `finish_migration`
//! 才写 `sync2_self.migrated_at`；App 等首次同步确认后才迁移，BUG-4011，从没同步过的用户一直是 NULL）、同步轮次里的
//! `dedup`、收段收尾的 `ingest_finish` / `replay_pending`（收段通道 `sync2_boot`、待重放 `sync2_replay_pending`、待刷新
//! 缓存 `sync2_cache_pending`）。S1 删了 `ffsrs_store_open`、G7-5 删了 Dart 的这些调用之后，没有任何路径再做它们，
//! 而迁移的前提核对（`legacy::preflight` / `migration_blockers` / `library_blockers`）把它们当硬阻断：这些用户永远迁不了。
//!
//! # 做什么（[plan] 只读判断，[complete] 才写）
//!
//! - 旧库 schema 比这一版的协议 3 旧：`SrsCore::open` 的升级阶梯把它升上来（协议 3 打开时本来就做；空间不够照协议 3
//!   的空间守卫报 [Outcome::NoSpace]，库不动）。
//! - 每个要补的 profile（[Plan::profiles]，升序），经协议 3 的分发器（`store/ffi.rs` `sync2_dispatch`，与旧 app 发的
//!   是同一串命令，通道没做完时分发器自己先按片做完）依次：
//!   1. `migrate`（每批 [Options::batch] 条、各自一个提交）到 `done`：建本机身份（没有的话）、把还没有任何操作代表的
//!      旧行包成操作、写 `migrated_at`。只在投影表里的孤儿 uid 也这样进操作日志，迁移时与别的 profile 一样迁过去；
//!   2. `dedup` 到 `done` 不为假（重复流收敛，本机就能做完：发 `Dedup` 只是追加本机操作）；
//!   3. `replay_pending` 到 `more` 不为真（收段通道、待重放的卡、待刷新的缓存）。
//!
//! 每一步都是协议 3 自己本来会做的事，不改变数据的含义（迁移只包「还没被代表」的旧行，重放是全部日志的纯函数，缓存
//! 随时可重建）；每批 / 每片各自提交，进程在任何一点被杀、取消，旧库都是协议 3 能照常打开的状态，重跑从断点接着做
//! （`migrate` 的队列、`dedup` 的游标、`replay_pending` 的集合都在库里）。什么都不用补的库不开写连接，一个字节不写。
//!
//! # 补不了的（拦下，[BlockCode]）
//!
//! - 并入做到一半（`profile_merge/<uid>`，D23：由冻结的旧并入代码做完，它由 Dart 驱动、带着主库那一侧的状态）。
//! - 旧库里有 profile 没给缓存配置（`dedup` / `replay_pending` 要刷新协议 3 的缓存行，迁移也要）：Dart 按
//!   `gen4_migrate_status` 的 `profiles`（[crate::store::gen4::legacy::all_profiles]）逐个给。
//! - 要写之前 `PRAGMA quick_check` 不过（文件坏了）：不往坏文件里写。
//!
//! 协议 1 的主库（`srs_entities` 在 app 主库里，D21）不在这里：那是另一个文件，G7-6 处理。

use std::collections::BTreeMap;
use std::path::Path;

use rusqlite::{Connection, OpenFlags};
use serde_json::{Value, json};

use super::legacy;
use super::migrate::{BlockCode, Options, Outcome, Step, blocked, hold_legacy, is_corrupt};
use crate::store::SrsCore;
use crate::store::schema::{SCHEMA_VERSION, UPGRADE_NO_SPACE};

/// 要补的事（[plan] 的结果）。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Plan {
    /// 旧库 schema 比这一版的协议 3 旧：打开时先升级。
    pub upgrade: bool,
    /// 要补的 profile（uid 文本，升序）。
    pub profiles: Vec<String>,
}

impl Plan {
    pub(crate) fn is_empty(&self) -> bool {
        !self.upgrade && self.profiles.is_empty()
    }
}

/// 只读：[src]（`dryrun::open_legacy` 的读快照，schema 是 [schema]）要补什么。补不了的直接给结论（`Ok(Err(..))`）：
/// 并入做到一半、缺缓存配置。
///
/// schema 比这一版旧时表形态不同，`preflight` 读不了：全部 profile 都走一遍补完（命令对已经做完的 profile 什么都不写）。
pub(crate) fn plan(
    src: &Connection,
    schema: i64,
    caches: &BTreeMap<String, String>,
) -> Result<Result<Plan, Outcome>, String> {
    let marks = legacy::merge_marks(src)?;
    if !marks.is_empty() {
        return Ok(Err(blocked(
            BlockCode::MergeHalfDone,
            format!("a profile merge is half done ({})", marks.join(", ")),
        )));
    }
    let all = legacy::all_profiles(src)?;
    let missing: Vec<&str> = all
        .iter()
        .filter(|p| !caches.contains_key(*p))
        .map(String::as_str)
        .collect();
    if !missing.is_empty() {
        return Ok(Err(blocked(
            BlockCode::MissingCacheConfig,
            format!(
                "no cache configuration was given for profile(s) {}",
                missing.join(", ")
            ),
        )));
    }
    let upgrade = schema < SCHEMA_VERSION;
    let profiles = if upgrade {
        all
    } else {
        let mut todo = Vec::new();
        for p in all {
            if !legacy::preflight(src, &p)?.is_empty()
                || !legacy::migration_blockers(src, &p)?.is_empty()
            {
                todo.push(p);
            }
        }
        todo
    };
    Ok(Ok(Plan { upgrade, profiles }))
}

/// 写之前的完整性检查（`PRAGMA quick_check`）：不过 = 原因。
fn damage(path: &Path) -> Result<Option<String>, String> {
    // 表达式索引 / 生成列引用协议 3 的 SQL 函数：检查要算它们，连接上得注册（`dryrun::open_legacy` 同一套）。
    let c = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|e| format!("gen4 prepare: {e}"))?;
    crate::store::sync2::digest::register(&c).map_err(|e| format!("gen4 prepare: {e}"))?;
    crate::store::ids::register(&c).map_err(|e| format!("gen4 prepare: {e}"))?;
    crate::store::slim::register(&c).map_err(|e| format!("gen4 prepare: {e}"))?;
    let first: Result<String, rusqlite::Error> =
        c.query_row("PRAGMA quick_check(1)", [], |r| r.get(0));
    match first {
        Ok(v) if v == "ok" => Ok(None),
        Ok(v) => Ok(Some(format!("srs.db is damaged: {v}"))),
        Err(e) if is_corrupt(&e) => Ok(Some(format!("srs.db is damaged: {e}"))),
        Err(e) => Err(format!("gen4 prepare: {e}")),
    }
}

/// 照 [plan] 补完（拿着换代锁调；[legacy_path] 是 `srs.db`）。`Ok(None)` = 补完了，接着核对前提；`Ok(Some(..))` =
/// 结论（拦下 / 空间不够 / 叫停）。出错（IO、协议 3 的命令报错）是 `Err`：已提交的批次留着（协议 3 的状态），重跑接着做。
pub(crate) fn complete(
    legacy_path: &Path,
    plan: &Plan,
    opts: &mut Options<'_>,
) -> Result<Option<Outcome>, String> {
    if plan.is_empty() {
        return Ok(None);
    }
    if opts.stop.stopped() {
        return Ok(Some(Outcome::Cancelled));
    }
    // 旧库正被别的连接写：先不碰（与核对前提时同一个判断）。试完马上放开：补完要协议 3 自己的写连接。
    match hold_legacy(legacy_path)? {
        None => {
            return Ok(Some(blocked(BlockCode::Busy, super::migrate::BLOCKED_BUSY)));
        }
        Some(held) => {
            let _ = held.execute_batch("ROLLBACK");
            drop(held);
        }
    }
    if let Some(why) = damage(legacy_path)? {
        return Ok(Some(blocked(BlockCode::Corrupt, why)));
    }
    let core = match SrsCore::open(legacy_path) {
        Ok(core) => core,
        Err(e) => {
            if let Some(rest) = e.strip_prefix(UPGRADE_NO_SPACE) {
                let v: Value = serde_json::from_str(rest).unwrap_or(Value::Null);
                if let (Some(needed), Some(free)) = (v["need"].as_u64(), v["free"].as_u64()) {
                    return Ok(Some(Outcome::NoSpace { needed, free }));
                }
            }
            return Err(format!("gen4 prepare: open the protocol 3 library: {e}"));
        }
    };
    let out = finish_profiles(&core, plan, opts);
    // 关库：WAL 并回主文件（最后一条连接负责），随后核对前提的只读快照与写锁看到的就是补完的全部。
    core.close();
    drop(core);
    out
}

/// 经协议 3 的分发器发一条命令（与旧 app 发的同形）。
fn dispatch(core: &SrsCore, req: Value) -> Result<Value, String> {
    crate::store::ffi::sync2_dispatch(core, &req, &mut Vec::new(), &mut Vec::new()).map_err(|e| {
        format!(
            "gen4 prepare: protocol 3 `{}` for {}: {e}",
            req["op"].as_str().unwrap_or_default(),
            req["profile"].as_str().unwrap_or_default()
        )
    })
}

/// 文件头的三步，逐 profile。每条命令之后报一次进度（[Step::Prepare]，(已做完的 profile 数, 要补的 profile 数)），
/// 每条命令之前看一次叫停。
fn finish_profiles(
    core: &SrsCore,
    plan: &Plan,
    opts: &mut Options<'_>,
) -> Result<Option<Outcome>, String> {
    let n = plan.profiles.len() as u64;
    let now = opts.now_ms;
    let batch = opts.batch.max(1);
    for (i, p) in plan.profiles.iter().enumerate() {
        let at = i as u64;
        // [plan] 已核对过每个 profile 都有。
        let caches: Value = serde_json::from_str(
            opts.caches
                .get(p)
                .ok_or_else(|| format!("gen4 prepare: no cache configuration for {p}"))?,
        )
        .map_err(|e| format!("gen4 prepare: bad cache configuration for {p}: {e}"))?;
        let steps: [(Value, fn(&Value) -> bool); 3] = [
            (
                json!({"op": "migrate", "profile": p, "now": now, "limit": batch}),
                |r| r["done"] == json!(true),
            ),
            (
                json!({"op": "dedup", "profile": p, "now": now, "caches": caches}),
                |r| r["done"] != json!(false),
            ),
            (
                json!({"op": "replay_pending", "profile": p, "caches": caches}),
                |r| r["more"] != json!(true),
            ),
        ];
        for (req, finished) in steps {
            loop {
                if opts.stop.stopped() {
                    return Ok(Some(Outcome::Cancelled));
                }
                let r = dispatch(core, req.clone())?;
                (opts.progress)(Step::Prepare, at, n);
                if finished(&r) {
                    break;
                }
            }
        }
    }
    (opts.progress)(Step::Prepare, n, n);
    Ok(None)
}

#[cfg(test)]
#[path = "prepare_tests.rs"]
mod tests;
