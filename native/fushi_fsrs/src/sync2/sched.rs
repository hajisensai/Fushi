//! 上层排程策略（Dart `scheduler.dart` / `card_ops.dart` 的 Rust 移植）：学习 / 重学步长、毕业、确定性
//! fuzz、最大间隔、手动改期 / 重置 / 移交 / 立即重排。记忆状态与间隔由确定性 FSRS（fsrs_det.rs）算。
//!
//! 重放（replay.rs）与评分预览都只走这一份，所以「按钮上显示的间隔」与「合并后重放出来的到期日」
//! 出自同一段代码、同一套浮点运算。

use serde_json::{json, Map, Value};

use super::fsrs_det::{Item, Memory, Model, Version};
use crate::projection::{Day, DAY_MS};

const MINUTE_MS: i64 = 60_000;

/// 卡片队列（持久化名冻结）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Queue {
    New,
    Learning,
    Review,
    Relearning,
}

impl Queue {
    pub fn wire(self) -> &'static str {
        match self {
            Queue::New => "new",
            Queue::Learning => "learning",
            Queue::Review => "review",
            Queue::Relearning => "relearning",
        }
    }

    pub fn parse(s: Option<&str>) -> Queue {
        match s {
            Some("learning") => Queue::Learning,
            Some("review") => Queue::Review,
            Some("relearning") => Queue::Relearning,
            _ => Queue::New,
        }
    }
}

/// 「这次操作后」的完整排程状态（Dart `SrsScheduleResult`）。
#[derive(Clone, Debug, PartialEq)]
pub struct Sched {
    pub queue: Queue,
    pub due_day: Option<i64>,
    pub due_at: Option<i64>,
    pub ivl: i64,
    pub step: i64,
    pub mem: Option<Memory>,
    pub last_reviewed_at: Option<i64>,
    pub reps: i64,
    pub lapses: i64,
    pub scheduler: String,
    pub ease: Option<i64>,
}

impl Sched {
    pub fn initial() -> Sched {
        Sched {
            queue: Queue::New,
            due_day: None,
            due_at: None,
            ivl: 0,
            step: 0,
            mem: None,
            last_reviewed_at: None,
            reps: 0,
            lapses: 0,
            scheduler: "fushi".into(),
            ease: None,
        }
    }

    /// `SrsScheduleResult.fromJson`（缺省值与 Dart 相同）。
    pub fn from_json(v: &Value) -> Sched {
        let i = |k: &str| v.get(k).and_then(Value::as_i64);
        let mem = v.get("mem").and_then(|m| {
            let s = m.get("s")?.as_f64()?;
            let d = m.get("d")?.as_f64()?;
            let sf = m.get("sf").and_then(Value::as_f64).unwrap_or(s);
            Some(Memory { s: s as f32, d: d as f32, sf: sf as f32 })
        });
        Sched {
            queue: Queue::parse(v.get("queue").and_then(Value::as_str)),
            due_day: i("dueDay"),
            due_at: i("dueAt"),
            ivl: i("ivl").unwrap_or(0),
            step: i("step").unwrap_or(0),
            mem,
            last_reviewed_at: i("lastReviewedAt"),
            reps: i("reps").unwrap_or(0),
            lapses: i("lapses").unwrap_or(0),
            scheduler: v.get("scheduler").and_then(Value::as_str).unwrap_or("fushi").to_owned(),
            ease: i("ease"),
        }
    }

    /// `SrsScheduleResult.toJson`（键按字典序输出 = 规范形）。记忆状态按 f32 输出（与 FFI 一贯的口径相同）。
    pub fn to_json(&self) -> Value {
        let mut m = Map::new();
        m.insert("queue".into(), json!(self.queue.wire()));
        if let Some(d) = self.due_day {
            m.insert("dueDay".into(), json!(d));
        }
        if let Some(d) = self.due_at {
            m.insert("dueAt".into(), json!(d));
        }
        m.insert("ivl".into(), json!(self.ivl));
        m.insert("step".into(), json!(self.step));
        if let Some(mem) = self.mem {
            m.insert("mem".into(), json!({ "s": f32_json(mem.s), "d": f32_json(mem.d), "sf": f32_json(mem.sf) }));
        }
        if let Some(l) = self.last_reviewed_at {
            m.insert("lastReviewedAt".into(), json!(l));
        }
        m.insert("reps".into(), json!(self.reps));
        m.insert("lapses".into(), json!(self.lapses));
        m.insert("scheduler".into(), json!(self.scheduler));
        if let Some(e) = self.ease {
            m.insert("ease".into(), json!(e));
        }
        Value::Object(m)
    }
}

