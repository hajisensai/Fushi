//! 读命令的新代实现（规划 §2.1 G7-4；设计 §2.3「读路径」）。已接分发器（`dispatch.rs`）；协议 3 的读命令
//! （`store/reads.rs` 的 `read` / `read_lib`、`sync2_history`）不再经分发器调用（冻结）。
//!
//! - [reads]：`read`（一个集合的只读查询，查询名与列契约同协议 3）与 `read_lib`（不针对单个集合）。
//! - [views]：`entity_views`——每实体一份视图 JSON（规划 §1.1 缺口 G-7；远程复习 V2 与本机共用同一个解码器）。
//! - [history]：一个实体的修改历史（协议 3 `sync2_history` 的新代版）。
//! - [columns]：列式批量读 `card_columns` 与 AnkiConnect 数字 id 的 `anki_resolve` / `anki_notes_info`（协议 3 `store/bulk.rs`）。
//! - [lineage]：`lineages`——一组卡各自的血统（协议 3 `caches::lineage_ids`，同一个判定函数，按类读前身链接）。
//! - [browse]：卡片浏览与 AnkiConnect 兼容层的会话读命令（`browse_*` / `anki_find` / `anki_dupes` / `anki_tags`，协议 3
//!   `store/browse.rs`，同一份会话实现；常驻会话按缓存层的代号失效）。
//! - [stats]：复习统计 `stats_report` / `stats_recall` / `stats_rows`（协议 3 `store/stats.rs`，同一份聚合）。
//! - [center]：冲突中心与时间线的只读命令 `conflicts` / `checkpoints` / `undo_check`（G7-4e）。
//! - [profile]：按集合的 `binding_get` / `profile_footprint`（G7-4e）。
//! - [identity]：身份命令 `identity` / `binding_set` / `collection_*` / `canonical_ids` / `key_evidence` / `divergence`
//!   （G9-4；存储层是 `store/gen4/identity.rs` 与 `truth.rs`）。
//! - [study]：出卡与牌组计数 `study`（协议 3 `store/study.rs`，同一份排队规则；常驻会话与索引的取舍见那里的文件头）。
//! - [preview]：评分预览 `preview`（协议 3 `sync2_preview`，同一份重放与回包；G7-4f）。
//! - [training]：逐卡重放与训练集的直读命令——C 直出入口 `ffsrs_store_history_states` / `_stat_projection` /
//!   `_optimizer_items` / `_calibration_items` / `_rwkv_rows` / `_rwkv_log_tail` 的新代版（同一份投影与输出布局；G7-4f）。
//! - [media_gc]：媒体回收 `media_gc_queue` / `media_gc_collect` / `media_live_refs`（协议 3 `store/media_gc.rs`，同一份
//!   逐名规则；待回收集合在本机状态行里，存活引用读缓存层；S1b）。
//!
//! 分发器命令与新代实现的逐条对照（哪条已有、归谁、S1 怎么接）见 `docs/specs/2026-11-15-srs-gen4-handoff.md`
//! 「分发器命令对照表」。
//!
//! # 共同约定
//!
//! - **一条命令一个读快照**（[snapshot]）：调用方没开事务就在这里开一个只读事务、跑完提交；开头先 [Truth::reset]
//!   （规划 §1.2 G-1：别的连接——主进程写入者——可能在上一个事务之后写过）。一条命令里的多条语句因此读同一个快照，
//!   不会出现「笔记行是写入之后、修改行是写入之前」的拼接结果。调用方已在事务里就沿用它。
//! - **按规范 ID**（D24）：结果里的 ID 一律是规范 ID（别名表 `alias.rs`）；请求里按号查找的 ID 接受别名类里任何成员的
//!   号（先归一再查）。按实体读的（身份记录、修改、日志）一个别名类出一份，规则与缓存层相同（`cache.rs` 文件头「别名」）。
//! - **顺序契约**（设计 §2.3「读命令的顺序契约」）：凡是有顺序语义的结果都显式排序；协议 3 依赖落库顺序的地方（同一实体的
//!   修改记录按 rowid）换成只看内容的确定顺序，逐处写在函数注释里。
//! - **行的 JSON 形与协议 3 相同**：修改记录 / 日志 / 身份记录的 JSON 用协议 3 同一份拼法（`derive.rs`
//!   [super::derive::Index] 的 `edit_lines_as`、`store/sync2` 的 `log_json`、`project_entity` 的 `canonical(d)`），分区键
//!   `p` 填这个集合绑定的 profile uid（协议 3 存的就是它）。

