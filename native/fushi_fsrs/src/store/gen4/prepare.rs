//! 迁移前提补完（G7-2b；设计 §6.1「前提」，交接说明 §9.5 第 1、2 条、§11）：`gen4_migrate_run` 拿到换代锁与原件的写锁
//! 之后、核对前提之前，用**冻结的协议 3 代码**把旧库还没做完的协议 3 收尾做完——**在原件的副本上做**
//! （[PREPARE_COPY]），原件在提交点之前一个字节不写。
//!
//! # 为什么在这里补
//!
//! 协议 3 的这些收尾原本由 app 驱动：开库时 `identity` + `migrate`（旧行包成操作，`sync2/mod.rs` `finish_migration`
//! 才写 `sync2_self.migrated_at`；App 等首次同步确认后才迁移，BUG-4011，从没同步过的用户一直是 NULL）、同步轮次里的
//! `dedup`、收段收尾的 `ingest_finish` / `replay_pending`（收段通道 `sync2_boot`、待重放 `sync2_replay_pending`、待刷新
//! 缓存 `sync2_cache_pending`）。S1 删了 `ffsrs_store_open`、G7-5 删了 Dart 的这些调用之后，没有任何路径再做它们，
//! 而迁移的前提核对（`legacy::preflight` / `migration_blockers` / `library_blockers`）把它们当硬阻断：这些用户永远迁不了。
//!
//! # 为什么在副本上做
//!
//! 最新的协议 3 正式版（v3.3.0，D2 的回退目标）的库是 schema 26，这一版的协议 3 是 29：从正式版升上来的用户，补完的
//! 第一步就是协议 3 的升级阶梯。v3.3.0 打不开 schema 更新的库（「newer than this build」），在原件上补完的话，之后只要
//! 对拍中止、取消、出错或进程被杀，用户就再也回不到 v3.3.0，而这一版又没有协议 3 的开库入口。所以：
//!
//! - 迁移拿着原件的写锁（`migrate::hold_legacy`，`BEGIN IMMEDIATE`，不写）从补完之前一直持到封存：补完、对拍、提交期间
//!   谁也写不进原件；
//! - 用 SQLite 的在线备份把原件逐页拷成 [PREPARE_COPY]（一个读快照，含 WAL 里已提交的部分；原件不动）；
//! - 升级与补完都只写副本；之后的读快照、对拍、提交都从副本来；提交点（改名）之后封存的是**原件**——新代库记的迁移
//!   来源也是原件的指纹（`files::record_migrated_from` / `files::source_mark`），补封时拿原件核对；
//! - 迁移结束（不论结论）删掉副本；崩溃留下的由下一次迁移或 Primary 打开删掉。
//!
//! 提交点之前任何一种结局（叫停、panic、进程被杀、对拍中止、补完报错），原件都逐字节是迁移前的样子：哪个版本的协议 3
//! 写的，就还能被哪个版本打开。代价是补完期间多占一份旧库的空间（空间核对算进去了）。
//!
//! # 做什么（[plan] 只读判断，[complete] 才写副本）
//!
//! - 旧库 schema 比这一版的协议 3 旧：`SrsCore::open` 的升级阶梯在副本上把它升上来（空间不够照协议 3 的空间守卫报
//!   [Outcome::NoSpace]）。
//! - 每个要补的 profile（[Plan::profiles]，升序），经协议 3 的分发器（`store/legacy3` `sync2_dispatch`，与旧 app 发的
//!   是同一串命令，通道没做完时分发器自己先按片做完）依次：
//!   1. `migrate`（每批 [Options::batch] 条）到 `done`：建本机身份（没有的话）、把还没有任何操作代表的旧行包成操作、
//!      写 `migrated_at`。只在投影表里的孤儿 uid 也这样进操作日志，迁移时与别的 profile 一样迁过去；
//!   2. `dedup` 到 `done` 不为假（重复流收敛，本机就能做完：发 `Dedup` 只是追加本机操作）；
//!   3. `replay_pending` 到 `more` 不为真（收段通道、待重放的卡、待刷新的缓存）。
//!
//! 每一步都是协议 3 自己本来会做的事，不改变数据的含义（迁移只包「还没被代表」的旧行，重放是全部日志的纯函数，缓存
//! 随时可重建）。什么都不用补的库不拷副本，读快照直接开在原件上。
//!
//! 与协议 3 的 app 不同，这里不等首次同步确认、不先从同步位置收一轮（BUG-4011 的推迟迁移）：多台设备、协议 3 同步
//! 从没确认过、却共享同一份旧行的用户，每台设备各自把旧行包一遍，迁到新代后存储里是两份操作流；新代的派生层按 dot /
//! 日志 ID 取操作号最小的一份（`derive.rs`），用户看到的结果不变，只是体积与同步量多一份（交接说明 §11，交 G8 / G9
//! 判断要不要在新代收敛副本）。
//!
//! # 并入做到一半（G9-5）
//!
//! 协议 3 的 profile 并入（Dart `srs_profile_merge.dart`）中断留下的 `profile_merge/<旧 uid>` 标记**不拦**：并入两边的
//! uid 各自照常补完、各迁成一个集合（旧 uid 的数据完整，新 uid 里是目标集合加一部分重映射副本），标记原样带进新代库
//! （`migrate.rs` [carry_library_meta](super::migrate::carry_library_meta)）。收尾由 Dart（知道主库 profile 现在指着
//! 哪个 uid）在新代里发 `profile_merge_commit`：一个事务里把旧 uid 的集合并进新 uid 的（`cmd/profile_data.rs` 文件头）。
//! 补完不碰标记：那是 Dart 并入的状态，协议 3 的这几条命令不读它。
//!
//! # 补不了的（拦下，[BlockCode]）
//!
//! - 旧库里有 profile 没给缓存配置（`dedup` / `replay_pending` 要刷新协议 3 的缓存行，迁移也要）：Dart 按
//!   `gen4_migrate_profiles`（[crate::store::gen4::legacy::all_profiles]）逐个给。
//! - 拷副本之前 `PRAGMA quick_check` 不过（文件坏了）：不在坏文件上补。
//! - 副本升级到这一版的 schema 之后，缺这一版协议 3 该有的表（[missing_tables]：schema 标记与表对不上，例如开发版
//!   留下的库标了 13 却没有 v12 的 `sync2_replay_pending`）：协议 3 的命令在这种库上只会报「no such table」，补不了、
//!   重试也不会变，按文件坏了拦下（[BlockCode::Corrupt]），不当成内部错误返回。
//!
//! 协议 1 的主库（`srs_entities` 在 app 主库里，D21）不在这里：那是另一个文件，G7-6 处理。

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use rusqlite::{Connection, OpenFlags};
use serde_json::{Value, json};

