//! 意图类写命令的新代实现（G7-3b，`writes.rs` 文件头的约定全部适用）：`note_fields_if`、`change`（含移牌组段）、
//! `merge_notes`、`deck_delete`、`sched`。每条都是协议 3 同名命令（`store/sync2/{note_fields_if,change,merge_notes,
//! deck_delete,sched_local}.rs`）的同一套判定，只是现值从派生层按别名类读（[Session::lines] / [Session::note_info] /
//! 缓存层的 `cards` / `notes`），拼好的输入经 [apply_in] 落原生日志。读与写在同一个事务里。
//!
//! 与协议 3 的差别（都是「新代没有那样东西」）：
//!
//! - 缓存表没有 rowid（`notes` / `cards` 是 `WITHOUT ROWID`，按 `(col, id)` 聚簇）：协议 3 按 rowid 排、按 rowid 记
//!   游标的地方，这里按规范 ID 排、游标记 ID（`deck_delete` 的 `token` 对宿主是不透明的，形状变了无妨）。写出的操作
//!   顺序因此可能不同，结果状态相同（每条写的是互不相干的 (实体, 键)）。
//! - 旧版时钟没有了：`deck_delete` 给牌组写的删除标记协议 3 取 `tickNow`（旧版时钟的此刻），这里取同一步的
//!   `deletedAt`（宿主给笔记删除标记的那个此刻）。
//! - 没有跨 profile 归属（`writes.rs` 文件头）：`merge_notes` / `note_fields_if` 里「别的 profile 的笔记按不存在算」
//!   的分支不存在。

use std::collections::{HashMap, HashSet};

use rusqlite::params;
use serde_json::{Map, Value, json};

use super::super::derive::{Index, Ref};
use super::super::schema::sql;
use super::super::truth::Truth;
use super::ref_of;
use super::writes::{
    ApplyOpts, Born, Origin, Session, apply_in, draft, fail_after, now_of, row_with_profile,
    stored, write,
};
use crate::card_cache::is_js_space;
use crate::projection::Day;
use crate::registers;
use crate::store::caches::NoteInfo;
use crate::store::sync2::{checkpoint_bodies, log_body_of};
use crate::sync2::id::Id;
use crate::sync2::op::{Body, EntKind, Intent};
use crate::sync2::replay::{self, Row};
use crate::sync2::sched::Queue;

/// Dart `SrsFieldKeys`：`noteDeck` / `cardDeck`、`deleted`、`noteTags`、`cardHistoryFromPrefix`。
const KEY_DECK: &str = "deck";
const KEY_DELETED: &str = "deleted";
const KEY_PARENT: &str = "parent";
const KEY_TAGS: &str = "tags";
const HISTORY_FROM: &str = "historyFrom/";

/// 两段结果并成一份：`landed` 接上（协议 3 `change::merge_results` 对逐项数组的口径），其余取后一段的。统一的那几项
/// （`changed` 等）由 [Session] 攒、[write] 补，不在这里。
fn merge(a: &mut Value, b: Value) {
    let Value::Object(b) = b else { return };
    if !a.is_object() {
        *a = json!({});
    }
    for (k, v) in b {
        if k == "landed" {
            let mut out: Vec<Value> = a["landed"].as_array().cloned().unwrap_or_default();
            out.extend(v.as_array().cloned().unwrap_or_default());
            a["landed"] = Value::Array(out);
        } else {
            a[k.as_str()] = v;
        }
    }
}

/// 给 [ids] 每个实体的 [key] 写 [value] 的输入项，值没变的跳过（协议 3 `deck_delete::push_edits`）。
#[allow(clippy::too_many_arguments)]
fn push_edits(
    s: &mut Session<'_, '_>,
    ts: &str,
    kind: EntKind,
    ids: &[String],
    key: &str,
    value: &Value,
    items: &mut Vec<Value>,
) -> Result<(), String> {
    let profile = s.profile.clone();
    for id in ids {
        let lines = s.lines(kind, id)?;
        if registers::write_is_noop(&stored(&lines), key, value)? {
            continue;
        }
        items.push(draft(&profile, kind.wire(), id, key, value, ts));
    }
    Ok(())
}

/// [apply_in]，没有输入项时什么都不做（协议 3「没有要写的就不发命令」）。
fn apply_some(s: &mut Session<'_, '_>, now: i64, items: &[Value]) -> Result<Value, String> {
    if items.is_empty() {
        return Ok(json!({}));
    }
    apply_in(
        s,
        now,
        items,
        ApplyOpts {
            chg: false,
            compact: false,
            origin: Origin::Synthesized,
        },
    )
}

// ---------------------------------------------------------------------- note_fields_if

