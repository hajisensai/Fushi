//! 干跑报告的「ID 溯源」（`idTrace`，BUG-5269）：对拍差异只说「哪里对不上」，这里把例子里出现的 ID 逐个摊开，说清
//! 「为什么对不上」所需的全部线索，用户发回报告就能定位，不必再要整个库。
//!
//! 每个 ID 给：
//! - 别名层怎么判的（`alias_ix` 的 how 与规范 ID；验不上的也在这里）；
//! - 它在两侧缓存行里的位置：笔记行（笔记类型、牌组、guid 是否按某个盐的规则派生出这个笔记 ID）、卡行（笔记、模板、
//!   序号、行 ID 是否正是由这三者派生）、统计行（挂的卡）、新代日志索引里挂的卡；
//! - 内置实体的规则身份：ID 是哪个内置笔记类型 / 模板 / 默认牌组、在哪个盐下（盐按排序后的序号写，不写 profile uid）；
//! - 卡 ID 的派生反查：在相关笔记（两侧行里出现过的、它们的规范 ID 与别名类成员）× 候选模板（内置模板在全部盐与规范规则
//!   下的 ID、相关卡行里的模板）× 序号里，找出能派生出这个 ID 的组合。
//!
//! 只有 ID、序号与规则名，不含笔记内容（guid 只报「是否派生出笔记 ID」，不报原文）。

use std::collections::{BTreeMap, BTreeSet, HashMap};

use rusqlite::{OptionalExtension, params};
use serde_json::{Map, Value, json};

use super::alias::{A_DERIVED, A_FALLBACK, A_SALTED, A_UNVERIFIED};
use super::compare::{CARD_COLS, CacheRows, CanonMap, NOTE_COLS, STAT_COLS, cell};
use super::derive::Ref;
use super::schema::sql;
use super::truth::Truth;
use crate::gen4_ids::builtins::BUILTIN_NOTE_TYPES;
use crate::gen4_ids::rules;
use crate::sync2::id::{Id, Key};

/// 一次最多摊开几个 ID（报告体积有上限）。
pub(crate) const TRACE_LIMIT: usize = 40;

/// 卡派生反查时序号最多试到几（填空题的序号；普通模板是 0）。
const MAX_ORD: i64 = 32;

fn at(cols: &[(&str, &str)], name: &str) -> usize {
    cols.iter()
        .position(|c| c.0 == name)
        .expect("column listed in the constant")
}

fn is_uuid(s: &str) -> bool {
    s.len() == 36 && Id::parse(s).is_some()
}

/// 一行里出现的 UUID 格（不碰别的格：笔记行的内容列不会进报告）。
pub(crate) fn uuids_in_row(row: &str) -> impl Iterator<Item = &str> {
    row.split(" | ").filter(|c| is_uuid(c))
}

/// 内置实体的规则身份表：ID → `内置 <类型键> 笔记类型 / 模板 <模板键> / 默认牌组`，加盐序号（`salt#i`）或 `canonical`。
fn rule_table(salts: &[String]) -> HashMap<String, String> {
    let mut out = HashMap::new();
    let mut salted: Vec<(String, Option<&str>)> = vec![("canonical".to_owned(), rules::CANONICAL)];
    salted.extend(
        salts
            .iter()
            .enumerate()
            .map(|(i, s)| (format!("salt#{i}"), Some(s.as_str()))),
    );
    for (label, salt) in &salted {
        out.insert(
            rules::builtin_default_deck(*salt).text(),
            format!("builtin default deck ({label})"),
        );
        for b in BUILTIN_NOTE_TYPES {
            let nt = rules::note_type(*salt, rules::builtin_note_type_anki_num(b.key));
            out.insert(nt.text(), format!("builtin {} note type ({label})", b.key));
            for t in b.template_keys {
                let n = rules::builtin_template_anki_num(b.key, t);
                out.insert(
                    rules::template(&nt, n).text(),
                    format!("builtin {} template {t} ({label})", b.key),
                );
            }
        }
    }
    out
}

fn how_name(how: i64) -> &'static str {
    match how {
        A_SALTED => "salted",
        A_DERIVED => "derived",
        A_FALLBACK => "fallback",
        A_UNVERIFIED => "unverified",
        _ => "other",
    }
}

