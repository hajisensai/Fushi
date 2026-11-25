//! `change` 的换类型段（请求带 `retype`）：一批笔记换笔记类型（字段按映射搬、旧卡经前身链接把复习历史交给新卡）+
//! 逐条「遗漏字段补迁」（目标字段从没写过、为空，按候选源字段的优先顺序取第一个有内容的），**由内核逐条笔记读现值、
//! 算、写**。宿主只给类型层面的计划（几十个 ID），不再给逐条笔记的修改记录。
//!
//! 为什么在内核里做（BUG-5176）：以前 Dart 把这批笔记整批物化成视图（含每个字段的全部修改记录），据此算出每条笔记
//! 的全部字段值与卡片链接，攒成一个修改记录列表，再编码成一个 JSON blob 交给 `change`——大牌组在 iPad 上 Dart 堆
//! 直接 Out of Memory。现在逐块（[CHUNK] 条笔记）读、算、落，峰值只与一块的大小有关；整段仍在 `change` 的那一个事务
//! 里，任何一步失败整次改动都不落库（一次迁移一个还原点不变）。
//!
//! 判定与 Dart 逐条相同（那边仍是预演的口径）：
//! - 换类型：`fushi_srs/lib/src/note_type_ops.dart` `srsPlanNoteTypeChange`——类型键写成目标类型；目标类型的每个字段
//!   写映射来的值（源字段的现值，没映射 = 空串），与现值相同的不写；旧卡按模板映射 / cloze 序号接到新卡上。
//! - 补迁：`fushi_engine/lib/srs/srs_legacy_lapis_migration.dart` `srsPlanLapisFieldFill`——目标字段有修改记录（或这次
//!   换类型刚写过）就是写过，不补；有内容的不补；否则取候选里第一个现值有内容（Dart `trim()` 口径）的。
//!
//! 请求 `retype`：
//! ```json
//! {"notes": [笔记 ID...],
//!  "from": {"id": 类型, "cloze": bool, "templates": [模板 ID...]} | null,
//!  "to": {"id": 类型, "cloze": bool, "templates": [模板 ID...], "fields": [字段 ID...]},
//!  "fieldMap": {目标字段: 源字段 | null}, "templateMap": {目标模板: 源模板 | null},
//!  "fill": {目标字段: [候选源字段...]}}
//! ```
//! `from` 为 null = 只补迁不换类型：当前不是 `to` 类型的笔记、已删除的笔记跳过。给了 `from` 时笔记必须存在且是
//! `from` 类型（否则报错、整笔回滚）；已删除的笔记照样换类型、不补迁（Dart 同口径）。
//!
//! 回包：`retyped`（换了类型的笔记数）、`filled`（补了至少一个字段的笔记数）。这一段落下的修改记录不进回包 `edits`
//! （[Session::set_echo_edits]）。

use std::collections::{HashMap, HashSet};

use serde_json::{Map, Value, json};

use super::writes::{ApplyOpts, Origin, Session, apply_in, draft, stored};
use super::writes_intent::dart_blank;
use crate::registers;
use crate::sync2::op::EntKind;

/// 一块的笔记数：读、算、落一块，再下一块。
const CHUNK: usize = 200;

/// Dart `SrsFieldKeys.noteType` / `noteField` / `cardHistoryFromPrefix`。
const KEY_NOTE_TYPE: &str = "noteType";
const HISTORY_FROM: &str = "historyFrom/";

fn field_key(id: &str) -> String {
    format!("f/{id}")
}

/// 一个笔记类型里换类型要用的部分（ID 一律规范形）。
struct TypeSpec {
    id: String,
    cloze: bool,
    templates: Vec<String>,
}

/// 解析好的 `retype`（ID 一律规范形）。
struct Plan {
    notes: Vec<String>,
    from: Option<TypeSpec>,
    to: TypeSpec,
    /// 目标字段（目标类型的字段顺序）。
    to_fields: Vec<String>,
    field_map: HashMap<String, Option<String>>,
    template_map: HashMap<String, Option<String>>,
    /// (目标字段, 候选源字段按优先顺序)，目标类型的字段顺序；没有候选的不列。
    fill: Vec<(String, Vec<String>)>,
}