/// `note_fields_if`（条件写笔记字段：批量改字段的落计划 / 撤销；协议 3 `note_fields_if.rs`）。[req]：
/// `{"now", "mode": "note"|"field", "ts"?}`；[items]：`{"n": 笔记, "f": 字段 ID, "x": 期望的现值, "v": 要写的值}`。
///
/// - `note`：笔记不存在 / 已删除 / 它名下任一项现值 ≠ `x` → 整条笔记拒绝、一项都不写；
/// - `field`：笔记不存在 / 已删除 → 它的项都不写；否则逐项，现值 ≠ `x` 的那一项不写（笔记计入拒绝）。
///
/// 回包另带 `rejected`（被拒的笔记，调用方给的 ID，去重、按首次出现的顺序）。比对与写入在同一个事务里。
pub fn note_fields_if(
    t: &Truth<'_>,
    col: i64,
    req: &Value,
    items: &[Value],
) -> Result<Value, String> {
    let now = now_of(req)?;
    let whole_note = match req["mode"].as_str() {
        Some("note") => true,
        Some("field") => false,
        other => return Err(format!("note_fields_if: bad mode {other:?}")),
    };
    struct It<'a> {
        note: &'a str,
        field: &'a str,
        expect: &'a str,
        value: &'a Value,
    }
    let items: Vec<It<'_>> = items
        .iter()
        .map(|it| {
            Ok(It {
                note: it["n"].as_str().ok_or("note_fields_if: missing n")?,
                field: it["f"].as_str().ok_or("note_fields_if: missing f")?,
                expect: it["x"].as_str().ok_or("note_fields_if: missing x")?,
                value: it.get("v").ok_or("note_fields_if: missing v")?,
            })
        })
        .collect::<Result<_, String>>()?;
    let ts = req["ts"].as_str().unwrap_or("wall").to_owned();
    write(t, col, |s| {
        let mut views: HashMap<&str, Option<NoteInfo>> = HashMap::new();
        for it in &items {
            if !views.contains_key(it.note) {
                let v = s.note_info(it.note)?;
                views.insert(it.note, v);
            }
        }
        let mut rejected: Vec<&str> = Vec::new();
        let mut rejected_set: HashSet<&str> = HashSet::new();
        let mut pass: Vec<bool> = Vec::with_capacity(items.len());
        for it in &items {
            // 视图里的字段 ID 是规范形：请求里的字段 ID 归一了再查。
            let field = s.canon_text(it.field)?;
            let ok = views[it.note]
                .as_ref()
                .filter(|n| n.deleted_at.is_none())
                .is_some_and(|n| n.field(&field) == it.expect);
            if !ok && rejected_set.insert(it.note) {
                rejected.push(it.note);
            }
            pass.push(ok);
        }
        let mut writes: Vec<(&str, Vec<(&str, &Value)>)> = Vec::new();
        let mut at: HashMap<&str, usize> = HashMap::new();
        for (it, ok) in items.iter().zip(&pass) {
            if whole_note && rejected_set.contains(it.note) || !*ok {
                continue;
            }
            let i = *at.entry(it.note).or_insert_with(|| {
                writes.push((it.note, Vec::new()));
                writes.len() - 1
            });
            match writes[i].1.iter_mut().find(|(f, _)| *f == it.field) {
                Some(slot) => slot.1 = it.value,
                None => writes[i].1.push((it.field, it.value)),
            }
        }
        let profile = s.profile.clone();
        let mut input: Vec<Value> = Vec::new();
        for (note, fields) in &writes {
            let lines = s.lines(EntKind::Note, note)?;
            for (field, value) in fields {
                let key = s.ix().canonical_key(&format!("f/{field}"))?;
                if registers::write_is_noop(&stored(&lines), &key, value)? {
                    continue;
                }
                input.push(draft(&profile, "note", note, &key, value, &ts));
            }
        }
        let mut v = apply_some(s, now, &input)?;
        fail_after(req, "apply")?;
        v["rejected"] = json!(rejected);
        Ok(v)
    })
}

// ---------------------------------------------------------------------- change

/// `change`（结构性改动：更改笔记类型、删除重复模板、旧 Lapis 迁移；协议 3 `change.rs`）：还原点 + 一批修改记录
/// （`chg` 项值没变的不写）+ 带 `retype` 时由内核逐条笔记换类型 / 补迁（`writes_retype.rs`，回包另带 `retyped` /
/// `filled`），带 `move` 时再把这些笔记连同它们此刻可见的卡移到一个牌组。[req]：
/// `{"now", "checkpoint"?: {"name", "reason"}, "retype"?: {...}, "move"?: {"deck", "notes"}, "ts"?}`；[items] 同
/// `apply`。
///
/// 移牌组段要看换完类型之后有哪些可见卡（缓存层推导），所以在前一段收尾之后读 `cards`；三段同一个事务，任何一段出错
/// 整笔回滚。
pub fn change(t: &Truth<'_>, col: i64, req: &Value, items: &[Value]) -> Result<Value, String> {
    let now = now_of(req)?;
    write(t, col, |s| {
        s.want_edit_rows(req);
        if let Some(cp) = req.get("checkpoint").filter(|cp| cp.is_object()) {
            let name = cp["name"]
                .as_str()
                .ok_or("change: missing checkpoint.name")?;
            let reason = cp["reason"]
                .as_str()
                .ok_or("change: missing checkpoint.reason")?;
            for b in checkpoint_bodies(name, reason) {
                s.land(b, now)?;
            }
        }
        // 协议 3 先就地筛掉 `chg` 没变的项，筛完一项不剩就不走 `apply`（回包没有 `landed` / `foreign`）。
        let mut v = if items.is_empty() {
            json!({})
        } else {
            let v = apply_in(
                s,
                now,
                items,
                ApplyOpts {
                    chg: true,
                    compact: true,
                    origin: Origin::Caller,
                },
            )?;
            if v["landed"].as_array().is_some_and(Vec::is_empty) {
                json!({})
            } else {
                v
            }
        };
        // 换类型段（`writes_retype.rs`）：内核逐条笔记读现值、算、写，与上面的修改记录同一笔。
        if req.get("retype").is_some_and(Value::is_object) {
            let r = super::writes_retype::retype(s, now, req)?;
            v["retyped"] = r["retyped"].clone();
            v["filled"] = r["filled"].clone();
        }
        fail_after(req, "apply")?;
        if req.get("move").is_some_and(Value::is_object) {
            let moved = move_notes(s, now, req)?;
            merge(&mut v, moved);
            fail_after(req, "move")?;
        }
        Ok(v)
    })
}

