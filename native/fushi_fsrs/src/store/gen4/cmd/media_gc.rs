//! 媒体回收 `media_gc_queue` / `media_gc_collect` / `media_live_refs` 的新代实现（S1b；协议 3 `store/media_gc.rs`，策略见
//! Dart `srs_purge.dart`）。回包与协议 3 逐键相同。
//!
//! # 一份规则
//!
//! 逐名回收（裸文件名、存活引用不区分大小写、读不到文件移出、宽限期内留着、删不掉留着）`media_gc::sweep`、参数解析
//! `CollectArgs`、直接给的名字 `add_names`、`media_refs` 列的拆分 `add_refs`、笔记类型文本里的引用与「只留裸文件名」
//! `finish_live_refs` / `caches::note_type_view_texts` 都与协议 3 同一个函数。这里只换「从哪读、存哪」：
//!
//! - **待回收集合**是本机状态（不进真相、不同步、不参与对拍）：存在新代本机状态行（`gen4/local.rs`，`srs_meta` 键
//!   `local_state/<profile>`）的 `mediaGc` 键里，键名与形态同协议 3（排序的字符串数组，空集合时没有这个键）。按 profile
//!   记、不要绑定（同协议 3：这一行只按 profile uid 记）。迁移不带协议 3 的那一行（`local.rs` 文件头）：换代时还没回收的
//!   名字这一轮不删——宁可多留。
//! - **存活引用**读缓存层：`notes.media_refs`（与协议 3 `srs_notes_cache.media_refs` 同一个函数 `card_cache::media_refs`
//!   算的列，缓存层按规范 ID 物化——一个别名类一行，类里每个成员上写的字段都并在那一行里）∪ 这个集合全部笔记类型
//!   （含已删除的：可能被恢复）现行模板与 CSS 里的引用：每个规范笔记类型的身份记录 + 按类判定活着的修改拼视图
//!   （`registers::note_type_view_of`，内置类型的代码默认值取缓存配置，同缓存层 `type_info`）。
//! - **队列里的 `notes`**（彻底清除之前调）：请求里的笔记 ID 先归一（别名类），读它的缓存行 `media_refs`——新代派生层
//!   随每笔写入维护，同一个事务里缓存行就是字段现值算的（协议 3 读字段是因为缓存行可能还没刷到）。
//!
//! # 读不全就不删
//!
//! 协议 3 在「缓存行还没刷完」时回 `deferred`、什么都不删。新代的派生层随写入维护、提交后不会欠着，但缓存层只在设了
//! 缓存配置之后才物化（`cache.rs` 文件头「缓存配置」）：没有配置（或 profile 还没绑定集合）时 `notes` 里这个集合一行
//! 都没有，存活引用是空的——按它删文件就会删掉仍被引用的媒体。所以：
//!
//! - `media_gc_collect`：没绑定 / 没缓存配置 = `deferred`，什么都不删、集合原样留着（同协议 3 的形状）。
//! - `media_live_refs`：同样的情形明确报错（调用方——位置清理——拿空集合会把位置上的媒体全当无引用）。
//! - `media_gc_queue` 的 `notes` / `expiredBefore`：读不到缓存行就不并进候选（只会少删，不会多删）。
//!
//! 写命令（`queue` / `collect`）在分发器的一个写事务里（`G4Core::write`）：「核对存活引用 → 删文件 → 移出集合」期间
//! 持着写锁，没有写入能重新引用刚判为无引用的文件（HBK-AUDIT-014，同协议 3）。不推进修订号（不改真相与派生层）。

use std::collections::BTreeSet;

use rusqlite::{OptionalExtension, params};
use serde_json::{Value, json};

use super::ref_of;
use crate::store::caches::{CacheConfig, note_type_view_texts};
use crate::store::gen4::derive::{Index, Ref};
use crate::store::gen4::local;
use crate::store::gen4::schema::sql;
use crate::store::gen4::truth::Truth;
use crate::store::media_gc::{CollectArgs, add_names, add_refs, finish_live_refs, sweep};
use crate::sync2::op::EntKind;

