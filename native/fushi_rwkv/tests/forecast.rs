// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! 作答时排程（`forecast` / `next_intervals`）的契约，大小两个模型都测：
//! - 什么都不保存：预测前后快照逐字节相同；
//! - 与真的作答一致：预测「以评分 g 作答后第 d 天的 R」= 从快照恢复、真的回放这条作答、
//!   再在第 d 天查询得到的 R；
//! - next_intervals：读假设作答的遗忘曲线（单调不增）；天数在 [1, 上限]、按评分单调不减，
//!   所选那天曲线上 R ≤ 目标、前一天 R > 目标。

mod common;

use std::io::Read;

use common::{model, small_package};
use fushi_rwkv::{forecast_query, Model, ReviewInput, RwkvRuntime, StatePrecision};

fn small_model() -> Model {
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(small_package())).unwrap();
    let mut bytes = Vec::new();
    archive
        .by_name("sm56/weights.int8.bin")
        .unwrap()
        .read_to_end(&mut bytes)
        .unwrap();
    Model::from_bytes(&bytes).unwrap()
}

/// 120 天、60 张卡（两卡一笔记）的确定性小历史；返回历史与「今天」的一条作答。
fn history() -> (Vec<ReviewInput>, ReviewInput) {
    let mut reviews = Vec::new();
    let mut last: Vec<Option<(i64, i64)>> = vec![None; 60];
    let mut seed = 7u64;
    let mut next = || {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        (seed >> 33) as i64
    };
    let row = |card: usize, day: i64, ts: i64, last: Option<(i64, i64)>, ease: u8, card_type: i64| {
        let (ed, es) = last.map_or((-1, -1), |(d, t)| (day - d, ts - t));
        ReviewInput {
            card_id: 1_000 + card as i64,
            note_id: Some(5_000 + card as i64 / 2),
            deck_id: Some(1 + card as i64 % 3),
            preset_id: Some(1),
            is_query: false,
            ease: Some(ease),
            duration_millis: Some(4_000),
            card_type: Some(card_type),
            day_offset: Some(day),
            current_elapsed_days: Some(ed),
            current_elapsed_seconds: Some(es),
        }
    };
    for day in 0..120i64 {
        let mut ts = day * 86_400 + 9 * 3600;
        for card in 0..60 {
            let due = match last[card] {
                None => card as i64 / 2 == day,
                Some((d, _)) => (day - d) >= 1 + (next() % 9),
            };
            if !due {
                continue;
            }
            let ease = [1u8, 3, 3, 3, 3, 4, 2][(next() % 7) as usize];
            let card_type = if last[card].is_none() { 0 } else { 2 };
            reviews.push(row(card, day, ts, last[card], ease, card_type));
            last[card] = Some((day, ts));
            ts += 30;
        }
    }
    let answer = row(5, 120, 120 * 86_400 + 9 * 3600, last[5], 3, 2);
    (reviews, answer)
}

fn runtimes() -> Vec<(&'static str, Model, StatePrecision)> {
    let large = Model::from(model().clone());
    let small = small_model();
    vec![
        ("large f32", large.clone(), StatePrecision::F32),
        ("large int8", large, StatePrecision::Int8),
        ("small f32", small.clone(), StatePrecision::F32),
        ("small int8", small.clone(), StatePrecision::Int8),
        ("small int4", small, StatePrecision::Int4),
    ]
}

#[test]
fn forecast_keeps_nothing_and_matches_answering() {
    let (reviews, answer) = history();
    for (name, model, precision) in runtimes() {
        let mut runtime = RwkvRuntime::new(&model, precision, 0).unwrap();
        runtime.replay(&reviews, false).unwrap();
        let before = runtime.snapshot().unwrap();
        let horizons = [1, 3, 10, 45];
        let ratings = [1, 2, 3, 4];
        let forecast = runtime.forecast(&answer, &ratings, &horizons).unwrap();
        assert_eq!(runtime.snapshot().unwrap(), before, "{name}: forecast changed the state");
        assert!(forecast.iter().all(|r| r.is_finite()), "{name}: {forecast:?}");

        for (index, &rating) in ratings.iter().enumerate() {
            let mut real = RwkvRuntime::new(&model, precision, 0).unwrap();
            real.restore(&before).unwrap();
            let mut given = answer.clone();
            given.ease = Some(rating);
            real.replay(&[given.clone()], false).unwrap();
            for (k, &days) in horizons.iter().enumerate() {
                // 每个查询都从「刚作答完」开始：查询会给新 id 分配编码，不能互相影响。
                let mut fresh = RwkvRuntime::new(&model, precision, 0).unwrap();
                fresh.restore(&real.snapshot().unwrap()).unwrap();
                let r = fresh.query(&[forecast_query(&given, days, days * 86_400)]).unwrap()[0];
                let predicted = forecast[index * horizons.len() + k];
                assert!(
                    (r - predicted).abs() <= 1e-5,
                    "{name}: rating {rating} day {days}: answered {r}, forecast {predicted}"
                );
            }
        }
        // Again 之后的 R 低于 Easy 之后的（同一天）。
        assert!(forecast[0] < forecast[3 * horizons.len()], "{name}: {forecast:?}");
    }
}