/// `change` 的移牌组段（协议 3 `move_notes_on`）：`move.notes` 的首选牌组与它们此刻可见的卡都移到 `move.deck`，已经
/// 在那里的不写。笔记在前（按给的顺序），再逐条笔记的卡。隐藏的卡（被换掉的旧模板卡）不动。
fn move_notes(s: &mut Session<'_, '_>, now: i64, req: &Value) -> Result<Value, String> {
    let mv = &req["move"];
    let deck = s.canon_text(mv["deck"].as_str().ok_or("change: missing move.deck")?)?;
    let mut seen: HashSet<&str> = HashSet::new();
    let notes: Vec<String> = mv["notes"]
        .as_array()
        .ok_or("change: missing move.notes")?
        .iter()
        .filter_map(Value::as_str)
        .filter(|n| seen.insert(*n))
        .map(str::to_owned)
        .collect();
    let ts = req["ts"].as_str().unwrap_or("wall").to_owned();
    let target = json!(deck);
    let profile = s.profile.clone();
    let mut items: Vec<Value> = Vec::new();
    for n in &notes {
        let lines = s.lines(EntKind::Note, n)?;
        if registers::register_value(&stored(&lines), KEY_DECK)? == target {
            continue;
        }
        items.push(draft(&profile, "note", n, KEY_DECK, &target, &ts));
    }
    for n in &notes {
        let cards: Vec<String> = s
            .note_cards(n)?
            .into_iter()
            .filter(|c| !c.hidden && c.deck != deck)
            .map(|c| c.card)
            .collect();
        push_edits(s, &ts, EntKind::Card, &cards, KEY_DECK, &target, &mut items)?;
    }
    apply_some(s, now, &items)
}

// ---------------------------------------------------------------------- merge_notes

/// Dart `String.trim().isEmpty`（协议 3 `merge_notes.rs` 同一个判据）。
pub(super) fn dart_blank(s: &str) -> bool {
    s.chars().all(|c| is_js_space(c) || c == '\u{85}')
}

/// `merge_notes`（合并重复笔记；协议 3 `merge_notes.rs`）：还原点 + 前身链接 + 补空字段 / 并标签 + 删除被吸收的笔记，
/// 一笔。[req]：`{"now", "keep", "absorb": [...], "deletedAt", "ts"?}`。回包另带 `linked` / `unmatched`。`absorb` 去掉
/// `keep` 自己之后为空 = 什么都不做；笔记不存在、笔记类型不同 = 报错、什么都不写。
pub fn merge_notes(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let now = now_of(req)?;
    let keep_id = req["keep"].as_str().ok_or("merge_notes: missing keep")?;
    let mut seen: HashSet<&str> = HashSet::new();
    let absorb: Vec<&str> = req["absorb"]
        .as_array()
        .ok_or("merge_notes: missing absorb")?
        .iter()
        .filter_map(Value::as_str)
        .filter(|id| *id != keep_id && seen.insert(*id))
        .collect();
    let ts = req["ts"].as_str().unwrap_or("wall").to_owned();
    write(t, col, |s| {
        if absorb.is_empty() {
            return Ok(json!({"linked": 0, "unmatched": 0}));
        }
        let mut views: HashMap<&str, NoteInfo> = HashMap::new();
        for id in std::iter::once(keep_id).chain(absorb.iter().copied()) {
            let v = s
                .note_info(id)?
                .ok_or_else(|| format!("merge_notes: note {id} not found"))?;
            views.insert(id, v);
        }
        let keep = views.remove(keep_id).expect("keep was just read");
        for id in &absorb {
            if views[id].note_type != keep.note_type {
                return Err("merge_notes: notes of different note types cannot be merged".into());
            }
        }
        let deleted_at = req["deletedAt"]
            .as_i64()
            .ok_or("merge_notes: missing deletedAt")?;
        let name = keep.fields.first().map_or(keep_id, |(_, v)| v.as_str());
        for b in checkpoint_bodies(name, "merge_notes") {
            s.land(b, now)?;
        }
        let mut wanted: Vec<(EntKind, String, String, Value)> = Vec::new();
        let mut keep_cards: HashMap<(String, i64), String> = HashMap::new();
        for c in s.note_cards(keep_id)? {
            keep_cards.insert((c.template, c.ord), c.card);
        }
        let (mut linked, mut unmatched) = (0i64, 0i64);
        let mut filled: Vec<(String, String)> = Vec::new();
        let mut tags: Vec<String> = Vec::new();
        for t in &keep.tags {
            if !tags.contains(t) {
                tags.push(t.clone());
            }
        }
        let own_tags = tags.len();
        for id in &absorb {
            for c in s.note_cards(id)? {
                match keep_cards.get(&(c.template, c.ord)) {
                    Some(target) => {
                        wanted.push((
                            EntKind::Card,
                            target.clone(),
                            format!("{HISTORY_FROM}{}", c.card),
                            json!(true),
                        ));
                        linked += 1;
                    }
                    None => unmatched += 1,
                }
            }
            let n = &views[id];
            for (k, val) in &n.fields {
                if dart_blank(keep.field(k))
                    && !dart_blank(val)
                    && !filled.iter().any(|(fk, _)| fk == k)
                {
                    filled.push((k.clone(), val.clone()));
                }
            }
            for t in &n.tags {
                if !tags.contains(t) {
                    tags.push(t.clone());
                }
            }
        }
        for (k, val) in &filled {
            wanted.push((
                EntKind::Note,
                keep_id.to_owned(),
                format!("f/{k}"),
                json!(val),
            ));
        }
        if tags.len() != own_tags {
            wanted.push((
                EntKind::Note,
                keep_id.to_owned(),
                KEY_TAGS.to_owned(),
                json!(tags),
            ));
        }
        for id in &absorb {
            wanted.push((
                EntKind::Note,
                (*id).to_owned(),
                KEY_DELETED.to_owned(),
                json!(deleted_at),
            ));
        }
        let profile = s.profile.clone();
        let mut items: Vec<Value> = Vec::new();
        let mut lines: HashMap<(EntKind, String), super::writes::Lines> = HashMap::new();
        for (kind, entity, key, value) in &wanted {
            let slot = (*kind, entity.clone());
            if !lines.contains_key(&slot) {
                let l = s.lines(*kind, entity)?;
                lines.insert(slot.clone(), l);
            }
            if registers::write_is_noop(&stored(&lines[&slot]), key, value)? {
                continue;
            }
            items.push(draft(&profile, kind.wire(), entity, key, value, &ts));
        }
        let mut v = apply_some(s, now, &items)?;
        fail_after(req, "apply")?;
        v["linked"] = json!(linked);
        v["unmatched"] = json!(unmatched);
        Ok(v)
    })
}

