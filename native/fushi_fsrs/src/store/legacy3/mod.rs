//! 协议 3 的冻结侧（G7-6；设计稿 §2.4、D34，规划缺口 G-10）：协议 3 的 JSON 命令分发器。
//!
//! 换代之后协议 3 的库（`srs.db`）只在两处还要被打开、并按旧 app 发过的同一串命令推进到「可迁移」：
//!
//! - 迁移前提补完（`store/gen4/prepare.rs`）：在原件的副本上发 `migrate` / `dedup` / `replay_pending`；
//! - 旧形态备份读入（`store/gen4/cmd/backup.rs`）：在临时副本上发 `cache_config_set` / `migrate` / `apply`（外来已盖戳事件）
//!   / `dedup` / `replay_pending`。
//!
//! 生产入口 [dispatch] 只认这 5 条（[FROZEN_OPS]），别的命令明确报错；分发器里其余命令的臂（以及只被它们用到的协议 3
//! 实现）只编进测试构建（`#[cfg(test)]`）：它们是协议 3 的行为测试与迁移对拍的语料（`#[cfg(test)]` 下每个协议 3 内核关库时
//! 跑 `gen4::parity::check_core`），也是新代测试现场生成协议 3 夹具的工具（`store/sync2/tests.rs` 的 `Device`）。
//!
//! # 冻结件（只修 bug，不改行为、不改任何持久化名）
//!
//! - 这 5 条命令的实现链：`cache_config_set` → `store/cache_rev.rs`；`apply` / `dedup` → [local_write]（`store/sync2`
//!   `changing::drop_noops` / `apply_local_on`、`store/legacy_clock.rs`、`store/sync2/dedup.rs`）；`migrate` →
//!   `SrsCore::sync2_migrate`；`replay_pending` → `store/sync2/transport.rs` `replay_pending` 与缓存收尾。
//! - schema 1→29 的升级阶梯：`store/schema.rs` 阶梯段、`store/sync2/schema.rs` V5–V29、`snapshots` / `mvr` /
//!   `digest::install`（`SrsCore::open` 跑它）。
//! - 旧形态读入链：`store/gen4/dryrun.rs` `open_legacy` / `profile_stages`、`gen4/legacy.rs`、`legacy_export.rs`、
//!   `oldroot.rs`、`import.rs`，以及 `store/sync2/replay.rs`（K1 的对拍口径）。
//! - 新代复用的协议 3 纯函数层（`store::caches` / `browse` / `queue` / `study` / `stats` / `projections` / `seal` 等与
//!   `store::sync2` 的 `canonical` / `config` / `semantics` 等）不算冻结件，是两代共用的代码，原地留着。
//!
//! 实现链与阶梯原地留在 `store/` 下（挪文件只会让并行的模块冲突，名字不持久化），以这里为唯一入口。

use super::SrsCore;
#[cfg(test)]
use super::ffi::{crypto_command, key32};

/// 生产构建里协议 3 分发器唯一认的命令（模块文件头）。别的命令经 [dispatch] 报 [NOT_FROZEN] 开头的错误。
pub(crate) const FROZEN_OPS: [&str; 5] = [
    "cache_config_set",
    "migrate",
    "apply",
    "dedup",
    "replay_pending",
];

/// 不在 [FROZEN_OPS] 里的命令经 [dispatch] 报的错误开头。
pub(crate) const NOT_FROZEN: &str = "legacy3: not a frozen protocol 3 command";

/// 冻结侧的生产入口：协议 3 的一条 JSON 命令（与旧 app 发的同形），只认 [FROZEN_OPS]。
pub(crate) fn dispatch(
    c: &SrsCore,
    req: &serde_json::Value,
    blobs: &mut Vec<Vec<u8>>,
) -> Result<serde_json::Value, String> {
    let op = req
        .get("op")
        .and_then(serde_json::Value::as_str)
        .ok_or("sync2: missing op")?;
    if !FROZEN_OPS.contains(&op) {
        return Err(format!("{NOT_FROZEN}: {op}"));
    }
    sync2_dispatch(c, req, blobs, &mut Vec::new())
}

/// **协议 3** 的一条 JSON 命令（[sync2_dispatch_op]）。返回之后（命令自己的写入已提交或已回滚）按请求与结果推进这个
/// profile 的进程内刷新键（store/refresh.rs [SrsCore::refresh_after]）；收段通道在命令之前自己做完的片在每片提交时已经记过。
///
/// 生产构建里只经 [dispatch] 进来（只有 [FROZEN_OPS]）；测试构建里协议 3 的测试、对拍装置（`gen4/parity.rs` /
/// `cmd/*_tests.rs` 的「同一串命令打到两侧」）直接调它，能发全部命令。
pub(crate) fn sync2_dispatch(
    c: &SrsCore,
    req: &serde_json::Value,
    blobs: &mut Vec<Vec<u8>>,
    files: &mut Vec<(String, Vec<u8>)>,
) -> Result<serde_json::Value, String> {
    let out = sync2_dispatch_op(c, req, blobs, files);
    let projecting = req
        .get("op")
        .and_then(serde_json::Value::as_str)
        .is_some_and(|op| PROJECTING_OPS.contains(&op));
    c.refresh_after(req, out.as_ref().map_err(|_| ()), projecting);
    out
}

