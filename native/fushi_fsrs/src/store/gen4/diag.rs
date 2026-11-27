//! 迁移报告里给「为什么没过」用的诊断件（反馈 QW3kL_jEQF / hX_SnLpapZ）：对拍差异与 `idTrace` 只说「哪些行对不上、
//! 这些 ID 在两侧缓存行里的位置」，用户的库我们拿不到，合成库又复现不出时，就得靠报告把两侧**为什么**算出不同的
//! 中间结论带回来。三块：
//!
//! - [environment]：库与运行环境（SQLite 版本、内核版本、`user_version` 与页面计数、`srs_meta` 的短值、每张表 / 索引的
//!   DDL 与行数）。DDL 是应用自己的建表语句，不含用户内容。
//! - [profile_counts]：本 profile 在每张带 `profile_uid` 列的表里有几行。
//! - [stats_trace]：统计行（`srs_stat_reviews` / 新代 `stats`）差异的例子逐条摊开：协议 3 的日志行、旧库现成的与冻结
//!   重建出来的统计行、冻结重建里 Anki 副本去重的落选记录（`caches.rs` [StatsProbe]）、冻结规则下这张卡所在的归属组与
//!   组里每条日志的选取 / 投影去向（`caches.rs` [explain_stat_groups]），以及新代一侧的日志索引与统计行。
//!
//! 只有 ID、计数、时刻与规则字段，不含笔记内容。读失败只记进报告（`{"error": …}`），不让迁移因为诊断失败。

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Map, Value, json};

use super::cache::CFG_KEY;
use super::class::legacy_config_for;
use super::compare::{CARD_COLS, CacheRows, CanonMap, Diff, STAT_COLS};
use super::derive::Ref;
use super::schema::sql;
use super::trace;
use super::truth::Truth;
use crate::store::caches::{self, CacheConfig, StatsProbe};
use crate::sync2::id::Key;

/// [stats_trace] 最多摊开几个种子 ID（报告体积有上限）。
const STATS_TRACE_LIMIT: usize = 40;

/// 一个种子展开成的协议 3 ID 最多几个（别名类成员）。
const MEMBERS_LIMIT: usize = 16;

/// `srs_meta` 里只报这么短的值（版本、标志）；更长的只报长度。
const META_VALUE_MAX: usize = 64;

fn err(e: impl std::fmt::Display) -> Value {
    json!({ "error": e.to_string() })
}

fn or_error(v: Result<Value, String>) -> Value {
    v.unwrap_or_else(err)
}

/// 库与运行环境（模块文件头）。[c] 是旧库的读连接。
pub(crate) fn environment(c: &Connection) -> Value {
    let mut out = Map::new();
    out.insert("sqlite".into(), json!(rusqlite::version()));
    out.insert("core".into(), json!(env!("CARGO_PKG_VERSION")));
    out.insert("os".into(), json!(std::env::consts::OS));
    out.insert("arch".into(), json!(std::env::consts::ARCH));
    let mut pragmas = Map::new();
    for p in [
        "user_version",
        "schema_version",
        "application_id",
        "page_size",
        "page_count",
        "freelist_count",
        "encoding",
        "journal_mode",
        "auto_vacuum",
    ] {
        let v: Result<Value, rusqlite::Error> = c.query_row(&format!("PRAGMA main.{p}"), [], |r| {
            Ok(match r.get_ref(0)? {
                rusqlite::types::ValueRef::Integer(i) => json!(i),
                rusqlite::types::ValueRef::Text(t) => json!(String::from_utf8_lossy(t)),
                other => json!(format!("{other:?}")),
            })
        });
        pragmas.insert(p.into(), v.unwrap_or_else(err));
    }
    out.insert("pragmas".into(), Value::Object(pragmas));
    out.insert("srsMeta".into(), or_error(srs_meta(c)));
    out.insert("schema".into(), or_error(schema_objects(c)));
    Value::Object(out)
}

fn srs_meta(c: &Connection) -> Result<Value, String> {
    let has: bool = c
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM main.sqlite_schema WHERE type = 'table' AND name = 'srs_meta')",
            [],
            |r| r.get(0),
        )
        .map_err(sql)?;
    if !has {
        return Ok(Value::Null);
    }
    let mut stmt = c
        .prepare("SELECT key, value FROM main.srs_meta ORDER BY key")
        .map_err(sql)?;
    let rows = stmt
        .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
        .map_err(sql)?;
    let mut out = Map::new();
    for row in rows {
        let (k, v) = row.map_err(sql)?;
        let v = if v.chars().count() <= META_VALUE_MAX {
            json!(v)
        } else {
            json!({ "chars": v.chars().count() })
        };
        out.insert(k, v);
    }
    Ok(Value::Object(out))
}