/// f32 按最短往返十进制输出（与 FFI 一贯用 serde 直接序列化 f32 的文本相同；直接 `json!(f32)` 会先展开成
/// f64 的完整小数）。
pub fn f32_json(v: f32) -> Value {
    format!("{v}").parse::<f64>().ok().and_then(serde_json::Number::from_f64).map_or(Value::Null, Value::Number)
}

/// 排程用的算法（记忆状态都由 FSRS 算：RWKV 牌组用 FSRS-7）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MemAlg {
    Fsrs6,
    Fsrs7,
}

impl MemAlg {
    /// 牌组算法的 wire 值 → 记忆算法（不认识的按回退顺序取 fsrs7，Dart `resolveLocalAlgorithm`）。
    pub fn of_wire(wire: &str) -> MemAlg {
        if wire == "fsrs6" { MemAlg::Fsrs6 } else { MemAlg::Fsrs7 }
    }

    pub fn version(self) -> Version {
        match self {
            MemAlg::Fsrs6 => Version::Fsrs6,
            MemAlg::Fsrs7 => Version::Fsrs7,
        }
    }

    pub fn param_count(self) -> usize {
        match self {
            MemAlg::Fsrs6 => 21,
            MemAlg::Fsrs7 => 34,
        }
    }

    pub fn projection_alg(self) -> crate::projection::Alg {
        match self {
            MemAlg::Fsrs6 => crate::projection::Alg::Fsrs6,
            MemAlg::Fsrs7 => crate::projection::Alg::Fsrs7,
        }
    }
}

/// 一个牌组的排程配置（Dart `SrsSchedulingConfig`）。
#[derive(Clone, Debug, PartialEq)]
pub struct Config {
    pub learn_steps: Vec<f64>,
    pub relearn_steps: Vec<f64>,
    pub desired_retention: f64,
    pub max_interval: i64,
    pub alg: MemAlg,
    /// 空 / 个数不对 = 该算法默认参数。
    pub params: Vec<f32>,
    pub fuzz: bool,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            learn_steps: vec![1.0, 10.0],
            relearn_steps: vec![10.0],
            desired_retention: 0.8,
            max_interval: 36500,
            alg: MemAlg::Fsrs7,
            params: Vec::new(),
            fuzz: true,
        }
    }
}

impl Config {
    pub fn model(&self) -> Result<Model, String> {
        if self.params.len() == self.alg.param_count() {
            if let Ok(m) = Model::new(&self.params) {
                return Ok(m);
            }
        }
        Model::new(Model::defaults(self.alg.version()))
    }

    /// 作答 / 立即重排那一刻的生效配置快照（日志的 `sc` 键；设计 §4.6）。重放按日志自己记下的这份算，
    /// 不按「此刻」的牌组配置：改牌组设置只影响之后的复习，不追溯改写已经发生的复习。
    pub fn to_json(&self) -> Value {
        json!({
            "ls": self.learn_steps,
            "rs": self.relearn_steps,
            "ret": self.desired_retention,
            "mi": self.max_interval,
            "alg": match self.alg {
                MemAlg::Fsrs6 => "fsrs6",
                MemAlg::Fsrs7 => "fsrs7",
            },
            "params": self.params.iter().map(|p| f32_json(*p)).collect::<Vec<_>>(),
            "fuzz": self.fuzz,
        })
    }

    /// [Config::to_json] 的逆；缺键或类型不对返回 `None`（这条日志按作者结果照抄，不重算）。
    pub fn from_json(v: &Value) -> Option<Config> {
        let o = v.as_object()?;
        let f64s = |k: &str| -> Option<Vec<f64>> { o.get(k)?.as_array()?.iter().map(Value::as_f64).collect() };
        let alg = match o.get("alg")?.as_str()? {
            "fsrs6" => MemAlg::Fsrs6,
            "fsrs7" => MemAlg::Fsrs7,
            _ => return None,
        };
        let params: Vec<f32> = o.get("params")?.as_array()?.iter().map(|x| x.as_f64().map(|f| f as f32)).collect::<Option<_>>()?;
        Some(Config {
            learn_steps: f64s("ls")?,
            relearn_steps: f64s("rs")?,
            desired_retention: o.get("ret")?.as_f64()?,
            max_interval: o.get("mi")?.as_i64()?,
            alg,
            params,
            fuzz: o.get("fuzz")?.as_bool()?,
        })
    }
}

