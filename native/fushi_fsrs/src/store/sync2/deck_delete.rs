//! 删牌组（连同全部子牌组）：Dart 只发**意图**（哪个牌组、要不要连笔记一起删），内核自己找出要动的笔记与卡、判
//! 「值没变不写」、落修改记录。以前 Dart 先读两遍缓存表（`_notesOnlyInDecks` / `_cardIdsInDecks`）、逐块读现值、
//! 组好修改记录再交给 `apply`，读与写之间隔着好几次往返。
//!
//! 一条命令做不完一个大牌组（几万张卡在一个 SAVEPOINT 里会把排队的作答卡住）：命令**分步**，每步自己一个
//! SAVEPOINT（store/ffi.rs `local_write`：命令本体、缓存刷新、本机状态行一起落），步与步之间别的写入照常插进来。
//!
//! - 第一步 `plan: true`：只数（要删的笔记 + 要移的卡），有要删的笔记就顺手打还原点（设计 §10.2：批量删除之前自动
//!   打），不动别的。宿主拿到总数先报一次进度，再发后面的步。
//! - 之后每步最多处理 `limit` 个实体：先删笔记（`deleteCards` 时：卡全在子树里、还没删的笔记），再把子树里的卡移到
//!   被删牌组的父牌组（没有父牌组则到默认牌组）；都按缓存表的 rowid 游标往后走（`token`，宿主原样带回来）。卡取完的
//!   那一步接着**收尾**：不带游标重扫一遍（期间别的写入放进子树的笔记 / 卡），再给此刻子树里的每个牌组写删除标记，
//!   回包 `done: true`。子树、目标牌组每步都重读：分步期间建的子牌组、挪走的父牌组都算数。
//!
//! 每条写入都是 [super::apply_local_on] 的一项（`clk: "t"`）：操作的字节、旧版时钟每条走一步，都与逐条 `editField`
//! 相同——同步协议、段格式、srs.db schema 都不变。卡按缓存表的 rowid 序（以前 Dart 那次表扫描的顺序），牌组按
//! [config::DeckTree::subtree] 的顺序。

use std::collections::HashSet;

use rusqlite::{Connection, params};
use serde_json::{Value, json};

use super::{LegacyApply, append_on, apply_local_on, checkpoint_bodies, config, sql};
use crate::registers;

/// Dart `SrsFieldKeys.deleted`。
const KEY_DELETED: &str = "deleted";
/// Dart `SrsFieldKeys.cardDeck`。
const KEY_CARD_DECK: &str = "deck";

/// 一步最多处理的实体数（宿主没给 `limit` 时）。
const DEFAULT_LIMIT: i64 = 500;

/// 还没删、且卡全都归在 [sub]（JSON 数组，牌组 ID）这些牌组下的笔记：有卡在别的牌组的不算（删笔记会连带那些卡）。
const NOTES_WHERE: &str = "n.profile_uid = srs_id(?1) AND n.deleted_at IS NULL \
     AND EXISTS (SELECT 1 FROM srs_cards_cache c WHERE c.note_id = n.id \
                 AND c.deck_id IN (SELECT srs_id(value) FROM json_each(?2))) \
     AND NOT EXISTS (SELECT 1 FROM srs_cards_cache c WHERE c.note_id = n.id \
                     AND c.deck_id NOT IN (SELECT srs_id(value) FROM json_each(?2)))";

/// 缓存里归在 [sub] 这些牌组下的卡（含隐藏的：恢复笔记后卡不该落在已删除的牌组里）。
const CARDS_WHERE: &str = "c.deck_id IN (SELECT srs_id(value) FROM json_each(?1))";

/// `(id, rowid)`：rowid 在 [after] 之后的至多 [limit] 条笔记（负数 = 不限）。
fn note_rows(
    c: &Connection,
    profile: &str,
    sub: &str,
    after: i64,
    limit: i64,
) -> Result<Vec<(String, i64)>, String> {
    c.prepare_cached(&format!(
        "SELECT srs_idt(n.id) AS id, n.rowid FROM srs_notes_cache n WHERE {NOTES_WHERE} \
         AND n.rowid > ?3 ORDER BY n.rowid LIMIT ?4"
    ))
    .map_err(sql)?
    .query_map(params![profile, sub, after, limit], |r| {
        Ok((r.get(0)?, r.get(1)?))
    })
    .map_err(sql)?
    .collect::<Result<Vec<_>, _>>()
    .map_err(sql)
}