/// 每张表 / 索引 / 视图 / 触发器：类型、所属表、DDL；表另给行数。
fn schema_objects(c: &Connection) -> Result<Value, String> {
    let objs: Vec<(String, String, String, Option<String>)> = c
        .prepare(
            "SELECT type, name, tbl_name, sql FROM main.sqlite_schema ORDER BY type DESC, name",
        )
        .map_err(sql)?
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    let mut out = Vec::with_capacity(objs.len());
    for (kind, name, table, ddl) in objs {
        let mut o = Map::new();
        o.insert("type".into(), json!(kind));
        o.insert("name".into(), json!(name));
        if table != name {
            o.insert("table".into(), json!(table));
        }
        o.insert("sql".into(), json!(ddl));
        if kind == "table" && !name.starts_with("sqlite_") {
            let n: Result<i64, rusqlite::Error> = c.query_row(
                &format!(
                    "SELECT COUNT(*) FROM main.\"{}\"",
                    name.replace('"', "\"\"")
                ),
                [],
                |r| r.get(0),
            );
            o.insert("rows".into(), n.map_or_else(err, |n| json!(n)));
        }
        out.push(Value::Object(o));
    }
    Ok(Value::Array(out))
}

/// 本 profile 在每张带 `profile_uid` 列的表里有几行（[c] 要有 `srs_id` 函数：`dryrun::open_legacy` 开的连接）。
pub(crate) fn profile_counts(c: &Connection, profile: &str) -> Value {
    or_error((|| -> Result<Value, String> {
        let tables: Vec<String> = c
            .prepare(
                "SELECT m.name FROM main.sqlite_schema m WHERE m.type = 'table' \
                 AND EXISTS (SELECT 1 FROM pragma_table_info(m.name) WHERE name = 'profile_uid') ORDER BY m.name",
            )
            .map_err(sql)?
            .query_map([], |r| r.get(0))
            .map_err(sql)?
            .collect::<Result<_, _>>()
            .map_err(sql)?;
        let mut out = Map::new();
        for t in tables {
            let n: Result<i64, rusqlite::Error> = c.query_row(
                &format!(
                    "SELECT COUNT(*) FROM main.\"{}\" WHERE profile_uid = srs_id(?1)",
                    t.replace('"', "\"\"")
                ),
                [profile],
                |r| r.get(0),
            );
            out.insert(t, n.map_or_else(err, |n| json!(n)));
        }
        Ok(Value::Object(out))
    })())
}

fn col_at(cols: &[(&str, &str)], name: &str) -> usize {
    cols.iter()
        .position(|c| c.0 == name)
        .expect("column listed in the constant")
}

/// 差异里统计相关的例子（`stats` 行的日志与卡、`canonicalStats` 的卡）里出现的 UUID，按出现顺序去重。
fn stat_seeds(diffs: &[&Diff], examples: usize) -> Vec<String> {
    let mut seen = BTreeSet::new();
    let mut out = Vec::new();
    for d in diffs {
        for (what, old, new) in d.iter() {
            if !matches!(*what, "stats" | "canonicalStats") {
                continue;
            }
            for r in old.iter().take(examples).chain(new.iter().take(examples)) {
                // 行是 `列 | 列 | …`：第一列是行的身份（`stats` 的日志 ID、`canonicalStats` 的卡 ID，不一定是 UUID），
                // 其余列里的 UUID（统计行挂的卡）也摊开。
                let first = r.split(" | ").next().filter(|f| !f.is_empty());
                for tok in first.into_iter().chain(trace::uuids_in_row(r)) {
                    if seen.insert(tok.to_owned()) {
                        out.push(tok.to_owned());
                    }
                }
            }
        }
    }
    out.truncate(STATS_TRACE_LIMIT);
    out
}

