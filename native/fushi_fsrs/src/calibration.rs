//! 校准图与 UM+（复习统计页）：每次复习**作答前**的预测回忆概率 vs 实际是否记住。
//!
//! 移植自 JSchoreels/Anki-Search-Stats-Extended @ 526a4f9（GPL-3.0；kuma3-anki-app 把同一份页面原样搬上
//! AnkiDroid）：分箱与自助法置信区间（`MemorisedBar.ts` `calibrationBinIndex` / `buildCalibrationBins`、
//! `calibrationBootstrap.ts`）、UM+（`umPlusData.ts` `buildUmPlusData`）。数值规则逐条对齐：
//!
//! - 校准图 20 个对数分箱：`floor(exp(ln 21 · p)) − 1`，与 fsrs-rs 的 `get_bin(p, 20)` 同一个式子；
//! - 每箱实际记住率的 95% 置信区间：先按（卡, 箱）汇总，再对**卡**有放回抽样 500 次（同一张卡的多次复习不独立，
//!   按卡抽才不会把区间算窄），种子固定（`0x5f3759df`，同一份数据每次画出来一样）；
//! - UM+：按两个模型的分歧 `FSRS − RWKV` 分 41 箱（每 0.05 一箱，JS `Math.round` 的「.5 往正无穷」取整），
//!   每箱两个模型各自的平均预测误差 `预测 − 实际`；分数 = 按箱内条数加权的箱均误差 RMSE。
//!
//! 这里只做数学：样本（卡、实际、两边的预测）由调用方给齐（FSRS 的留出预测见 lib.rs `ffsrs_predict_tss`，
//! RWKV 的回放预测由 fushi_rwkv 给），筛选与配对见 [report]。

use std::collections::{HashMap, HashSet};

use serde_json::{Value, json};

/// 校准图的箱数（`CALIBRATION_BIN_COUNT`）。
pub const CALIBRATION_BINS: usize = 20;

/// 自助法次数（`CALIBRATION_BOOTSTRAP_ITERATIONS`）。
pub const BOOTSTRAP_ITERATIONS: usize = 500;

const BOOTSTRAP_SEED: u32 = 0x5f37_59df;
const LOWER_PERCENTILE: f64 = 0.025;
const UPPER_PERCENTILE: f64 = 0.975;

/// UM+ 每单位分歧几箱（`UM_PLUS_BINS_PER_UNIT`）。
pub const UM_PLUS_BINS_PER_UNIT: i64 = 20;

/// UM+ 箱数（−1..1，每 0.05 一箱）。
pub const UM_PLUS_BIN_COUNT: usize = 2 * UM_PLUS_BINS_PER_UNIT as usize + 1;

/// 预测概率所在的校准箱。
pub fn bin_index(predicted: f64) -> usize {
    let n = CALIBRATION_BINS as f64;
    let raw = ((n + 1.0).ln() * predicted).exp().floor() - 1.0;
    raw.clamp(0.0, n - 1.0) as usize
}

/// 只收 [0, 1] 里的有限值（`isValidProbability` / `isProbability`）。
fn probability(v: f32) -> Option<f64> {
    (v.is_finite() && (0.0..=1.0).contains(&v)).then_some(v as f64)
}

/// `seededRandom`：32 位整数运算逐位照搬（JS 的 `Math.imul` / `>>>` 都是 32 位环绕）。
struct Rng(u32);

impl Rng {
    fn next(&mut self) -> f64 {
        self.0 = self.0.wrapping_add(0x6d2b_79f5);
        let mut v = self.0;
        v = (v ^ (v >> 15)).wrapping_mul(v | 1);
        v ^= v.wrapping_add((v ^ (v >> 7)).wrapping_mul(v | 61));
        (v ^ (v >> 14)) as f64 / 4_294_967_296.0
    }
}

/// 已升序的 [values] 的分位数（线性插值，`quantileSorted`）。
fn quantile_sorted(values: &[f64], q: f64) -> f64 {
    let pos = (values.len() - 1) as f64 * q;
    let lo = pos.floor() as usize;
    let hi = pos.ceil() as usize;
    let w = pos - lo as f64;
    values[lo] * (1.0 - w) + values[hi] * w
}