use super::dryrun::Stop;
use super::files::{LEGACY_FILE, PREPARE_COPY};
use super::legacy;
use super::migrate::{BlockCode, Options, Outcome, Step, blocked, is_corrupt};
use crate::store::SrsCore;
use crate::store::schema::{SCHEMA_VERSION, UPGRADE_NO_SPACE};
use crate::store::seal;

/// 要补的事（[plan] 的结果）。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Plan {
    /// 旧库 schema 比这一版的协议 3 旧：副本打开时先升级。
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
/// 缺缓存配置。
///
/// schema 比这一版旧时表形态不同，`preflight` 读不了：全部 profile 都走一遍补完（命令对已经做完的 profile 什么都不写）。
pub(crate) fn plan(
    src: &Connection,
    schema: i64,
    caches: &BTreeMap<String, String>,
) -> Result<Result<Plan, Outcome>, String> {
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

/// 拷副本之前的完整性检查（`PRAGMA quick_check`）：不过 = 原因。
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

/// 副本（已升级到 [SCHEMA_VERSION]）缺的协议 3 表：与同一版升级阶梯在空库上建出来的表逐个比（表的清单只有阶梯一处）。
/// 都在 = `None`。
fn missing_tables(copy: &Path) -> Result<Option<String>, String> {
    let err = |e: String| format!("gen4 prepare: check the protocol 3 tables: {e}");
    let tables = |c: &Connection| -> Result<std::collections::BTreeSet<String>, String> {
        let mut stmt = c
            .prepare("SELECT name FROM main.sqlite_schema WHERE type = 'table'")
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], |r| r.get::<_, String>(0))
            .map_err(|e| e.to_string())?;
        rows.collect::<Result<_, _>>().map_err(|e| e.to_string())
    };
    let mut fresh = Connection::open_in_memory().map_err(|e| err(e.to_string()))?;
    crate::store::schema::migrate(&mut fresh).map_err(err)?;
    let want = tables(&fresh).map_err(err)?;
    let c = Connection::open_with_flags(
        copy,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|e| err(e.to_string()))?;
    let have = tables(&c).map_err(err)?;
    let missing: Vec<&str> = want.difference(&have).map(String::as_str).collect();
    Ok((!missing.is_empty()).then(|| {
        format!(
            "srs.db claims schema {SCHEMA_VERSION} after the upgrade but lacks table(s) {}",
            missing.join(", ")
        )
    }))
}