/// splitmix64（Dart 64 位补码 int 同语义）。
fn splitmix64(x: u64) -> u64 {
    let mut z = x.wrapping_add(0x9E37_79B9_7F4A_7C15);
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

/// [0, 1) 的确定性随机数：种子 = FNV-1a(cardId 的 UTF-16 码元) + reps（Dart `srsFuzzFactor`）。
pub fn fuzz_factor(card_id: &str, reps: i64) -> f64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for c in card_id.encode_utf16() {
        h = (h ^ u64::from(c)).wrapping_mul(0x0000_0100_0000_01b3);
    }
    let r = splitmix64(h.wrapping_add(reps as u64));
    (r >> 11) as f64 / 9_007_199_254_740_992.0
}

/// Dart `int.clamp`（lo > hi 时 Dart 抛异常；调用方已保证 lo ≤ hi）。
fn clampi(v: i64, lo: i64, hi: i64) -> i64 {
    v.max(lo).min(hi)
}

/// Dart `double.round()`：四舍五入远离零，转 int。
fn round_i(v: f64) -> i64 {
    v.round() as i64
}

/// Anki 的 fuzz 区间（Dart `srsFuzzRange`）。
pub fn fuzz_range(interval: f64, minimum: i64, maximum: i64) -> (i64, i64) {
    if interval < 2.5 {
        let v = clampi(round_i(interval), minimum, maximum);
        return (v, v);
    }
    const RANGES: [(f64, f64, f64); 3] = [(2.5, 7.0, 0.15), (7.0, 20.0, 0.1), (20.0, f64::INFINITY, 0.05)];
    let mut delta = 1.0;
    for (start, end, factor) in RANGES {
        delta += factor * ((if interval < end { interval } else { end }) - start).max(0.0);
    }
    let mut lo = clampi(round_i(interval - delta), minimum, maximum);
    let hi = clampi(round_i(interval + delta), minimum, maximum);
    if lo > hi {
        lo = hi;
    }
    (lo, hi)
}

/// 把 FSRS 给的小数间隔落成整天（Dart `srsConstrainInterval`）。
pub fn constrain_interval(raw: f64, minimum: i64, cfg: &Config, card_id: &str, reps: i64) -> i64 {
    let maximum = if cfg.max_interval < minimum { minimum } else { cfg.max_interval };
    if !cfg.fuzz {
        return clampi(round_i(raw), minimum, maximum);
    }
    let (lo, hi) = fuzz_range(raw, minimum, maximum);
    let f = fuzz_factor(card_id, reps);
    lo + clampi((f * (hi - lo + 1) as f64).floor() as i64, 0, hi - lo)
}

/// 下次评分的 elapsed（Dart `SrsAnswerContext.elapsedDaysFor`）。
pub fn elapsed_days(alg: MemAlg, last: Option<i64>, now: i64, day: &Day) -> f64 {
    let Some(last) = last else { return 0.0 };
    if now <= last {
        return 0.0;
    }
    match alg {
        MemAlg::Fsrs7 => (now - last) as f64 / DAY_MS as f64,
        MemAlg::Fsrs6 => (day.index(now) - day.index(last)) as f64,
    }
}

/// Hard 在学习步上的延迟（Dart `_hardDelay`）。
fn hard_delay(steps: &[f64], step: i64) -> f64 {
    if step > 0 {
        return steps[clampi(step, 0, steps.len() as i64 - 1) as usize];
    }
    if steps.len() >= 2 {
        return (steps[0] + steps[1]) / 2.0;
    }
    let plus = steps[0] * 1.5;
    let cap = steps[0] + 1440.0;
    if plus < cap { plus } else { cap }
}

