// Copyright: Ankitects Pty Ltd and contributors; Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
// Adapted for Fushi from Pedrubik2000/kuma3-anki-core@c639bcec696f2317f9bb9a736d433b9d6c0d9c56 rslib/src/rwkv/mod.rs
//
//! 作答时排程：RWKV-Curve 的区间求解。
//!
//! 每个评分一次假设作答，读那一行的**曲线头**（这次作答之后的遗忘曲线 R(t)，按构造随 t 不增），
//! 间隔 = R(t) 第一次 ≤ 目标保留率的 t。不能用即时头（`p_imm`）沿天数外推：它是「到期这一刻答对的
//! 概率」，训练数据里间隔越长的卡本就越熟，所以它几乎不随假设的间隔下降、也不单调——2026-10-20 在
//! 真实历史上实测，保留率 0.8 时一半用户的 Good 间隔顶到上限、另一些用户天天到期（README「排程」）。
//!
//! 下面的网格 / 割线细化 / PAVA 评分顺序修正与上游 `unrounded_intervals_for_answer_curves`、
//! `crossings_on_grid`、`crossing_between`、`pava_non_decreasing`、`interval_search_days`、
//! `clamped_interval_days` 逐字相同（上游 `enforce_grade_order = true`，四个评分同一个目标）。

use crate::rwkv::predict_curve;
use crate::rwkv::small::SmallHeads;

const SECONDS_PER_DAY: f32 = 86_400.0;

/// 一次假设作答之后的遗忘曲线。
pub enum AnswerCurve {
    /// 大模型：128 条固定指数曲线的混合权重。
    Large(Vec<f32>),
    /// 小模型：3 条幂曲线的混合（`w_logits`、`s_raw`、`d_raw`）。
    Small(SmallHeads),
}

impl AnswerCurve {
    /// 作答后 `seconds` 秒的 R；随 `seconds` 不增。
    pub fn retrievability(&self, seconds: f32) -> f32 {
        match self {
            Self::Large(weights) => predict_curve(weights, seconds),
            Self::Small(heads) => heads.curve_retrievability(seconds),
        }
    }
}

/// 四条曲线（Again..Easy）在 `target_retention` 下的间隔（整天，1..=`max_interval_days`，到上限仍高于
/// 目标给上限），评分顺序已修正为不减。
pub fn answer_intervals(curves: &[AnswerCurve; 4], target_retention: f32, max_interval_days: u32) -> [u32; 4] {
    let margins_at = |days: f32| -> [f32; 4] {
        pava_non_decreasing(std::array::from_fn(|index| {
            curves[index].retrievability(days * SECONDS_PER_DAY) - target_retention
        }))
    };
    crossings_on_grid(max_interval_days, margins_at).map(|days| clamped_interval_days(days, max_interval_days))
}

const SUB_DAY_SEARCH_POINTS: [f32; 14] = [
    1.0 / 1440.0,
    5.0 / 1440.0,
    10.0 / 1440.0,
    20.0 / 1440.0,
    30.0 / 1440.0,
    1.0 / 24.0,
    2.0 / 24.0,
    3.0 / 24.0,
    4.0 / 24.0,
    6.0 / 24.0,
    8.0 / 24.0,
    12.0 / 24.0,
    16.0 / 24.0,
    20.0 / 24.0,
];

fn crossings_on_grid<const N: usize>(max_interval_days: u32, margins_at: impl Fn(f32) -> [f32; N]) -> [f32; N] {
    let mut points = Vec::new();
    if margins_at(1.0).iter().any(|margin| *margin <= 0.0) {
        points.extend(SUB_DAY_SEARCH_POINTS);
    }
    points.extend(
        interval_search_days(max_interval_days)
            .into_iter()
            .map(|day| day as f32),
    );

    let maximum = max_interval_days as f32;
    let mut crossings: [Option<f32>; N] = [None; N];
    let mut previous: [Option<(f32, f32)>; N] = [None; N];
    let mut at_zero: Option<[f32; N]> = None;
    for point in points {
        let margins = margins_at(point);
        for index in 0..N {
            if crossings[index].is_some() {
                continue;
            }
            let margin = margins[index];
            if margin <= 0.0 {
                let (low, low_margin) =
                    previous[index].unwrap_or_else(|| (0.0, at_zero.get_or_insert_with(|| margins_at(0.0))[index]));
                let crossing = if low_margin > 0.0 {
                    crossing_between(low, low_margin, point, margin, |days| margins_at(days)[index])
                } else {
                    point
                };
                crossings[index] = Some(crossing.min(maximum));
            }
            previous[index] = Some((point, margin));
        }
        if crossings.iter().all(Option::is_some) {
            break;
        }
    }
    crossings.map(|crossing| crossing.unwrap_or(maximum))
}