fn strings(v: &Value, what: &str) -> Result<Vec<String>, String> {
    v.as_array()
        .ok_or_else(|| format!("change.retype: missing {what}"))?
        .iter()
        .map(|x| {
            x.as_str()
                .map(str::to_owned)
                .ok_or_else(|| format!("change.retype: {what} must be strings"))
        })
        .collect()
}

fn opt_map(
    s: &Session<'_, '_>,
    v: &Value,
    what: &str,
) -> Result<HashMap<String, Option<String>>, String> {
    let empty = Map::new();
    let m = match v {
        Value::Null => &empty,
        Value::Object(m) => m,
        _ => return Err(format!("change.retype: {what} must be an object")),
    };
    let mut out = HashMap::new();
    for (k, x) in m {
        let src = match x {
            Value::Null => None,
            Value::String(id) => Some(s.canon_text(id)?),
            _ => {
                return Err(format!(
                    "change.retype: {what} values must be strings or null"
                ));
            }
        };
        out.insert(s.canon_text(k)?, src);
    }
    Ok(out)
}

fn type_spec(s: &Session<'_, '_>, v: &Value, what: &str) -> Result<TypeSpec, String> {
    Ok(TypeSpec {
        id: s.canon_text(
            v["id"]
                .as_str()
                .ok_or_else(|| format!("change.retype: missing {what}.id"))?,
        )?,
        cloze: v["cloze"].as_bool().unwrap_or(false),
        templates: strings(&v["templates"], &format!("{what}.templates"))?
            .iter()
            .map(|t| s.canon_text(t))
            .collect::<Result<_, _>>()?,
    })
}

fn parse(s: &Session<'_, '_>, r: &Value) -> Result<Plan, String> {
    let mut seen: HashSet<String> = HashSet::new();
    let notes: Vec<String> = strings(&r["notes"], "notes")?
        .into_iter()
        .filter(|n| seen.insert(n.clone()))
        .collect();
    let from = match &r["from"] {
        Value::Null => None,
        v => Some(type_spec(s, v, "from")?),
    };
    let to = type_spec(s, &r["to"], "to")?;
    let to_fields: Vec<String> = strings(&r["to"]["fields"], "to.fields")?
        .iter()
        .map(|f| s.canon_text(f))
        .collect::<Result<_, _>>()?;
    let mut fill_by: HashMap<String, Vec<String>> = HashMap::new();
    match &r["fill"] {
        Value::Null => {}
        Value::Object(m) => {
            for (k, v) in m {
                let c: Vec<String> = strings(v, "fill candidates")?
                    .iter()
                    .map(|f| s.canon_text(f))
                    .collect::<Result<_, _>>()?;
                fill_by.insert(s.canon_text(k)?, c);
            }
        }
        _ => return Err("change.retype: fill must be an object".into()),
    }
    let fill = to_fields
        .iter()
        .filter_map(|f| {
            fill_by
                .remove(f)
                .filter(|c| !c.is_empty())
                .map(|c| (f.clone(), c))
        })
        .collect();
    Ok(Plan {
        notes,
        from,
        field_map: opt_map(s, &r["fieldMap"], "fieldMap")?,
        template_map: opt_map(s, &r["templateMap"], "templateMap")?,
        to,
        to_fields,
        fill,
    })
}

/// 一条笔记的卡（[Session::note_cards] 的一行）里换类型用得到的部分。
struct OldCard {
    card: String,
    template: String,
    ord: i64,
}