/// 统计行差异逐条摊开（模块文件头）。[parity] / [canonical] 是对拍与按规范 ID 比的差异（规范 ID），[existing] 是旧库
/// 现成缓存对冻结重建的差异（协议 3 ID）；[rebuilt] 是冻结重建出来的缓存行（协议 3 ID，没有基准时 None）。
#[allow(clippy::too_many_arguments)]
pub(crate) fn stats_trace(
    src: &Connection,
    profile: &str,
    t: &Truth<'_>,
    col: i64,
    canon: &CanonMap,
    rebuilt: Option<&CacheRows>,
    probe: &StatsProbe,
    diffs: &[&Diff],
    examples: usize,
) -> Value {
    let seeds = stat_seeds(diffs, examples);
    if seeds.is_empty() {
        return Value::Null;
    }
    or_error(stats_trace_of(
        src, profile, t, col, canon, rebuilt, probe, &seeds,
    ))
}

#[allow(clippy::too_many_arguments)]
fn stats_trace_of(
    src: &Connection,
    profile: &str,
    t: &Truth<'_>,
    col: i64,
    canon: &CanonMap,
    rebuilt: Option<&CacheRows>,
    probe: &StatsProbe,
    seeds: &[String],
) -> Result<Value, String> {
    // 冻结重建的行按协议 3 ID 索引。
    let (s_log, s_card) = (col_at(STAT_COLS, "log"), col_at(STAT_COLS, "card"));
    let (c_note, c_hidden) = (col_at(CARD_COLS, "note_id"), col_at(CARD_COLS, "hidden"));
    let mut rebuilt_stat: HashMap<&str, &[String]> = HashMap::new();
    let mut rebuilt_stats_of: HashMap<&str, usize> = HashMap::new();
    let mut visible: HashSet<String> = HashSet::new();
    let mut note_of: HashMap<String, String> = HashMap::new();
    let mut rebuilt_card: HashMap<&str, &[String]> = HashMap::new();
    if let Some((_, cards, stats)) = rebuilt {
        for r in stats {
            rebuilt_stat.insert(&r[s_log], r);
            *rebuilt_stats_of.entry(&r[s_card]).or_default() += 1;
        }
        for r in cards {
            rebuilt_card.insert(&r[0], r);
            if r[c_hidden] == "0" {
                visible.insert(r[0].clone());
            }
            note_of.insert(r[0].clone(), r[c_note].clone());
        }
    }
    let mut items: Vec<Value> = Vec::new();
    let mut cards: BTreeSet<String> = BTreeSet::new();
    for seed in seeds {
        let mut item = Map::new();
        item.insert("id".into(), json!(seed));
        let c = canon.text(seed);
        if c != *seed {
            item.insert("canonical".into(), json!(c));
        }
        // 协议 3 一侧可能的原值：种子本身、它的规范 ID、规范 ID 别名类里的成员。
        let mut members: BTreeSet<String> = [seed.clone(), c.clone()].into_iter().collect();
        members.extend(class_members(t, col, &c)?);
        let mut p3 = Vec::new();
        for m in members.iter().take(MEMBERS_LIMIT) {
            if let Some(v) = p3_log(src, profile, m, &rebuilt_stat, probe, canon)? {
                if let Some(card) = v["card"].as_str() {
                    cards.insert(card.to_owned());
                }
                p3.push(v);
                continue;
            }
            if let Some(v) = p3_card(src, m, &rebuilt_card, &rebuilt_stats_of)? {
                cards.insert(m.clone());
                p3.push(v);
            }
        }
        item.insert("p3".into(), Value::Array(p3));
        item.insert("gen4".into(), gen4_side(t, col, seed, &c)?);
        items.push(Value::Object(item));
    }
    let mut out = Map::new();
    out.insert("ids".into(), Value::Array(items));
    out.insert("rebuildAnkiLosers".into(), json!(probe.losers.len()));
    // 冻结规则下这些卡的归属组与组里每条日志的去向：要冻结重建用的配置（与 `compare::cache_pairs` 同一份换法）。
    if rebuilt.is_some() && !cards.is_empty() {
        let groups = (|| -> Result<Value, String> {
            let Some(cfg) = t.derive_cfg(col, CFG_KEY)? else {
                return Ok(Value::Null);
            };
            let legacy = legacy_config_for(profile, &cfg)?;
            let parsed =
                CacheConfig::parse(&serde_json::from_str(&legacy).map_err(|e| e.to_string())?)?;
            caches::explain_stat_groups(src, &parsed, &cards, &visible, &note_of)
        })();
        out.insert("frozenGroups".into(), or_error(groups));
    }
    Ok(Value::Object(out))
}