// ---------------------------------------------------------------------- deck_delete

/// 一步最多处理的实体数（宿主没给 `limit` 时；协议 3 同值）。
const DEFAULT_LIMIT: i64 = 500;

/// 一组 ID 的 JSON 参数（`[[1, "<hex>"], [0, "<文本>"]]`，SQL 里还原成存储形，`cmd/mod.rs` [super::Sel::ids] 同形）。
fn ids_json(ids: &[String]) -> String {
    let list: Vec<Value> = ids
        .iter()
        .map(|id| match ref_of(id) {
            Ref::Uuid(b) => json!([1, super::hex(&b)]),
            Ref::Text(t) => json!([0, t]),
        })
        .collect();
    Value::Array(list).to_string()
}

/// 子查询：参数 [p] 是 [ids_json] 的结果。
fn in_ids(p: &str) -> String {
    format!(
        "(SELECT CASE value ->> 0 WHEN 1 THEN unhex(value ->> 1) ELSE value ->> 1 END FROM json_each({p}))"
    )
}

/// 还没删、且卡全都归在子树 `?2` 下的笔记（协议 3 `NOTES_WHERE`）；`?1` = 集合号。
fn notes_where() -> String {
    let sub = in_ids("?2");
    format!(
        "n.col = ?1 AND n.deleted_at IS NULL \
         AND EXISTS (SELECT 1 FROM cards c WHERE c.col = ?1 AND c.note_id = n.id AND c.deck_id IN {sub}) \
         AND NOT EXISTS (SELECT 1 FROM cards c WHERE c.col = ?1 AND c.note_id = n.id AND c.deck_id NOT IN {sub})"
    )
}

/// 归在子树 `?2` 下的卡（含隐藏的；协议 3 `CARDS_WHERE`）。
fn cards_where() -> String {
    format!("c.col = ?1 AND c.deck_id IN {}", in_ids("?2"))
}

/// 游标之后（`after` = None 从头）至多 [limit] 个 ID（负数 = 不限），按 ID。
fn rows_after(
    s: &mut Session<'_, '_>,
    notes: bool,
    sub: &str,
    after: Option<&str>,
    limit: i64,
) -> Result<Vec<String>, String> {
    let col = s.col;
    let ix = s.settled()?;
    let (alias, table, cond) = if notes {
        ("n", "notes", notes_where())
    } else {
        ("c", "cards", cards_where())
    };
    let q = format!(
        "SELECT {alias}.id FROM {table} {alias} WHERE {cond} \
         AND (?3 IS NULL OR {alias}.id > ?3) ORDER BY {alias}.id LIMIT ?4"
    );
    let after: Option<Ref> = after.map(ref_of);
    let mut stmt = ix.t.conn().prepare_cached(&q).map_err(sql)?;
    let rows = stmt
        .query_map(params![col, sub, after, limit], |r| r.get::<_, Ref>(0))
        .map_err(sql)?;
    rows.map(|r| r.map(|x| x.text()).map_err(sql)).collect()
}

/// 子树里的笔记 / 卡数（`plan`）。
fn count(s: &mut Session<'_, '_>, notes: bool, sub: &str) -> Result<i64, String> {
    let col = s.col;
    let ix = s.settled()?;
    let q = if notes {
        format!("SELECT COUNT(*) FROM notes n WHERE {}", notes_where())
    } else {
        format!("SELECT COUNT(*) FROM cards c WHERE {}", cards_where())
    };
    ix.t.conn()
        .prepare_cached(&q)
        .map_err(sql)?
        .query_row(params![col, sub], |r| r.get(0))
        .map_err(sql)
}

/// 「父::子」全名（还原点的名字；协议 3 `deck_delete::full_name`；实体归属闸按它重算牌组 ID，`writes_owner.rs`）。
pub(super) fn full_name(tree: &crate::store::sync2::config::DeckTree, id: &str) -> String {
    let mut parts: Vec<&str> = Vec::new();
    let mut cur = Some(id);
    let mut guard = 0;
    while let Some(d) = cur {
        if guard >= 64 {
            break;
        }
        guard += 1;
        let node = tree.decks.get(d);
        parts.push(node.and_then(|n| n.view["nm"].as_str()).unwrap_or("?"));
        cur = node.and_then(|n| n.parent.as_deref());
    }
    parts.reverse();
    parts.join("::")
}