use rusqlite::types::Value as Sv;
use serde_json::Value;

use super::derive::{Index, Ref, body_of};
use super::schema::sql;
use super::truth::Truth;
use crate::gen4::name::write_edit_key;
use crate::gen4::op::{Body4, Log4};
use crate::store::bulk::{self, Col};
use crate::store::gen4::weigh::S_PURGED;
use crate::store::sync2::canonical;
use crate::store::sync2::config::DeckTree;
use crate::sync2::codec::Writer;
use crate::sync2::id::Key;
use crate::sync2::op::EntKind;
use crate::sync2::vv::OpId;

pub mod backup;
pub mod browse;
pub mod center;
pub mod columns;
pub mod fushisrs;
pub mod history;
pub mod identity;
pub mod lineage;
// 媒体同步（G8-7b）：见 [media_sync] 文件头。
pub mod media_gc;
pub mod media_sync;
pub mod preview;
pub mod profile;
pub mod profile_data;
pub mod reads;
pub mod stats;
pub mod study;
// 同步一轮（G8-7）：见 [sync] 文件头。
pub mod sync;
// 旧根接手与承袭上传（G8-7b）：见 [sync_oldroot] 文件头。
pub mod sync_oldroot;
// 转发（G8-7b）：见 [sync_relay] 文件头。
pub mod sync_relay;
// 重切件的停放（第六波）：见 [sync_park] 文件头。
pub mod sync_park;
pub mod training;
pub mod views;
// 写命令的新代实现（规划 §2.1 G7-3b），同样已接分发器：见 [writes] 文件头。
pub mod writes;
pub mod writes_intent;
pub mod writes_local;
pub mod writes_restore;

#[cfg(test)]
mod backup_tests;
#[cfg(test)]
mod browse_tests;
#[cfg(test)]
mod center_tests;
#[cfg(test)]
pub(crate) mod dispatch_tests;
#[cfg(test)]
mod fushisrs_tests;
#[cfg(test)]
mod id_reply_tests;
#[cfg(test)]
mod identity_tests;
#[cfg(test)]
mod purge_scrub_tests;
#[cfg(test)]
mod refresh_tests;
#[cfg(test)]
mod study_tests;
#[cfg(test)]
mod sync_complete_tests;
#[cfg(test)]
mod sync_heritage_trust_tests;
#[cfg(test)]
mod sync_park_tests;
#[cfg(test)]
mod sync_relay_tests;
#[cfg(test)]
mod sync_tests;
#[cfg(test)]
mod sync_trust_tests;
#[cfg(test)]
mod tests;
#[cfg(test)]
pub(in crate::store::gen4) mod tests_class;
#[cfg(test)]
mod training_tests;
#[cfg(test)]
mod views_tests;
#[cfg(test)]
mod writes_tests;

/// 结果里的列式表（`store/bulk.rs` 的 `FCL1`）：(名字, 字节)。
pub type Files = Vec<(String, Vec<u8>)>;

/// 在一个读快照里跑 [f]（模块文件头「一条命令一个读快照」）。调用方已在事务里（不是自动提交）就直接跑；否则
/// [Truth::reset] → `BEGIN` → [f] → `COMMIT`（出错 `ROLLBACK`）。读命令不写库，提交与回滚效果相同；出错时也 reset，
/// 不让半路填进缓存的东西留给下一个事务。
pub fn snapshot<'c, T>(
    t: &Truth<'c>,
    f: impl FnOnce(&Truth<'c>) -> Result<T, String>,
) -> Result<T, String> {
    let conn = t.conn();
    if !conn.is_autocommit() {
        return f(t);
    }
    t.reset();
    conn.execute_batch("BEGIN").map_err(sql)?;
    match f(t) {
        Ok(v) => match conn.execute_batch("COMMIT") {
            Ok(()) => Ok(v),
            Err(e) => {
                let _ = conn.execute_batch("ROLLBACK");
                t.reset();
                Err(sql(e))
            }
        },
        Err(e) => {
            // 回滚失败只可能是连接已坏；原错误更有用，回滚的错误不盖掉它。
            let _ = conn.execute_batch("ROLLBACK");
            t.reset();
            Err(e)
        }
    }
}

