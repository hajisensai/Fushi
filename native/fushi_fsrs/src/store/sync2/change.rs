//! 结构性改动的意图命令 `change`（更改笔记类型、删除重复模板、旧 Lapis 迁移）：还原点 + 一批修改记录
//! （+ 把这些笔记连同它们此刻可见的卡移到一个牌组），**一条命令、一笔**。
//!
//! 以前这是 Dart 的两三条命令：先 `checkpoint`，再 `apply`；旧 Lapis 迁移还要再读一遍「换完类型之后」的卡片缓存行、
//! 第三次 `apply` 把卡移走——三步靠 Dart 在写连接上开的一笔 Drift 事务包成原子的（守卫里的 Join）。现在：
//!
//! 1. 命令本体（[change_on]）：打还原点、落这批修改记录（[super::apply_local_on]，Dart 基于改动前的状态一次算好）；
//! 2. 分发器紧接着刷新缓存（store/ffi.rs `local_write`）——换了类型的笔记的新卡在这里生成；
//! 3. 请求带 `move` 时（[move_notes_on]）：按刷新后的缓存行找这些笔记的可见卡，连同笔记的首选牌组一起移过去，再刷新
//!    一次缓存。「换完类型之后有哪些可见卡、各在哪个牌组」只有内核的缓存推导知道，所以这一段在内核里做。
//!
//! 三段同在分发器开的那一个 SAVEPOINT 里：任何一段出错整笔回滚，笔记仍是旧类型、仍在原牌组。每条写入都是
//! `apply` 的一项（`clk: "t"`），操作的字节、顺序、旧版时钟的推进都与以前那几条命令逐条相同。

use std::collections::{BTreeSet, HashSet};

use rusqlite::{Connection, params};
use serde_json::{Value, json};

use super::{LegacyApply, append_on, apply_local_on, checkpoint_bodies, config, deck_delete, sql};
use crate::registers;

/// Dart `SrsFieldKeys.noteDeck` / `SrsFieldKeys.cardDeck`。
const KEY_DECK: &str = "deck";

/// 请求里的旧版时钟部分（两段共用）。
fn legacy_of(req: &Value) -> Result<LegacyApply<'_>, String> {
    Ok(LegacyApply {
        device: req["legacyDevice"]
            .as_str()
            .ok_or("change: missing legacyDevice")?,
        recv_now: None,
        tick_now: req["tickNow"].as_i64(),
        stamps: false,
    })
}

/// 测试注入：请求带 `failAfter: <段>` 时在做完那一段之后报错（验证整笔回滚；生产调用方不带）。
fn fail_after(req: &Value, stage: &str) -> Result<(), String> {
    if req["failAfter"].as_str() == Some(stage) {
        return Err(format!("change: injected failure after {stage}"));
    }
    Ok(())
}

/// 把后一段的结果 [b]（`apply` 同形）并进 [a]，合起来就是「两条命令各自的结果」加在一起：`marks` 的计数相加、实体
/// 集合取并集；`changed` / `purged` 与逐项的数组接上（Dart 对 `changed` 的每一项推进一次修订号，两段各算各的）；其余
/// 取后一段的。
pub(crate) fn merge_results(a: &mut Value, b: Value) {
    let Value::Object(b) = b else { return };
    if !a.is_object() {
        *a = json!({});
    }
    let union = |x: &Value, y: &Value| -> Value {
        let all: BTreeSet<&str> = [x, y]
            .into_iter()
            .flat_map(|v| v.as_array().into_iter().flatten())
            .filter_map(Value::as_str)
            .collect();
        json!(all)
    };
    let concat = |x: &Value, y: &Value| -> Value {
        let mut out: Vec<Value> = x.as_array().cloned().unwrap_or_default();
        out.extend(y.as_array().cloned().unwrap_or_default());
        Value::Array(out)
    };
    for (k, v) in b {
        let k = k.as_str();
        match k {
            "marks" => {
                let mut m = a["marks"].take();
                if !m.is_object() {
                    m = json!({});
                }
                for (mk, mv) in v.as_object().into_iter().flatten() {
                    let mk = mk.as_str();
                    m[mk] = match mv {
                        Value::Array(_) => union(&m[mk], mv),
                        _ => json!(m[mk].as_i64().unwrap_or(0) + mv.as_i64().unwrap_or(0)),
                    };
                }
                a["marks"] = m;
            }
            "replayed" => a[k] = union(&a[k], &v),
            "changed" | "purged" | "landed" | "diagnostics" => a[k] = concat(&a[k], &v),
            _ => a[k] = v,
        }
    }
}