/// 一条笔记（规范 ID）缓存行上的引用（`notes` 主键点查）。
pub(crate) const NOTE_REFS_SQL: &str = "SELECT media_refs FROM notes WHERE col = ?1 AND id = ?2";

/// 删除时刻不晚于 ?2 的已删笔记的引用（过了保留期的候选）。沿 `notes` 主键走这个集合的一段（不另建索引：回收的
/// `collect` 本来就要把这个集合的全部存活笔记读一遍，[LIVE_SQL]，同阶）。
pub(crate) const EXPIRED_SQL: &str =
    "SELECT media_refs FROM notes WHERE col = ?1 AND deleted_at <= ?2 AND media_refs <> ''";

/// 存活笔记与删除晚于 ?2 的已删笔记的引用（协议 3 `live_refs` 同一个口径）。
pub(crate) const LIVE_SQL: &str = "SELECT media_refs FROM notes WHERE col = ?1 \
     AND (deleted_at IS NULL OR deleted_at > ?2) AND media_refs <> ''";

/// 这个集合里出现过的笔记类型（原值 ID，`ent_kind` 部分索引；归一后去重）。含已删除的（删除是寄存器，身份记录还在）。
pub(crate) const TYPES_SQL: &str =
    "SELECT DISTINCT id FROM ent_ix WHERE col = ?1 AND kind = ?2 AND win = 1";