/// 规范 ID [c] 的别名类成员（不含 [c]）。
fn class_members(t: &Truth<'_>, col: i64, c: &str) -> Result<Vec<String>, String> {
    let Key::Uuid(cid) = Key::of(c) else {
        return Ok(Vec::new());
    };
    let mut stmt = t
        .conn()
        .prepare_cached("SELECT id FROM alias_ix WHERE col = ?1 AND canon = ?2 AND id != canon")
        .map_err(sql)?;
    let rows = stmt
        .query_map(params![col, Ref::Uuid(cid.0)], |r| r.get::<_, Ref>(0))
        .map_err(sql)?;
    rows.map(|r| r.map(|r| r.text()).map_err(sql)).collect()
}

/// 协议 3 的一条日志：日志行（归属、种类、来源、评分、时刻）、旧库现成的统计行、冻结重建的统计行、冻结重建里 Anki
/// 副本去重的落选记录。不是日志 = None。
fn p3_log(
    src: &Connection,
    profile: &str,
    id: &str,
    rebuilt_stat: &HashMap<&str, &[String]>,
    probe: &StatsProbe,
    canon: &CanonMap,
) -> Result<Option<Value>, String> {
    type LogRow = (String, bool, String, String, String, Option<i64>, i64, i64);
    let row: Option<LogRow> = src
        .prepare_cached(
            "SELECT srs_idt(card_id), profile_uid = srs_id(?2), kind, origin, review_type, rating, occurred_at, \
             duration_ms FROM main.srs_review_logs WHERE id = srs_id(?1)",
        )
        .map_err(sql)?
        .query_row(params![id, profile], |r| {
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get(2)?,
                r.get(3)?,
                r.get(4)?,
                r.get(5)?,
                r.get(6)?,
                r.get(7)?,
            ))
        })
        .optional()
        .map_err(sql)?;
    let Some((card, mine, kind, origin, rtype, rating, at, dur)) = row else {
        return Ok(None);
    };
    let existing: Option<(String, i64)> = src
        .prepare_cached(
            "SELECT srs_idt(card_id), kind FROM main.srs_stat_reviews WHERE log_id = srs_id(?1)",
        )
        .map_err(sql)?
        .query_row(params![id], |r| Ok((r.get(0)?, r.get(1)?)))
        .optional()
        .map_err(sql)?;
    let (s_card, s_kind) = (col_at(STAT_COLS, "card"), col_at(STAT_COLS, "kind"));
    let mut v = Map::new();
    v.insert("log".into(), json!(id));
    v.insert("card".into(), json!(card));
    let cc = canon.text(&card);
    if cc != card {
        v.insert("cardCanonical".into(), json!(cc));
    }
    v.insert("profile".into(), json!(if mine { "self" } else { "other" }));
    v.insert("kind".into(), json!(kind));
    v.insert("origin".into(), json!(origin));
    v.insert("reviewType".into(), json!(rtype));
    v.insert("rating".into(), json!(rating));
    v.insert("at".into(), json!(at));
    v.insert("durationMs".into(), json!(dur));
    v.insert(
        "existingStat".into(),
        existing.map_or(Value::Null, |(c, k)| json!({"card": c, "kind": k})),
    );
    v.insert(
        "rebuiltStat".into(),
        rebuilt_stat.get(id).map_or(
            Value::Null,
            |r| json!({"card": r[s_card], "kind": r[s_kind]}),
        ),
    );
    if let Some((owner, winner, winner_owner)) = probe.losers.get(id) {
        v.insert(
            "rebuildAnkiLoser".into(),
            json!({"owner": owner, "keptLog": winner, "keptOwner": winner_owner}),
        );
    }
    Ok(Some(Value::Object(v)))
}