/// 这个集合绑定的 profile uid（行 JSON 里的 `p`）。没绑定的集合号是调用方的 bug。
pub(super) fn profile_of(t: &Truth<'_>, col: i64) -> Result<String, String> {
    Ok(t.binding(col)?
        .ok_or_else(|| format!("gen4 read: collection {col} is not bound"))?
        .profile)
}

/// ID 文本 → 索引里的 [Ref]（UUID 文本存 16 字节，其余文本）。
pub(super) fn ref_of(text: &str) -> Ref {
    Ref::of(&Key::of(text))
}

/// 请求里的一组 ID（JSON 字符串数组）归一成规范 ID：去重，保持第一次出现的顺序。不是字符串的元素是调用方的 bug。
pub(super) fn canon_ids(ix: &Index<'_, '_>, ids: &Value) -> Result<Vec<Ref>, String> {
    Ok(canon_ids_echo(ix, ids)?.0)
}

/// [canon_ids]，外加请求 ID 与它的规范 ID 不同的那几项 `{请求 ID: 规范 ID}`（G9-7）：按实体出行的读（`entities` /
/// `edits`）行里写规范 ID，调用方按自己给的 ID 预建了槽（Dart `_prefetchEdits` / `_prefetchEntities`），拿这张表在
/// 同一次回包里对回去，不另发 `canonical_ids`。请求都是规范 ID 时表是空的。
pub(super) fn canon_ids_echo(
    ix: &Index<'_, '_>,
    ids: &Value,
) -> Result<(Vec<Ref>, serde_json::Map<String, Value>), String> {
    let xs = ids.as_array().ok_or("gen4 read: ids must be an array")?;
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::with_capacity(xs.len());
    let mut echo = serde_json::Map::new();
    for x in xs {
        let s = x.as_str().ok_or("gen4 read: ids must be strings")?;
        let c = ix.canonical(&ref_of(s))?;
        let text = c.text();
        if text != s {
            echo.insert(s.to_owned(), Value::String(text));
        }
        if seen.insert(c.clone()) {
            out.push(c);
        }
    }
    Ok((out, echo))
}

/// 集合 [col] 的默认牌组（规范 ID）：缓存配置给了就用它（归一后，与缓存层同一个），否则是规范规则的内置默认牌组。
/// 写命令（[writes]）与出卡读命令（[study]）共用。
/// 解析经 [Index::cache_config]（库句柄的缓存配置记忆，`cache.rs` `CfgMemo`）。
pub(super) fn default_deck(t: &Truth<'_>, ix: &Index<'_, '_>, col: i64) -> Result<String, String> {
    debug_assert_eq!(ix.col, col);
    debug_assert!(std::ptr::eq(ix.t, t));
    match ix.cache_config()? {
        Some(cfg) => Ok(cfg.default_deck().to_owned()),
        None => Ok(
            crate::gen4_ids::rules::builtin_default_deck(crate::gen4_ids::rules::CANONICAL).text(),
        ),
    }
}

/// 此刻的牌组树（未删除的牌组，ID 是规范 ID）：每个规范牌组的定义 + 按类判定活着的写入拼视图，再走协议 3 同一份
/// 拼树规则（`DeckTree::of_views`）。写命令（[writes]）与出卡读命令（[study]）共用。
pub(super) fn deck_tree(ix: &mut Index<'_, '_>, default: String) -> Result<DeckTree, String> {
    let ids: Vec<Ref> = {
        let mut stmt =
            ix.t.conn()
                .prepare_cached(
                    "SELECT DISTINCT id FROM ent_ix WHERE col = ?1 AND kind = ?2 AND win = 1",
                )
                .map_err(sql)?;
        let rows = stmt
            .query_map(rusqlite::params![ix.col, EntKind::Deck as i64], |r| {
                r.get::<_, Ref>(0)
            })
            .map_err(sql)?;
        rows.collect::<Result<_, _>>().map_err(sql)?
    };
    let mut canon: std::collections::BTreeSet<Ref> = std::collections::BTreeSet::new();
    for id in &ids {
        canon.insert(ix.canon(id)?);
    }
    let mut views = Vec::with_capacity(canon.len());
    for c in &canon {
        let Some((kind, _, payload)) = ix.definition(c)? else {
            continue;
        };
        if kind != EntKind::Deck as i64 {
            continue;
        }
        let (lines, _) = ix.class_lines(EntKind::Deck, c)?;
        views.push((
            c.text(),
            crate::registers::deck_view_of(&payload, &crate::store::sync2::config::stored(&lines))?,
        ));
    }
    Ok(DeckTree::of_views(views, default))
}