/// 每箱实际记住率的卡级自助法 95% 区间（`cardBootstrapConfidenceIntervals`）。观测 = (卡, 箱, 记住)，
/// 卡按第一次出现的先后、箱按卡内第一次出现的先后排（与 JS `Map` 的插入序一致）。
pub fn bootstrap_intervals(
    observations: &[(i64, usize, f64)],
    iterations: usize,
) -> Vec<Option<(f64, f64)>> {
    let mut slot: HashMap<i64, usize> = HashMap::new();
    // 每张卡：(箱, 记住数, 条数)，箱按插入序。
    let mut cards: Vec<Vec<(usize, f64, f64)>> = Vec::new();
    for &(card, bin, actual) in observations {
        let k = *slot.entry(card).or_insert_with(|| {
            cards.push(Vec::new());
            cards.len() - 1
        });
        match cards[k].iter_mut().find(|c| c.0 == bin) {
            Some(c) => {
                c.1 += actual;
                c.2 += 1.0;
            }
            None => cards[k].push((bin, actual, 1.0)),
        }
    }
    if cards.is_empty() || iterations == 0 {
        return vec![None; CALIBRATION_BINS];
    }
    let mut estimates: Vec<Vec<f64>> = vec![Vec::new(); CALIBRATION_BINS];
    let mut rng = Rng(BOOTSTRAP_SEED);
    let mut successes = [0.0f64; CALIBRATION_BINS];
    let mut counts = [0.0f64; CALIBRATION_BINS];
    for _ in 0..iterations {
        successes.fill(0.0);
        counts.fill(0.0);
        for _ in 0..cards.len() {
            let card = &cards[(rng.next() * cards.len() as f64).floor() as usize];
            for &(bin, s, n) in card {
                successes[bin] += s;
                counts[bin] += n;
            }
        }
        for bin in 0..CALIBRATION_BINS {
            if counts[bin] > 0.0 {
                estimates[bin].push(successes[bin] / counts[bin]);
            }
        }
    }
    estimates
        .into_iter()
        .map(|mut v| {
            if v.is_empty() {
                return None;
            }
            v.sort_by(f64::total_cmp);
            Some((
                quantile_sorted(&v, LOWER_PERCENTILE),
                quantile_sorted(&v, UPPER_PERCENTILE),
            ))
        })
        .collect()
}