/// 新卡 → 旧卡（Dart `srsPlanNoteTypeChange` 的卡片那一半，逐分支同序）。新卡 ID 与旧卡相同（换回原类型）的不链；
/// 一张旧卡只交给一张新卡；同一张新卡第二次被链时后者为准（Dart 的 Map 赋值口径）。
fn card_links(
    note: &str,
    from: &TypeSpec,
    to: &TypeSpec,
    template_map: &HashMap<String, Option<String>>,
    cards: &[OldCard],
) -> Result<Vec<(String, String)>, String> {
    let mut links: Vec<(String, String)> = Vec::new();
    let mut linked: HashSet<String> = HashSet::new();
    let mut link = |tpl: &str, ord: i64, old: &OldCard| -> Result<(), String> {
        let new_card = registers::card_id(note, tpl, ord)?;
        if new_card == old.card || linked.contains(&old.card) {
            return Ok(());
        }
        match links.iter_mut().find(|(n, _)| *n == new_card) {
            Some(slot) => slot.1 = old.card.clone(),
            None => links.push((new_card, old.card.clone())),
        }
        linked.insert(old.card.clone());
        Ok(())
    };
    let mine: Vec<&OldCard> = cards
        .iter()
        .filter(|c| from.templates.contains(&c.template))
        .collect();
    if !from.cloze && !to.cloze {
        for t in &to.templates {
            let Some(Some(old_tpl)) = template_map.get(t) else {
                continue;
            };
            if let Some(old) = mine.iter().find(|c| &c.template == old_tpl) {
                link(t, 0, old)?;
            }
        }
    } else if !from.cloze && to.cloze {
        if let Some(cloze) = to.templates.first() {
            for c in &mine {
                let pos = from
                    .templates
                    .iter()
                    .position(|t| *t == c.template)
                    .map_or(-1, |p| p as i64);
                link(cloze, pos + 1, c)?;
            }
        }
    } else if from.cloze && to.cloze {
        if let Some(cloze) = to.templates.first() {
            for c in &mine {
                link(cloze, c.ord, c)?;
            }
        }
    } else {
        for c in &mine {
            let pos = c.ord - 1;
            if pos >= 0 && (pos as usize) < to.templates.len() {
                link(&to.templates[pos as usize], 0, c)?;
            }
        }
    }
    Ok(links)
}