/// 协议 3 的一张卡（有日志、或有缓存行）：现成的与冻结重建的卡缓存行（笔记、模板、隐藏）、日志条数、两份统计行条数、
/// 链接（`historyFrom/` 修改：它的前身、以它为前身的卡）。都没有 = None。
fn p3_card(
    src: &Connection,
    id: &str,
    rebuilt_card: &HashMap<&str, &[String]>,
    rebuilt_stats_of: &HashMap<&str, usize>,
) -> Result<Option<Value>, String> {
    let count = |q: &str| -> Result<i64, String> {
        src.prepare_cached(q)
            .map_err(sql)?
            .query_row(params![id], |r| r.get(0))
            .map_err(sql)
    };
    let logs = count("SELECT COUNT(*) FROM main.srs_review_logs WHERE card_id = srs_id(?1)")?;
    let existing: Option<(String, String, i64)> = src
        .prepare_cached(
            "SELECT srs_idt(note_id), srs_idt(template_id), hidden FROM main.srs_cards_cache WHERE id = srs_id(?1)",
        )
        .map_err(sql)?
        .query_row(params![id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .optional()
        .map_err(sql)?;
    let rebuilt = rebuilt_card.get(id);
    if logs == 0 && existing.is_none() && rebuilt.is_none() {
        return Ok(None);
    }
    let preds: Vec<String> = src
        .prepare_cached(
            "SELECT substr(field_key, 13) FROM main.srs_field_edits WHERE entity_kind = 'card' \
             AND entity_id = srs_id(?1) AND substr(field_key, 1, 12) = 'historyFrom/'",
        )
        .map_err(sql)?
        .query_map(params![id], |r| r.get(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    let succs: Vec<String> = src
        .prepare_cached(
            "SELECT srs_idt(entity_id) FROM main.srs_field_edits WHERE field_key = 'historyFrom/' || ?1 \
             AND +entity_kind = 'card'",
        )
        .map_err(sql)?
        .query_map(params![id], |r| r.get(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    let (c_note, c_tpl, c_hidden) = (
        col_at(CARD_COLS, "note_id"),
        col_at(CARD_COLS, "template_id"),
        col_at(CARD_COLS, "hidden"),
    );
    Ok(Some(json!({
        "cardId": id,
        "logs": logs,
        "existingCard": existing.map(|(n, t, h)| json!({"note": n, "template": t, "hidden": h})),
        "rebuiltCard": rebuilt.map(|r| json!({"note": r[c_note], "template": r[c_tpl], "hidden": r[c_hidden]})),
        "existingStats": count("SELECT COUNT(*) FROM main.srs_stat_reviews WHERE card_id = srs_id(?1)")?,
        "rebuiltStats": rebuilt_stats_of.get(id).copied().unwrap_or(0),
        "historyFrom": preds,
        "successors": succs,
    })))
}

/// 新代一侧：日志索引里这个 ID 的各份（挂的卡、是不是这个原值的代表）、规范 ID 的统计行、作为卡时的统计行条数与卡行。
fn gen4_side(t: &Truth<'_>, col: i64, id: &str, canon_id: &str) -> Result<Value, String> {
    let r = Ref::of(&Key::of(id));
    let c = Ref::of(&Key::of(canon_id));
    let copies: Vec<(Ref, i64)> = t
        .conn()
        .prepare_cached("SELECT card, win FROM log_ix WHERE col = ?1 AND id = ?2 ORDER BY k")
        .map_err(sql)?
        .query_map(params![col, r], |r| Ok((r.get(0)?, r.get(1)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    let stat: Option<(Ref, i64)> = t
        .conn()
        .prepare_cached("SELECT card, kind FROM stats WHERE col = ?1 AND log = ?2 LIMIT 1")
        .map_err(sql)?
        .query_row(params![col, c], |r| Ok((r.get(0)?, r.get(1)?)))
        .optional()
        .map_err(sql)?;
    let card_stats: i64 = t
        .conn()
        .prepare_cached("SELECT COUNT(*) FROM stats WHERE col = ?1 AND card = ?2")
        .map_err(sql)?
        .query_row(params![col, c], |r| r.get(0))
        .map_err(sql)?;
    let card_row: Option<(Ref, Ref, i64)> = t
        .conn()
        .prepare_cached("SELECT note_id, template_id, hidden FROM cards WHERE col = ?1 AND id = ?2")
        .map_err(sql)?
        .query_row(params![col, c], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .optional()
        .map_err(sql)?;
    let card_logs: i64 = t
        .conn()
        .prepare_cached("SELECT COUNT(*) FROM log_ix WHERE col = ?1 AND card = ?2")
        .map_err(sql)?
        .query_row(params![col, r], |r| r.get(0))
        .map_err(sql)?;
    let mut by: BTreeMap<String, Vec<i64>> = BTreeMap::new();
    for (card, win) in copies {
        by.entry(card.text()).or_default().push(win);
    }
    Ok(json!({
        "logCopies": by,
        "stat": stat.map(|(card, kind)| json!({"card": card.text(), "kind": kind})),
        "cardStats": card_stats,
        "cardLogs": card_logs,
        "card": card_row.map(|(n, tpl, h)| json!({"note": n.text(), "template": tpl.text(), "hidden": h})),
    }))
}