/// 一条校准曲线：[CALIBRATION_BINS] 箱（空箱为 None）与总体指标。
#[derive(Debug, Clone, PartialEq)]
pub struct Series {
    pub count: usize,
    /// 二元交叉熵（预测钳到 [1e-4, 1 − 1e-4]，与 fsrs-rs `weighted_binary_cross_entropy` 同一钳位）。
    pub log_loss: f64,
    /// 校准箱的「箱均预测 − 箱均实际」按条数加权的 RMSE（不是 fsrs-rs 按间隔 / 长度分箱的 RMSE(bins)）。
    pub rmse: f64,
    pub bins: Vec<Option<Bin>>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Bin {
    pub count: usize,
    /// 箱均预测。
    pub predicted: f64,
    /// 箱均实际（记住率）。
    pub actual: f64,
    pub interval: Option<(f64, f64)>,
}

/// 由 (卡, 实际, 预测) 样本画一条校准曲线；没有样本返回 None。
pub fn series(samples: &[(i64, f64, f64)], iterations: usize) -> Option<Series> {
    if samples.is_empty() {
        return None;
    }
    let mut pred = [0.0f64; CALIBRATION_BINS];
    let mut real = [0.0f64; CALIBRATION_BINS];
    let mut count = [0usize; CALIBRATION_BINS];
    let mut loss = 0.0f64;
    let mut observations = Vec::with_capacity(samples.len());
    for &(card, actual, p) in samples {
        let bin = bin_index(p);
        pred[bin] += p;
        real[bin] += actual;
        count[bin] += 1;
        observations.push((card, bin, actual));
        let c = p.clamp(1e-4, 1.0 - 1e-4);
        loss -= actual * c.ln() + (1.0 - actual) * (1.0 - c).ln();
    }
    let intervals = bootstrap_intervals(&observations, iterations);
    let n = samples.len() as f64;
    let mut sq = 0.0f64;
    let bins = (0..CALIBRATION_BINS)
        .map(|b| {
            (count[b] > 0).then(|| {
                let c = count[b] as f64;
                let bin = Bin {
                    count: count[b],
                    predicted: pred[b] / c,
                    actual: real[b] / c,
                    interval: intervals[b],
                };
                sq += c * (bin.predicted - bin.actual).powi(2);
                bin
            })
        })
        .collect();
    Some(Series {
        count: samples.len(),
        log_loss: loss / n,
        rmse: (sq / n).sqrt(),
        bins,
    })
}

#[derive(Debug, Clone, PartialEq)]
pub struct UmPlusBin {
    pub index: usize,
    pub count: usize,
    /// 箱内平均分歧（FSRS − RWKV）。
    pub disagreement: f64,
    /// 箱内 FSRS 的平均预测误差（预测 − 实际）。
    pub fsrs_error: f64,
    pub rwkv_error: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct UmPlus {
    pub count: usize,
    pub fsrs_score: f64,
    pub rwkv_score: f64,
    pub bins: Vec<UmPlusBin>,
}

/// 分歧所在的 UM+ 箱：`clamp(Math.round(d · 20) + 20, 0, 40)`。JS `Math.round` 是「.5 往正无穷」（负数也一样，
/// −2.5 → −2），Rust `round` 是远离零，所以写成 `floor(x + 0.5)`。
pub fn um_plus_index(disagreement: f64) -> usize {
    let k =
        (disagreement * UM_PLUS_BINS_PER_UNIT as f64 + 0.5).floor() as i64 + UM_PLUS_BINS_PER_UNIT;
    k.clamp(0, UM_PLUS_BIN_COUNT as i64 - 1) as usize
}

/// UM+（`buildUmPlusData`）：(实际, FSRS 预测, RWKV 预测) 配对样本。
pub fn um_plus(samples: &[(f64, f64, f64)]) -> UmPlus {
    let mut dis = [0.0f64; UM_PLUS_BIN_COUNT];
    let mut fe = [0.0f64; UM_PLUS_BIN_COUNT];
    let mut re = [0.0f64; UM_PLUS_BIN_COUNT];
    let mut counts = [0usize; UM_PLUS_BIN_COUNT];
    for &(actual, f, r) in samples {
        let d = f - r;
        let k = um_plus_index(d);
        dis[k] += d;
        fe[k] += f - actual;
        re[k] += r - actual;
        counts[k] += 1;
    }
    let bins: Vec<UmPlusBin> = (0..UM_PLUS_BIN_COUNT)
        .filter(|&k| counts[k] > 0)
        .map(|k| {
            let c = counts[k] as f64;
            UmPlusBin {
                index: k,
                count: counts[k],
                disagreement: dis[k] / c,
                fsrs_error: fe[k] / c,
                rwkv_error: re[k] / c,
            }
        })
        .collect();
    let count: usize = counts.iter().sum();
    let score = |e: fn(&UmPlusBin) -> f64| {
        if count == 0 {
            return 0.0;
        }
        (bins
            .iter()
            .map(|b| b.count as f64 * e(b).powi(2))
            .sum::<f64>()
            / count as f64)
            .sqrt()
    };
    UmPlus {
        count,
        fsrs_score: score(|b| b.fsrs_error),
        rwkv_score: score(|b| b.rwkv_error),
        bins,
    }
}

/// 一次统计的样本（与条目一一对应）。
pub struct Samples<'a> {
    /// 卡（自助法按卡抽样、范围按卡筛）。
    pub cards: &'a [i64],
    /// 复习日志的数字 ID（与 RWKV 回放行的标签同一个：`store::schema::anki_numeric_id`）。
    pub tags: &'a [i64],
    /// 复习时刻（毫秒）。
    pub ats: &'a [i64],
    /// 距上一次评分的天数（按复习日）。
    pub elapsed: &'a [i64],
    /// 1 = 记住（评分 > 1）。
    pub actual: &'a [i64],
    /// FSRS 作答前的预测；NaN = 没有（时间序列切分的第一段只训练不预测）。
    pub fsrs: &'a [f32],
}

/// 筛选条件。
#[derive(Clone, Copy, Debug)]
pub struct Filter<'a> {
    /// 只看 `[from, to)` 毫秒之间的复习（统计页的时间范围）。
    pub from: Option<i64>,
    pub to: Option<i64>,
    /// 距上一次评分至少几天（扩展的口径：同一天里的再次复习不进校准）。
    pub min_elapsed: i64,
    /// 只看这些卡（统计页选的牌组）；None = 全部。
    pub scope: Option<&'a HashSet<i64>>,
}