fn sync2_dispatch_op(
    c: &SrsCore,
    req: &serde_json::Value,
    blobs: &mut Vec<Vec<u8>>,
    files: &mut Vec<(String, Vec<u8>)>,
) -> Result<serde_json::Value, String> {
    use serde_json::Value;
    #[cfg(test)]
    use serde_json::json;
    let s = |k: &str| {
        req.get(k)
            .and_then(Value::as_str)
            .ok_or_else(|| format!("sync2: missing {k}"))
    };
    #[cfg(test)]
    let i = |k: &str| {
        req.get(k)
            .and_then(Value::as_i64)
            .ok_or_else(|| format!("sync2: missing {k}"))
    };
    // 不针对单个 profile 的命令（store/profile_data.rs 找无主数据；WAL 并回）。只在测试构建里（模块文件头）。
    #[cfg(test)]
    match s("op")? {
        "profile_uids" => return c.profile_uids(),
        // 不针对单个 profile 的只读查询（store/reads.rs）：查询道的只读连接。
        "read_lib" => {
            return c.read_query(|conn| crate::store::reads::run_lib(conn, req, files));
        }
        "orphan_sweep_done" => {
            let keep: Vec<String> = req
                .get("keep")
                .and_then(Value::as_array)
                .ok_or("sync2: missing keep")?
                .iter()
                .filter_map(|v| v.as_str().map(str::to_owned))
                .collect();
            let mark = req.get("mark") == Some(&Value::Bool(true));
            return c.orphan_sweep_done(i("now")?, &keep, mark);
        }
        // profile 并入 / 链接在 srs.db 里的写（store/profile_data.rs）：各自一次持写锁、一个 SAVEPOINT。
        "profile_merge_mark" => {
            return c.profile_merge_mark(s("from")?, i("profileId")?, s("to")?);
        }
        "profile_merge_commit" => {
            let map = blobs.first().ok_or("profile_merge_commit: missing map")?;
            return c.profile_merge_commit(
                s("from")?,
                s("to")?,
                map,
                req.get("failAfter").and_then(Value::as_str),
            );
        }
        "meta_set_edit" => {
            return c.meta_set_edit(
                s("set")?,
                req.get("add").and_then(Value::as_str),
                req.get("remove").and_then(Value::as_str),
            );
        }
        // 不占写连接的 WAL 并回（store/mod.rs）：大批写入收尾用。
        "wal_checkpoint" => return c.wal_checkpoint(),
        // 批量写入开始 / 结束（Dart `bulkWrites`）：内核按库计嵌套深度，最外层调高 / 恢复写连接的 WAL 自动 checkpoint 阈值
        // （保存原值）、结束时另开连接并回 WAL，期间写连接放回时留着页缓存（store/mod.rs `bulk_begin`，store/mem_budget.rs）。
        // 回包 `{depth}`：这条命令之后的深度。
        "bulk_cache" => {
            let depth = if req.get("on") == Some(&Value::Bool(true)) {
                c.bulk_begin()?
            } else {
                c.bulk_end()?
            };
            return Ok(json!({"depth": depth}));
        }
        // 有写入在等写锁：正在投的收段那一片尽快收（只置一个标志，等锁的一侧直接同步调）。
        "ingest_yield" => {
            c.sync2_ingest_yield();
            return Ok(json!({}));
        }
        // 进程内刷新键（store/refresh.rs）：只读内存，不碰通道、不拿写锁、不读库。Dart 在 UI isolate 上同步调（指纹 getter）。
        "refresh_keys" => return Ok(c.refresh_keys(s("profile")?)),
        _ => {}
    }
    let profile = s("profile")?;
    let op = s("op")?;
    // 新设备收段通道（store/sync2/channel.rs）没做完时，投影里还缺已收下的操作：要改投影 / 读完整投影的命令先把它
    // 按片做完。收段命令自己推进通道；其余只读或不碰投影的命令照常。没有通道时只读内存标记，不拿写锁。
    if !CHANNEL_TRANSPARENT.contains(&op) {
        c.sync2_channel_settle(profile)?;
    }
    // 改投影的命令：同一次调用里接着刷新本机缓存行（store/caches.rs），Dart 只收写过哪些笔记 / 卡。缓存配置
    // （内置笔记类型的代码默认值、默认牌组）只有 Dart 知道，随命令带来；缺了是调用方的 bug，不跳过刷新。
    // 按制卡标签补出处列（Dart 缓存修订号 9；只改笔记缓存的两列，不算缓存写入，不要缓存配置）。
    #[cfg(test)]
    if op == "backfill_tag_sources" {
        let w = c.writer()?;
        let n = crate::store::sync2::in_savepoint(&w, |conn| {
            crate::store::caches::backfill_tag_sources(conn, profile)
        })?;
        return Ok(json!({"filled": n}));
    }
    // 补出处分组键列（srs.db v25 / Dart 缓存修订号 10；只改笔记缓存的这一列，不算缓存写入，不要缓存配置）。
    #[cfg(test)]
    if op == "backfill_source_keys" {
        let w = c.writer()?;
        let n = crate::store::sync2::in_savepoint(&w, |conn| {
            crate::store::caches::backfill_source_keys(conn, profile)
        })?;
        return Ok(json!({"filled": n}));
    }
    // 打开副本时注册本 profile 的缓存配置（之后没带 `caches` 的命令用它；库重开就没了，每次打开都注册），并在同一次
    // 持写锁、同一个 SAVEPOINT 里把缓存补到当前推导口径（store/cache_rev.rs：版本是内核持有的本机状态键 `cacheRev`）。
    // 回包 `{from, to, cache}`。
    if op == "cache_config_set" {
        let cfg = std::sync::Arc::new(crate::store::caches::CacheConfig::parse(
            req.get("caches").ok_or("sync2: missing caches")?,
        )?);
        c.set_cache_config(profile, cfg.clone())?;
        let w = c.writer()?;
        return crate::store::sync2::in_savepoint(&w, |conn| {
            crate::store::cache_rev::upgrade(conn, profile, &cfg)
        });
    }
    // 存量样式去重的落库一半（store/repr_rewrite.rs）：改写一批修改记录的表示、刷新这些笔记的缓存行、推进去重游标并写
    // 本机状态行，一个 SAVEPOINT。回包 `{rewritten, notes, localRevision, localEpoch, cache}`。
    #[cfg(test)]
    if op == "edits_rewrite_repr" {
        let cfg = cache_config_of(c, profile, req)?;
        let w = c.writer()?;
        return crate::store::sync2::in_savepoint(&w, |conn| {
            crate::store::repr_rewrite::command_on(conn, profile, req, &cfg)
        });
    }
    // 媒体回收（store/media_gc.rs）：待回收集合是内核持有的本机状态键。并候选、「核对存活引用 → 删文件 → 移出集合」
    // 各自一次持写锁、一个 SAVEPOINT（后者对写入原子：期间没有写入能重新引用刚判为无引用的文件）；存活引用另有
    // 只读命令给 Dart 的位置清理用。都不改投影、不推进修订号。回收要完整的存活引用，所以只有它在通道没做完时
    // 先做完通道（[CHANNEL_SETTLES]）；另外两条对通道透明。
    #[cfg(test)]
    if op == "media_gc_queue" {
        let w = c.writer()?;
        return crate::store::sync2::in_savepoint(&w, |conn| {
            crate::store::media_gc::queue(conn, profile, req)
        });
    }
    #[cfg(test)]
    if op == "media_gc_collect" {
        let cfg = cache_config_of(c, profile, req)?;
        let w = c.writer()?;
        return crate::store::sync2::in_savepoint(&w, |conn| {
            crate::store::media_gc::collect(conn, profile, &cfg, req)
        });
    }
    #[cfg(test)]
    if op == "media_live_refs" {
        let cfg = cache_config_of(c, profile, req)?;
        let after = i("aliveAfter")?;
        return c.read_visible(|conn| {
            Ok(json!({"refs": crate::store::media_gc::live_refs(conn, profile, &cfg, after)?}))
        });
    }
    // 本机写命令：命令本体、缓存刷新、排队与本机状态行在同一次持写锁、同一个 SAVEPOINT 里（[local_write]）。
    if LOCAL_WRITE_OPS.contains(&op) {
        let cfg = cache_config_of(c, profile, req)?;
        return local_write(c, op, profile, req, blobs, &cfg);
    }
    if PROJECTING_OPS.contains(&op)
        || op == "refresh_caches"
        || op == "rebuild_caches"
        || op == "backfill_dupe_norms"
    {
        let cfg = cache_config_of(c, profile, req)?;
        let mut v = match op {
            #[cfg(test)]
            "refresh_caches" => json!({}),
            // srs.db v15 的老行补 `dupe_norm`（只改这一列，不算缓存写入：不进 Dart 的缓存变更日志）。
            #[cfg(test)]
            "backfill_dupe_norms" => {
                let w = c.writer()?;
                let n = crate::store::sync2::in_savepoint(&w, |conn| {
                    crate::store::caches::backfill_dupe_norms(conn, profile, &cfg)
                })?;
                return Ok(json!({"filled": n}));
            }
            #[cfg(test)]
            "rebuild_caches" => {
                let w = c.writer()?;
                // 缓存整份按当前规则重建：同一个 SAVEPOINT 里记下当前推导口径（store/cache_rev.rs）。
                let written = crate::store::sync2::in_savepoint(&w, |conn| {
                    let written = crate::store::caches::rebuild(conn, profile, &cfg)?;
                    crate::store::cache_rev::record(conn, profile)?;
                    // 覆盖恢复 / 采用别处的 profile 之后：恢复进来的行可能还是内联样式，存量样式去重从头再查。
                    if req.get("resetStyles").and_then(Value::as_bool) == Some(true) {
                        crate::store::local_state::reset_style_cursor(conn, profile)?;
                    }
                    Ok(written)
                })?;
                return Ok(json!({"cache": written.to_json()}));
            }
            // 分批收段的一片：本机已有缓存行的在这一片的事务里当场刷新，新实体记进待刷新集合等收尾
            // （transport.rs `defer_cache_refresh`），这里不再刷。一次投一片（默认按时间切、有写入排队就让出；测试用
            // `sliceOps` 按条数切、`sliceMs` 改时间上限）；结果 `more` 为真 Dart 放开写锁再调。本机状态行与这一片
            // 同一笔事务写下（见 `sync2_ingest_commit_persisting`）。
            #[cfg(test)]
            "ingest_commit" => {
                let now = req
                    .get("now")
                    .and_then(Value::as_i64)
                    .ok_or("sync2: missing now")?;
                let anchor = crate::store::local_state::anchor_of(req)?;
                let (r, written) = c.sync2_ingest_commit_cached(
                    profile,
                    now,
                    slice_budget(c, req),
                    anchor.as_ref(),
                    Some(&*cfg),
                )?;
                let mut v: Value = serde_json::from_str(&r).map_err(|e| e.to_string())?;
                if let Some(m) = v.as_object_mut() {
                    m.insert("cache".to_owned(), written.to_json());
                }
                return Ok(v);
            }
            _ => sync2_command(c, op, profile, req, blobs, files)?,
        };
        let mut dirty = crate::store::caches::Dirty::of_projection(&v);
        // 收尾（重放放完之后）：按块刷新各片记下的缓存，还有剩的就回报 `more`，Dart 放开写锁后用 `replay_pending` 接着刷。
        let drain =
            matches!(op, "ingest_finish" | "replay_pending") && v["more"] != Value::Bool(true);
        #[cfg(test)]
        if op == "refresh_caches" {
            let ids = |k: &str, into: &mut std::collections::BTreeSet<String>| {
                for x in req.get(k).and_then(Value::as_array).into_iter().flatten() {
                    if let Some(id) = x.as_str() {
                        into.insert(id.to_owned());
                    }
                }
            };
            ids("notes", &mut dirty.notes);
            ids("cards", &mut dirty.cards);
            ids("noteTypes", &mut dirty.note_types);
            dirty.all_notes = req["allNotes"] == Value::Bool(true);
            dirty.all_stats = req["allStats"] == Value::Bool(true);
        }
        let w = c.writer()?;
        let mut cache_more = false;
        let written = crate::store::sync2::in_savepoint(&w, |conn| {
            if drain {
                let (pending, _) = crate::store::sync2::transport::take_cache_pending(
                    conn,
                    profile,
                    CACHE_PENDING_CHUNK,
                )?;
                dirty.merge(pending);
            }
            let written =
                crate::store::caches::refresh(conn, profile, &cfg, std::mem::take(&mut dirty))?;
            if drain {
                // 笔记刷新已整行重算过的卡不再单独刷一遍（之后的卡块里）。
                crate::store::sync2::transport::settle_refreshed_cards(
                    conn,
                    profile,
                    &written.cards,
                )?;
                cache_more = crate::store::sync2::transport::cache_is_pending(conn, profile)?;
            }
            Ok(written)
        })?;
        if cache_more {
            v["more"] = Value::Bool(true);
        }
        // 收尾收完：收尾阶段结束，这次放回写连接起照常还页缓存。收尾阶段只由测试构建里的收段会话进入（G7-6）。
        #[cfg(test)]
        if !cache_more && drain {
            c.sync2_ingest_drained(profile)?;
        }
        // 本机作答：落库、刷新缓存之后接着在同一条写连接上排队（下一张 + 牌组计数，store/study.rs），复习页一次
        // 评分一次命令。看得见这笔还没提交的写入。
        let study = match req.get("study").filter(|s| s.is_object()) {
            Some(s) => Some(crate::store::study::study(
                &w,
                &c.study_hub,
                true,
                profile,
                s,
            )?),
            None => None,
        };
        if let Some(m) = v.as_object_mut() {
            m.insert("cache".to_owned(), written.to_json());
            if let Some(s) = study {
                m.insert("study".to_owned(), s);
            }
        }
        return Ok(v);
    }
    sync2_command(c, op, profile, req, blobs, files)
}