/// 卡（规范 ID）的有效牌组：协议 3 `config::card_deck` 同一份规则（`config::card_deck_with`），卡与笔记的修改行按类判定
/// （[Index::class_lines]）。[note] = 卡所属笔记（规范 ID；没有 = None）。写命令（[writes] 的 `Session::card_deck`，读之前
/// 先收尾）与评分预览（[preview]）共用。
pub(super) fn card_deck(
    ix: &mut Index<'_, '_>,
    tree: &DeckTree,
    card: &str,
    note: Option<&str>,
) -> Result<String, String> {
    let note_edits = match note {
        Some(n) => Some(ix.class_lines(EntKind::Note, &ref_of(n))?.0),
        None => None,
    };
    crate::store::sync2::config::card_deck_with(tree, card, note_edits, &mut |c| {
        Ok(ix.class_lines(EntKind::Card, &ref_of(c))?.0)
    })
}

/// 请求里以 ID 为键的表（牌组 → 值之类）归一成规范 ID 为键：同一个类有几个键时，规范 ID 自己给了就取它的，否则取
/// 成员里 ID 的 SQLite 序（[sql_order]）最小的那个的——与键在请求里的先后无关。值原样。
pub(super) fn canon_keyed(
    ix: &Index<'_, '_>,
    m: &serde_json::Map<String, Value>,
) -> Result<serde_json::Map<String, Value>, String> {
    // 规范 ID → (它自己给了没有, 给了值的成员里 ID 的 SQLite 序最小的, 值)。
    let mut by: std::collections::BTreeMap<String, (bool, (u8, Vec<u8>), Value)> =
        std::collections::BTreeMap::new();
    for (key, v) in m.iter() {
        let r = ref_of(key);
        let c = ix.canonical(&r)?;
        let own = r == c;
        let (o, b) = sql_order(&r);
        let rank = (o, b.to_vec());
        let ct = c.text();
        let better = match by.get(&ct) {
            None => true,
            Some((had_own, had_rank, _)) => {
                (own && !had_own) || (own == *had_own && rank < *had_rank)
            }
        };
        if better {
            by.insert(ct, (own, rank, v.clone()));
        }
    }
    Ok(by.into_iter().map(|(k, (_, _, v))| (k, v)).collect())
}

/// SQLite 比较 ID 列的顺序（`ORDER BY id`）：TEXT 在 BLOB 之前，各自按字节。[Ref] 自己的 `Ord` 把 UUID 排在前面，
/// 与协议 3 `ORDER BY id`（存的是 `srs_id` 形）不同，排结果一律用这个键。
pub(super) fn sql_order(r: &Ref) -> (u8, &[u8]) {
    match r {
        Ref::Text(s) => (0, s.as_bytes()),
        Ref::Uuid(b) => (1, b.as_slice()),
    }
}

/// 按规范日志 ID 取的日志代表：规范日志 ID → (操作号, 操作主键, 日志)。
pub(super) type LogReps = std::collections::BTreeMap<Ref, (OpId, i64, Log4)>;