/// 统计页要的一整份结果（JSON，见 lib.rs `ffsrs_calibration_report`）。
///
/// - `fsrs`：有 FSRS 留出预测的复习；
/// - `rwkv`：其中也有 RWKV 回放预测的那些（两条线比的是同一批复习，与 kuma3 一致）；
/// - `umPlus`：同上那批配对样本。
pub fn report(samples: &Samples<'_>, rwkv: &HashMap<i64, f32>, filter: Filter<'_>) -> Value {
    let n = samples.cards.len();
    let mut eligible = 0usize;
    let mut fsrs: Vec<(i64, f64, f64)> = Vec::new();
    let mut rw: Vec<(i64, f64, f64)> = Vec::new();
    let mut paired: Vec<(f64, f64, f64)> = Vec::new();
    for i in 0..n {
        if samples.elapsed[i] < filter.min_elapsed
            || filter.from.is_some_and(|f| samples.ats[i] < f)
            || filter.to.is_some_and(|t| samples.ats[i] >= t)
            || filter.scope.is_some_and(|s| !s.contains(&samples.cards[i]))
        {
            continue;
        }
        eligible += 1;
        let actual = if samples.actual[i] > 0 { 1.0 } else { 0.0 };
        let Some(f) = probability(samples.fsrs[i]) else {
            continue;
        };
        fsrs.push((samples.cards[i], actual, f));
        if let Some(r) = rwkv.get(&samples.tags[i]).copied().and_then(probability) {
            rw.push((samples.cards[i], actual, r));
            paired.push((actual, f, r));
        }
    }
    let series_json = |s: Option<Series>| match s {
        None => Value::Null,
        Some(s) => json!({
            "count": s.count,
            "logLoss": s.log_loss,
            "rmse": s.rmse,
            "bins": s.bins.iter().map(|b| match b {
                None => Value::Null,
                Some(b) => json!({
                    "count": b.count,
                    "predicted": b.predicted,
                    "actual": b.actual,
                    "lower": b.interval.map(|i| i.0),
                    "upper": b.interval.map(|i| i.1),
                }),
            }).collect::<Vec<_>>(),
        }),
    };
    let um = um_plus(&paired);
    json!({
        "eligible": eligible,
        "fsrs": series_json(series(&fsrs, BOOTSTRAP_ITERATIONS)),
        "rwkv": series_json(series(&rw, BOOTSTRAP_ITERATIONS)),
        "umPlus": if um.count == 0 { Value::Null } else { json!({
            "count": um.count,
            "fsrsScore": um.fsrs_score,
            "rwkvScore": um.rwkv_score,
            "bins": um.bins.iter().map(|b| json!({
                "index": b.index,
                "count": b.count,
                "disagreement": b.disagreement,
                "fsrsError": b.fsrs_error,
                "rwkvError": b.rwkv_error,
            })).collect::<Vec<_>>(),
        })},
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bin_index_matches_the_log_scaled_rule() {
        // floor(exp(ln 21 · p)) − 1：p = 0 落第 0 箱，p = 1 落最后一箱，0.5 落 floor(√21) − 1 = 3。
        assert_eq!(bin_index(0.0), 0);
        assert_eq!(bin_index(1.0), CALIBRATION_BINS - 1);
        assert_eq!(bin_index(0.5), 3);
        assert_eq!(
            bin_index(0.9),
            ((21f64.ln() * 0.9).exp().floor() - 1.0) as usize
        );
        assert_eq!(bin_index(-0.1), 0);
        assert_eq!(bin_index(1.5), CALIBRATION_BINS - 1);
    }

    #[test]
    fn rng_matches_the_extension_seeded_random() {
        // 参考值：node 里跑 calibrationBootstrap.ts 的 seededRandom(0x5f3759df) 前五次。
        let mut r = Rng(BOOTSTRAP_SEED);
        let got: Vec<f64> = (0..5).map(|_| r.next()).collect();
        assert_eq!(
            got,
            vec![
                0.8006246744189411,
                0.06993603962473571,
                0.6627159540075809,
                0.06382904597558081,
                0.6551432637497783,
            ]
        );
    }

    #[test]
    fn series_bins_means_and_log_loss() {
        let samples = vec![(1, 1.0, 0.9), (1, 0.0, 0.9), (2, 1.0, 0.3)];
        let s = series(&samples, 0).unwrap();
        assert_eq!(s.count, 3);
        let b = s.bins[bin_index(0.9)].as_ref().unwrap();
        assert_eq!(b.count, 2);
        assert!((b.predicted - 0.9).abs() < 1e-12);
        assert!((b.actual - 0.5).abs() < 1e-12);
        assert!(b.interval.is_none(), "0 iterations: no interval");
        let expect = -((0.9f64).ln() + (0.1f64).ln() + (0.3f64).ln()) / 3.0;
        assert!((s.log_loss - expect).abs() < 1e-12);
        // RMSE：两箱各自的（预测 − 实际）按条数加权。
        let rmse = ((2.0 * (0.9f64 - 0.5).powi(2) + (0.3f64 - 1.0).powi(2)) / 3.0).sqrt();
        assert!((s.rmse - rmse).abs() < 1e-12);
        assert!(series(&[], 10).is_none());
    }

    #[test]
    fn bootstrap_is_deterministic_and_brackets_the_mean() {
        let mut obs = Vec::new();
        for card in 0..40 {
            for k in 0..5 {
                obs.push((card, 7usize, if (card + k) % 3 == 0 { 0.0 } else { 1.0 }));
            }
        }
        let a = bootstrap_intervals(&obs, BOOTSTRAP_ITERATIONS);
        let b = bootstrap_intervals(&obs, BOOTSTRAP_ITERATIONS);
        assert_eq!(a, b);
        let (lo, hi) = a[7].unwrap();
        let mean = obs.iter().map(|o| o.2).sum::<f64>() / obs.len() as f64;
        assert!(lo < mean && mean < hi, "{lo} < {mean} < {hi}");
        assert!(a[0].is_none());
    }

    #[test]
    fn um_plus_index_rounds_like_js_math_round() {
        // node：[-0.5, 0.5, -1.5, 1.5].map(Math.round) = [0, 1, -1, 2]；±1 之外夹到两端。
        assert_eq!(um_plus_index(-0.5 / 20.0), 20);
        assert_eq!(um_plus_index(0.5 / 20.0), 21);
        assert_eq!(um_plus_index(-1.5 / 20.0), 19);
        assert_eq!(um_plus_index(1.5 / 20.0), 22);
        assert_eq!(um_plus_index(-3.0), 0);
        assert_eq!(um_plus_index(3.0), UM_PLUS_BIN_COUNT - 1);
    }

    #[test]
    fn um_plus_bins_and_scores() {
        let um = um_plus(&[(1.0, 0.5, 0.525), (0.0, 0.525, 0.5), (1.0, 0.9, 0.2)]);
        let idx: Vec<usize> = um.bins.iter().map(|b| b.index).collect();
        // 0.5 − 0.525 在浮点里略小于 −0.025（×20 = −0.5000000000000004，JS 同样舍到 −1 → 19 箱）。
        assert_eq!(idx, vec![19, 21, 34]);
        // 每箱两个模型的误差之差恒等于平均分歧。
        for b in &um.bins {
            assert!((b.fsrs_error - b.rwkv_error - b.disagreement).abs() < 1e-12);
        }
        let fs = ((0.25f64 + 0.525f64.powi(2) + 0.01) / 3.0).sqrt();
        assert!((um.fsrs_score - fs).abs() < 1e-12);
        assert_eq!(um.count, 3);
        assert_eq!(um_plus(&[]).count, 0);
    }

    #[test]
    fn report_filters_and_pairs() {
        let cards = [1, 1, 2, 3];
        let tags = [10, 11, 12, 13];
        let ats = [100, 200, 300, 400];
        let elapsed = [1, 0, 3, 2];
        let actual = [1i64, 0, 1, 0];
        let fsrs = [0.9, 0.8, f32::NAN, 0.4];
        let rwkv: HashMap<i64, f32> = [(10, 0.85), (13, 0.5)].into();
        let samples = Samples {
            cards: &cards,
            tags: &tags,
            ats: &ats,
            elapsed: &elapsed,
            actual: &actual,
            fsrs: &fsrs,
        };
        let all = report(
            &samples,
            &rwkv,
            Filter {
                from: None,
                to: None,
                min_elapsed: 1,
                scope: None,
            },
        );
        // 第 2 条同一天（elapsed 0）不算；第 3 条没有 FSRS 预测；剩 1、4 两条，两条都有 RWKV。
        assert_eq!(all["eligible"], 3);
        assert_eq!(all["fsrs"]["count"], 2);
        assert_eq!(all["rwkv"]["count"], 2);
        assert_eq!(all["umPlus"]["count"], 2);
        let scope: HashSet<i64> = [3].into();
        let one = report(
            &samples,
            &rwkv,
            Filter {
                from: Some(150),
                to: None,
                min_elapsed: 1,
                scope: Some(&scope),
            },
        );
        assert_eq!(one["eligible"], 1);
        assert_eq!(one["fsrs"]["count"], 1);
        let none = report(
            &samples,
            &HashMap::new(),
            Filter {
                from: None,
                to: None,
                min_elapsed: 1,
                scope: None,
            },
        );
        assert!(none["rwkv"].is_null() && none["umPlus"].is_null());
    }
}