/// 缓存刷新用的配置：请求带了 `caches` 就用带来的，否则用这个 profile 打开时注册的（`cache_config_set`）。两样都没有
/// 是调用方的 bug（没经 `SrsDbStore.open` 就发投影命令），不跳过刷新。
fn cache_config_of(
    c: &SrsCore,
    profile: &str,
    req: &serde_json::Value,
) -> Result<std::sync::Arc<crate::store::caches::CacheConfig>, String> {
    match req.get("caches") {
        Some(v) => Ok(std::sync::Arc::new(
            crate::store::caches::CacheConfig::parse(v)?,
        )),
        None => c.cache_config(profile)?.ok_or_else(|| {
            "sync2: missing caches (no cache_config_set for this profile)".to_owned()
        }),
    }
}

/// 本机写命令（收掉 Dart 写路径第 2 步）。分发器取**一次**写锁，在**一个** SAVEPOINT 里
/// 依次做完命令本体（[local_write_body]）、缓存刷新（store/caches.rs）、请求带 `study` 时的排队（store/study.rs，看得见
/// 这笔还没提交的写入），以及本机状态行（store/local_state.rs `persist_projected`：修订号按投影
/// 结果从库里的值推进，回包带 `localRevision` / `localEpoch`；请求带了校时状态 `anchor` 就一并写下）。任何一步出错整个 SAVEPOINT 回滚：命令、缓存行、本机状态行一起不落。写连接上
/// 没有别人开着的事务（Dart 没有别的入口能在写连接上开事务），这个 SAVEPOINT 就是一笔独立提交的事务。
const LOCAL_WRITE_OPS: &[&str] = &[
    "apply",
    "import_drafts",
    "change",
    "note_fields_if",
    "merge_notes",
    "sched",
    "deck_delete",
    "import",
    "resolve",
    "purge",
    "checkpoint",
    "restore",
    "retire",
    "dedup",
    "digest_heal",
    "trust",
];

/// [LOCAL_WRITE_OPS] 写锁外的预处理：只读已提交数据（冲突表）、不持锁的解析与收段预处理。
#[derive(Default)]
struct LocalPre {
    /// `apply` 的输入。
    items: Vec<serde_json::Value>,
    #[cfg(test)]
    /// `resolve` 的冲突实体（读连接上预读：命令本身还没写过东西，读已提交数据即可）。
    conflict: Option<(crate::sync2::op::EntKind, String)>,
    #[cfg(test)]
    /// `retire` 之后紧接着投一遍缓冲用的空批（收段的锁外一半，不持锁）。
    drain: Option<crate::store::sync2::transport::PreparedIngest<'static>>,
}

/// [LOCAL_WRITE_OPS] 的执行（见那张表）。
fn local_write(
    c: &SrsCore,
    op: &str,
    profile: &str,
    req: &serde_json::Value,
    blobs: &[Vec<u8>],
    cfg: &crate::store::caches::CacheConfig,
) -> Result<serde_json::Value, String> {
    #[cfg(test)]
    use serde_json::Value;
    let mut pre = LocalPre::default();
    if op == "apply" || op == "import_drafts" || op == "change" || op == "note_fields_if" {
        let input = std::str::from_utf8(blobs.first().ok_or("apply: missing input")?)
            .map_err(|e| e.to_string())?;
        pre.items = crate::store::sync2::parse_apply_input(input)?;
    }
    #[cfg(test)]
    if op == "resolve" {
        let conflict = req
            .get("conflict")
            .and_then(Value::as_str)
            .ok_or("sync2: missing conflict")?;
        pre.conflict = Some(c.sync2_conflict_target(profile, conflict)?);
    } else if op == "retire" {
        pre.drain = Some(c.prepare_unlocked(profile, std::borrow::Cow::Owned(Vec::new()), None)?);
    }
    let anchor = crate::store::local_state::anchor_of(req)?;
    let w = c.writer()?;
    // 会话外投递（导入、停用后的那一遍投递）：新设备收段通道没做完就先按片做完（各片自己提交，不进下面的 SAVEPOINT；
    // 分发器已在取写锁前收过，这里通常没有通道）。
    #[cfg(test)]
    if op == "import" || op == "retire" {
        c.settle_channel_on(&w, profile)?;
    }
    crate::store::sync2::in_savepoint(&w, |conn| {
        // `apply` 的前置条件（远程作答核对基准）：不成立就什么都不做——不落、旧版时钟不走、不排队、不写本机状态行。
        if op == "apply" && !expect_last_holds(conn, req)? {
            return Ok(serde_json::json!({"stale": true}));
        }
        let mut v = local_write_body(conn, op, profile, req, blobs, &mut pre)?;
        let written = crate::store::caches::refresh(
            conn,
            profile,
            cfg,
            crate::store::caches::Dirty::of_projection(&v),
        )?;
        // `change` 的移牌组段（store/sync2/change.rs）：要看上面这次刷新生成的卡，所以排在它后面；写完再刷新一次，
        // 两段的结果并成一份（修订号、Dart 的变更日志都按合起来的算）。
        #[cfg(test)]
        let mut written = written;
        #[cfg(test)]
        if op == "change" && crate::store::sync2::change::wants_move(req) {
            let now = req
                .get("now")
                .and_then(Value::as_i64)
                .ok_or("sync2: missing now")?;
            let moved = crate::store::sync2::change::move_notes_on(conn, profile, now, req)?;
            written.absorb(crate::store::caches::refresh(
                conn,
                profile,
                cfg,
                crate::store::caches::Dirty::of_projection(&moved),
            )?);
            crate::store::sync2::change::merge_results(&mut v, moved);
        }
        let study = match req.get("study").filter(|s| s.is_object()) {
            Some(s) => Some(crate::store::study::study(
                conn,
                &c.study_hub,
                true,
                profile,
                s,
            )?),
            None => None,
        };
        // 本机状态行：修订号按这次的投影结果从库里的值推进（`apply` / `sched` 推进过的旧版时钟已由命令本体写进同一
        // 行，这里读改写整行，不动它）。
        crate::store::local_state::persist_projected(conn, profile, anchor.as_ref(), &mut v)?;
        if let Some(m) = v.as_object_mut() {
            m.insert("cache".to_owned(), written.to_json());
            if let Some(s) = study {
                m.insert("study".to_owned(), s);
            }
        }
        Ok(v)
    })
}

/// `apply` 请求的可选前置条件 `expectLast: {card, log}`：这张卡的缓存行还在、且它最后一条生效日志就是 `log`（null =
/// 还没有日志）。远程复习的作答带它（Dart `SrsRemoteStoreService` 的 `answerAndStudy` 路由）：客户端出题之后主机上
/// 这张卡又被作答 / 撤销 / 删掉了，就不该再按客户端看到的那一面记一条日志。核对与落库在同一笔里，中间插不进别的
/// 写入。不带 = 成立。
fn expect_last_holds(conn: &rusqlite::Connection, req: &serde_json::Value) -> Result<bool, String> {
    let Some(expect) = req.get("expectLast").filter(|e| e.is_object()) else {
        return Ok(true);
    };
    let card = expect["card"]
        .as_str()
        .ok_or("apply: missing expectLast.card")?;
    let last: Option<Option<String>> = conn
        .prepare_cached("SELECT srs_idt(last_log_id) FROM srs_cards_cache WHERE id = srs_id(?1)")
        .map_err(|e| e.to_string())?
        .query_row([card], |r| r.get(0))
        .map(Some)
        .or_else(|e| match e {
            rusqlite::Error::QueryReturnedNoRows => Ok(None),
            e => Err(e.to_string()),
        })?;
    Ok(last.is_some_and(|l| l.as_deref() == expect["log"].as_str()))
}