/// 别名表里验不上的 ID（[A_UNVERIFIED]），按 ID 排序取前 [limit] 个。
pub(crate) fn unverified_ids(t: &Truth<'_>, col: i64, limit: usize) -> Result<Vec<String>, String> {
    let mut stmt = t
        .conn()
        .prepare("SELECT id FROM alias_ix WHERE col = ?1 AND how = ?2 ORDER BY id LIMIT ?3")
        .map_err(sql)?;
    let rows = stmt
        .query_map(params![col, A_UNVERIFIED, limit as i64], |r| {
            r.get::<_, Ref>(0)
        })
        .map_err(sql)?;
    rows.map(|r| r.map(|r| r.text()).map_err(sql)).collect()
}

/// 一侧的缓存行按身份索引（借用行，不复制）。
#[derive(Default)]
struct Side<'r> {
    notes: HashMap<&'r str, &'r [String]>,
    cards: HashMap<&'r str, &'r [String]>,
    /// 笔记 → 它名下的卡行。
    cards_of: HashMap<&'r str, Vec<&'r [String]>>,
    /// 统计行按日志 ID；同一张卡的统计行按卡 ID。
    stats: HashMap<&'r str, &'r [String]>,
    stats_of_card: HashMap<&'r str, Vec<&'r str>>,
}

impl<'r> Side<'r> {
    fn of(rows: &'r CacheRows) -> Side<'r> {
        let mut s = Side::default();
        for r in &rows.0 {
            s.notes.insert(&r[0], r);
        }
        let note = at(CARD_COLS, "note_id");
        for r in &rows.1 {
            s.cards.insert(&r[0], r);
            s.cards_of.entry(&r[note]).or_default().push(r);
        }
        let (log, card) = (at(STAT_COLS, "log"), at(STAT_COLS, "card"));
        for r in &rows.2 {
            s.stats.insert(&r[log], r);
            s.stats_of_card.entry(&r[card]).or_default().push(&r[log]);
        }
        s
    }
}

/// 新代一侧只读和 [ids] 有关的行（大库整表读进内存会抬高峰值内存）：挂着它们的统计行、它们与这些统计行的卡、
/// 两侧卡行指向的笔记及其别名类成员、这些笔记与名下的卡。
fn new_rows(
    t: &Truth<'_>,
    col: i64,
    canon: &CanonMap,
    old: Option<&Side<'_>>,
    ids: &[String],
) -> Result<CacheRows, String> {
    let names = |cols: &[(&'static str, &'static str)]| -> String {
        cols.iter().map(|c| c.0).collect::<Vec<_>>().join(", ")
    };
    let rows = |table: &str, cols: &[(&'static str, &'static str)], cond: &str, id: &str| {
        let mut stmt = t
            .conn()
            .prepare_cached(&format!(
                "SELECT {} FROM {table} WHERE col = ?1 AND ({cond})",
                names(cols)
            ))
            .map_err(sql)?;
        let mut q = stmt
            .query(params![col, Ref::of(&Key::of(id))])
            .map_err(sql)?;
        let mut out: Vec<Vec<String>> = Vec::new();
        while let Some(r) = q.next().map_err(sql)? {
            out.push(
                (0..cols.len())
                    .map(|i| r.get_ref(i).map(cell))
                    .collect::<Result<_, _>>()
                    .map_err(sql)?,
            );
        }
        Ok::<_, String>(out)
    };
    let (card_note, stat_card) = (at(CARD_COLS, "note_id"), at(STAT_COLS, "card"));
    let mut stats = Vec::new();
    let mut cards: BTreeSet<String> = BTreeSet::new();
    for id in ids {
        cards.insert(id.clone());
        for r in rows("stats", STAT_COLS, "log = ?2 OR card = ?2", id)? {
            cards.insert(r[stat_card].clone());
            stats.push(r);
        }
        if let Some(o) = old {
            if let Some(r) = o.stats.get(id.as_str()) {
                cards.insert(r[stat_card].clone());
            }
        }
    }
    let mut notes_rel: BTreeSet<String> = ids.iter().cloned().collect();
    let mut card_rows: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for c in &cards {
        for r in rows("cards", CARD_COLS, "id = ?2", c)? {
            notes_rel.insert(r[card_note].clone());
            card_rows.insert(r[0].clone(), r);
        }
        if let Some(r) = old.and_then(|o| o.cards.get(c.as_str())) {
            notes_rel.insert(r[card_note].clone());
        }
    }
    let mut notes_all = BTreeSet::new();
    for n in &notes_rel {
        notes_all.extend(class_members(t, col, canon, n)?);
    }
    let mut note_rows = Vec::new();
    for n in &notes_all {
        note_rows.extend(rows("notes", NOTE_COLS, "id = ?2", n)?);
        for r in rows("cards", CARD_COLS, "note_id = ?2", n)? {
            card_rows.insert(r[0].clone(), r);
        }
    }
    Ok((note_rows, card_rows.into_values().collect(), stats))
}

/// 与 [id] 同一别名类的成员（含 [id] 与规范 ID 本身）。
fn class_members(
    t: &Truth<'_>,
    col: i64,
    canon: &CanonMap,
    id: &str,
) -> Result<BTreeSet<String>, String> {
    let c = canon.text(id);
    let mut out: BTreeSet<String> = [id.to_owned(), c.clone()].into_iter().collect();
    let Key::Uuid(cid) = Key::of(&c) else {
        return Ok(out);
    };
    let mut stmt = t
        .conn()
        .prepare_cached("SELECT id FROM alias_ix WHERE col = ?1 AND canon = ?2")
        .map_err(sql)?;
    let rows = stmt
        .query_map(params![col, Ref::Uuid(cid.0)], |r| r.get::<_, Ref>(0))
        .map_err(sql)?;
    for r in rows {
        out.insert(r.map_err(sql)?.text());
    }
    Ok(out)
}

struct Ctx<'a> {
    t: &'a Truth<'a>,
    col: i64,
    canon: &'a CanonMap,
    salts: &'a [String],
    rules: HashMap<String, String>,
    old: Option<Side<'a>>,
    new: Side<'a>,
}