/// 四个评分各自的「这次操作后」结果（Dart `srsPlanAnswer`）。[next] 是 again..easy。
pub fn plan_answer(card_id: &str, cur: &Sched, now: i64, day: &Day, cfg: &Config, next: &[Item; 4]) -> [Sched; 4] {
    let today = day.index(now);
    let reps = cur.reps + 1;
    let learning = |queue: Queue, step: i64, delay_min: f64, memory: Memory, lapses: i64| Sched {
        queue,
        due_day: None,
        due_at: Some(now + (delay_min * MINUTE_MS as f64).round() as i64),
        ivl: 0,
        step,
        mem: Some(memory),
        last_reviewed_at: Some(now),
        reps,
        lapses,
        scheduler: cur.scheduler.clone(),
        ease: None,
    };
    let review_at = |ivl: i64, memory: Memory, lapses: i64| Sched {
        queue: Queue::Review,
        due_day: Some(today + ivl),
        due_at: None,
        ivl,
        step: 0,
        mem: Some(memory),
        last_reviewed_at: Some(now),
        reps,
        lapses,
        scheduler: cur.scheduler.clone(),
        ease: None,
    };
    let ivl_of = |raw: f32, minimum: i64| constrain_interval(f64::from(raw), minimum, cfg, card_id, reps);
    let passing = |from_review: bool| -> (i64, i64, i64) {
        let prev = if from_review { cur.ivl } else { 0 };
        let mut hard = ivl_of(next[1].interval, 1);
        let mut good = ivl_of(next[2].interval, hard + i64::from(from_review));
        if from_review && f64::from(next[2].interval) >= prev as f64 && good < prev {
            good = prev;
        }
        if good <= hard && from_review {
            good = hard + 1;
        }
        let mut easy = ivl_of(next[3].interval, good + 1);
        if from_review && f64::from(next[3].interval) >= prev as f64 && easy < prev {
            easy = prev;
        }
        if easy <= good {
            easy = good + 1;
        }
        let max = cfg.max_interval;
        hard = clampi(hard, 1, max.max(1));
        good = clampi(good, 1, max.max(1));
        easy = clampi(easy, 1, max.max(1));
        (hard, good, easy)
    };
    let mem = |i: usize| next[i].memory;
    match cur.queue {
        Queue::New | Queue::Learning => {
            let steps = &cfg.learn_steps;
            let step = if cur.queue == Queue::New { 0 } else { cur.step };
            let (_, good, easy) = passing(false);
            let again = if steps.is_empty() {
                review_at(ivl_of(next[0].interval, 1), mem(0), cur.lapses)
            } else {
                learning(Queue::Learning, 0, steps[0], mem(0), cur.lapses)
            };
            let hard = if steps.is_empty() {
                review_at(ivl_of(next[1].interval, 1), mem(1), cur.lapses)
            } else {
                learning(Queue::Learning, step, hard_delay(steps, step), mem(1), cur.lapses)
            };
            let good_s = if ((step + 1) as usize) < steps.len() {
                learning(Queue::Learning, step + 1, steps[(step + 1) as usize], mem(2), cur.lapses)
            } else {
                review_at(good, mem(2), cur.lapses)
            };
            [again, hard, good_s, review_at(easy, mem(3), cur.lapses)]
        }
        Queue::Review => {
            let rsteps = &cfg.relearn_steps;
            let lapses = cur.lapses + 1;
            let again = if rsteps.is_empty() {
                review_at(ivl_of(next[0].interval, 1), mem(0), lapses)
            } else {
                learning(Queue::Relearning, 0, rsteps[0], mem(0), lapses)
            };
            let (hard, good, easy) = passing(true);
            [again, review_at(hard, mem(1), cur.lapses), review_at(good, mem(2), cur.lapses), review_at(easy, mem(3), cur.lapses)]
        }
        Queue::Relearning => {
            let rsteps = &cfg.relearn_steps;
            let step = cur.step;
            let (_, good, easy) = passing(false);
            let again = if rsteps.is_empty() {
                review_at(ivl_of(next[0].interval, 1), mem(0), cur.lapses)
            } else {
                learning(Queue::Relearning, 0, rsteps[0], mem(0), cur.lapses)
            };
            let hard = if rsteps.is_empty() {
                review_at(ivl_of(next[1].interval, 1), mem(1), cur.lapses)
            } else {
                learning(Queue::Relearning, step, hard_delay(rsteps, step), mem(1), cur.lapses)
            };
            let good_s = if ((step + 1) as usize) < rsteps.len() {
                learning(Queue::Relearning, step + 1, rsteps[(step + 1) as usize], mem(2), cur.lapses)
            } else {
                review_at(good, mem(2), cur.lapses)
            };
            [again, hard, good_s, review_at(easy, mem(3), cur.lapses)]
        }
    }
}

/// 「manual 改到期」（Dart `srsManualSetDue`）。
pub fn manual_set_due(cur: &Sched, due_day: i64, today: i64) -> Sched {
    Sched {
        queue: Queue::Review,
        due_day: Some(due_day),
        due_at: None,
        ivl: clampi(due_day - today, 1, 1 << 30),
        step: 0,
        ..cur.clone()
    }
}