/// 在线备份一次拷的页数（两次之间看一次叫停）。
const COPY_PAGES: i32 = 4096;

/// 把原件 [from] 逐页拷成 [to]（SQLite 在线备份：一个读快照，含 WAL 里已提交的部分；不写原件）。叫停 = `Ok(false)`。
fn copy_legacy(from: &Path, to: &Path, stop: &Stop) -> Result<bool, String> {
    let err = |e: rusqlite::Error| format!("gen4 prepare: copy the protocol 3 library: {e}");
    let src = Connection::open_with_flags(
        from,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(err)?;
    let mut dst = Connection::open(to).map_err(err)?;
    {
        let b = rusqlite::backup::Backup::new(&src, &mut dst).map_err(err)?;
        loop {
            if stop.stopped() {
                return Ok(false);
            }
            match b.step(COPY_PAGES).map_err(err)? {
                rusqlite::backup::StepResult::Done => break,
                rusqlite::backup::StepResult::More => {}
                // 拿着原件的写锁、副本只有这一条连接：不该忙。
                other => {
                    return Err(format!(
                        "gen4 prepare: copy the protocol 3 library: {other:?}"
                    ));
                }
            }
        }
    }
    dst.close().map_err(|(_, e)| err(e))?;
    Ok(true)
}

/// 照 [plan] 在副本上补完（调用方拿着换代锁与原件 `dir/srs.db` 的写锁）。`Ok(Ok(副本路径))` = 补完了，之后的读快照与
/// 阶段都开在副本上；`Ok(Err(..))` = 结论（拦下 / 空间不够 / 叫停）。出错（IO、协议 3 的命令报错）是 `Err`。副本由
/// 调用方在迁移结束时删（不论结论）；原件不论哪种结局都不动。
pub(crate) fn complete(
    dir: &Path,
    plan: &Plan,
    opts: &mut Options<'_>,
) -> Result<Result<PathBuf, Outcome>, String> {
    let legacy = dir.join(LEGACY_FILE);
    let copy = dir.join(PREPARE_COPY);
    if opts.stop.stopped() {
        return Ok(Err(Outcome::Cancelled));
    }
    if let Some(why) = damage(&legacy)? {
        return Ok(Err(blocked(BlockCode::Corrupt, why)));
    }
    seal::remove_sqlite_files(&copy)?;
    if !copy_legacy(&legacy, &copy, opts.stop)? {
        return Ok(Err(Outcome::Cancelled));
    }
    let core = match SrsCore::open(&copy) {
        Ok(core) => core,
        Err(e) => {
            if let Some(rest) = e.strip_prefix(UPGRADE_NO_SPACE) {
                let v: Value = serde_json::from_str(rest).unwrap_or(Value::Null);
                if let (Some(needed), Some(free)) = (v["need"].as_u64(), v["free"].as_u64()) {
                    return Ok(Err(Outcome::NoSpace { needed, free }));
                }
            }
            return Err(format!("gen4 prepare: open the protocol 3 library: {e}"));
        }
    };
    if let Some(why) = missing_tables(&copy)? {
        core.close();
        drop(core);
        return Ok(Err(blocked(BlockCode::Corrupt, why)));
    }
    let out = finish_profiles(&core, plan, opts);
    // 关库：WAL 并回副本主文件（最后一条连接负责），随后的读快照看到的就是补完的全部。
    core.close();
    drop(core);
    Ok(match out? {
        Some(o) => Err(o),
        None => Ok(copy),
    })
}

/// 经协议 3 的分发器发一条命令（与旧 app 发的同形）。
fn dispatch(core: &SrsCore, req: Value) -> Result<Value, String> {
    crate::store::legacy3::dispatch(core, &req, &mut Vec::new()).map_err(|e| {
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
