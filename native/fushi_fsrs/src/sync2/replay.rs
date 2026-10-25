//! 复习重放（设计 §4）：一张卡（或一个归属组：卡 + 它继承历史的前身）的调度状态 = 全部复习事实按确定
//! 顺序从初始状态重放的结果。
//!
//! 旧实现里每条日志自带「作者当时算出的结果」，卡片状态 = 最后一条有效日志的结果。两台设备离线各复习
//! 同一张卡，合并后排在后面的那条日志的结果是在**没见过另一条**的状态上算的，前一条的调度影响被丢掉 ——
//! 这正是设计 §1 第一行的 Anki 缺陷。这里把结果从事实里拿掉：
//!
//! - 排序与有效日志选取不变（history.rs：撤销、等价导入、排程归属的规则只写一份）；
//! - 「派生」日志（评分、手动改期 / 重置、立即重排、移交）的结果在重放到它时用**重放出的前一状态**、
//!   当前牌组配置、确定性 FSRS 重新算；导入锚点、恢复照抄这类外部给定的绝对状态照抄；
//! - 记忆状态输入沿用 projection.rs 的规则（重置之后的有效评分、锚点 / SM-2 起点），输入里的结果用重放值；
//! - 日界用每条日志自己记下的 UTC 偏移与翻日时刻（作者当时的口径；与设备当前时区无关，重放逐位确定）；
//! - fuzz 种子 = (日志所属卡, reps)，与旧实现同一公式（不用 RNG）。
//!
//! 结果写回日志的投影行（srs_review_logs.json 的 `res`），所以统计、优化器、RWKV、撤销判定这些读侧
//! 全部自动看到重放后的值，不需要各自改。

use serde_json::{Map, Value};

use super::op::Intent;
use super::sched::{self, Config, Queue, Sched};
use crate::history::{select, Kind, Outcome, STATUS_CLAMPED, STATUS_EFFECTIVE};
use crate::projection::{memory_input, Day, EffLog, MemoryInput};

/// 重放的一行输入：日志投影行的 JSON、它的 S(e)、它的意图。
#[derive(Debug, Clone)]
pub struct Row<'a> {
    pub json: &'a str,
    pub server_time: Option<i64>,
    pub intent: Intent,
}

/// 重放结果：每行一个新 JSON（`None` = 与输入相同，不用写回）、重放后的卡片状态（`None` = 新卡）。
#[derive(Debug, Clone, PartialEq)]
pub struct Replayed {
    pub rows: Vec<Option<String>>,
    pub state: Option<Sched>,
    /// 算不出来、保留作者原结果的日志（参数坏 / 记忆状态非有限）：诊断用。
    pub kept_author: Vec<usize>,
}

/// 从一条日志（落库形态）推出它的意图。v2 本机新写的日志在创建时就按这一份算好存进操作；迁移进来的
/// 旧日志在迁移时按它算一次。
pub fn infer_intent(json: &Value) -> Intent {
    let s = |k: &str| json.get(k).and_then(Value::as_str);
    let res = json.get("res").filter(|v| v.is_object());
    match s("kind") {
        Some("review") => {
            let rating_type = matches!(s("rtype"), Some("learn" | "review" | "relearn"));
            let rating = json.get("rating").and_then(Value::as_i64).is_some_and(|r| (1..=4).contains(&r));
            if s("origin").unwrap_or("fushi") == "fushi" && rating_type && rating {
                Intent::Answer
            } else {
                Intent::Absolute
            }
        }
        Some("manual") => {
            let Some(res) = res else { return Intent::Absolute };
            if json.get("restoreOf").is_some_and(|v| !v.is_null()) {
                return Intent::Absolute;
            }
            let r = Sched::from_json(res);
            if r.queue == Queue::New && r.reps == 0 {
                Intent::Reset
            } else if let Some(d) = r.due_day {
                Intent::SetDue { due_day: d }
            } else {
                Intent::Absolute
            }
        }
        Some("reschedule") if res.is_some() => Intent::Reschedule,
        Some("handOff") => match res {
            Some(r) => Intent::HandOff { to_anki: r.get("scheduler").and_then(Value::as_str) == Some("anki") },
            None => Intent::Absolute,
        },
        _ => Intent::Absolute,
    }
}