/// 「设为新卡」（Dart `srsManualReset`）：只保留排程归属。
pub fn manual_reset(cur: &Sched) -> Sched {
    Sched { scheduler: cur.scheduler.clone(), ..Sched::initial() }
}

/// handOff / 收回：只改排程归属。
pub fn hand_off(cur: &Sched, to_anki: bool) -> Sched {
    Sched { scheduler: if to_anki { "anki" } else { "fushi" }.into(), ..cur.clone() }
}

/// 「立即重排」（Dart `SrsCardOps.reschedule`）：复习卡按当前参数重算到期；条件不满足 = 不变。
pub fn reschedule(card_id: &str, cur: &Sched, memory: Option<Memory>, model: &Model, cfg: &Config, day: &Day) -> Sched {
    let (Queue::Review, Some(last), Some(memory)) = (cur.queue, cur.last_reviewed_at, memory) else {
        return cur.clone();
    };
    let Ok(next) = model.next_states(Some(memory), cfg.desired_retention as f32, 0.0) else {
        return cur.clone();
    };
    let ivl = constrain_interval(f64::from(next[2].interval), 1, cfg, card_id, cur.reps);
    Sched { due_day: Some(day.index(last) + ivl), ivl, mem: Some(memory), ..cur.clone() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fuzz_factor_is_stable_and_in_range() {
        let a = fuzz_factor("0193a1b2-0000-7000-8000-000000000001", 3);
        assert_eq!(a, fuzz_factor("0193a1b2-0000-7000-8000-000000000001", 3));
        assert_ne!(a, fuzz_factor("0193a1b2-0000-7000-8000-000000000001", 4));
        for r in 0..200 {
            let f = fuzz_factor("x", r);
            assert!((0.0..1.0).contains(&f));
        }
    }

    #[test]
    fn fuzz_range_matches_anki_table() {
        assert_eq!(fuzz_range(1.4, 1, 100), (1, 1));
        assert_eq!(fuzz_range(10.0, 1, 100), (8, 12));
        assert_eq!(fuzz_range(100.0, 1, 50), (50, 50));
    }

    fn day() -> Day {
        Day { utc_offset_min: 0, rollover_hour: 4 }
    }

    #[test]
    fn new_card_answer_plan_follows_learning_steps() {
        let cfg = Config::default();
        let model = cfg.model().unwrap();
        let next = model.next_states(None, 0.9, 0.0).unwrap();
        let now = 1_700_000_000_000;
        let plan = plan_answer("c", &Sched::initial(), now, &day(), &cfg, &next);
        assert_eq!(plan[0].queue, Queue::Learning);
        assert_eq!(plan[0].due_at, Some(now + 60_000));
        assert_eq!(plan[1].due_at, Some(now + 330_000));
        assert_eq!(plan[2].queue, Queue::Learning);
        assert_eq!(plan[2].step, 1);
        assert_eq!(plan[3].queue, Queue::Review);
        assert!(plan.iter().all(|s| s.reps == 1 && s.last_reviewed_at == Some(now)));
    }

    #[test]
    fn review_card_intervals_are_strictly_increasing() {
        let cfg = Config::default();
        let model = cfg.model().unwrap();
        let cur = Sched {
            queue: Queue::Review,
            due_day: Some(10),
            ivl: 10,
            mem: Some(Memory { s: 10.0, d: 5.0, sf: 8.0 }),
            last_reviewed_at: Some(0),
            reps: 5,
            ..Sched::initial()
        };
        let now = 10 * DAY_MS + 5 * 3_600_000;
        let next = model.next_states(cur.mem, 0.8, elapsed_days(MemAlg::Fsrs7, cur.last_reviewed_at, now, &day()) as f32).unwrap();
        let p = plan_answer("c", &cur, now, &day(), &cfg, &next);
        assert_eq!(p[0].queue, Queue::Relearning);
        assert_eq!(p[0].lapses, 1);
        assert!(p[1].ivl < p[2].ivl && p[2].ivl < p[3].ivl);
    }

    #[test]
    fn result_json_round_trips() {
        let s = Sched {
            queue: Queue::Review,
            due_day: Some(3),
            mem: Some(Memory { s: 3.9221, d: 5.5, sf: 3.1 }),
            last_reviewed_at: Some(9),
            ease: Some(2500),
            ..Sched::initial()
        };
        let v = s.to_json();
        assert_eq!(Sched::from_json(&v), s);
        assert_eq!(v["mem"]["s"].to_string(), "3.9221");
    }
}