impl Ctx<'_> {
    fn rule(&self, id: &str) -> Value {
        self.rules.get(id).map_or(Value::Null, |r| json!(r))
    }

    /// 一个引用的描述：原 ID、规范 ID（不同才写）、内置规则身份（有才写）。
    fn reference(&self, id: &str) -> Value {
        let mut v = Map::new();
        v.insert("id".into(), json!(id));
        let c = self.canon.text(id);
        if c != id {
            v.insert("canonical".into(), json!(c));
        }
        if let Some(r) = self.rules.get(id).or_else(|| self.rules.get(&c)) {
            v.insert("rule".into(), json!(r));
        }
        Value::Object(v)
    }

    fn alias(&self, id: &str) -> Result<Value, String> {
        let Key::Uuid(raw) = Key::of(id) else {
            return Ok(Value::Null);
        };
        let row: Option<(i64, Ref)> = self
            .t
            .conn()
            .prepare_cached("SELECT how, canon FROM alias_ix WHERE col = ?1 AND id = ?2 LIMIT 1")
            .map_err(sql)?
            .query_row(params![self.col, Ref::Uuid(raw.0)], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .optional()
            .map_err(sql)?;
        Ok(row.map_or(
            Value::Null,
            |(how, canon)| json!({"how": how_name(how), "canon": canon.text()}),
        ))
    }

    fn note_json(&self, r: &[String], side: &Side) -> Value {
        let id = &r[0];
        let guid = &r[at(NOTE_COLS, "guid")];
        // 笔记 ID 是否由 guid 按规则派生，在哪个盐下。
        let mut by_guid = Vec::new();
        if Id::parse(id).is_some() {
            if rules::note(rules::CANONICAL, guid).text() == *id {
                by_guid.push("canonical".to_owned());
            }
            for (i, s) in self.salts.iter().enumerate() {
                if rules::note(Some(s), guid).text() == *id {
                    by_guid.push(format!("salt#{i}"));
                }
            }
        }
        let cards: Vec<Value> = side
            .cards_of
            .get(id.as_str())
            .into_iter()
            .flatten()
            .map(|c| self.card_json(c))
            .collect();
        json!({
            "noteType": self.reference(&r[at(NOTE_COLS, "note_type_id")]),
            "deck": self.reference(&r[at(NOTE_COLS, "deck_id")]),
            "idFromGuid": by_guid,
            "deleted": r[at(NOTE_COLS, "deleted_at")] != "∅",
            "cards": cards,
        })
    }

    fn card_json(&self, r: &[String]) -> Value {
        let (note, tpl, ord) = (
            &r[at(CARD_COLS, "note_id")],
            &r[at(CARD_COLS, "template_id")],
            &r[at(CARD_COLS, "cloze_ord")],
        );
        let from_row = ord
            .parse::<i64>()
            .ok()
            .and_then(|o| crate::registers::card_id(note, tpl, o).ok())
            .is_some_and(|d| d == r[0]);
        json!({
            "id": r[0],
            "note": self.reference(note),
            "template": self.reference(tpl),
            "ord": ord,
            "idFromRow": from_row,
            "hidden": r[at(CARD_COLS, "hidden")],
            "reps": r[at(CARD_COLS, "reps")],
        })
    }

    fn log_card(&self, id: &str) -> Result<Option<String>, String> {
        let card: Option<Ref> = self
            .t
            .conn()
            .prepare_cached(
                "SELECT card FROM log_ix WHERE col = ?1 AND id = ?2 ORDER BY win DESC, k LIMIT 1",
            )
            .map_err(sql)?
            .query_row(params![self.col, Ref::of(&Key::of(id))], |r| r.get(0))
            .optional()
            .map_err(sql)?;
        Ok(card.map(|c| c.text()))
    }

    /// 和 [id] 有关的笔记：两侧挂着它的卡行、挂着它的统计行另一侧的卡行、它本身是笔记。
    fn related_notes(&self, id: &str) -> BTreeSet<String> {
        let note = at(CARD_COLS, "note_id");
        let card = at(STAT_COLS, "card");
        let sides: Vec<&Side> = self.old.iter().chain([&self.new]).collect();
        let mut cards: BTreeSet<String> = [id.to_owned()].into_iter().collect();
        for s in &sides {
            if let Some(r) = s.stats.get(id) {
                cards.insert(r[card].clone());
            }
            if let Some(logs) = s.stats_of_card.get(id) {
                for l in logs {
                    for s2 in &sides {
                        if let Some(r) = s2.stats.get(l) {
                            cards.insert(r[card].clone());
                        }
                    }
                }
            }
        }
        let mut out = BTreeSet::new();
        for c in &cards {
            for s in &sides {
                if let Some(r) = s.cards.get(c.as_str()) {
                    out.insert(r[note].clone());
                }
                if s.notes.contains_key(c.as_str()) {
                    out.insert(c.clone());
                }
            }
        }
        out
    }

    /// 能派生出卡 ID [id] 的（笔记, 模板, 序号）组合。
    fn derivations(&self, id: &str) -> Result<Vec<String>, String> {
        let mut notes = BTreeSet::new();
        for n in self.related_notes(id) {
            notes.extend(class_members(self.t, self.col, self.canon, &n)?);
        }
        if notes.is_empty() {
            return Ok(Vec::new());
        }
        let tpl_col = at(CARD_COLS, "template_id");
        let ord_col = at(CARD_COLS, "cloze_ord");
        let mut templates: BTreeSet<String> = self
            .rules
            .iter()
            .filter(|(_, r)| r.contains(" template "))
            .map(|(id, _)| id.clone())
            .collect();
        let mut max_ord = 0i64;
        for s in self.old.iter().chain([&self.new]) {
            for n in &notes {
                for r in s.cards_of.get(n.as_str()).into_iter().flatten() {
                    templates.insert(r[tpl_col].clone());
                    templates.insert(self.canon.text(&r[tpl_col]));
                    if let Ok(o) = r[ord_col].parse::<i64>() {
                        max_ord = max_ord.max(o);
                    }
                }
            }
        }
        let mut out = Vec::new();
        for n in &notes {
            for tpl in &templates {
                for o in 0..=max_ord.min(MAX_ORD) {
                    if crate::registers::card_id(n, tpl, o).is_ok_and(|d| d == id) {
                        let rule = self
                            .rules
                            .get(tpl)
                            .cloned()
                            .unwrap_or_else(|| "template of a card row".to_owned());
                        out.push(format!("card({n}, {tpl} [{rule}], {o})"));
                    }
                }
            }
        }
        Ok(out)
    }

    fn trace(&self, id: &str) -> Result<Value, String> {
        let mut v = Map::new();
        v.insert("id".into(), json!(id));
        v.insert("alias".into(), self.alias(id)?);
        let c = self.canon.text(id);
        if c != id {
            v.insert("canonical".into(), json!(c));
        }
        let rule = self.rule(id);
        let has_rule = !rule.is_null();
        if has_rule {
            v.insert("rule".into(), rule);
        }
        let mut found = false;
        for (name, side) in [("old", self.old.as_ref()), ("new", Some(&self.new))] {
            let Some(side) = side else { continue };
            if let Some(r) = side.notes.get(id) {
                v.insert(format!("{name}Note"), self.note_json(r, side));
                found = true;
            }
            if let Some(r) = side.cards.get(id) {
                v.insert(format!("{name}Card"), self.card_json(r));
                found = true;
            }
            if let Some(r) = side.stats.get(id) {
                v.insert(
                    format!("{name}Stat"),
                    json!({"card": r[at(STAT_COLS, "card")], "kind": r[at(STAT_COLS, "kind")]}),
                );
                found = true;
            }
            if let Some(logs) = side.stats_of_card.get(id) {
                v.insert(format!("{name}StatLogs"), json!(logs.len()));
            }
        }
        if let Some(card) = self.log_card(id)? {
            v.insert("newLogCard".into(), json!(card));
            found = true;
        }
        // 不是笔记、日志的 ID 当卡 ID 反查派生（卡行在不在都查：统计行改挂的卡可能没有卡行）。
        let is_note = v.contains_key("oldNote") || v.contains_key("newNote");
        let is_log = v.contains_key("oldStat") || v.contains_key("newStat");
        if !is_note && !is_log && !has_rule {
            v.insert("derivations".into(), json!(self.derivations(id)?));
        }
        v.insert("found".into(), json!(found));
        Ok(Value::Object(v))
    }
}