/// [LOCAL_WRITE_OPS] 的命令本体：在 [local_write] 持着的写连接、开好的 SAVEPOINT 里做（各 `*_on` 都不自己取锁）。
fn local_write_body(
    conn: &rusqlite::Connection,
    op: &str,
    profile: &str,
    req: &serde_json::Value,
    // 只有测试构建才编的臂（G7-6）读它；生产构建的冻结命令用不到。
    #[cfg_attr(not(test), allow(unused_variables))] blobs: &[Vec<u8>],
    pre: &mut LocalPre,
) -> Result<serde_json::Value, String> {
    use crate::store::sync2 as s2;
    use serde_json::Value;
    let s = |k: &str| {
        req.get(k)
            .and_then(Value::as_str)
            .ok_or_else(|| format!("sync2: missing {k}"))
    };
    let now = req
        .get("now")
        .and_then(Value::as_i64)
        .ok_or("sync2: missing now")?;
    Ok(match op {
        "apply" => {
            // 旧版时钟（store/legacy_clock.rs）：宿主的设备 ID 必带（没存过写入者时用它拼缺省写入者）；带 `clk` 的项
            // 按 `recvNow` / `tickNow` 推进，`stamps` 为真时回包带每项落库用的戳。
            let legacy = s2::LegacyApply {
                device: s("legacyDevice")?,
                recv_now: req.get("recvNow").and_then(Value::as_i64),
                tick_now: req.get("tickNow").and_then(Value::as_i64),
                stamps: req.get("stamps") == Some(&Value::Bool(true)),
            };
            // 标了 `chg` 的修改记录草稿：值没变的不落（store/sync2/changing.rs）。一项不剩就什么都不做——不占序号、
            // 旧版时钟不走；回包的 `landed` / `stamps` 仍按原输入的长度给。
            match s2::changing::drop_noops(conn, &mut pre.items)? {
                None => s2::apply_local_on(conn, profile, now, &pre.items, Some(&legacy))?,
                Some(kept) => {
                    let mut v = if pre.items.is_empty() {
                        serde_json::json!({})
                    } else {
                        s2::apply_local_on(conn, profile, now, &pre.items, Some(&legacy))?
                    };
                    kept.widen(&mut v, legacy.stamps);
                    v
                }
            }
        }
        // 导入攒的一批草稿（Anki 包、AnkiConnect）：`apply` 的本体，外加「初值」项的去留与「落库前已存在的实体」由内核在
        // 同一笔里判（store/sync2/mod.rs `import_drafts_on`）。
        #[cfg(test)]
        "import_drafts" => {
            let legacy = s2::LegacyApply {
                device: s("legacyDevice")?,
                recv_now: req.get("recvNow").and_then(Value::as_i64),
                tick_now: req.get("tickNow").and_then(Value::as_i64),
                stamps: false,
            };
            s2::import_drafts_on(conn, profile, now, &mut pre.items, &legacy)?
        }
        // 结构性改动（更改笔记类型、删除重复模板、旧 Lapis 迁移）：还原点 + 一批修改记录（store/sync2/change.rs）；带
        // `move` 时 [local_write] 在缓存刷新之后接着做移牌组那一段。
        #[cfg(test)]
        "change" => s2::change::change_on(conn, profile, now, req, &mut pre.items)?,
        // 条件写笔记字段（批量改字段的落计划 / 撤销）：比对现值与写入在一笔里（store/sync2/note_fields_if.rs）。
        #[cfg(test)]
        "note_fields_if" => {
            s2::note_fields_if::note_fields_if_on(conn, profile, now, req, &pre.items)?
        }
        // 合并重复笔记：还原点、前身链接、补字段 / 并标签、删除被吸收的笔记（store/sync2/merge_notes.rs）。
        #[cfg(test)]
        "merge_notes" => s2::merge_notes::merge_notes_on(conn, profile, now, req)?,
        // 本机手动排程操作（重置 / 改期 / 撤销 / 立即重排）：显式意图，内核算结果并落库（store/sync2/sched_local.rs）。
        #[cfg(test)]
        "sched" => s2::sched_local::sched_local_on(conn, profile, now, req)?,
        // 删牌组（连同子牌组）：显式意图，分步（store/sync2/deck_delete.rs）；`done` 为假就带着 `token` 再发。
        #[cfg(test)]
        "deck_delete" => s2::deck_delete::deck_delete_on(conn, profile, now, req)?,
        // 存量重复流收敛作业推进一步（store/sync2/dedup.rs）；`done` 为假就再发。
        "dedup" => s2::dedup::dedup_on(conn, profile, now)?,
        // 摘要不一致的自动重建（store/sync2/heal.rs）：重放改写的卡随这次命令刷新缓存。
        #[cfg(test)]
        "digest_heal" => s2::heal::digest_heal_on(conn, profile, now)?,
        #[cfg(test)]
        "import" => s2::transport::import_on(
            conn,
            profile,
            blobs.first().ok_or("import: missing file")?,
            now,
        )?,
        #[cfg(test)]
        "resolve" => {
            let (kind, entity) = pre.conflict.take().ok_or("resolve: conflict not read")?;
            let delete = req["delete"] == Value::Bool(true);
            s2::append_on(
                conn,
                profile,
                now,
                &s2::resolve_bodies(kind, &entity, delete, now),
            )?
        }
        // 彻底清除一批同类实体：每个实体仍是「删除 + 清除」两条操作，按输入顺序，一笔落下（逐个发时每个实体一笔
        // 事务、一次缓存刷新、一次本机状态行）。不存在 / 已清除过的 ID 照常追加（清除标记幂等，semantics.rs
        // `purge_entity`）。
        #[cfg(test)]
        "purge" => {
            let kind = s("kind")?;
            let entities = req
                .get("entities")
                .and_then(Value::as_array)
                .filter(|e| !e.is_empty())
                .ok_or("purge: missing entities")?;
            let mut bodies = Vec::with_capacity(entities.len() * 2);
            for e in entities {
                let e = e.as_str().ok_or("purge: entity is not a string")?;
                bodies.extend(s2::purge_bodies(kind, e, now)?);
            }
            s2::append_on(conn, profile, now, &bodies)?
        }
        #[cfg(test)]
        "checkpoint" => s2::append_on(
            conn,
            profile,
            now,
            &s2::checkpoint_bodies(s("name")?, s("reason")?),
        )?,
        #[cfg(test)]
        "restore" => s2::timeline::restore_on(
            conn,
            profile,
            &restore_target(req)?,
            req["retract"] == Value::Bool(true),
            now,
        )?,
        // 信任 / 拒绝一台待确认的设备（store/sync2/trust.rs）：信任时扣着的删除 / 彻底清除放行进投影。
        #[cfg(test)]
        "trust" => s2::trust::trust_on(
            conn,
            profile,
            &crate::sync2::id::Id::parse(s("device")?).ok_or("trust: bad device")?,
            req["trust"] != Value::Bool(false),
            now,
        )?,
        // 停用 / 取消停用一台设备，紧接着在同一个 SAVEPOINT 里投一遍缓冲（因它卡住的操作不再等它）。
        #[cfg(test)]
        "retire" => {
            let id = crate::sync2::id::Id::parse(s("device")?).ok_or("retire: bad device")?;
            let retire = req["retire"] != Value::Bool(false);
            let mut v = s2::devices::retire_on(conn, profile, &id, retire, now)?;
            let prepared = pre.drain.as_mut().ok_or("retire: drain not prepared")?;
            let drained: Value =
                serde_json::from_str(&s2::transport::ingest_on(conn, profile, prepared, now)?)
                    .map_err(|e| e.to_string())?;
            if let (Some(m), Value::Object(d)) = (v.as_object_mut(), drained) {
                m.extend(d);
            }
            v
        }
        _ => return Err(format!("sync2: `{op}` is not a local write")),
    })
}

#[cfg(test)]
/// 恢复的目标（`restore` / `plan_restore`）：还原点 `checkpoint: {device, seq}`（按它的因果截断）或某个时刻 `at`。
fn restore_target(
    req: &serde_json::Value,
) -> Result<crate::store::sync2::timeline::RestoreTarget, String> {
    use crate::store::sync2::timeline::RestoreTarget;
    Ok(match req.get("checkpoint") {
        Some(cp) if cp.is_object() => RestoreTarget::Checkpoint(crate::sync2::vv::OpId {
            device: crate::sync2::id::Id::parse(cp["device"].as_str().ok_or("checkpoint.device")?)
                .ok_or("bad checkpoint device")?,
            seq: cp["seq"].as_u64().ok_or("checkpoint.seq")?,
        }),
        _ => RestoreTarget::At(
            req.get("at")
                .and_then(serde_json::Value::as_i64)
                .ok_or("sync2: missing at")?,
        ),
    })
}

/// 收段 / 重放的一片：默认按时间切、有写入排队就让出；测试用 `sliceOps` 按条数切、`sliceMs` 改时间上限。
fn slice_budget<'a>(
    c: &'a SrsCore,
    req: &serde_json::Value,
) -> crate::store::sync2::transport::CommitBudget<'a> {
    use crate::store::sync2::transport::CommitBudget;
    use serde_json::Value;
    match (
        req.get("sliceOps").and_then(Value::as_u64),
        req.get("sliceMs").and_then(Value::as_u64),
    ) {
        (Some(n), _) => CommitBudget::ops(n as usize),
        (None, Some(ms)) => {
            CommitBudget::slice_within(c.ingest_yield_flag(), std::time::Duration::from_millis(ms))
        }
        (None, None) => CommitBudget::slice(c.ingest_yield_flag()),
    }
}