/// `deck_delete` 一步里分几次落的输入项的 `landed`，按落的顺序接起来（一次也没落 = `{}`，同 [apply_some]）。
#[derive(Default)]
struct Landed {
    landed: Vec<Value>,
    any: bool,
}

impl Landed {
    fn apply(&mut self, s: &mut Session<'_, '_>, now: i64, items: &[Value]) -> Result<(), String> {
        let v = apply_some(s, now, items)?;
        if let Some(l) = v["landed"].as_array() {
            self.landed.extend(l.iter().cloned());
            self.any = true;
        }
        Ok(())
    }

    fn finish(self) -> Value {
        if self.any {
            json!({"landed": self.landed, "foreign": []})
        } else {
            json!({})
        }
    }
}

/// 把子树里的卡移到目标牌组（`deck_delete` 的移卡段）。
///
/// **前身先于后继**：卡的有效牌组按血统继承（`historyFrom`，[crate::store::sync2::config::card_deck_with]）——没有自己
/// 卡级牌组的后继卡跟着前身走。所以移一张卡之前先把它还在子树里的前身移掉（不论前身在不在这一页，最多 256 层），
/// 再按缓存重判：后继已经跟着离开子树的不再单写一条卡级牌组。每张卡单独落、单独收尾，判定读的就是前面那些移动生效
/// 之后的缓存。协议 3 按缓存 rowid 走、逐步提交，碰巧前身先移；按 ID 走时后继常排在前身前面，不这样做就会给后继多写
/// 一条卡级牌组，以后前身再换牌组后继不再跟着走（复核 minor-4）。
struct Mover<'a> {
    sub: &'a str,
    ts: &'a str,
    target: &'a Value,
    now: i64,
}

impl Mover<'_> {
    /// 依次移 [rows]。返回额外移掉的前身张数（不在 [rows] 里、为了「前身先于后继」提前移的）。
    fn move_cards(
        &self,
        s: &mut Session<'_, '_>,
        rows: &[String],
        out: &mut Landed,
    ) -> Result<usize, String> {
        let mut extra = 0;
        let listed: HashSet<&str> = rows.iter().map(String::as_str).collect();
        for c in rows {
            self.move_card(s, c, &listed, &mut Vec::new(), &mut extra, out)?;
        }
        Ok(extra)
    }

    fn move_card(
        &self,
        s: &mut Session<'_, '_>,
        card: &str,
        listed: &HashSet<&str>,
        stack: &mut Vec<String>,
        extra: &mut usize,
        out: &mut Landed,
    ) -> Result<(), String> {
        if !self.in_subtree(s, card)? {
            return Ok(());
        }
        // 血统成环 / 过深（同 `card_deck_with` 的 256 张上限）：不再往上追，就地写。
        if stack.len() < 256 {
            stack.push(card.to_owned());
            let lines = s.lines(EntKind::Card, card)?;
            for p in crate::store::sync2::config::predecessors(&lines) {
                if !stack.contains(&p) && self.in_subtree(s, &p)? {
                    if !listed.contains(p.as_str()) {
                        *extra += 1;
                    }
                    self.move_card(s, &p, listed, stack, extra, out)?;
                }
            }
            stack.pop();
            // 前身移走之后它跟着离开了子树：不单写。
            if !self.in_subtree(s, card)? {
                return Ok(());
            }
        }
        let mut items = Vec::new();
        push_edits(
            s,
            self.ts,
            EntKind::Card,
            &[card.to_owned()],
            KEY_DECK,
            self.target,
            &mut items,
        )?;
        out.apply(s, self.now, &items)
    }

    /// 卡（规范 ID）此刻（收尾之后）的缓存行在子树里。
    fn in_subtree(&self, s: &mut Session<'_, '_>, card: &str) -> Result<bool, String> {
        let col = s.col;
        let ix = s.settled()?;
        let q = format!(
            "SELECT 1 FROM cards c WHERE {} AND c.id = ?3",
            cards_where()
        );
        let mut stmt = ix.t.conn().prepare_cached(&q).map_err(sql)?;
        let mut rows = stmt
            .query(params![col, self.sub, ref_of(card)])
            .map_err(sql)?;
        Ok(rows.next().map_err(sql)?.is_some())
    }
}

