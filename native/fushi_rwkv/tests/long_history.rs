// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! 长历史压力：卡被复习成千上万次，card / note 的紧凑（int8）状态必须全程有限、与 f32 同一量级，
//! 回放预测与 f32 的差在界内。
//!
//! 背景：
//! - 2026-10-20：旧的 int4 量化（每行按 max/7 定标、四舍五入）在一份真实的 121 万条复习历史上让
//!   101 张高频卡的 card 状态每次复习 ×1.06；改成最小二乘比例因子后这份历史不再发散。
//! - BUG-5594（2026-11-27）：最小二乘也不够。单卡 2 万次复习时，int4 的 note / card 状态在
//!   sm101（连刷 Again）、sm113（每天 Again）、sm130io（每天 Again）上指数增长到 1e4～4e33
//!   （f32 为 2～8），sm101 到 4 万次左右状态坏掉、该卡预测卡死在 0.8577；大模型每卡 1 万次复习峰值
//!   1.3e16。上游 JSchoreels/anki 同期（2dc21da67fed）也因此弃用 int4。int4 已删，状态一律 int8；
//!   int8 在同样的模式、每卡 10 万次复习上与 f32 同量级。
//!
//! `LONG_ANSWERS` / `LONG_DAYS` 可加长（例：`LONG_ANSWERS=100000`）。

mod common;

use common::{SmallFile, SmallModelId, model, small_file_of, small_weights};
use fushi_rwkv::{ReviewInput, RwkvInference, SmallInference, SmallModel, StatePrecision};

fn small_model() -> SmallModel {
    SmallModel::from_bytes(small_weights()).unwrap()
}