fn crossing_between(low: f32, low_margin: f32, high: f32, high_margin: f32, margin: impl Fn(f32) -> f32) -> f32 {
    const MAX_STEPS: usize = 64;
    let (mut low, mut low_margin) = (low as f64, low_margin as f64);
    let (mut high, mut high_margin) = (high as f64, high_margin as f64);
    let mut last_moved = 0;
    for _ in 0..MAX_STEPS {
        let tolerance = (1.0 / SECONDS_PER_DAY as f64).max(high * 1e-6);
        if high - low <= tolerance || low_margin <= high_margin {
            break;
        }
        let mut day = (low * high_margin - high * low_margin) / (high_margin - low_margin);
        if !(day > low && day < high) {
            day = 0.5 * (low + high);
        }
        let day_margin = margin(day as f32) as f64;
        if day_margin > 0.0 {
            low = day;
            low_margin = day_margin;
            if last_moved == -1 {
                high_margin *= 0.5;
            }
            last_moved = -1;
        } else {
            high = day;
            high_margin = day_margin;
            if last_moved == 1 {
                low_margin *= 0.5;
            }
            last_moved = 1;
        }
    }
    high as f32
}

fn pava_non_decreasing(values: [f32; 4]) -> [f32; 4] {
    #[derive(Clone, Copy)]
    struct Block {
        first: usize,
        last: usize,
        sum: f32,
        count: usize,
    }

    impl Block {
        fn mean(self) -> f32 {
            self.sum / self.count as f32
        }
    }

    let empty_block = Block {
        first: 0,
        last: 0,
        sum: 0.0,
        count: 0,
    };
    let mut blocks = [empty_block; 4];
    let mut block_count = 0;
    for (index, value) in values.into_iter().enumerate() {
        blocks[block_count] = Block {
            first: index,
            last: index,
            sum: value,
            count: 1,
        };
        block_count += 1;
        while block_count >= 2 {
            let right = blocks[block_count - 1];
            let left = blocks[block_count - 2];
            if left.mean() <= right.mean() {
                break;
            }

            blocks[block_count - 2] = Block {
                first: left.first,
                last: right.last,
                sum: left.sum + right.sum,
                count: left.count + right.count,
            };
            block_count -= 1;
        }
    }

    let mut adjusted = [0.0; 4];
    for block in &blocks[..block_count] {
        adjusted[block.first..=block.last].fill(block.mean());
    }
    adjusted
}

fn interval_search_days(max_interval_days: u32) -> Vec<u32> {
    if max_interval_days <= 30 {
        return (1..=max_interval_days).collect();
    }

    let mut days = (1..=30).collect::<Vec<_>>();
    let mut day = 45;
    while day < max_interval_days {
        days.push(day);
        day = ((day as f32) * 1.5) as u32;
    }
    days.push(max_interval_days);
    days
}

fn clamped_interval_days(elapsed_days: f32, max_interval_days: u32) -> u32 {
    elapsed_days.ceil().clamp(1.0, max_interval_days as f32) as u32
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 已知形状的曲线：小模型单分量（其余两个分量权重 ≈ 0），d = 1，S = `scale_days`，
    /// 即 R(t) = 1 / (1 + t/S)，R = r 处 t = S (1/r - 1)。
    fn hyperbolic(scale_days: f32) -> AnswerCurve {
        AnswerCurve::Small(SmallHeads {
            p_logits: [0.0; 4],
            curve: [
                0.0,
                -50.0,
                -50.0,
                (scale_days * SECONDS_PER_DAY).ln(),
                0.0,
                0.0,
                0.0,
                0.0,
                0.0,
            ],
        })
    }

    #[test]
    fn interval_is_the_target_crossing_rounded_up() {
        // 越线点都不落在整数天上（落在整数上时 ceil 对 1 秒的误差敏感）。
        let curves = [hyperbolic(0.6), hyperbolic(3.6), hyperbolic(9.4), hyperbolic(39.2)];
        // 0.8：t = S/4 = 0.15 / 0.9 / 2.35 / 9.8 天。
        assert_eq!(answer_intervals(&curves, 0.8, 36_500), [1, 1, 3, 10]);
        // 0.5：t = S。
        assert_eq!(answer_intervals(&curves, 0.5, 36_500), [1, 4, 10, 40]);
    }

    #[test]
    fn grade_order_and_limits() {
        // Hard 的曲线比 Good 长：PAVA 把它们拉到同一处，结果不减。
        let curves = [hyperbolic(1.3), hyperbolic(30.3), hyperbolic(10.3), hyperbolic(40.3)];
        let days = answer_intervals(&curves, 0.5, 36_500);
        assert!(days.windows(2).all(|w| w[0] <= w[1]), "{days:?}");
        assert!(days[1] > 10 && days[1] < 30, "{days:?}");
        // 到上限仍高于目标：给上限；最短 1 天。
        let long = || hyperbolic(1e6);
        assert_eq!(answer_intervals(&[long(), long(), long(), long()], 0.9, 365), [365; 4]);
        let short = || hyperbolic(1e-4);
        assert_eq!(
            answer_intervals(&[short(), short(), short(), short()], 0.9, 365),
            [1; 4]
        );
    }
}