/// `deck_delete`（删牌组连同子牌组，分步；协议 3 `deck_delete.rs`）。[req]：`{"now", "deck", "deleteCards"?,
/// "plan"?: true}`，非 `plan` 的步另带 `{"limit"?, "token"?, "deletedAt", "ts"?}`。
///
/// - `plan`：只数（要删的笔记 + 要移的卡），有要删的笔记就打还原点；回包 `{"total", "done": 牌组已不在}`。
/// - 之后每步最多 `limit` 个实体：先删笔记（`deleteCards`），再把子树里的卡移到被删牌组的父牌组（没有则默认牌组），
///   都按 ID 游标往后走（`token`，原样带回）。卡取完的那一步收尾：不带游标重扫（期间放进子树的），再给子树里每个
///   牌组写删除标记，回包 `done: true`。回包另带 `token` / `notes`（这一步删掉的笔记）/ `count`（处理的实体数）。
/// - 默认牌组恒在树里（宿主的「有效牌组」回落到它）：它被挪进这棵子树时不随之删除——它自己和它的卡都不动，收尾时
///   把它挂回顶层；它下面的子牌组照常随子树删除（Anki 删除含 Default 的父牌组同语义）。以前整棵子树连默认牌组一起
///   写了删除标记，树里从此缺默认牌组，按它取排程配置的浏览页空断言（BUG-5209）。
///
/// 每步一个事务（[write]）；子树与目标牌组每步都重读。
pub fn deck_delete(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let now = now_of(req)?;
    let deck_in = req["deck"].as_str().ok_or("deck_delete: missing deck")?;
    let delete_cards = req["deleteCards"] == Value::Bool(true);
    write(t, col, |s| {
        let deck = s.canon_text(deck_in)?;
        let (known, sub, name, parent, held_default) = {
            let tree = s.deck_tree()?;
            if deck == tree.default_deck {
                return Err("deck_delete: the default deck cannot be deleted".into());
            }
            let mut sub = tree.subtree(&deck);
            let before = sub.len();
            sub.retain(|d| *d != tree.default_deck);
            let held_default = (sub.len() != before).then(|| tree.default_deck.clone());
            (
                tree.decks.contains_key(&deck),
                sub,
                full_name(tree, &deck),
                tree.decks
                    .get(&deck)
                    .and_then(|d| d.parent.clone())
                    .unwrap_or_else(|| tree.default_deck.clone()),
                held_default,
            )
        };
        let sub_json = ids_json(&sub);
        if known {
            s.require_caches()?;
        }
        if req["plan"] == Value::Bool(true) {
            let (notes, cards) = if known {
                (
                    if delete_cards {
                        count(s, true, &sub_json)?
                    } else {
                        0
                    },
                    count(s, false, &sub_json)?,
                )
            } else {
                (0, 0)
            };
            if notes > 0 {
                for b in checkpoint_bodies(&name, "bulk_delete") {
                    s.land(b, now)?;
                }
            }
            return Ok(json!({"total": notes + cards, "done": !known}));
        }
        let token = &req["token"];
        let mut note_cursor: Option<String> = token["n"].as_str().map(str::to_owned);
        let mut card_cursor: Option<String> = token["c"].as_str().map(str::to_owned);
        let mut notes: Vec<String> = Vec::new();
        let mut count_done = 0usize;
        let mut done = !known;
        let mut out = Landed::default();
        if known {
            let ts = req["ts"].as_str().unwrap_or("wall").to_owned();
            let deleted_at = req["deletedAt"]
                .as_i64()
                .ok_or("deck_delete: missing deletedAt")?;
            let deleted = json!(deleted_at);
            let target = json!(parent);
            let limit = req["limit"].as_i64().unwrap_or(DEFAULT_LIMIT).max(1);
            let mut budget = limit;
            let mut notes_done = !delete_cards;
            let mv = Mover {
                sub: &sub_json,
                ts: &ts,
                target: &target,
                now,
            };
            if delete_cards {
                let rows = rows_after(s, true, &sub_json, note_cursor.as_deref(), budget)?;
                notes_done = (rows.len() as i64) < budget;
                budget -= rows.len() as i64;
                count_done += rows.len();
                if let Some(last) = rows.last() {
                    note_cursor = Some(last.clone());
                }
                let mut items = Vec::new();
                push_edits(
                    s,
                    &ts,
                    EntKind::Note,
                    &rows,
                    KEY_DELETED,
                    &deleted,
                    &mut items,
                )?;
                out.apply(s, now, &items)?;
                notes.extend(rows);
            }
            let mut moved: Vec<String> = Vec::new();
            let mut cards_done = false;
            if notes_done && budget > 0 {
                let rows = rows_after(s, false, &sub_json, card_cursor.as_deref(), budget)?;
                cards_done = (rows.len() as i64) < budget;
                count_done += rows.len();
                if let Some(last) = rows.last() {
                    card_cursor = Some(last.clone());
                }
                count_done += mv.move_cards(s, &rows, &mut out)?;
                moved = rows;
            }
            if cards_done {
                // 收尾：游标走过之后才进子树的（缓存行按 ID 聚簇，游标之前插进来的行游标看不见），不带游标重扫。这一
                // 步处理过的卡已经逐张收尾、缓存行是新的（[Mover::move_cards] 落之前还会按缓存再判一次）。
                if delete_cards {
                    let seen: HashSet<&str> = notes.iter().map(String::as_str).collect();
                    let late: Vec<String> = rows_after(s, true, &sub_json, None, -1)?
                        .into_iter()
                        .filter(|n| !seen.contains(n.as_str()))
                        .collect();
                    let mut items = Vec::new();
                    push_edits(
                        s,
                        &ts,
                        EntKind::Note,
                        &late,
                        KEY_DELETED,
                        &deleted,
                        &mut items,
                    )?;
                    out.apply(s, now, &items)?;
                    notes.extend(late);
                }
                let seen: HashSet<&str> = moved.iter().map(String::as_str).collect();
                let late: Vec<String> = rows_after(s, false, &sub_json, None, -1)?
                    .into_iter()
                    .filter(|x| !seen.contains(x.as_str()))
                    .collect();
                mv.move_cards(s, &late, &mut out)?;
                let mut items = Vec::new();
                push_edits(
                    s,
                    &ts,
                    EntKind::Deck,
                    &sub,
                    KEY_DELETED,
                    &deleted,
                    &mut items,
                )?;
                // 默认牌组留下、挂回顶层（它原来的祖先这一步都删了）。
                if let Some(default) = &held_default {
                    push_edits(
                        s,
                        &ts,
                        EntKind::Deck,
                        std::slice::from_ref(default),
                        KEY_PARENT,
                        &Value::Null,
                        &mut items,
                    )?;
                }
                out.apply(s, now, &items)?;
                done = true;
            }
        }
        let mut v = out.finish();
        v["done"] = json!(done);
        v["token"] = json!({"n": note_cursor, "c": card_cursor});
        v["notes"] = json!(notes);
        v["count"] = json!(count_done);
        Ok(v)
    })
}