/// 发生时刻落在 [lo, hi]（[hi] = None：不设上界）的日志并进 [reps]：每个规范日志 ID 取操作号最小的一份（`log_ix.win`
/// 的规则搬到别名类上；多次调用跨区间累积，仍取最小的一份）。走 `log_at (col, at)`。按时刻读日志的读命令
/// （[reads] 的 `anki_logs_at` / `native_logs_near`、[study] 的计数上下文与自定义学习）共用这一份代表规则。
pub(super) fn logs_between(
    t: &Truth<'_>,
    ix: &Index<'_, '_>,
    col: i64,
    lo: i64,
    hi: Option<i64>,
    reps: &mut LogReps,
) -> Result<(), String> {
    let rows: Vec<(i64, Ref)> = match hi {
        Some(hi) => t
            .conn()
            .prepare_cached(
                "SELECT k, id FROM log_ix WHERE col = ?1 AND at BETWEEN ?2 AND ?3 AND win = 1",
            )
            .map_err(sql)?
            .query_map(rusqlite::params![col, lo, hi], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .map_err(sql)?
            .collect::<Result<_, _>>()
            .map_err(sql)?,
        None => t
            .conn()
            .prepare_cached("SELECT k, id FROM log_ix WHERE col = ?1 AND at >= ?2 AND win = 1")
            .map_err(sql)?
            .query_map(rusqlite::params![col, lo], |r| Ok((r.get(0)?, r.get(1)?)))
            .map_err(sql)?
            .collect::<Result<_, _>>()
            .map_err(sql)?,
    };
    for (k, id) in rows {
        let c = ix.canonical(&id)?;
        let op = t.id_of_key(k)?;
        if reps.get(&c).is_some_and(|(o, _, _)| *o <= op) {
            continue;
        }
        let Some(e) = t.entry_by_key(k)? else {
            continue;
        };
        if let Some(Body4::Log(l)) = body_of(&e) {
            reps.insert(c, (op, k, l));
        }
    }
    Ok(())
}

/// 行 JSON（规范 JSON 文本，`p` 是空串或别的值）的分区键换成 [profile]，再按规范形写回。解不开的原样（不是本层能修的数据，
/// 交给读者按坏行处理，与协议 3 读到坏行相同）。
pub(super) fn with_profile(json: &str, profile: &str) -> String {
    match serde_json::from_str::<Value>(json) {
        Ok(Value::Object(mut m)) => {
            m.insert("p".to_owned(), Value::String(profile.to_owned()));
            canonical(&Value::Object(m))
        }
        _ => json.to_owned(),
    }
}

/// 规范实体 [c]（种类 [kind]）按类判定活着的修改行：(修改键, 行 JSON（`p` = [profile]）, 服务器时刻)，按 (键, JSON) 排。
/// `read` 的 `edits` / `events`、`entity_views` 的 `edits` 都是它。
///
/// 笔记的 `tags` 照协议 3 的投影出（store/sync2/semantics.rs `tags_row`）：碰过标签（`#tag` 增删或整列表 `tags` 修改）
/// 的笔记恰有一行合成的 `tags`——写入者 `sync2:tags:<笔记>`、`s` = 1、空因果上下文、值 = 标签 OR-Set 的当前值（按类判，
/// [Index::class_tags]）、`hlc` = 最后一条标签操作的 HLC——其它 `tags` 行不出。读者（Dart 的笔记归约）拿这一行当标签。
pub(super) fn edit_rows(
    t: &Truth<'_>,
    ix: &mut Index<'_, '_>,
    kind: EntKind,
    c: &Ref,
    profile: &str,
) -> Result<Vec<(String, String, Option<i64>)>, String> {
    edit_rows_with(t, ix, kind, c, profile, true)
}

/// [edit_rows]；[tags] = false 时不拼笔记的合成 `tags` 行（调用方只要字段键时省掉 [tags_line] 的那几次查询，浏览
/// `browse.rs` `edits_with`），别的行一样。
pub(super) fn edit_rows_with(
    t: &Truth<'_>,
    ix: &mut Index<'_, '_>,
    kind: EntKind,
    c: &Ref,
    profile: &str,
    tags: bool,
) -> Result<Vec<(String, String, Option<i64>)>, String> {
    let (lines, _) = ix.class_lines(kind, c)?;
    let mut rows: Vec<(String, String, Option<i64>)> = Vec::with_capacity(lines.len() + 1);
    for (json, st) in lines {
        let json = with_profile(&json, profile);
        let f = serde_json::from_str::<Value>(&json)
            .ok()
            .and_then(|v| v.get("f").and_then(Value::as_str).map(str::to_owned))
            .unwrap_or_default();
        if kind == EntKind::Note && f == "tags" {
            continue;
        }
        rows.push((f, json, st));
    }
    if kind == EntKind::Note && tags {
        if let Some(json) = tags_line(t, ix, c, profile)? {
            rows.push(("tags".to_owned(), json, None));
        }
    }
    rows.sort();
    Ok(rows)
}

/// 笔记类 [c] 的合成 `tags` 行（[edit_rows]）；没碰过标签 = None。
fn tags_line(
    t: &Truth<'_>,
    ix: &mut Index<'_, '_>,
    c: &Ref,
    profile: &str,
) -> Result<Option<String>, String> {
    let tags_key = {
        let mut w = Writer::new();
        write_edit_key(&mut w, "tags");
        w.into_vec()
    };
    let mut ks: Vec<i64> = Vec::new();
    for m in ix.members(c)? {
        let mut stmt = t
            .conn()
            .prepare_cached(
                "SELECT k FROM tag_ix WHERE col = ?1 AND note = ?2 AND state != ?4 \
                 UNION SELECT k FROM reg_ix WHERE col = ?1 AND ekind = ?3 AND ent = ?2 AND key = ?5 \
                 AND state != ?4",
            )
            .map_err(sql)?;
        let rows = stmt
            .query_map(
                rusqlite::params![ix.col, m, EntKind::Note as i64, S_PURGED, tags_key],
                |r| r.get::<_, i64>(0),
            )
            .map_err(sql)?;
        for k in rows {
            ks.push(k.map_err(sql)?);
        }
    }
    let mut last: Option<(i64, i64, [u8; 16])> = None;
    for k in ks {
        if let Some(h) = t.head_by_key(k)? {
            let p = (h.wall, h.logical, h.id.device.0);
            if last.is_none_or(|l| p > l) {
                last = Some(p);
            }
        }
    }
    let Some((wall, logical, device)) = last else {
        return Ok(None);
    };
    let note = c.text();
    let writer = format!("sync2:tags:{note}");
    let row = serde_json::json!({
        "id": crate::registers::edit_id(&writer, 1), "p": profile, "k": "note", "e": note, "f": "tags",
        "w": writer, "s": 1, "ctx": {"vv": {}}, "v": ix.class_tags(c)?,
        "hlc": format!("{wall}:{logical}:{}", crate::sync2::id::Id(device).text()), "ts": "wall",
    });
    Ok(Some(canonical(&row)))
}

/// 一张列式表的构造器：列名与类型（`bulk::KIND_*`）先定，逐行往里推。
pub(super) struct Table {
    names: Vec<&'static str>,
    cols: Vec<Col>,
    rows: usize,
}

/// 一格（[Table::push] 的输入）。
pub(super) enum Cell {
    I(i64),
    OptI(Option<i64>),
    S(String),
    OptS(Option<String>),
}

impl Table {
    pub(super) fn new(cols: &[(&'static str, u32)]) -> Table {
        Table {
            names: cols.iter().map(|c| c.0).collect(),
            cols: cols
                .iter()
                .map(|c| match c.1 {
                    bulk::KIND_I64 => Col::I64(Vec::new()),
                    bulk::KIND_F64 => Col::F64(Vec::new()),
                    bulk::KIND_OPT_I64 => Col::OptI64(Vec::new()),
                    bulk::KIND_OPT_F64 => Col::OptF64(Vec::new()),
                    bulk::KIND_STR => Col::Str(Vec::new()),
                    _ => Col::OptStr(Vec::new()),
                })
                .collect(),
            rows: 0,
        }
    }

    /// 推一行；格数与类型必须与列一一对应（不对是本模块的 bug，报错不 panic）。
    pub(super) fn push(&mut self, row: Vec<Cell>) -> Result<(), String> {
        if row.len() != self.cols.len() {
            return Err(format!(
                "gen4 read: row has {} cells for {} columns",
                row.len(),
                self.cols.len()
            ));
        }
        for (col, cell) in self.cols.iter_mut().zip(row) {
            match (col, cell) {
                (Col::I64(x), Cell::I(v)) => x.push(v),
                (Col::OptI64(x), Cell::OptI(v)) => x.push(v),
                (Col::OptI64(x), Cell::I(v)) => x.push(Some(v)),
                (Col::Str(x), Cell::S(v)) => x.push(v),
                (Col::OptStr(x), Cell::OptS(v)) => x.push(v),
                (Col::OptStr(x), Cell::S(v)) => x.push(Some(v)),
                _ => return Err("gen4 read: cell type does not match its column".to_owned()),
            }
        }
        self.rows += 1;
        Ok(())
    }

    pub(super) fn encode(self) -> Vec<u8> {
        bulk::encode(self.rows, &self.names, &self.cols)
    }
}

/// 一条 SQL 查询：`?1` = 集合号，其余参数按序号绑定。
pub(super) struct Sel {
    pub(super) sql: String,
    args: Vec<Sv>,
}

impl Sel {
    pub(super) fn of(col: i64) -> Sel {
        Sel {
            sql: String::new(),
            args: vec![Sv::Integer(col)],
        }
    }

    fn bind(&mut self, v: Sv) -> String {
        self.args.push(v);
        format!("?{}", self.args.len())
    }

    pub(super) fn text(&mut self, s: &str) -> String {
        self.bind(Sv::Text(s.to_owned()))
    }

    pub(super) fn int(&mut self, n: i64) -> String {
        self.bind(Sv::Integer(n))
    }

    pub(super) fn bind_blob(&mut self, b: Vec<u8>) -> String {
        self.bind(Sv::Blob(b))
    }

    /// 一个 ID（存储形：UUID 16 字节，其余文本）。
    pub(super) fn id(&mut self, r: &Ref) -> String {
        self.bind(match r {
            Ref::Uuid(b) => Sv::Blob(b.to_vec()),
            Ref::Text(s) => Sv::Text(s.clone()),
        })
    }

    /// 一组 ID 的子查询（`IN (…)` 的右边）：一个 JSON 参数，`[[1, "<hex>"], [0, "<文本>"]]`，SQL 里还原成存储形。
    /// 不分块、不受变量数上限限制（协议 3 `and_id_in` 同理）。
    pub(super) fn ids(&mut self, refs: &[Ref]) -> String {
        let list: Vec<Value> = refs
            .iter()
            .map(|r| match r {
                Ref::Uuid(b) => serde_json::json!([1, hex(b)]),
                Ref::Text(s) => serde_json::json!([0, s]),
            })
            .collect();
        let p = self.text(&Value::Array(list).to_string());
        format!(
            "(SELECT CASE value ->> 0 WHEN 1 THEN unhex(value ->> 1) ELSE value ->> 1 END AS v FROM json_each({p}))"
        )
    }

    pub(super) fn push(&mut self, s: &str) {
        self.sql.push_str(s);
    }

    pub(super) fn params(&self) -> Vec<&dyn rusqlite::ToSql> {
        self.args
            .iter()
            .map(|a| a as &dyn rusqlite::ToSql)
            .collect()
    }

    /// 跑完编码成列式表；[cols] 与 SELECT 的列一一对应（ID 列的 16 字节 BLOB 解回文本，`bulk::read_cols`）。
    pub(super) fn table(&self, t: &Truth<'_>, cols: &[(&str, u32)]) -> Result<Vec<u8>, String> {
        let names: Vec<&str> = cols.iter().map(|(n, _)| *n).collect();
        let kinds: Vec<u32> = cols.iter().map(|(_, k)| *k).collect();
        let (rows, data) = bulk::read_cols(t.conn(), &self.sql, &self.params(), &kinds)?;
        Ok(bulk::encode(rows, &names, &data))
    }

    /// 只有一行一列整数的查询。
    pub(super) fn scalar(&self, t: &Truth<'_>) -> Result<i64, String> {
        t.conn()
            .prepare_cached(&self.sql)
            .map_err(sql)?
            .query_row(self.params().as_slice(), |r| r.get(0))
            .map_err(sql)
    }

    /// 每行一组值交给 [f]。
    pub(super) fn each(
        &self,
        t: &Truth<'_>,
        mut f: impl FnMut(&rusqlite::Row<'_>) -> Result<(), String>,
    ) -> Result<(), String> {
        let mut stmt = t.conn().prepare_cached(&self.sql).map_err(sql)?;
        let mut rows = stmt.query(self.params().as_slice()).map_err(sql)?;
        while let Some(r) = rows.next().map_err(sql)? {
            f(r)?;
        }
        Ok(())
    }
}

pub(super) fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}