/// 收尾时一次命令最多刷新多少个待刷新实体（笔记类型 / 笔记 / 卡）：一块的锁内时间与重放的一片同量级，排队的
/// 作答只等这一块。
#[cfg(any(not(test), srs_probe))]
const CACHE_PENDING_CHUNK: usize = 512;
/// 测试里压到很小：笔记与它的卡、前身与后继落在不同的块里（tests_cache_pending.rs）。冷启动探针
/// （bootstrap_probe.rs，`--cfg srs_probe` 构建）用生产值。
#[cfg(all(test, not(srs_probe)))]
const CACHE_PENDING_CHUNK: usize = 5;

/// 新设备收段通道没做完时不必先做完它的命令（[sync2_dispatch]）：收段命令本身（推进通道）、只读命令（读到的投影
/// 与逐条投递收段途中一样不全，收尾后一致），以及不碰投影的传输记账 / 加解密。不在表里的一律先做完通道——漏列只多
/// 花时间，不会错。`digest` / `digest_buckets` 不在表里：摘要按已应用的版本向量发布，投影不全时算出来的会被别的
/// 设备当成分歧（没有通道时它们照样只走读连接：分发器只读内存标记，见 `SrsCore::sync2_channel_settle`）。
///
/// 每条命令都必须显式登记在这张表或 [CHANNEL_SETTLES] 里（`every_command_declares_its_channel_policy` 按
/// [sync2_dispatch] / [sync2_command] 的匹配臂逐条核对）：新增命令时必须想一遍它要不要完整投影，不会悄悄落进默认。
pub(crate) const CHANNEL_TRANSPARENT: &[&str] = &[
    "identity",
    "device_info",
    "device_hint",
    "location_sealed",
    "location_seal",
    "channel_settle",
    "plan",
    "ingest_begin",
    "ingest_batch",
    "ingest_prepare",
    "ingest_commit",
    "ingest_finish",
    "ingest_end",
    "replay_pending",
    "status",
    "legacy_dots",
    "conflicts",
    "checkpoints",
    "history",
    "study",
    "read",
    "card_columns",
    "stats_report",
    "stats_recall",
    "stats_rows",
    "stats_release",
    "anki_resolve",
    "anki_notes_info",
    "lineages",
    "preview",
    "browse_query",
    "browse_rows",
    "browse_ids",
    "browse_targets",
    "browse_close",
    "anki_find",
    "anki_dupes",
    "anki_tags",
    "browse_stats",
    "browse_counts",
    "browse_sources",
    "outbox",
    "outbox_ack",
    "head",
    "relay_outbox",
    "obsolete",
    "obsolete_former",
    "obsolete_ack",
    "relay_ack",
    "media_known",
    "media_gc_queue",
    "media_live_refs",
    "local_state",
    "local_state_ensure",
    "local_anchor",
    "profile_footprint",
    "profile_purge",
    "binding_get",
    "binding_set",
    "derive_key",
    "seal",
    "open",
    "seal_file",
    "open_file",
    "refresh_caches",
    "rebuild_caches",
    "cache_config_set",
];

/// 改投影的 v2 命令（结果带 `marks`）：分发器在同一次调用里刷新缓存行；`ingest_commit` 在投递的事务里自己刷
/// （只刷本机已有缓存行的，新实体记待刷新）。
/// 通道没做完时要先做完它的命令（改投影、读完整投影、在投影上记账的）。分发器只看 [CHANNEL_TRANSPARENT]（不在那张表
/// 里的一律先做完）；这张表只为登记完整（见上）。
#[cfg(test)]
pub(crate) const CHANNEL_SETTLES: &[&str] = &[
    "apply",
    "import_drafts",
    "change",
    "note_fields_if",
    "merge_notes",
    "sched",
    "deck_delete",
    "undo_check",
    "retire",
    "dedup",
    "migrate",
    "replay_all",
    "ingest",
    "rotate",
    "export",
    "import",
    "digest",
    "digest_buckets",
    "digest_heal",
    "media_record",
    "media_hash",
    "media_scan",
    "media_landed",
    "media_doomed",
    "resolve",
    "trust",
    "purge",
    "checkpoint",
    "plan_restore",
    "restore",
    "backfill_dupe_norms",
    "backfill_tag_sources",
    "backfill_source_keys",
    "edits_rewrite_repr",
    "media_gc_collect",
];

const PROJECTING_OPS: &[&str] = &[
    "apply",
    "import_drafts",
    "change",
    "note_fields_if",
    "merge_notes",
    "sched",
    "deck_delete",
    "retire",
    "ingest",
    "ingest_batch",
    "ingest_commit",
    "ingest_finish",
    "replay_pending",
    "import",
    "resolve",
    "trust",
    "purge",
    "checkpoint",
    "restore",
    "dedup",
    "digest_heal",
];