fn env_or(name: &str, default: i64) -> i64 {
    std::env::var(name)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

fn history(cards: i64, days: i64) -> Vec<ReviewInput> {
    let mut seed = 3u64;
    let mut next = || {
        seed = seed
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        (seed >> 33) as i64
    };
    let mut reviews = Vec::new();
    let mut last: Vec<Option<(i64, i64)>> = vec![None; cards as usize];
    for day in 0..days {
        let mut ts = day * 86_400 + 8 * 3600;
        for card in 0..cards {
            let previous = last[card as usize];
            let (ed, es) = previous.map_or((-1, -1), |(d, t)| (day - d, ts - t));
            reviews.push(ReviewInput {
                card_id: 10 + card,
                note_id: Some(100 + card / 2),
                deck_id: Some(1),
                preset_id: Some(1),
                is_query: false,
                ease: Some([1u8, 2, 3, 3, 3, 3, 4][(next() % 7) as usize]),
                duration_millis: Some(2_000 + next() % 9_000),
                card_type: Some(if previous.is_none() { 0 } else { 2 }),
                day_offset: Some(day),
                current_elapsed_days: Some(ed),
                current_elapsed_seconds: Some(es),
            });
            last[card as usize] = Some((day, ts));
            ts += 40 + next() % 300;
        }
    }
    reviews
}

/// 一张卡（一个笔记）答 `answers` 次的几种作答模式，取自 BUG-5594 复现里 int4 发散的那几种
/// 以及混合评分 / 随机间隔两种常态。
#[derive(Clone, Copy, Debug)]
enum Pattern {
    /// 每天一次，总按 Again（sm113 / sm130io 的 int4 在这里发散）。
    DailyAgain,
    /// 一天里隔 30～90 秒连按 Again，每 50 次换一天（sm101 的 int4 在这里发散）。
    CramAgain,
    /// 每天一次，Again / Easy 交替。
    Alternate,
    /// 每天一次，混合评分。
    DailyMixed,
    /// 随机评分、随机间隔（0～9 天，同天内随机秒数）。
    RandomGaps,
}

const PATTERNS: [Pattern; 5] = [
    Pattern::DailyAgain,
    Pattern::CramAgain,
    Pattern::Alternate,
    Pattern::DailyMixed,
    Pattern::RandomGaps,
];

fn one_card(pattern: Pattern, answers: usize) -> Vec<ReviewInput> {
    let mut seed = 7u64;
    let mut next = || {
        seed = seed
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        (seed >> 33) as i64
    };
    let mut out = Vec::with_capacity(answers);
    let (mut day, mut ts): (i64, i64) = (0, 8 * 3600);
    let mut last: Option<(i64, i64)> = None;
    for i in 0..answers {
        let (ease, gap_days, gap_seconds): (u8, i64, i64) = match pattern {
            Pattern::DailyAgain => (1, 1, 0),
            Pattern::CramAgain => (1, i64::from(i % 50 == 49), 30 + next() % 60),
            Pattern::Alternate => (if i % 2 == 0 { 1 } else { 4 }, 1, 0),
            Pattern::DailyMixed => ([1u8, 2, 3, 3, 3, 3, 4][(next() % 7) as usize], 1, 0),
            Pattern::RandomGaps => ((1 + next() % 4) as u8, next() % 10, next() % 4000),
        };
        if gap_days > 0 {
            day += gap_days;
            ts = day * 86_400 + 8 * 3600 + next() % 3600;
        } else {
            ts += gap_seconds.max(1);
        }
        let (ed, es) = last.map_or((-1, -1), |(d, t)| (day - d, ts - t));
        out.push(ReviewInput {
            card_id: 10,
            note_id: Some(100),
            deck_id: Some(1),
            preset_id: Some(1),
            is_query: false,
            ease: Some(ease),
            duration_millis: Some(2_000 + next() % 9_000),
            card_type: Some(if last.is_none() { 0 } else { 2 }),
            day_offset: Some(day),
            current_elapsed_days: Some(ed),
            current_elapsed_seconds: Some(es),
        });
        last = Some((day, ts));
    }
    out
}

/// 回放 `reviews`（带每次作答前的预测），每 `answers / 20` 次量一次 card / note 状态峰值，
/// 返回 (全程峰值 [card, note], 预测)。
fn replay_small(
    model: &SmallModel,
    precision: StatePrecision,
    reviews: &[ReviewInput],
) -> ([f32; 2], Vec<f32>) {
    let mut runtime = SmallInference::new(model, precision);
    let mut peaks = [0.0f32; 2];
    let mut predictions = Vec::with_capacity(reviews.len());
    for chunk in reviews.chunks((reviews.len() / 20).max(1)) {
        let out = runtime.warm_up_reviews(chunk.to_vec(), true).unwrap();
        predictions.extend(out.into_iter().map(|(_, r)| r));
        for (peak, stream) in peaks.iter_mut().zip([0, 2]) {
            *peak = peak.max(runtime.stream_peak(stream));
        }
    }
    (peaks, predictions)
}

/// BUG-5594：每个小模型、每种作答模式，单卡 2 万次复习（上游复现用的长度）。int8 状态全程有限、
/// 峰值不超过 f32 的 2 倍，每次作答前的预测有限，与 f32 的最大差 ≤ 0.1、平均差 ≤ 0.01
/// （实测 2026-11-27：最大 0.052、平均 0.0054；int4 在同样的历史上最大 0.85、状态到 4e33）。
#[test]
fn every_small_model_keeps_long_card_states_bounded() {
    let answers = env_or("LONG_ANSWERS", 20_000) as usize;
    for id in SmallModelId::ALL {
        let model = SmallModel::from_bytes(small_file_of(id, SmallFile::Int8Weights)).unwrap();
        for pattern in PATTERNS {
            let reviews = one_card(pattern, answers);
            let (exact_peaks, exact) = replay_small(&model, StatePrecision::F32, &reviews);
            let (peaks, compact) = replay_small(&model, StatePrecision::Int8, &reviews);
            let context = format!("{} {pattern:?} x{answers}", id.name());
            assert_eq!(compact.len(), answers, "{context}: predictions");
            for (stream, (&c, &e)) in ["card", "note"].iter().zip(peaks.iter().zip(&exact_peaks)) {
                assert!(
                    e.is_finite() && c.is_finite() && c <= 2.0 * e.max(0.1),
                    "{context}: int8 {stream} state peak {c} vs f32 {e}"
                );
            }
            let mut max = 0.0f32;
            let mut sum = 0.0f64;
            for (k, (&c, &e)) in compact.iter().zip(&exact).enumerate() {
                assert!(
                    c.is_finite() && (0.0..=1.0).contains(&c),
                    "{context}: answer {k}: int8 prediction {c}"
                );
                let d = (c - e).abs();
                max = max.max(d);
                sum += f64::from(d);
            }
            let mean = sum / answers as f64;
            eprintln!(
                "{context}: peaks int8 {peaks:?} f32 {exact_peaks:?}; |dR| max {max:.4} mean {mean:.5}"
            );
            assert!(
                max <= 0.1 && mean <= 0.01,
                "{context}: int8 predictions drift from f32 (max {max}, mean {mean})"
            );
        }
    }
}

#[test]
fn long_histories_keep_compact_states_bounded() {
    let model = small_model();
    let (cards, days): (i64, i64) = (6, env_or("LONG_DAYS", 2500));
    let reviews = history(cards, days);
    let peaks = |precision: StatePrecision| {
        let mut runtime = SmallInference::new(&model, precision);
        runtime.warm_up_reviews(reviews.clone(), false).unwrap();
        [runtime.stream_peak(0), runtime.stream_peak(2)]
    };
    let exact = peaks(StatePrecision::F32);
    let compact = peaks(StatePrecision::Int8);
    eprintln!("Int8: card / note peaks {compact:?} (f32 {exact:?})");
    for (stream, (&c, &e)) in ["card", "note"].iter().zip(compact.iter().zip(&exact)) {
        assert!(
            c.is_finite() && c <= 2.0 * e.max(0.1),
            "Int8 {stream} state peak {c} vs f32 {e} after {days} reviews per card"
        );
    }
}

/// 大模型同样的历史：int8 与 f32 同量级（int4 在这里每卡 2,500 次复习峰值 ~1.2e3、1 万次 ~1.3e16，
/// 是删 int4 的另一半依据）。`LONG_DAYS=10000` 可加长（本地 ~1 分钟）。
#[test]
fn long_histories_keep_large_model_compact_states_bounded() {
    let (cards, days): (i64, i64) = (6, env_or("LONG_DAYS", 2500));
    let reviews = history(cards, days);
    let peaks = |precision: StatePrecision| {
        let mut runtime = RwkvInference::new(model(), precision);
        runtime.warm_up_reviews(reviews.clone(), false).unwrap();
        [runtime.stream_peak(0), runtime.stream_peak(2)]
    };
    let exact = peaks(StatePrecision::F32);
    let compact = peaks(StatePrecision::Int8);
    eprintln!("large Int8: card / note peaks {compact:?} (f32 {exact:?})");
    for (stream, (&c, &e)) in ["card", "note"].iter().zip(compact.iter().zip(&exact)) {
        assert!(
            c.is_finite() && c <= 2.0 * e.max(0.1),
            "large Int8 {stream} state peak {c} vs f32 {e} after {days} reviews per card"
        );
    }
}

/// int4 不再是可选精度：名字解析不出来，C ABI 的 4 被拒。
#[test]
fn int4_is_no_longer_a_precision() {
    assert!(StatePrecision::parse("int4").is_err());
    assert_eq!(StatePrecision::parse("int8").unwrap(), StatePrecision::Int8);
    for kind in [fushi_rwkv::ModelKind::Large, fushi_rwkv::ModelKind::Small] {
        assert_eq!(kind.default_precision(), StatePrecision::Int8);
    }
}