// ---------------------------------------------------------------------- revive_default_deck

/// 默认牌组不变式的开库自愈（BUG-5209）：默认牌组（缓存配置给的规范 ID）带着删除标记时，写 `deleted = null`、
/// `parent = null` 复活并挂回顶层；活着的、或还没有身份记录的（全新库：宿主随后补内置实体）什么都不写。
///
/// 旧版 [deck_delete] 删一个祖先牌组时把挪进它子树的默认牌组连带写了删除标记（现已不这样做），牌组树（只收未删除的
/// 牌组）从此缺默认牌组，而宿主的「有效牌组」与排程配置都回落到它。这里是内核自己的一笔写：经 [apply_in] 落本机
/// 原生日志、HLC 由内核按 `ts: "wall"` 盖，随同步传到别的设备；只动默认牌组自己的两个键，卡与别的牌组一行不碰。
/// 宿主每次开库的 `cache_config_set` 在同一个事务里调它（`dispatch.rs`），不另发命令、宿主也不先读。
///
/// 回包是 [write] 的统一回包，另带 `revived`（这次写了没有）。
pub fn revive_default_deck(t: &Truth<'_>, col: i64, now: i64) -> Result<Value, String> {
    // 先只读判（与牌组树同一份判据，`mod.rs` [super::deck_tree] → `DeckTree::of_views`：有身份记录、视图的删除时刻
    // `da` 非空 = 不在树里）；只看默认牌组自己一个，不拼整棵树。要写才开写会话。绝大多数开库默认牌组活着，不碰写
    // 会话（它要本机身份等）。
    let mut ix = Index::new(t, col);
    let deck = super::default_deck(t, &ix, col)?;
    let r = ref_of(&deck);
    let deleted = match ix.definition(&r)? {
        Some((kind, _, payload)) if kind == EntKind::Deck as i64 => {
            let (lines, _) = ix.class_lines(EntKind::Deck, &r)?;
            !registers::deck_view_of(&payload, &stored(&lines))?["da"].is_null()
        }
        // 还没有身份记录（全新库：宿主随后补内置实体）。
        _ => false,
    };
    if !deleted {
        return Ok(json!({"revived": false}));
    }
    write(t, col, |s| {
        let profile = s.profile.clone();
        let items: Vec<Value> = [KEY_DELETED, KEY_PARENT]
            .into_iter()
            .map(|key| {
                draft(
                    &profile,
                    EntKind::Deck.wire(),
                    &deck,
                    key,
                    &Value::Null,
                    "wall",
                )
            })
            .collect();
        let mut v = apply_some(s, now, &items)?;
        v["revived"] = Value::Bool(true);
        Ok(v)
    })
}

// ---------------------------------------------------------------------- sched

/// 一个排程动作（协议 3 `sched_local.rs` `Action`）。
enum Action {
    Reset { skip_new: bool },
    SetDue { due_day: i64 },
    Undo { log: String },
    Reschedule,
}

/// 卡（规范 ID）所属的笔记（缓存行；没有行 = None）。
fn note_of(s: &mut Session<'_, '_>, card: &str) -> Result<Option<String>, String> {
    let col = s.col;
    let ix = s.settled()?;
    let mut stmt =
        ix.t.conn()
            .prepare_cached("SELECT note_id FROM cards WHERE col = ?1 AND id = ?2")
            .map_err(sql)?;
    let mut rows = stmt.query(params![col, ref_of(card)]).map_err(sql)?;
    match rows.next().map_err(sql)? {
        Some(r) => Ok(Some(r.get::<_, Ref>(0).map_err(sql)?.text())),
        None => Ok(None),
    }
}

/// 牌组子树里 `queue = 'review'` 的卡（规范 ID，升序去重；协议 3 `review_cards_in`）。
fn review_cards_in(s: &mut Session<'_, '_>, deck: &str) -> Result<Vec<String>, String> {
    s.require_caches()?;
    let sub = s.deck_tree()?.subtree(deck);
    let sub_json = ids_json(&sub);
    let col = s.col;
    let ix = s.settled()?;
    let q = format!(
        "SELECT id FROM cards WHERE col = ?1 AND deck_id IN {} AND queue = 'review' ORDER BY id",
        in_ids("?2")
    );
    let mut stmt = ix.t.conn().prepare_cached(&q).map_err(sql)?;
    let rows = stmt
        .query_map(params![col, sub_json], |r| r.get::<_, Ref>(0))
        .map_err(sql)?;
    let mut out: Vec<String> = rows
        .map(|r| r.map(|x| x.text()).map_err(sql))
        .collect::<Result<_, _>>()?;
    out.sort();
    out.dedup();
    Ok(out)
}