/// 重放后的结果按 JSON 往返后的形态交给记忆状态输入（与读侧从落库 JSON 解出来的值逐位相同）。
fn outcome_of(s: &Sched) -> Outcome {
    let back = |v: f32| sched::f32_json(v).as_f64().unwrap_or(f64::from(v));
    Outcome {
        queue: match s.queue {
            Queue::New => 0,
            Queue::Learning => 1,
            Queue::Review => 2,
            Queue::Relearning => 3,
        },
        due_day: s.due_day,
        scheduled_days: s.ivl,
        reps: s.reps,
        last_reviewed_at: s.last_reviewed_at,
        memory: s.mem.map(|m| (back(m.s), back(m.d), back(m.sf))),
        ease: s.ease,
    }
}

/// Dart `srsComputeMemory`（sm2Retention = 0.9）在确定性 FSRS 上的同一流程。
fn compute_memory(input: &MemoryInput, model: &super::fsrs_det::Model) -> Option<super::fsrs_det::Memory> {
    use super::fsrs_det::Memory;
    let mut starting = input.starting.map(|(s, d, sf)| Memory { s: s as f32, d: d as f32, sf: sf as f32 });
    if starting.is_none() {
        if let Some((ease, ivl)) = input.sm2 {
            starting = model.memory_state_from_sm2(ease as f32, ivl as f32, 0.9).ok();
        }
    }
    if input.reviews.is_empty() {
        return starting;
    }
    let reviews: Vec<(u32, f32)> = input
        .reviews
        .iter()
        .enumerate()
        .map(|(i, &(r, dt))| (r.clamp(0, 4) as u32, if i == 0 && starting.is_none() { 0.0 } else { dt as f32 }))
        .collect();
    model.memory_state(&reviews, starting).ok()
}