/// `(id, rowid)`：rowid 在 [after] 之后的至多 [limit] 张卡（负数 = 不限）。
fn card_rows(
    c: &Connection,
    sub: &str,
    after: i64,
    limit: i64,
) -> Result<Vec<(String, i64)>, String> {
    c.prepare_cached(&format!(
        "SELECT srs_idt(c.id) AS id, c.rowid FROM srs_cards_cache c WHERE {CARDS_WHERE} \
         AND c.rowid > ?2 ORDER BY c.rowid LIMIT ?3"
    ))
    .map_err(sql)?
    .query_map(params![sub, after, limit], |r| Ok((r.get(0)?, r.get(1)?)))
    .map_err(sql)?
    .collect::<Result<Vec<_>, _>>()
    .map_err(sql)
}

/// 「父::子」全名（Dart `SrsDeckTree.fullName`；还原点的名字）。
fn full_name(tree: &config::DeckTree, id: &str) -> String {
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

/// 给 [ids] 每个实体的 [key] 写 [value] 的 `apply` 输入项，值没变的跳过（[registers::write_is_noop]）。项的形状就是
/// Dart `_applyInput` 为一条修改记录草稿发的那一项。
#[allow(clippy::too_many_arguments)]
fn push_edits(
    c: &Connection,
    profile: &str,
    ts: &str,
    kind: &str,
    ids: &[String],
    key: &str,
    value: &Value,
    items: &mut Vec<Value>,
) -> Result<(), String> {
    let edits = config::edits_of(c, kind, ids)?;
    let none = Vec::new();
    for id in ids {
        let stored = config::stored(edits.get(id).unwrap_or(&none));
        if registers::write_is_noop(&stored, key, value)? {
            continue;
        }
        items.push(json!({
            "e": {"t": "edit", "x": {"p": profile, "k": kind, "e": id, "f": key, "v": value, "ts": ts}},
            "note": Value::Null,
            "clk": "t",
        }));
    }
    Ok(())
}

/// `deck_delete` 的本体（见文件头）：在调用方的写连接、调用方开的 SAVEPOINT 里做。[req]：
/// `{"deck", "deleteCards"?, "plan"?: true}`，非 `plan` 的步另带
/// `{"limit"?, "token"?, "deletedAt": 笔记删除标记的值, "tickNow", "ts": "anchored"|"wall", "legacyDevice"}`。
///
/// 回包与 `apply` 同形（`marks` / `replayed` / `changed` / `purged`，Dart 照样接进修订号与缓存），另带：
/// - `plan`：`{"total": 要删的笔记数 + 要移的卡数, "done": 牌组已不在}`；
/// - 其余：`{"done", "token", "notes": [这一步删掉的笔记], "count": 这一步按游标处理的实体数（进度）}`。
pub(crate) fn deck_delete_on(
    c: &Connection,
    profile: &str,
    now: i64,
    req: &Value,
) -> Result<Value, String> {
    let deck = req["deck"].as_str().ok_or("deck_delete: missing deck")?;
    let delete_cards = req["deleteCards"] == Value::Bool(true);
    let tree = config::DeckTree::load(c, profile)?;
    if deck == tree.default_deck {
        return Err("deck_delete: the default deck cannot be deleted".into());
    }
    // 牌组已不在（别处删掉了、或分步期间被另一次删除收了尾）：没有要做的。
    let known = tree.decks.contains_key(deck);
    let sub = tree.subtree(deck);
    let sub_json = Value::from(sub.clone()).to_string();
    if req["plan"] == Value::Bool(true) {
        let count = |from: &str, args: &[&dyn rusqlite::ToSql]| -> Result<i64, String> {
            c.prepare_cached(&format!("SELECT COUNT(*) FROM {from}"))
                .map_err(sql)?
                .query_row(args, |r| r.get(0))
                .map_err(sql)
        };
        let (notes, cards) = if known {
            (
                if delete_cards {
                    count(
                        &format!("srs_notes_cache n WHERE {NOTES_WHERE}"),
                        &[&profile, &sub_json],
                    )?
                } else {
                    0
                },
                count(
                    &format!("srs_cards_cache c WHERE {CARDS_WHERE}"),
                    &[&sub_json],
                )?,
            )
        } else {
            (0, 0)
        };
        let bodies = if notes > 0 {
            checkpoint_bodies(&full_name(&tree, deck), "bulk_delete")
        } else {
            Vec::new()
        };
        let mut v = append_on(c, profile, now, &bodies)?;
        v["total"] = json!(notes + cards);
        v["done"] = json!(!known);
        return Ok(v);
    }
    let legacy = LegacyApply {
        device: req["legacyDevice"]
            .as_str()
            .ok_or("deck_delete: missing legacyDevice")?,
        recv_now: None,
        tick_now: Some(
            req["tickNow"]
                .as_i64()
                .ok_or("deck_delete: missing tickNow")?,
        ),
        stamps: false,
    };
    let (mut note_cursor, mut card_cursor) = (
        req["token"]["n"].as_i64().unwrap_or(0),
        req["token"]["c"].as_i64().unwrap_or(0),
    );
    let mut items: Vec<Value> = Vec::new();
    let mut notes: Vec<String> = Vec::new();
    let mut count = 0usize;
    let mut done = !known;
    if known {
        let ts = req["ts"].as_str().unwrap_or("wall");
        let deleted_at = json!(
            req["deletedAt"]
                .as_i64()
                .ok_or("deck_delete: missing deletedAt")?
        );
        let target = json!(
            tree.decks[deck]
                .parent
                .clone()
                .unwrap_or_else(|| tree.default_deck.clone())
        );
        let limit = req["limit"].as_i64().unwrap_or(DEFAULT_LIMIT).max(1);
        let mut budget = limit;
        let ids = |rows: &[(String, i64)]| -> Vec<String> {
            rows.iter().map(|(id, _)| id.clone()).collect()
        };
        // 笔记在前（进度里笔记数在前）：删掉的笔记的卡已隐藏，之后照样移走。
        let mut notes_done = !delete_cards;
        if delete_cards {
            let rows = note_rows(c, profile, &sub_json, note_cursor, budget)?;
            notes_done = (rows.len() as i64) < budget;
            budget -= rows.len() as i64;
            count += rows.len();
            if let Some((_, rowid)) = rows.last() {
                note_cursor = *rowid;
            }
            let chunk = ids(&rows);
            push_edits(
                c,
                profile,
                ts,
                "note",
                &chunk,
                KEY_DELETED,
                &deleted_at,
                &mut items,
            )?;
            notes.extend(chunk);
        }
        let mut moved: Vec<String> = Vec::new();
        let mut cards_done = false;
        if notes_done && budget > 0 {
            let rows = card_rows(c, &sub_json, card_cursor, budget)?;
            cards_done = (rows.len() as i64) < budget;
            count += rows.len();
            if let Some((_, rowid)) = rows.last() {
                card_cursor = *rowid;
            }
            moved = ids(&rows);
            push_edits(
                c,
                profile,
                ts,
                "card",
                &moved,
                KEY_CARD_DECK,
                &target,
                &mut items,
            )?;
        }
        if cards_done {
            // 收尾：游标走过之后才进子树的笔记 / 卡（别的写入在步与步之间放进来的；缓存行原地更新，rowid 不变，所以
            // 不带游标重扫）。这一步里刚处理过的缓存行还是旧的，按 ID 跳过。
            if delete_cards {
                let seen: HashSet<&str> = notes.iter().map(String::as_str).collect();
                let late: Vec<String> = ids(&note_rows(c, profile, &sub_json, 0, -1)?)
                    .into_iter()
                    .filter(|n| !seen.contains(n.as_str()))
                    .collect();
                push_edits(
                    c,
                    profile,
                    ts,
                    "note",
                    &late,
                    KEY_DELETED,
                    &deleted_at,
                    &mut items,
                )?;
                notes.extend(late);
            }
            let seen: HashSet<&str> = moved.iter().map(String::as_str).collect();
            let late: Vec<String> = ids(&card_rows(c, &sub_json, 0, -1)?)
                .into_iter()
                .filter(|x| !seen.contains(x.as_str()))
                .collect();
            push_edits(
                c,
                profile,
                ts,
                "card",
                &late,
                KEY_CARD_DECK,
                &target,
                &mut items,
            )?;
            // 卡都移完了，才给子树里每个牌组写删除标记（中途被杀时已提交的步留在库里，再删一次即补齐）。
            push_edits(
                c,
                profile,
                ts,
                "deck",
                &sub,
                KEY_DELETED,
                &json!(legacy.tick_now),
                &mut items,
            )?;
            done = true;
        }
    }
    let mut v = apply_local_on(c, profile, now, &items, Some(&legacy))?;
    v["done"] = json!(done);
    v["token"] = json!({"n": note_cursor, "c": card_cursor});
    v["notes"] = json!(notes);
    v["count"] = json!(count);
    Ok(v)
}