fn sync2_command(
    c: &SrsCore,
    op: &str,
    profile: &str,
    req: &serde_json::Value,
    // 只有测试构建才编的臂（G7-6）读它；生产构建的冻结命令用不到。
    #[cfg_attr(not(test), allow(unused_variables))] blobs: &mut Vec<Vec<u8>>,
    // 只有测试构建才编的臂（G7-6）读它；生产构建的冻结命令用不到。
    #[cfg_attr(not(test), allow(unused_variables))] files: &mut Vec<(String, Vec<u8>)>,
) -> Result<serde_json::Value, String> {
    use serde_json::Value;
    #[cfg(test)]
    use serde_json::json;
    #[cfg(test)]
    let s = |k: &str| {
        req.get(k)
            .and_then(Value::as_str)
            .ok_or_else(|| format!("sync2: missing {k}"))
    };
    let i = |k: &str| {
        req.get(k)
            .and_then(Value::as_i64)
            .ok_or_else(|| format!("sync2: missing {k}"))
    };
    let parse = |t: String| serde_json::from_str::<Value>(&t).map_err(|e| e.to_string());
    Ok(match op {
        #[cfg(test)]
        "identity" => {
            let mut v = c.sync2_identity(profile, i("now")?)?;
            // 旧协议的本机写入者 ID（store/legacy_clock.rs）：宿主给了设备 ID 才回（开库那一次）。
            if let Some(device) = req.get("legacyDevice").and_then(Value::as_str) {
                v["legacyWriter"] = json!(c.read_visible(|conn| {
                    crate::store::legacy_clock::writer_of(conn, profile, device)
                })?);
            }
            // 有没做完的收段通道（上次 App 在收段途中退出）。诊断 / 测试用：分发器在每条要完整投影的命令之前自己按片收。
            v["channel"] = json!(c.sync2_channel_active(profile)?);
            v
        }
        // 把没做完的收段通道按片做完（store/sync2/channel.rs `settle`，每片一个事务）。这条命令本身什么都不做：
        // 它登记在 [CHANNEL_SETTLES] 里，分发器在进来之前已经收完。测试 / 诊断用。
        #[cfg(test)]
        "channel_settle" => {
            c.sync2_channel_settle(profile)?;
            json!({})
        }
        "migrate" => {
            c.sync2_migrate(profile, i("now")?, req.get("limit").and_then(Value::as_u64))?
        }
        #[cfg(test)]
        "replay_all" => json!(c.sync2_replay_all(profile)?),
        // 排队：牌组计数 + 出卡（store/study.rs），只读快照。
        #[cfg(test)]
        "study" => c.study(profile, req)?,
        // 只读查询（store/reads.rs）：查询道的只读连接，一条命令一个读事务。
        #[cfg(test)]
        "read" => c.read_query(|conn| crate::store::reads::run(conn, profile, req, files))?,
        // 列式批量读（store/bulk.rs），只读快照：卡片缓存行、统计页三张表、AnkiConnect 数字 id 反查。
        #[cfg(test)]
        "card_columns" => {
            files.push((
                "columns".to_owned(),
                c.read_visible(|conn| crate::store::bulk::card_columns(conn, profile, req))?,
            ));
            json!({})
        }
        // 复习统计（store/stats.rs）：原料按 profile + 统计指纹缓存在内核，换范围 / 牌组只重算聚合。
        #[cfg(test)]
        "stats_report" => c.stats_report(profile, req)?,
        #[cfg(test)]
        "stats_recall" => c.stats_recall(profile, req)?,
        #[cfg(test)]
        "stats_rows" => c.stats_rows(profile, req)?,
        #[cfg(test)]
        "stats_release" => {
            c.stats_release();
            json!({})
        }
        #[cfg(test)]
        "anki_resolve" => {
            c.read_visible(|conn| crate::store::bulk::anki_resolve(conn, profile, req))?
        }
        #[cfg(test)]
        "anki_notes_info" => {
            c.read_visible(|conn| crate::store::bulk::anki_notes_info(conn, profile, req))?
        }
        // 卡片浏览的常驻会话（store/browse.rs）：查询（筛选 + 排序）、取行、取行 id、批量目标、关闭；AnkiConnect 的
        // 搜索 / 查重 / 标签走同一个会话。
        #[cfg(test)]
        "browse_query" | "browse_rows" | "browse_ids" | "browse_targets" | "browse_close"
        | "anki_find" | "anki_dupes" | "anki_tags" | "browse_stats" | "browse_counts"
        | "browse_sources" => c.browse(op, profile, req, files)?,
        // 一组卡各自的血统（自己 + 全部前身，store/caches.rs `lineage_ids`）：卡片历史用。看得见本机写事务里未提交的行。
        #[cfg(test)]
        "lineages" => {
            let cards: Vec<String> = req
                .get("cards")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect();
            json!(c.read_visible(|conn| crate::store::caches::lineage_ids(conn, &cards))?)
        }
        #[cfg(test)]
        "preview" => c.sync2_preview(
            profile,
            s("card")?,
            req.get("note").and_then(Value::as_str),
            i("now")?,
            i("utcOff")?,
            i("rollover")?,
        )?,
        // 分批发件：一批上传完用 outbox_ack 交回 segments 推进水位，more 为真再取下一批（store/sync2/transport.rs）。
        #[cfg(test)]
        "outbox" => {
            let max_bytes = req
                .get("maxBytes")
                .and_then(Value::as_u64)
                .unwrap_or(crate::store::sync2::transport::OUTBOX_BATCH_BYTES);
            let max_segments = req
                .get("maxSegments")
                .and_then(Value::as_u64)
                .map_or(crate::store::sync2::transport::OUTBOX_BATCH_SEGMENTS, |n| {
                    n as usize
                });
            // `present`（可选，一轮的第一批带）：位置上 `devices/<本机>/` 的文件名。水位以下却不在的本机段先登记重传
            // （作者自检，transport.rs `sync2_audit_own`），这一批起照当前切法补传。
            let audited = match req.get("present").and_then(Value::as_array) {
                Some(names) => {
                    let present: std::collections::BTreeSet<String> = names
                        .iter()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect();
                    c.sync2_audit_own(profile, s("location")?, &present)?
                }
                None => 0,
            };
            // `archive`：归档位置（Dart 位置配置），副本收敛换下的段不重写（transport.rs `sync2_outbox_to`）。
            let archive = req.get("archive") == Some(&Value::Bool(true));
            let batch = c.sync2_outbox_to(
                profile,
                s("location")?,
                key32(&req["key"])?,
                max_bytes.max(1),
                max_segments.max(1),
                archive,
            )?;
            *files = batch.files;
            json!({"upto": batch.upto, "more": batch.more, "segments": batch.segments, "audited": audited})
        }
        #[cfg(test)]
        "outbox_ack" => {
            let segments: Vec<(u64, u64)> = req
                .get("segments")
                .and_then(Value::as_array)
                .ok_or("sync2: missing segments")?
                .iter()
                .map(|p| {
                    match p.as_array().map(|x| {
                        (
                            x.first().and_then(Value::as_u64),
                            x.get(1).and_then(Value::as_u64),
                        )
                    }) {
                        Some((Some(a), Some(b))) => Ok((a, b)),
                        _ => Err("sync2: bad segment pair".to_string()),
                    }
                })
                .collect::<Result<_, _>>()?;
            let (accepted, uploaded) = c.sync2_outbox_ack(profile, s("location")?, &segments)?;
            json!({"accepted": accepted, "uploaded": uploaded})
        }
        // `skipUnchangedMs`：内容与上次写出的相同且未到期时不写（见 `sync2_head_if_changed`），回 `unchanged` + 上次的路径。
        #[cfg(test)]
        "head" => {
            let skip = req.get("skipUnchangedMs").and_then(Value::as_i64);
            match c.sync2_head_if_changed(
                profile,
                s("location")?,
                i("upto")? as u64,
                i("now")?,
                skip,
            )? {
                crate::store::sync2::transport::HeadWrite::Written { path, bytes, gen } => {
                    files.push((path, bytes));
                    json!({"gen": gen})
                }
                crate::store::sync2::transport::HeadWrite::Unchanged { path } => {
                    json!({"unchanged": true, "path": path})
                }
                // 要引用的段还有没传到这个位置的（发件确认后被合并改切）：不写，Dart 按「改切」结束这一轮。
                crate::store::sync2::transport::HeadWrite::Recut => json!({"recut": true}),
            }
        }
        // `location`：这些 head 所在位置的进度身份（记下位置上有谁的哪些段，转发用，store/sync2/relay.rs）。
        // `readOnly`：只在读连接上算（Dart 不进写锁调）；要往库里记东西时回 `needsWrite`，Dart 再进写锁调一次（审查 S-8）。
        #[cfg(test)]
        "plan" if req["readOnly"] == Value::Bool(true) => {
            match c.sync2_plan_read_only(
                profile,
                blobs,
                req.get("location").and_then(Value::as_str),
            )? {
                Some(v) => v,
                None => json!({"needsWrite": true}),
            }
        }
        #[cfg(test)]
        "plan" => c.sync2_plan_at(profile, blobs, req.get("location").and_then(Value::as_str))?,
        // 转发（store/sync2/relay.rs）：本机持有、这个位置缺的别的设备的段（转发件）与 head 原文；传完 relay_ack。
        #[cfg(test)]
        "relay_outbox" => {
            let max_bytes = req
                .get("maxBytes")
                .and_then(Value::as_u64)
                .unwrap_or(crate::store::sync2::transport::OUTBOX_BATCH_BYTES);
            let batch = c.sync2_relay_outbox(
                profile,
                s("location")?,
                key32(&req["key"])?,
                max_bytes.max(1),
            )?;
            *files = batch.files;
            json!({"more": batch.more})
        }
        // 一轮收尾：位置上此刻该删的文件（本机的旧 head、合并换下来的旧小段、旧转发件），保留策略只在内核
        // （transport.rs `sync2_obsolete` / `HEAD_KEEP_GENS`）。`present`：head 已经在位置上之后列 `devices/<本机>/`
        // 得到的文件名；`archive`：归档位置（不给旧 head）。Dart 删成功的发 `obsolete_ack`。
        #[cfg(test)]
        "obsolete" => {
            let present: Vec<String> = req
                .get("present")
                .and_then(Value::as_array)
                .ok_or("sync2: missing present")?
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect();
            let archive = req.get("archive") == Some(&Value::Bool(true));
            let out = c.sync2_obsolete(profile, s("location")?, &present, archive, i("now")?)?;
            json!({"delete": out.delete, "again": out.again, "former": out.former})
        }
        // 换过身份的设备清旧身份的目录（store/sync2/former.rs）：`obsolete` 回复的 `former` 里点名的旧身份，Dart 列
        // `devices/<device>/`（`present`）、读其中每一份 head（blobs），这里给出证明得了可以删的（只会是被盖过的旧
        // head）。没有待删记录，删完不必回执。
        #[cfg(test)]
        "obsolete_former" => {
            let present: Vec<String> = req
                .get("present")
                .and_then(Value::as_array)
                .ok_or("sync2: missing present")?
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect();
            let archive = req.get("archive") == Some(&Value::Bool(true));
            json!({"delete": c.sync2_obsolete_former(
                profile,
                s("location")?,
                s("device")?,
                &present,
                blobs,
                archive,
                i("now")?,
            )?})
        }
        // 两段式删除：`obsolete` / `relay_ack` 给的待删清单里 Dart 已经删掉（归档位置：按策略不删）的那些，内核移除记录。
        #[cfg(test)]
        "obsolete_ack" => {
            let deleted: Vec<String> = req
                .get("deleted")
                .and_then(Value::as_array)
                .map(|a| {
                    a.iter()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect()
                })
                .unwrap_or_default();
            json!({"removed": c.sync2_obsolete_ack(profile, s("location")?, &deleted)?})
        }
        #[cfg(test)]
        "relay_ack" => {
            let paths: Vec<String> = req
                .get("paths")
                .and_then(Value::as_array)
                .map(|a| {
                    a.iter()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect()
                })
                .unwrap_or_default();
            c.sync2_relay_ack(profile, s("location")?, &paths)?
        }
        #[cfg(test)]
        "ingest" => parse(c.sync2_ingest(profile, blobs, key32(&req["key"])?, i("now")?)?)?,
        #[cfg(test)]
        "ingest_begin" => c.sync2_ingest_begin(profile)?,
        // 段的字节交给会话持有（不再复制一份，审查 S-9）。
        #[cfg(test)]
        "ingest_batch" => parse(c.sync2_ingest_batch(
            profile,
            std::mem::take(blobs),
            key32(&req["key"])?,
            i("now")?,
        )?)?,
        // 拆开的一批：prepare 在写锁外解码验签（Dart 侧也不进写锁），commit 在写锁里投递。
        #[cfg(test)]
        "ingest_prepare" => {
            c.sync2_ingest_prepare(profile, std::mem::take(blobs), key32(&req["key"])?)?
        }
        // `ingest_commit` 带缓存配置，在 [sync2_dispatch] 里处理。
        // 一轮中途收手 / 出错：放掉收段会话与留着的页缓存（srs_sync2_round.dart 的 finally）。
        #[cfg(test)]
        "ingest_end" => c.sync2_ingest_end(profile)?,
        // 收尾：换身份 + 重放各片记下的待重放卡（按片，`more` 为真 Dart 放开写锁后用 replay_pending 接着放，审查 S-4）。
        #[cfg(test)]
        "ingest_finish" => parse(c.sync2_ingest_finish_persisting(
            profile,
            i("now")?,
            slice_budget(c, req),
            crate::store::local_state::anchor_of(req)?.as_ref(),
        )?)?,
        "replay_pending" => parse(c.sync2_replay_pending_persisting(
            profile,
            slice_budget(c, req),
            crate::store::local_state::anchor_of(req)?.as_ref(),
        )?)?,
        // 本机状态行（store/local_state.rs）：Dart 开库 / 重读时要的几个值（只读，不建行）；开库在缓存重建之后把行与
        // 纪元落下；同步成功后写下校时状态。
        #[cfg(test)]
        "local_state" => c.read_visible(|conn| crate::store::local_state::read(conn, profile))?,
        #[cfg(test)]
        "local_state_ensure" => {
            let w = c.writer()?;
            crate::store::sync2::in_savepoint(&w, |conn| {
                crate::store::local_state::ensure(conn, profile)
            })?
        }
        #[cfg(test)]
        "local_anchor" => {
            let anchor =
                crate::store::local_state::anchor_of(req)?.ok_or("local_anchor: missing anchor")?;
            let w = c.writer()?;
            crate::store::sync2::in_savepoint(&w, |conn| {
                crate::store::local_state::set_anchor(conn, profile, &anchor)
            })?;
            json!({})
        }
        #[cfg(test)]
        "rotate" => c.sync2_rotate(profile, i("now")?)?,
        #[cfg(test)]
        "export" => {
            files.push(("export.fushisrs".to_owned(), c.sync2_export(profile)?));
            json!({})
        }
        // 纯加解密（不碰库）：与新代分发器共用 [crypto_command]。
        #[cfg(test)]
        "seal" | "open" | "seal_file" | "open_file" | "derive_key" => {
            crypto_command(op, req, blobs, files)?
        }
        #[cfg(test)]
        "digest" => match req.get("minIntervalMs").and_then(Value::as_i64) {
            Some(ms) => c.sync2_digest_due(profile, i("now")?, Some(ms))?,
            None => c.sync2_digest(profile)?,
        },
        #[cfg(test)]
        "status" => c.sync2_status(profile)?,
        // 设备可识别（store/sync2/devices.rs）：本机型号 / 版本 / 平台 / 昵称（给了哪个改哪个，没变不进写锁）；没有自报名字
        // 的设备的补充名（互联 host 认出上传者）。
        #[cfg(test)]
        "device_info" => c.sync2_device_info(profile, req, i("now")?)?,
        #[cfg(test)]
        "device_hint" => c.sync2_device_hint(s("device")?, s("hint")?)?,
        // 位置「见过加密」的本机记账（store/sync2/sealed.rs，BUG-4299）：读；记（带这一刻见到的 kdf，或段 / 转发件的开头字节）。
        #[cfg(test)]
        "location_sealed" => c.sync2_location_sealed(profile, s("location")?)?,
        #[cfg(test)]
        "location_seal" => c.sync2_location_seal(
            profile,
            s("location")?,
            req.get("kdf").filter(|v| !v.is_null()),
            req.get("seen").and_then(Value::as_bool).unwrap_or(false),
            blobs,
            i("now")?,
        )?,
        // 操作日志里带旧 dot 的修改记录（档案合并判断目标里是否已有同一批记录，BUG-4011）。
        #[cfg(test)]
        "legacy_dots" => c.sync2_legacy_dots(profile)?,
        // 摘要各桶（读连接；两台设备摘要不同时定位不一致的 ID 范围，审查 S-7）。
        #[cfg(test)]
        "digest_buckets" => c.sync2_digest_buckets(profile)?,
        // 位置媒体目录的已知内容 / 记下事实（store/sync2/media.rs）：媒体对账读日志投影，不列目录。
        #[cfg(test)]
        "media_known" => c.sync2_media_known(profile, s("location")?)?,
        #[cfg(test)]
        "media_record" => {
            let names = |k: &str| -> Vec<String> {
                req.get(k)
                    .and_then(Value::as_array)
                    .map(|a| {
                        a.iter()
                            .filter_map(Value::as_str)
                            .map(str::to_owned)
                            .collect()
                    })
                    .unwrap_or_default()
            };
            c.sync2_media_record_with_suspect(
                profile,
                s("location")?,
                &names("present"),
                &names("absent"),
                &names("suspect"),
                req["seeded"] == Value::Bool(true),
                i("now")?,
            )?
        }
        // 内容寻址媒体（store/sync2/media.rs，审查 S-3）：本机文件 → 内容 / 该下载什么；下载落地后对齐；清理哪些内容。
        #[cfg(test)]
        "media_hash" | "media_scan" => {
            let names: Vec<String> = req
                .get("names")
                .and_then(Value::as_array)
                .map(|a| {
                    a.iter()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect()
                })
                .unwrap_or_default();
            if op == "media_hash" {
                c.sync2_media_hash(profile, s("root")?, &names)?
            } else {
                let mut files = std::collections::HashMap::new();
                for f in req
                    .get("files")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                {
                    let name = f
                        .get("name")
                        .and_then(Value::as_str)
                        .ok_or("media_scan: missing name")?;
                    let sha = f
                        .get("sha")
                        .and_then(Value::as_str)
                        .and_then(super::sync2::media::unhex32)
                        .ok_or("media_scan: bad sha")?;
                    let n = |k: &str| {
                        f.get(k)
                            .and_then(Value::as_i64)
                            .ok_or(format!("media_scan: missing {k}"))
                    };
                    files.insert(name.to_owned(), (n("size")?, n("mtime")?, sha));
                }
                c.sync2_media_scan(profile, &names, &files, i("now")?)?
            }
        }
        #[cfg(test)]
        "media_landed" => {
            let mut items = Vec::new();
            for it in req
                .get("items")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                let name = it
                    .get("name")
                    .and_then(Value::as_str)
                    .ok_or("media_landed: missing name")?;
                let sha = it
                    .get("sha")
                    .and_then(Value::as_str)
                    .and_then(super::sync2::media::unhex32)
                    .ok_or("media_landed: bad sha")?;
                items.push((name.to_owned(), sha));
            }
            c.sync2_media_landed(profile, s("root")?, &items, i("now")?)?
        }
        #[cfg(test)]
        "media_doomed" => {
            let names = |k: &str| -> Vec<String> {
                req.get(k)
                    .and_then(Value::as_array)
                    .map(|a| {
                        a.iter()
                            .filter_map(Value::as_str)
                            .map(str::to_owned)
                            .collect()
                    })
                    .unwrap_or_default()
            };
            c.sync2_media_doomed(profile, &names("expired"), &names("live"))?
        }
        // 删 profile 的级联清理（store/profile_data.rs）：确认框的规模、一个事务里删光本机数据。
        #[cfg(test)]
        "profile_footprint" => c.profile_footprint(profile)?,
        #[cfg(test)]
        "profile_purge" => c.profile_purge(profile)?,
        // 本机 profile（集合）的绑定状态（store/binding.rs）：只读 / 只写 srs_meta 的一个键，不碰投影。
        #[cfg(test)]
        "binding_get" => c.binding_get(profile)?,
        #[cfg(test)]
        "binding_set" => c.binding_set(profile, s("state")?, s("via")?, i("now")?)?,
        #[cfg(test)]
        "conflicts" => c.sync2_conflicts(profile)?,
        #[cfg(test)]
        "checkpoints" => c.sync2_checkpoints(profile)?,
        #[cfg(test)]
        "history" => c.sync2_history(profile, s("kind")?, s("entity")?)?,
        // 编辑类撤销的校验（store/sync2/undo_check.rs）：只读，按修改记录判每个字段键能不能撤。
        #[cfg(test)]
        "undo_check" => c.sync2_undo_check(profile, req)?,
        // 预览恢复到还原点 / 某个时刻（只读；恢复本身是本机写命令，见 [local_write_body]）。
        #[cfg(test)]
        "plan_restore" => c.sync2_plan_restore(
            profile,
            &restore_target(req)?,
            req["retract"] == Value::Bool(true),
            i("now")?,
        )?,
        other => return Err(format!("unknown sync2 op {other}")),
    })
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::store::sync2::tests::{Device, P};
    use serde_json::json;

    /// 新设备收段通道：每条 v2 命令都显式声明「通道没做完时要不要先做完」（[CHANNEL_TRANSPARENT] / [CHANNEL_SETTLES]
    /// 恰好一张）。按源码里 [sync2_dispatch] 与 [sync2_command] 顶层匹配臂的命令名逐条核对：新增命令没登记就红。
    #[test]
    fn every_command_declares_its_channel_policy() {
        let mut ops = dispatched_ops();
        // 不针对单个 profile 的命令在分发器开头就返回，不碰通道。
        for global in [
            "profile_uids",
            "read_lib",
            "orphan_sweep_done",
            "profile_merge_mark",
            "profile_merge_commit",
            "meta_set_edit",
            "wal_checkpoint",
            "bulk_cache",
            "ingest_yield",
            "refresh_keys",
        ] {
            assert!(
                ops.remove(global),
                "{global} is no longer a profile-less command"
            );
        }
        assert!(ops.len() > 50, "parsed too few commands: {ops:?}");
        for op in &ops {
            let (t, s) = (
                CHANNEL_TRANSPARENT.contains(&op.as_str()),
                CHANNEL_SETTLES.contains(&op.as_str()),
            );
            assert!(
                t ^ s,
                "sync2 command `{op}` must be listed in exactly one of CHANNEL_TRANSPARENT / CHANNEL_SETTLES (transparent {t}, settles {s})"
            );
        }
        for listed in CHANNEL_TRANSPARENT.iter().chain(CHANNEL_SETTLES.iter()) {
            assert!(
                ops.contains(*listed),
                "`{listed}` is listed but no longer a command"
            );
        }
    }

    /// 协议 1 主库搬迁（`SrsCore::legacy_*`）只编进测试构建。它们是 `pub mod store` 上的 `pub fn`，rustc 从不报死代码，
    /// 去掉门也不会有任何告警，只能按源码钉住：每个方法（连同文档注释）前面一行是 `#[cfg(test)]`。
    #[test]
    fn protocol_1_migration_methods_are_test_only() {
        let src = include_str!("../mod.rs").replace("\r\n", "\n");
        for name in [
            "legacy_imported",
            "legacy_begin",
            "legacy_page",
            "legacy_commit",
            "legacy_abort",
            "legacy_mark_none",
        ] {
            let at = src.find(&format!("\n    pub fn {name}(")).expect(name);
            let gate = src[..at]
                .lines()
                .rev()
                .map(str::trim)
                .find(|l| !l.starts_with("///"));
            assert_eq!(gate, Some("#[cfg(test)]"), "{name}");
        }
    }

    /// 生产构建里分发器只剩 [FROZEN_OPS]：按源码，三个分发函数里没被 `#[cfg(test)]` 门住的匹配臂（门住的臂 / 语句后面整块
    /// 都算门住）与 `if op == "…" {` 语句，命令名恰好是这 5 条。往分发器加命令或去掉某条臂的门就红。
    #[test]
    fn only_the_frozen_commands_are_compiled_into_production() {
        let src = include_str!("mod.rs").replace("\r\n", "\n");
        let mut prod = std::collections::BTreeSet::new();
        for start in [
            "fn sync2_dispatch_op(",
            "fn local_write_body(",
            "fn sync2_command(",
        ] {
            let from = src.find(start).unwrap_or_else(|| panic!("missing {start}"));
            let body = &src[from..from + src[from..].find("\n}\n").expect("function end")];
            let lines: Vec<&str> = body.lines().collect();
            let indent = |l: &str| l.len() - l.trim_start().len();
            // 门住的块：块开头那一行的缩进；遇到同缩进的 `}` 收尾。
            let mut gated_until: Option<usize> = None;
            let mut prev = "";
            let mut k = 0;
            while k < lines.len() {
                let line = lines[k];
                k += 1;
                let t = line.trim();
                if let Some(at) = gated_until {
                    if indent(line) == at && t.starts_with('}') {
                        gated_until = None;
                    }
                    continue;
                }
                if t.is_empty() || t.starts_with("//") {
                    continue;
                }
                let gated = prev == "#[cfg(test)]";
                prev = t;
                let mut head = t.to_owned();
                if t.starts_with('"') {
                    while !head.contains("=>")
                        && k < lines.len()
                        && lines[k].trim().starts_with("| \"")
                    {
                        head.push(' ');
                        head.push_str(lines[k].trim());
                        k += 1;
                    }
                }
                let arm = t.starts_with('"') && head.contains("=>");
                let cmp = t.starts_with("if op == \"") && t.ends_with('{');
                if gated && (t.ends_with('{') || head.ends_with('{')) {
                    gated_until = Some(indent(line));
                }
                if gated || !(arm || cmp) {
                    continue;
                }
                let names = head.split("=>").next().unwrap();
                for (i, part) in names.split('"').enumerate() {
                    if i % 2 == 1 {
                        prod.insert(part.to_owned());
                    }
                }
            }
        }
        let frozen: std::collections::BTreeSet<String> =
            FROZEN_OPS.iter().map(|s| (*s).to_owned()).collect();
        assert_eq!(prod, frozen);
    }

    /// 生产入口 [dispatch] 只放行 [FROZEN_OPS]：协议 3 分发器里别的每一条命令都报 [NOT_FROZEN]、不碰库；冻结的照常跑。
    #[test]
    fn the_production_entry_refuses_every_other_command() {
        let d = Device::new("legacy3-frozen");
        let changes = || d.core.writer().unwrap().total_changes();
        let before = changes();
        let ops = dispatched_ops();
        assert!(ops.len() > 60, "{ops:?}");
        for op in &ops {
            if FROZEN_OPS.contains(&op.as_str()) {
                continue;
            }
            let e = dispatch(
                &d.core,
                &json!({"op": op, "profile": P, "now": 1}),
                &mut Vec::new(),
            )
            .unwrap_err();
            assert!(e.starts_with(NOT_FROZEN), "{op}: {e}");
        }
        assert_eq!(changes(), before, "a refused command wrote");
        for op in FROZEN_OPS {
            assert!(ops.contains(op), "{op} is not a protocol 3 command");
        }
        let cfg: serde_json::Value =
            serde_json::from_str(&crate::store::gen4::dryrun::tests::cfg()).unwrap();
        let v = dispatch(
            &d.core,
            &json!({"op": "cache_config_set", "profile": P, "caches": cfg}),
            &mut Vec::new(),
        )
        .unwrap();
        assert!(v.get("to").is_some(), "{v}");
    }

    /// 按源码里 [sync2_dispatch_op] 与 [sync2_command] 顶层匹配臂（及分发器里的命令名比较）列出全部命令名。
    pub(crate) fn dispatched_ops() -> std::collections::BTreeSet<String> {
        // 检出可能是 CRLF（Windows 工作区）：统一成 LF 再按行解析。
        let src = include_str!("mod.rs").replace("\r\n", "\n");
        let src = src.as_str();
        let body = |start: &str| -> &str {
            let from = src.find(start).unwrap_or_else(|| panic!("missing {start}"));
            let rest = &src[from..];
            &rest[..rest.find("\n}\n").expect("function end")]
        };
        let mut ops = std::collections::BTreeSet::new();
        for start in [
            "fn sync2_dispatch_op(",
            "fn sync2_command(",
            "fn local_write_body(",
        ] {
            let lines: Vec<&str> = body(start).lines().collect();
            let mut next = 0;
            while next < lines.len() {
                let line = lines[next];
                next += 1;
                // 顶层匹配臂：8 个空格缩进、以命令名字面量开头（`"a" | "b" [if ...] =>`）；分发器里的命令名比较同样收进来。
                // 分发器里改投影命令的 `match op`（12 个空格缩进：`ingest_commit` / `rebuild_caches` 等在那里直接处理）也算。
                let top =
                    line.strip_prefix("        \"").is_some() && !line.starts_with("         ");
                let projecting = start.starts_with("fn sync2_dispatch_op(")
                    && line.strip_prefix("            \"").is_some()
                    && !line.starts_with("             ");
                // rustfmt 把放不下一行的 `"a" | "b" | ...` 折成同缩进的 `| "c" ... =>` 续行：拼回一整条臂头再解析。
                let mut joined = line.to_owned();
                if top || projecting {
                    let cont = if top {
                        "        | \""
                    } else {
                        "            | \""
                    };
                    while !joined.contains("=>")
                        && next < lines.len()
                        && lines[next].starts_with(cont)
                    {
                        joined.push(' ');
                        joined.push_str(lines[next]);
                        next += 1;
                    }
                }
                let arm = (top || projecting) && joined.contains("=>");
                let compared = line.contains("op == \"");
                if !(arm || compared) {
                    continue;
                }
                let head = if arm {
                    joined.split("=>").next().unwrap()
                } else {
                    line
                };
                for (i, part) in head.split('"').enumerate() {
                    if i % 2 == 1
                        && !part.is_empty()
                        && part
                            .chars()
                            .all(|ch| ch.is_ascii_lowercase() || ch == '_' || ch.is_ascii_digit())
                    {
                        ops.insert(part.to_owned());
                    }
                }
            }
        }
        ops
    }
}
