//! 本机发起的手动排程操作（重置为新卡 / 改到期日 / 撤销 / 立即重排）：Dart 只发**显式意图**，内核在一个
//! SAVEPOINT 里逐卡重放到此刻、判能不能做、按意图算结果、落操作与投影、重放受影响的卡，交回落库后的日志行。
//!
//! 以前这四种操作由 Dart 逐卡读历史、逐卡跨 FFI 调 `fsrs` crate 算结果（`SrsCardOps`），再把组好的日志交给
//! `apply`；内核拿到的只是「结果长什么样」，意图要靠 [crate::sync2::replay::infer_intent] 从结果形状反推。现在
//! 意图由命令给出，结果与之后重放到这条日志时算的是同一段代码（[replay::Head]），`infer_intent` 只留给迁移 / 外来
//! 的旧形态日志。
//!
//! 写出的日志与旧路径同形（同样的键、同样的 HLC 推进方式、同样记下配置快照 `sc`），意图编码进操作的方式也相同：
//! 同步协议、段格式、srs.db schema 都不变。

use std::collections::BTreeSet;

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Map, Value, json};

use super::{
    Group, Local, Touched, append_local_cached, applied_vv, config, group_of, in_savepoint,
    log_body_of, project_body, replay_touched, sql, stamp_local_config,
};
use crate::projection::Day;
use crate::store::SrsCore;
use crate::sync2::id::Id;
use crate::sync2::op::{Body, Intent};
use crate::sync2::replay::{self, Row};
use crate::sync2::sched::Queue;

/// 一项请求展开后的单卡动作。
enum Action {
    /// [skip_new]：已经是新卡的跳过（批量「忘记」）；单卡入口照旧无条件写。
    Reset {
        skip_new: bool,
    },
    SetDue {
        due_day: i64,
    },
    Undo {
        log: String,
    },
    Reschedule,
}

/// Dart `HlcClock.tick` 的同一规则：本机发出事件取 max(可信时间, 已见过的最大 HLC)。从 Dart 时钟当前的
/// `last` 起推进，写了几条就推进几次，交回最后一个让 Dart 时钟跟上（没写就不动 Dart 时钟）。
struct Ticker {
    physical: i64,
    counter: i64,
    writer: String,
}

impl Ticker {
    fn parse(text: &str) -> Result<Ticker, String> {
        let mut parts = text.splitn(3, ':');
        let (Some(p), Some(c), Some(w)) = (parts.next(), parts.next(), parts.next()) else {
            return Err(format!("sched: bad hlc {text}"));
        };
        Ok(Ticker {
            physical: p.parse().map_err(|_| format!("sched: bad hlc {text}"))?,
            counter: c.parse().map_err(|_| format!("sched: bad hlc {text}"))?,
            writer: w.to_owned(),
        })
    }

    fn tick(&mut self, now: i64) -> String {
        if now > self.physical {
            self.physical = now;
            self.counter = 0;
        } else {
            self.counter += 1;
        }
        self.encode()
    }

    fn encode(&self) -> String {
        format!("{}:{}:{}", self.physical, self.counter, self.writer)
    }
}

/// 卡所属笔记（缓存行；没有缓存行 = None，与 Dart 旧路径按缓存行补笔记同一口径）。
fn note_of(c: &Connection, card: &str) -> Result<Option<String>, String> {
    c.prepare_cached(
        "SELECT srs_idt(note_id) AS note_id FROM srs_cards_cache WHERE id = srs_id(?1)",
    )
    .map_err(sql)?
    .query_row([card], |r| r.get(0))
    .optional()
    .map_err(sql)
}

/// 「立即重排整组」的候选：缓存里有效牌组在 [deck] 子树内、队列是复习的卡，按 ID 排（写出顺序确定）。
fn review_cards_in(
    c: &Connection,
    profile: &str,
    tree: &config::DeckTree,
    deck: &str,
) -> Result<Vec<String>, String> {
    let sub = tree.subtree(deck);
    let mut out = Vec::new();
    let mut stmt = c
        .prepare_cached(
            "SELECT srs_idt(id) AS id FROM srs_cards_cache WHERE profile_uid = srs_id(?1) \
             AND deck_id = srs_id(?2) AND queue = 'review' ORDER BY id",
        )
        .map_err(sql)?;
    for d in &sub {
        let ids = stmt
            .query_map(params![profile, d], |r| r.get::<_, String>(0))
            .map_err(sql)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sql)?;
        out.extend(ids);
    }
    out.sort();
    out.dedup();
    Ok(out)
}

/// 请求项 → 单卡动作（`rescheduleDeck` 在这里按牌组子树展开）。
fn expand(
    c: &Connection,
    profile: &str,
    tree: &config::DeckTree,
    items: &[Value],
) -> Result<Vec<(String, Action)>, String> {
    let mut out = Vec::new();
    for it in items {
        let card = || {
            it["card"]
                .as_str()
                .map(str::to_owned)
                .ok_or_else(|| "sched: missing card".to_owned())
        };
        match it["a"].as_str() {
            Some("reset") => out.push((
                card()?,
                Action::Reset {
                    skip_new: it["skipNew"] == Value::Bool(true),
                },
            )),
            Some("setDue") => out.push((
                card()?,
                Action::SetDue {
                    due_day: it["due"].as_i64().ok_or("sched: missing due")?,
                },
            )),
            Some("undo") => out.push((
                card()?,
                Action::Undo {
                    log: it["log"].as_str().ok_or("sched: missing log")?.to_owned(),
                },
            )),
            Some("rescheduleDeck") => {
                let deck = it["deck"].as_str().ok_or("sched: missing deck")?;
                for card in review_cards_in(c, profile, tree, deck)? {
                    out.push((card, Action::Reschedule));
                }
            }
            other => return Err(format!("sched: unknown action {other:?}")),
        }
    }
    Ok(out)
}