/// `sched`（本机手动排程：重置 / 改期 / 撤销 / 按牌组重排；协议 3 `sched_local.rs`）。[req]：
/// `{"now", "at", "utcOff", "rollover", "ts"?, "items": [{"a": "reset"|"setDue"|"undo"|"rescheduleDeck", …}]}`。内核按
/// 此刻的头状态（这张卡当链尾的归属组重放，`cache.rs` `group_rows`）算结果，写一条显式意图的日志。撤销只撤这张卡此刻
/// 最后一条生效的日志，不是就计入 `blocked`。回包另带 `logs`（写下的日志行，重放写回之后的）与 `blocked`。
pub fn sched(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let now = now_of(req)?;
    let at = req["at"].as_i64().ok_or("sched: missing at")?;
    let ts = req["ts"].as_str().unwrap_or("wall").to_owned();
    let day = Day {
        utc_offset_min: req["utcOff"].as_i64().ok_or("sched: missing utcOff")?,
        rollover_hour: req["rollover"].as_i64().ok_or("sched: missing rollover")?,
    };
    let items: &[Value] = req["items"].as_array().map_or(&[], Vec::as_slice);
    write(t, col, |s| {
        let mut actions: Vec<(String, Action)> = Vec::new();
        for it in items {
            let card = |s: &Session<'_, '_>| -> Result<String, String> {
                let c = it["card"].as_str().ok_or("sched: missing card")?;
                s.canon_text(c)
            };
            match it["a"].as_str() {
                Some("reset") => actions.push((
                    card(s)?,
                    Action::Reset {
                        skip_new: it["skipNew"] == Value::Bool(true),
                    },
                )),
                Some("setDue") => actions.push((
                    card(s)?,
                    Action::SetDue {
                        due_day: it["due"].as_i64().ok_or("sched: missing due")?,
                    },
                )),
                Some("undo") => {
                    let log = it["log"].as_str().ok_or("sched: missing log")?;
                    let log = s.canon_text(log)?;
                    actions.push((card(s)?, Action::Undo { log }));
                }
                Some("rescheduleDeck") => {
                    let deck = s.canon_text(it["deck"].as_str().ok_or("sched: missing deck")?)?;
                    for c in review_cards_in(s, &deck)? {
                        actions.push((c, Action::Reschedule));
                    }
                }
                other => return Err(format!("sched: unknown action {other:?}")),
            }
        }
        let profile = s.profile.clone();
        let mut written: Vec<(String, String)> = Vec::new();
        let mut blocked = 0u64;
        for (card, action) in actions {
            // 实体归属闸（`writes_owner.rs`）：别的集合的卡按「没有这张卡」跳过，撤销计入撤不了的条数（同协议 3）。
            if s.foreign(EntKind::Card, &card, &Born::new())? {
                if matches!(action, Action::Undo { .. }) {
                    blocked += 1;
                }
                continue;
            }
            let note = note_of(s, &card)?;
            let rows = s.settled()?.group_rows(&ref_of(&card))?;
            let input: Vec<Row<'_>> = rows
                .iter()
                .map(crate::store::gen4::cache::LogIn::replay_row)
                .collect();
            let head = replay::head(&input)?;
            let (kind, rtype, intent, res, revokes) = match &action {
                Action::Reset { skip_new } => {
                    if *skip_new && head.state.queue == Queue::New {
                        continue;
                    }
                    ("manual", "manual", Intent::Reset, Some(head.reset()), None)
                }
                Action::SetDue { due_day } => (
                    "manual",
                    "manual",
                    Intent::SetDue { due_day: *due_day },
                    Some(head.set_due(*due_day, at, &day)),
                    None,
                ),
                Action::Undo { log } => {
                    if head.last_effective.as_deref() != Some(log.as_str()) {
                        blocked += 1;
                        continue;
                    }
                    ("undo", "manual", Intent::Absolute, None, Some(log.clone()))
                }
                Action::Reschedule => {
                    let deck = s.card_deck(&card, note.as_deref())?;
                    let cfg = s.deck_tree()?.config(&deck);
                    match head.reschedule(&card, &cfg, &day)? {
                        Some(r) => (
                            "reschedule",
                            "rescheduled",
                            Intent::Reschedule,
                            Some(r),
                            None,
                        ),
                        None => continue,
                    }
                }
            };
            let id = Id::new_v7(at.max(0) as u64).text();
            let mut x: Map<String, Value> = Map::new();
            x.insert("id".into(), json!(id));
            x.insert("p".into(), json!(profile));
            x.insert("card".into(), json!(card));
            x.insert("kind".into(), json!(kind));
            if let Some(r) = &revokes {
                x.insert("revokes".into(), json!(r));
            }
            x.insert("at".into(), json!(at));
            x.insert("ts".into(), json!(ts));
            x.insert("origin".into(), json!("fushi"));
            x.insert("rtype".into(), json!(rtype));
            x.insert("utcOff".into(), json!(day.utc_offset_min));
            x.insert("rollover".into(), json!(day.rollover_hour));
            if let Some(r) = &res {
                x.insert("res".into(), r.to_json());
            }
            x.insert("fv".into(), json!(1));
            let mut body = log_body_of(&Value::Object(x), note.as_deref(), None, None)?;
            body.intent = intent;
            s.stamp_config(&mut body)?;
            s.land(Body::Log(body), now)?;
            written.push((card, id));
        }
        // 写下的日志行（重放写回之后，与读命令 `logs` 同一份）。
        let mut logs = Vec::with_capacity(written.len());
        for (card, id) in &written {
            let ix = s.settled()?;
            let row = ix
                .replayed_card_logs(&ref_of(card))?
                .into_iter()
                .find(|l| {
                    serde_json::from_str::<Value>(&l.json)
                        .ok()
                        .and_then(|v| v["id"].as_str().map(|x| x == id))
                        .unwrap_or(false)
                })
                .ok_or_else(|| format!("sched: log {id} vanished after landing"))?;
            logs.push(row_with_profile(&row.json, &profile));
        }
        Ok(json!({"logs": logs, "blocked": blocked}))
    })
}