/// `change` 的第一段（见文件头）：还原点 + 这批修改记录。[req]：
/// `{"checkpoint"?: {"name", "reason"}, "legacyDevice", "tickNow", "move"?: {"deck", "notes"}, "ts"?}`，输入项同 `apply`
/// （[items]）；标了 `chg` 的项值没变的先筛掉（changing.rs，就地）。筛完没有输入项就不走 `apply`（与以前「没有要写的
/// 就不发命令」相同：旧版时钟不动）。
pub(crate) fn change_on(
    c: &Connection,
    profile: &str,
    now: i64,
    req: &Value,
    items: &mut Vec<Value>,
) -> Result<Value, String> {
    let mut v = match req.get("checkpoint").filter(|cp| cp.is_object()) {
        Some(cp) => append_on(
            c,
            profile,
            now,
            &checkpoint_bodies(
                cp["name"]
                    .as_str()
                    .ok_or("change: missing checkpoint.name")?,
                cp["reason"]
                    .as_str()
                    .ok_or("change: missing checkpoint.reason")?,
            ),
        )?,
        None => json!({}),
    };
    super::changing::drop_noops(c, items)?;
    if !items.is_empty() {
        merge_results(
            &mut v,
            apply_local_on(c, profile, now, items, Some(&legacy_of(req)?))?,
        );
    }
    fail_after(req, "apply")?;
    Ok(v)
}

/// 请求要不要第三段。
pub(crate) fn wants_move(req: &Value) -> bool {
    req.get("move").is_some_and(Value::is_object)
}

/// `change` 的第三段（见文件头；分发器在第一段的缓存刷新之后调）：把 `move.notes` 的首选牌组与它们此刻可见的卡都移到
/// `move.deck`，已经在那里的不写。笔记在前（按给的顺序），再逐条笔记的卡（按缓存表的 rowid 序）——与 Dart 旧
/// `_moveNotesToDeck` 同序。隐藏的卡是被换掉的旧模板卡（只作新卡的前身留着历史），不动。
pub(crate) fn move_notes_on(
    c: &Connection,
    profile: &str,
    now: i64,
    req: &Value,
) -> Result<Value, String> {
    let mv = &req["move"];
    let deck = mv["deck"].as_str().ok_or("change: missing move.deck")?;
    let mut seen: HashSet<&str> = HashSet::new();
    let notes: Vec<String> = mv["notes"]
        .as_array()
        .ok_or("change: missing move.notes")?
        .iter()
        .filter_map(Value::as_str)
        .filter(|n| seen.insert(*n))
        .map(str::to_owned)
        .collect();
    let ts = req["ts"].as_str().unwrap_or("wall");
    let target = json!(deck);
    let mut items: Vec<Value> = Vec::new();
    let edits = config::edits_of(c, "note", &notes)?;
    let none = Vec::new();
    for n in &notes {
        // 生效的首选牌组已经是它就不写（Dart 旧 `views[id].deckId != deckId`；有并发冲突、胜者恰是它的也不写）。
        let stored = config::stored(edits.get(n).unwrap_or(&none));
        if registers::register_value(&stored, KEY_DECK)? == target {
            continue;
        }
        items.push(json!({
            "e": {"t": "edit", "x": {"p": profile, "k": "note", "e": n, "f": KEY_DECK, "v": deck, "ts": ts}},
            "note": Value::Null,
            "clk": "t",
        }));
    }
    let mut stmt = c
        .prepare_cached(
            "SELECT srs_idt(id) AS id FROM srs_cards_cache WHERE note_id = srs_id(?1) AND hidden = 0 \
             AND deck_id <> srs_id(?2) ORDER BY rowid",
        )
        .map_err(sql)?;
    for n in &notes {
        let cards = stmt
            .query_map(params![n, deck], |r| r.get::<_, String>(0))
            .map_err(sql)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sql)?;
        deck_delete::push_edits(
            c, profile, ts, "card", &cards, KEY_DECK, &target, &mut items,
        )?;
    }
    let v = if items.is_empty() {
        json!({})
    } else {
        apply_local_on(c, profile, now, &items, Some(&legacy_of(req)?))?
    };
    fail_after(req, "move")?;
    Ok(v)
}