/// 重放一个归属组。[rows] 顺序任意（排序由选取规则定）；同 ID 的多行按选取规则只认最后一行。
pub fn replay(rows: &[Row<'_>], cfg: &Config) -> Result<Replayed, String> {
    let model = cfg.model()?;
    let mut values: Vec<Map<String, Value>> = Vec::with_capacity(rows.len());
    let mut parsed = Vec::with_capacity(rows.len());
    for r in rows {
        let v: Value = serde_json::from_str(r.json).map_err(|e| format!("bad review log: {e}"))?;
        let Value::Object(m) = v else { return Err("bad review log: not an object".into()) };
        values.push(m);
        parsed.push(crate::history::parse_full(r.json, r.server_time)?);
    }
    let logs: Vec<_> = parsed.iter().map(|p| p.0.clone()).collect();
    let sel = select(&logs);

    let mut out: Vec<Option<String>> = vec![None; rows.len()];
    let mut kept_author = Vec::new();
    let mut prefix: Vec<EffLog> = Vec::new();
    let mut last: Option<Sched> = None;
    let mut owner: Option<String> = None;
    for (k, &i) in sel.order.iter().enumerate() {
        let status = sel.status[k];
        if status & STATUS_EFFECTIVE == 0 {
            continue;
        }
        let v = &values[i];
        let at = parsed[i].0.occurred_at;
        let day = Day {
            utc_offset_min: v.get("utcOff").and_then(Value::as_i64).unwrap_or(0),
            rollover_hour: v.get("rollover").and_then(Value::as_i64).unwrap_or(4),
        };
        let card = v.get("card").and_then(Value::as_str).unwrap_or_default();
        let base = last.clone().unwrap_or_else(Sched::initial);
        let scheduler = owner.clone().unwrap_or_else(|| "fushi".into());
        let cur = if base.scheduler == scheduler { base } else { Sched { scheduler, ..base } };
        let author = v.get("res").filter(|x| x.is_object()).map(Sched::from_json);
        let derived: Option<Option<Sched>> = match &rows[i].intent {
            Intent::Absolute => None,
            Intent::Answer => {
                let rating = parsed[i].0.rating.unwrap_or(0);
                if !(1..=4).contains(&rating) {
                    None
                } else {
                    let input = memory_input(&prefix, cfg.alg.projection_alg(), &day)?;
                    let memory = compute_memory(&input, &model);
                    let elapsed = sched::elapsed_days(cfg.alg, cur.last_reviewed_at, at, &day) as f32;
                    Some(
                        model
                            .next_states(memory, cfg.desired_retention as f32, elapsed)
                            .ok()
                            .map(|next| sched::plan_answer(card, &cur, at, &day, cfg, &next)[(rating - 1) as usize].clone()),
                    )
                }
            }
            Intent::SetDue { due_day } => Some(Some(sched::manual_set_due(&cur, *due_day, day.index(at)))),
            Intent::Reset => Some(Some(sched::manual_reset(&cur))),
            Intent::HandOff { to_anki } => Some(Some(sched::hand_off(&cur, *to_anki))),
            Intent::Reschedule => {
                let input = memory_input(&prefix, cfg.alg.projection_alg(), &day)?;
                let memory = compute_memory(&input, &model);
                Some(Some(sched::reschedule(card, &cur, memory, &model, cfg, &day)))
            }
        };
        let is_derived = derived.is_some();
        let res: Option<Sched> = match derived {
            None => author,
            Some(Some(s)) => Some(s),
            Some(None) => {
                kept_author.push(i);
                author
            }
        };
        if let (true, Some(r)) = (is_derived, &res) {
            let new = r.to_json();
            if v.get("res") != Some(&new) {
                let mut m = v.clone();
                m.insert("res".into(), new);
                out[i] = Some(serde_json::to_string(&Value::Object(m)).map_err(|e| e.to_string())?);
            }
        }
        if let Some(r) = &res {
            last = Some(r.clone());
            if parsed[i].0.kind == Kind::HandOff {
                owner = Some(r.scheduler.clone());
            }
        }
        let outcome = res.as_ref().map(outcome_of);
        prefix.push(EffLog::of(&parsed[i].0, &outcome, &parsed[i].2, status & STATUS_CLAMPED != 0));
    }
    let state = last.map(|b| {
        let scheduler = owner.unwrap_or_else(|| "fushi".into());
        if b.scheduler == scheduler { b } else { Sched { scheduler, ..b } }
    });
    Ok(Replayed { rows: out, state, kept_author })
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use serde_json::json;

    pub const DAY: i64 = 86_400_000;

    /// 一条与 Dart `SrsReviewLog.toJson` 同形的评分日志（结果先空着，由重放填）。
    pub fn review(id: &str, card: &str, writer: &str, at: i64, rating: i64, rtype: &str) -> Value {
        json!({
            "id": id, "p": "P", "card": card, "kind": "review", "rating": rating,
            "hlc": format!("{at}:0:{writer}"), "at": at, "ts": "anchored", "origin": "fushi",
            "rtype": rtype, "utcOff": 0, "rollover": 4, "fv": 1,
            "res": {"queue": "new", "ivl": 0, "step": 0, "reps": 0, "lapses": 0, "scheduler": "fushi"},
        })
    }

    pub fn run(rows: &[Value], cfg: &Config) -> (Vec<Value>, Option<Sched>) {
        let texts: Vec<String> = rows.iter().map(|r| r.to_string()).collect();
        let input: Vec<Row<'_>> = texts
            .iter()
            .zip(rows)
            .map(|(t, v)| Row { json: t, server_time: None, intent: infer_intent(v) })
            .collect();
        let r = replay(&input, cfg).unwrap();
        let out = r
            .rows
            .iter()
            .zip(&texts)
            .map(|(n, t)| serde_json::from_str(n.as_deref().unwrap_or(t)).unwrap())
            .collect();
        (out, r.state)
    }

    /// 本机顺序作答：每次作答都用「重放到目前为止」的状态算 → 重放整份历史后结果一条不变（幂等）。
    #[test]
    fn replaying_a_sequential_history_changes_nothing() {
        let cfg = Config::default();
        let mut rows: Vec<Value> = Vec::new();
        let t0 = 1_700_000_000_000i64;
        for (k, (dt, rating)) in [(0, 3), (600_000, 3), (DAY, 3), (4 * DAY, 1), (4 * DAY + 600_000, 3), (9 * DAY, 4)].iter().enumerate() {
            rows.push(review(&format!("l{k}"), "C", "A", t0 + dt, *rating, "learn"));
            let (filled, _) = run(&rows, &cfg);
            rows = filled;
        }
        let texts: Vec<String> = rows.iter().map(|r| r.to_string()).collect();
        let input: Vec<Row<'_>> = texts.iter().map(|t| Row { json: t, server_time: None, intent: Intent::Answer }).collect();
        let again = replay(&input, &cfg).unwrap();
        assert!(again.rows.iter().all(Option::is_none), "replay must be idempotent");
        let s = again.state.unwrap();
        assert_eq!(s.reps, 6);
        assert_eq!(s.lapses, 1);
        assert_eq!(s.queue, Queue::Review);
    }

    /// 设计 §4.1 的例子：两台设备离线各复习同一张卡，合并后三次都算，结果与「同一台设备按时间顺序复习
    /// 三次」完全相同；与输入顺序无关。
    #[test]
    fn concurrent_reviews_from_two_devices_all_count() {
        let cfg = Config::default();
        let t0 = 1_700_000_000_000i64;
        let a1 = review("a1", "C", "A", t0, 3, "learn");
        let b1 = review("b1", "C", "B", t0 + 2 * 3_600_000, 2, "learn");
        let a2 = review("a2", "C", "A", t0 + DAY + 1_800_000, 1, "review");
        let (merged, state) = run(&[a2.clone(), b1.clone(), a1.clone()], &cfg);
        let (sequential, seq_state) = run(&[a1, b1, a2], &cfg);
        assert_eq!(state, seq_state);
        let by_id = |rows: &[Value], id: &str| rows.iter().find(|r| r["id"] == id).unwrap()["res"].clone();
        for id in ["a1", "b1", "a2"] {
            assert_eq!(by_id(&merged, id), by_id(&sequential, id));
        }
        assert_eq!(state.unwrap().reps, 3);
    }

    #[test]
    fn undo_removes_a_review_from_the_replay() {
        let cfg = Config::default();
        let t0 = 1_700_000_000_000i64;
        let a = review("a", "C", "A", t0, 3, "learn");
        let b = review("b", "C", "A", t0 + 600_000, 4, "learn");
        let undo = json!({
            "id": "u", "p": "P", "card": "C", "kind": "undo", "revokes": "b",
            "hlc": format!("{}:0:A", t0 + 700_000), "at": t0 + 700_000, "ts": "anchored", "origin": "fushi",
            "rtype": "manual", "utcOff": 0, "rollover": 4, "fv": 1,
        });
        let (_, with_undo) = run(&[a.clone(), b, undo], &cfg);
        let (_, only_a) = run(&[a], &cfg);
        assert_eq!(with_undo, only_a);
    }

    #[test]
    fn manual_intents_are_inferred_from_the_author_result() {
        let mut m = review("m", "C", "A", 0, 0, "manual");
        m["kind"] = json!("manual");
        m.as_object_mut().unwrap().remove("rating");
        m["res"] = json!({"queue": "review", "dueDay": 77, "ivl": 3, "step": 0, "reps": 4, "lapses": 0, "scheduler": "fushi"});
        assert_eq!(infer_intent(&m), Intent::SetDue { due_day: 77 });
        m["res"] = json!({"queue": "new", "ivl": 0, "step": 0, "reps": 0, "lapses": 0, "scheduler": "fushi"});
        assert_eq!(infer_intent(&m), Intent::Reset);
        m["restoreOf"] = json!("backup-1");
        assert_eq!(infer_intent(&m), Intent::Absolute);
        let mut h = m.clone();
        h["kind"] = json!("handOff");
        h["res"]["scheduler"] = json!("anki");
        assert_eq!(infer_intent(&h), Intent::HandOff { to_anki: true });
    }

    /// 设为新卡与另一台设备并发的复习：按时间先后重放，重置之后的复习从新卡算起。
    #[test]
    fn reset_concurrent_with_reviews_replays_in_time_order() {
        let cfg = Config::default();
        let t0 = 1_700_000_000_000i64;
        let a = review("a", "C", "A", t0, 4, "learn");
        let mut reset = review("r", "C", "B", t0 + DAY, 0, "manual");
        reset["kind"] = json!("manual");
        reset.as_object_mut().unwrap().remove("rating");
        reset["res"] = json!({"queue": "new", "ivl": 0, "step": 0, "reps": 0, "lapses": 0, "scheduler": "fushi"});
        let b = review("b", "C", "A", t0 + 2 * DAY, 3, "learn");
        let (_, s) = run(&[b, reset, a], &cfg);
        let s = s.unwrap();
        assert_eq!(s.reps, 1, "only the review after the reset counts toward reps");
    }
}