/// 换类型段的本体（见文件头），在 `change` 的 [Session] 里、调用方修改记录之后、移牌组之前做。
pub(super) fn retype(s: &mut Session<'_, '_>, now: i64, req: &Value) -> Result<Value, String> {
    let plan = parse(s, &req["retype"])?;
    let ts = req["ts"].as_str().unwrap_or("wall").to_owned();
    let profile = s.profile.clone();
    let fill_keys: Vec<String> = plan
        .fill
        .iter()
        .map(|(t, _)| s.ix().canonical_key(&field_key(t)))
        .collect::<Result<_, _>>()?;
    let chg = |mut d: Value| {
        d["chg"] = Value::Bool(true);
        d
    };
    let (mut retyped, mut filled) = (0i64, 0i64);
    s.set_echo_edits(false);
    for chunk in plan.notes.chunks(CHUNK) {
        let mut items: Vec<Value> = Vec::new();
        for id in chunk {
            let Some(info) = s.note_info(id)? else {
                if plan.from.is_some() {
                    return Err(format!("change.retype: note {id} not found"));
                }
                continue;
            };
            let note_type = s.canon_text(&info.note_type)?;
            // 这次换类型写下的字段值（目标字段 → 值）：补迁按「换完之后」的值判。
            let mut mapped: HashMap<&str, String> = HashMap::new();
            match &plan.from {
                Some(from) => {
                    if note_type != from.id {
                        return Err(format!(
                            "change.retype: note {id} is not of note type {}",
                            from.id
                        ));
                    }
                    if from.id != plan.to.id {
                        items.push(chg(draft(
                            &profile,
                            "note",
                            &info.id,
                            KEY_NOTE_TYPE,
                            &json!(plan.to.id),
                            &ts,
                        )));
                        for f in &plan.to_fields {
                            let want = match plan.field_map.get(f) {
                                Some(Some(src)) => info.field(src),
                                _ => "",
                            };
                            if want != info.field(f) {
                                items.push(chg(draft(
                                    &profile,
                                    "note",
                                    &info.id,
                                    &field_key(f),
                                    &json!(want),
                                    &ts,
                                )));
                                mapped.insert(f.as_str(), want.to_owned());
                            }
                        }
                        let cards: Vec<OldCard> = s
                            .note_cards(&info.id)?
                            .into_iter()
                            .map(|c| OldCard {
                                card: c.card,
                                template: c.template,
                                ord: c.ord,
                            })
                            .collect();
                        for (new_card, old) in
                            card_links(&info.id, from, &plan.to, &plan.template_map, &cards)?
                        {
                            items.push(chg(draft(
                                &profile,
                                "card",
                                &new_card,
                                &format!("{HISTORY_FROM}{old}"),
                                &Value::Bool(true),
                                &ts,
                            )));
                        }
                        retyped += 1;
                    }
                }
                None => {
                    if note_type != plan.to.id || info.deleted_at.is_some() {
                        continue;
                    }
                }
            }
            if plan.fill.is_empty() || info.deleted_at.is_some() {
                continue;
            }
            let lines = s.lines(EntKind::Note, &info.id)?;
            let authored = registers::has_registers(&stored(&lines), &fill_keys)?;
            let current = |f: &str| -> &str {
                match mapped.get(f) {
                    Some(v) => v.as_str(),
                    None => info.field(f),
                }
            };
            let mut wrote = false;
            let mut fills: Vec<(String, String)> = Vec::new();
            for ((t, cands), had) in plan.fill.iter().zip(&authored) {
                if *had || mapped.contains_key(t.as_str()) || !dart_blank(current(t)) {
                    continue;
                }
                if let Some(v) = cands.iter().map(|c| current(c)).find(|v| !dart_blank(v)) {
                    fills.push((t.clone(), v.to_owned()));
                }
            }
            for (t, v) in fills {
                items.push(chg(draft(
                    &profile,
                    "note",
                    &info.id,
                    &field_key(&t),
                    &json!(v),
                    &ts,
                )));
                wrote = true;
            }
            if wrote {
                filled += 1;
            }
        }
        if !items.is_empty() {
            apply_in(
                s,
                now,
                &items,
                ApplyOpts {
                    chg: true,
                    compact: true,
                    origin: Origin::Synthesized,
                },
            )?;
        }
    }
    s.set_echo_edits(true);
    Ok(json!({"retyped": retyped, "filled": filled}))
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOTE: &str = "0193a1b2-0000-7000-8000-000000000001";

    fn ty(cloze: bool, templates: &[&str]) -> TypeSpec {
        TypeSpec {
            id: "t".into(),
            cloze,
            templates: templates.iter().map(|t| (*t).to_owned()).collect(),
        }
    }

    fn old(template: &str, ord: i64) -> OldCard {
        OldCard {
            card: registers::card_id(NOTE, template, ord).unwrap(),
            template: template.into(),
            ord,
        }
    }

    fn new(template: &str, ord: i64) -> String {
        registers::card_id(NOTE, template, ord).unwrap()
    }

    /// 四个分支与 Dart `srsPlanNoteTypeChange` 逐条相同：普通 → 普通按模板映射、普通 → 填空按模板位置、填空 → 填空按
    /// 序号、填空 → 普通按序号取第 N 个模板；不属于源类型模板的卡不动，与旧卡 ID 相同的不链。
    #[test]
    fn card_links_follow_dart_branches() {
        let cards = [old("a", 0), old("b", 0), old("stray", 0)];
        let map: HashMap<String, Option<String>> = [
            ("x".to_owned(), Some("b".to_owned())),
            ("y".to_owned(), None),
            ("a".to_owned(), Some("a".to_owned())),
        ]
        .into();
        let l = card_links(
            NOTE,
            &ty(false, &["a", "b"]),
            &ty(false, &["x", "y", "a"]),
            &map,
            &cards,
        )
        .unwrap();
        assert_eq!(l, vec![(new("x", 0), cards[1].card.clone())]);

        let l = card_links(
            NOTE,
            &ty(false, &["a", "b"]),
            &ty(true, &["c"]),
            &map,
            &cards,
        )
        .unwrap();
        assert_eq!(
            l,
            vec![
                (new("c", 1), cards[0].card.clone()),
                (new("c", 2), cards[1].card.clone()),
            ]
        );

        let cz = [old("c", 1), old("c", 3)];
        let l = card_links(NOTE, &ty(true, &["c"]), &ty(true, &["d"]), &map, &cz).unwrap();
        assert_eq!(
            l,
            vec![
                (new("d", 1), cz[0].card.clone()),
                (new("d", 3), cz[1].card.clone())
            ]
        );

        let l = card_links(NOTE, &ty(true, &["c"]), &ty(false, &["p", "q"]), &map, &cz).unwrap();
        assert_eq!(l, vec![(new("p", 0), cz[0].card.clone())]);
    }
}