/// 摊开 [ids]（报告例子里出现的 ID，按出现顺序去重，最多 [TRACE_LIMIT] 个）。[old] 是协议 3 重建出来的缓存行
/// （没有基准时只看新代一侧）。
pub(crate) fn id_trace(
    t: &Truth<'_>,
    col: i64,
    canon: &CanonMap,
    old: Option<&CacheRows>,
    ids: &[String],
) -> Result<Value, String> {
    if ids.is_empty() {
        return Ok(json!([]));
    }
    let salts: Vec<String> = t
        .binding(col)?
        .map(|b| b.salts.into_iter().collect())
        .unwrap_or_default();
    let old = old.map(Side::of);
    let new_rows = new_rows(t, col, canon, old.as_ref(), ids)?;
    let ctx = Ctx {
        t,
        col,
        canon,
        salts: &salts,
        rules: rule_table(&salts),
        old,
        new: Side::of(&new_rows),
    };
    let mut seen = BTreeSet::new();
    let mut out = Vec::new();
    for id in ids {
        if out.len() >= TRACE_LIMIT {
            break;
        }
        if seen.insert(id.clone()) {
            out.push(ctx.trace(id)?);
        }
    }
    Ok(json!({"salts": salts.len(), "ids": out}))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 内置模板在规范规则与每个盐下各有一个 ID，规则表都认得，并写清是哪个盐（BUG-5269 那张卡就是「带盐的 profile
    /// 里出现了按规范规则派生的卡」，报告要能直接看出来）。
    #[test]
    fn the_rule_table_names_builtin_ids_per_salt() {
        let salts = vec!["s-a".to_owned(), "s-b".to_owned()];
        let table = rule_table(&salts);
        let num = rules::builtin_note_type_anki_num("fushi_card");
        let tn = rules::builtin_template_anki_num("fushi_card", "Card 1");
        let canonical = rules::template(&rules::note_type(rules::CANONICAL, num), tn);
        let salted = rules::template(&rules::note_type(Some("s-b"), num), tn);
        assert_eq!(
            table[&canonical.text()],
            "builtin fushi_card template Card 1 (canonical)"
        );
        assert_eq!(
            table[&salted.text()],
            "builtin fushi_card template Card 1 (salt#1)"
        );
        assert_eq!(
            table[&rules::builtin_default_deck(Some("s-a")).text()],
            "builtin default deck (salt#0)"
        );
    }

    /// 只取 UUID 格：笔记行的内容列不进 `idTrace`。
    #[test]
    fn only_uuid_cells_are_taken_from_rows() {
        let id = "978c5904-c7fd-59db-8c4a-3a65d9877981";
        let row = format!("{id} | NT | 犬 | 12 | 01a1d4ca-d862-78b6-8039-1a52f144958f");
        let got: Vec<&str> = uuids_in_row(&row).collect();
        assert_eq!(got, vec![id, "01a1d4ca-d862-78b6-8039-1a52f144958f"]);
    }
}