/// 排程读的是假设作答那一行的**遗忘曲线**（曲线头），不是即时头沿天数外推（见 src/curve.rs 头注释）。
#[test]
fn next_intervals_are_the_first_day_below_target_on_the_answer_curve() {
    const DAY: f32 = 86_400.0;
    let (reviews, answer) = history();
    for (name, model, precision) in runtimes() {
        let mut runtime = RwkvRuntime::new(&model, precision, 0).unwrap();
        runtime.replay(&reviews, false).unwrap();
        let before = runtime.snapshot().unwrap();
        let curves = runtime.answer_curves(&answer).unwrap();
        let grid = [0.01f32, 0.5, 1.0, 3.0, 10.0, 30.0, 100.0, 365.0, 3650.0, 36_500.0];
        for (index, curve) in curves.iter().enumerate() {
            let r: Vec<f32> = grid.iter().map(|&d| curve.retrievability(d * DAY)).collect();
            assert!(
                r.iter().all(|r| r.is_finite() && (0.0..=1.0).contains(r)),
                "{name} {index}: {r:?}"
            );
            assert!(
                r.windows(2).all(|w| w[1] <= w[0]),
                "{name} rating {}: curve rises {r:?}",
                index + 1
            );
        }
        // 次日：Again 之后的 R 低于 Easy 之后的。更远处两条曲线可能交叉（大模型 f32 实测第 100 天
        // 交叉），这正是上游用 PAVA 修正评分顺序的原因——顺序由下面对天数的单调断言钉。
        let next_day = |index: usize| curves[index].retrievability(DAY);
        eprintln!("{name}: R on day 1 after Again..Easy: {:?}", [0, 1, 2, 3].map(next_day));
        assert!(
            next_day(0) < next_day(3),
            "{name}: R after Again not below R after Easy on day 1"
        );
        for (target, max) in [(0.9f32, 36_500u32), (0.8, 36_500), (0.97, 36_500), (0.5, 20)] {
            let (days, at) = runtime.next_intervals(&answer, target, max).unwrap();
            assert!(days.windows(2).all(|w| w[0] <= w[1]), "{name} {target}: {days:?}");
            assert!(
                days.iter().all(|&d| (1..=max).contains(&d)),
                "{name} {target}: {days:?}"
            );
            for (index, &d) in days.iter().enumerate() {
                let curve = &curves[index];
                let r = curve.retrievability(d as f32 * DAY);
                assert!((r - at[index]).abs() <= 1e-6, "{name}: {r} vs {}", at[index]);
                // 评分顺序修正（PAVA）可能挪动相邻评分的越线点；只核对没被合并的那些。
                let pooled = (index > 0 && d == days[index - 1]) || (index < 3 && d == days[index + 1]);
                if !pooled && d < max {
                    assert!(r <= target, "{name} {target}: rating {} day {d}: R {r}", index + 1);
                    if d > 1 {
                        let earlier = curve.retrievability((d - 1) as f32 * DAY);
                        assert!(
                            earlier > target,
                            "{name} {target}: rating {} day {}: R {earlier}",
                            index + 1,
                            d - 1
                        );
                    }
                }
            }
            eprintln!("{name} target {target}: {days:?} R {at:?}");
        }
        assert_eq!(
            runtime.snapshot().unwrap(),
            before,
            "{name}: next_intervals changed the state"
        );
    }
}

#[test]
fn forecast_rejects_bad_input() {
    let (reviews, answer) = history();
    let mut runtime = RwkvRuntime::new(&small_model(), StatePrecision::Int4, 1).unwrap();
    runtime.replay(&reviews, false).unwrap();
    assert!(runtime.forecast(&answer, &[0], &[1]).is_err());
    assert!(runtime.forecast(&answer, &[3], &[0]).is_err());
    let mut early = answer.clone();
    early.day_offset = Some(3);
    assert!(runtime.forecast(&early, &[3], &[1]).is_err());
    assert!(runtime.next_intervals(&answer, 1.0, 100).is_err());
}