/// `media_gc_queue`：把候选并进待回收集合（`names` / `notes` / `expiredBefore`，同协议 3 `media_gc::queue`）。回包
/// `{"pending": [...]}`。
pub fn queue(t: &Truth<'_>, profile: &str, req: &Value) -> Result<Value, String> {
    let mut set = local::media_gc_pending(t, profile)?;
    let before = set.len();
    add_names(&mut set, req);
    let notes: Vec<&str> = req["notes"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    let expired = req["expiredBefore"].as_i64();
    if !notes.is_empty() || expired.is_some() {
        // 没绑定集合 = 这个 profile 没有笔记，没有可并的引用。
        if let Some(b) = t.binding_of(profile)? {
            let ix = Index::new(t, b.col);
            for n in notes {
                let c = ix.canonical(&ref_of(n))?;
                let refs: Option<String> = t
                    .conn()
                    .prepare_cached(NOTE_REFS_SQL)
                    .map_err(sql)?
                    .query_row(params![b.col, c], |r| r.get(0))
                    .optional()
                    .map_err(sql)?;
                if let Some(refs) = refs {
                    add_refs(&mut set, &refs);
                }
            }
            if let Some(cutoff) = expired {
                each_refs(t, EXPIRED_SQL, b.col, cutoff, &mut set)?;
            }
        }
    }
    if set.len() != before {
        local::set_media_gc_pending(t, profile, &set)?;
    }
    Ok(json!({"pending": set}))
}

/// `media_gc_collect`：回收待回收集合里此刻没有任何存活引用、且过了宽限期的文件（同协议 3 `media_gc::collect`）。回包
/// `{"deleted": n, "next": 名字 | null, "deferred"?: true}`。
pub fn collect(t: &Truth<'_>, profile: &str, req: &Value) -> Result<Value, String> {
    let args = CollectArgs::of(req)?;
    let mut set = local::media_gc_pending(t, profile)?;
    if set.is_empty() {
        return Ok(json!({"deleted": 0, "next": Value::Null}));
    }
    // 存活引用读不全（文件头「读不全就不删」）：这一轮不删，名字留着下一轮。
    let Some((col, cfg)) = materialized(t, profile)? else {
        return Ok(json!({"deleted": 0, "next": Value::Null, "deferred": true}));
    };
    let alive = live_refs(t, col, &cfg, args.alive_after)?;
    let swept = sweep(&set, &args, &alive);
    if !swept.settled.is_empty() {
        for n in &swept.settled {
            set.remove(n);
        }
        local::set_media_gc_pending(t, profile, &set)?;
    }
    Ok(json!({"deleted": swept.deleted, "next": swept.next}))
}

/// `media_live_refs`：`{"refs": [...]}`（同协议 3）。读不全（没绑定 / 没缓存配置）明确报错。
pub fn live_refs_json(t: &Truth<'_>, profile: &str, alive_after: i64) -> Result<Value, String> {
    let (col, cfg) = materialized(t, profile)?.ok_or_else(|| {
        format!(
            "gen4: media_live_refs: profile {profile} has no materialized cache layer (no collection bound or no cache \
             config), live media references cannot be read"
        )
    })?;
    Ok(json!({"refs": live_refs(t, col, &cfg, alive_after)?}))
}

/// profile 绑定的集合与它的缓存配置；没绑定、或缓存层没物化（没设缓存配置）= None。
fn materialized(
    t: &Truth<'_>,
    profile: &str,
) -> Result<Option<(i64, std::sync::Arc<CacheConfig>)>, String> {
    let Some(b) = t.binding_of(profile)? else {
        return Ok(None);
    };
    Ok(Index::new(t, b.col).cache_config()?.map(|cfg| (b.col, cfg)))
}

/// 存活引用（文件头）：[alive_after] = 删除时刻晚于它的已删笔记也算。只留裸文件名。
fn live_refs(
    t: &Truth<'_>,
    col: i64,
    cfg: &CacheConfig,
    alive_after: i64,
) -> Result<BTreeSet<String>, String> {
    let mut out: BTreeSet<String> = BTreeSet::new();
    each_refs(t, LIVE_SQL, col, alive_after, &mut out)?;
    finish_live_refs(&mut out, &note_type_texts(t, col, cfg)?);
    Ok(out)
}

/// [q]（`?1` = 集合，`?2` = 时刻）选出的每一列 `media_refs` 并进 [out]。
fn each_refs(
    t: &Truth<'_>,
    q: &str,
    col: i64,
    at: i64,
    out: &mut BTreeSet<String>,
) -> Result<(), String> {
    let mut stmt = t.conn().prepare_cached(q).map_err(sql)?;
    let mut rows = stmt.query(params![col, at]).map_err(sql)?;
    while let Some(r) = rows.next().map_err(sql)? {
        add_refs(out, &r.get::<_, String>(0).map_err(sql)?);
    }
    Ok(())
}

/// 这个集合全部笔记类型（含已删除的）物化视图里的模板与 CSS 文本（协议 3 `caches::note_type_texts` 的新代版）：每个
/// 规范笔记类型一份视图——身份记录取类的定义（`Index::definition`），修改按类判定（`Index::class_lines`），与缓存层
/// 物化笔记类型同一套读法。
fn note_type_texts(t: &Truth<'_>, col: i64, cfg: &CacheConfig) -> Result<Vec<String>, String> {
    let ids: Vec<Ref> = t
        .conn()
        .prepare_cached(TYPES_SQL)
        .map_err(sql)?
        .query_map(params![col, EntKind::NoteType as i64], |r| r.get(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    let mut ix = Index::new(t, col);
    let mut canon: BTreeSet<Ref> = BTreeSet::new();
    for id in &ids {
        canon.insert(ix.canonical(id)?);
    }
    let mut out = Vec::new();
    for c in &canon {
        let Some((kind, _, payload)) = ix.definition(c)? else {
            continue;
        };
        if kind != EntKind::NoteType as i64 {
            continue;
        }
        let (lines, _) = ix.class_lines(EntKind::NoteType, c)?;
        let stored: Vec<crate::registers::StoredEdit<'_>> =
            lines.iter().map(|(j, s)| (j.as_str(), *s, None)).collect();
        let view =
            crate::registers::note_type_view_of(&payload, &stored, &cfg.builtin_of(&payload))?;
        note_type_view_texts(&view, &mut out);
    }
    Ok(out)
}