impl SrsCore {
    /// 本机手动排程操作（见文件头）。[req]：
    /// `{"at": 可信时刻, "ts": "anchored"|"wall", "utcOff", "rollover", "hlc": Dart 时钟当前的 last, "items": [..]}`，
    /// 每项 `{"a":"reset","card","skipNew"?}` / `{"a":"setDue","card","due"}` / `{"a":"undo","card","log"}` /
    /// `{"a":"rescheduleDeck","deck"}`。
    ///
    /// 返回 `{"logs": [落库后的日志行], "blocked": 撤不了的条数, "hlc": 用到的最后一个 HLC | null, "marks", "replayed",
    /// "changed", "purged", "diagnostics", "nextSeq"}`（后几项与 `apply` 同形，Dart 照样接进修订号与缓存）。
    pub fn sync2_sched_local(&self, profile: &str, now: i64, req: &Value) -> Result<Value, String> {
        let at = req["at"].as_i64().ok_or("sched: missing at")?;
        let ts = req["ts"].as_str().unwrap_or("wall").to_owned();
        let day = Day {
            utc_offset_min: req["utcOff"].as_i64().ok_or("sched: missing utcOff")?,
            rollover_hour: req["rollover"].as_i64().ok_or("sched: missing rollover")?,
        };
        let mut ticker = Ticker::parse(req["hlc"].as_str().ok_or("sched: missing hlc")?)?;
        let items: &[Value] = req["items"].as_array().map_or(&[], Vec::as_slice);
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let mut local = match Local::load(c, profile)? {
                Some(l) => l,
                None => Local::create(c, profile, now)?,
            };
            let mut applied = applied_vv(c, profile)?;
            let mut t = Touched {
                log_no_delete: Some(Default::default()),
                ..Touched::default()
            };
            let mut deps_row: Option<(Vec<u8>, i64)> = None;
            let tree = config::DeckTree::load(c, profile)?;
            // [stamp_local_config] 的牌组树缓存：这条命令只写日志，整批同一份。
            let mut stamp_tree: Option<config::DeckTree> = None;
            let mut written: Vec<String> = Vec::new();
            let mut blocked = 0u64;
            let mut last_hlc: Option<String> = None;
            let mut owners = super::ownership::Seen::new();
            for (card, action) in expand(c, profile, &tree, items)? {
                // 别的 profile 的卡按「没有这张卡」处理（ownership.rs）：不读它的历史、不写日志；撤销算撤不了。
                if super::ownership::foreign_seen(
                    c,
                    profile,
                    crate::sync2::op::EntKind::Card,
                    &card,
                    &mut owners,
                )? {
                    if matches!(action, Action::Undo { .. }) {
                        blocked += 1;
                    }
                    continue;
                }
                let note = note_of(c, &card)?;
                // 每张卡在它自己的归属组上重放到此刻（同一批里先写的日志已投影，后面的项看得见）。
                let Group { rows, .. } = group_of(c, &card, note.as_deref())?;
                let input: Vec<Row<'_>> = rows
                    .iter()
                    .map(|(_, j, s, i, _)| Row {
                        json: j,
                        server_time: *s,
                        intent: i.clone(),
                    })
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
                        // 与配置快照（[stamp_local_config]）同一份配置：结果就是之后重放到这条日志时算出的值。
                        let deck = config::card_deck(c, &tree, &card, note.as_deref())?;
                        match head.reschedule(&card, &tree.config(&deck), &day)? {
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
                let hlc = ticker.tick(at);
                let mut x: Map<String, Value> = Map::new();
                x.insert("id".into(), json!(id));
                x.insert("p".into(), json!(profile));
                x.insert("card".into(), json!(card));
                x.insert("kind".into(), json!(kind));
                if let Some(r) = &revokes {
                    x.insert("revokes".into(), json!(r));
                }
                x.insert("hlc".into(), json!(hlc));
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
                let mut body =
                    log_body_of(&Value::Object(x), note.as_deref(), Some(hlc.clone()), None)?;
                body.intent = intent;
                let body = stamp_local_config(c, profile, Body::Log(body), false, &mut stamp_tree)?;
                let op =
                    append_local_cached(c, &mut local, &mut applied, &body, now, &mut deps_row)?;
                project_body(c, profile, &op, body, now, true, &mut t)?;
                written.push(id);
                last_hlc = Some(hlc);
            }
            local.save(c)?;
            let replayed: BTreeSet<String> = replay_touched(c, &t)?;
            let mut logs = Vec::with_capacity(written.len());
            for id in &written {
                let json: String = c
                    .prepare_cached("SELECT json FROM srs_review_logs WHERE id = srs_id(?1)")
                    .map_err(sql)?
                    .query_row([id], |r| r.get(0))
                    .map_err(sql)?;
                logs.push(serde_json::from_str::<Value>(&json).map_err(|e| e.to_string())?);
            }
            Ok(json!({
                "logs": logs,
                "blocked": blocked,
                "hlc": last_hlc,
                "marks": t.marks.to_json(),
                "replayed": replayed,
                "diagnostics": t.diagnostics,
                "changed": t.entities_changed.iter().map(|(k, e)| json!([k, e])).collect::<Vec<_>>(),
                "purged": t.purged.iter().map(|(k, e)| json!([k, e])).collect::<Vec<_>>(),
                "nextSeq": local.next_seq,
            }))
        })
    }
}
