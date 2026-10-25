//! 确定性 FSRS（设计 §4.5）：重放与评分预览只用这一份。
//!
//! fsrs-rs 的推理用 `f32::powf / exp / ln`，它们落到各平台自己的 libm（MSVC CRT / bionic / Apple
//! libm / glibc），末位可能不同 —— 五台设备重放同一段历史会得到不同的 stability，Merkle 摘要永远对不上。
//! 这里把重放用到的推理路径**逐行**移植自 Cargo.lock 钉住的 fsrs-rs rev（`model_v6.rs` / `model_v7.rs` /
//! `model.rs` 的 step / next_states / memory_state / memory_state_from_sm2 / 参数补全与裁剪），超越函数一律
//! 换成纯 Rust 的 `libm`（musl 移植，逐位确定），`mul_add` 换成 `libm::fmaf`（软件实现也是正确舍入）。
//!
//! 与 fsrs crate 的差别只在超越函数的末位舍入；`tests::matches_fsrs_crate_within_ulps` 在本机对拍。
//! 升级 fsrs-rs rev 时必须同步本文件（`tests` 里的对拍会先红）。

use libm::{expf, expm1f, fmaf, logf, powf, roundf};

pub const S_MIN: f32 = 0.0001;
pub const S_MAX: f32 = 36500.0;
pub const D_MIN: f32 = 1.0;
pub const D_MAX: f32 = 10.0;
const INIT_S_MAX: f32 = 100.0;
const FSRS5_DEFAULT_DECAY: f32 = 0.5;

pub const FSRS6_DEFAULT: [f32; 21] = [
    0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001, 1.8722, 0.1666, 0.796, 1.4835, 0.0614, 0.2629,
    1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658, 0.1542,
];

pub const FSRS7_DEFAULT: [f32; 34] = [
    0.1104, 2.2395, 3.9221, 11.7841, 6.1686, 0.6457, 3.6807, 1.9795, 0.0, 1.3826, 0.7024, 0.5999, 0.8146, 0.6398,
    1.0, 1.3207, 0.6707, 3.8668, 0.4416, 0.0934, 1.8631, 0.6162, 1.0869, 0.1567, 0.0801, 0.2421, 0.9464, 0.1433,
    0.7145, 0.0, 0.5667, 0.3734, 0.5333, 0.3048,
];

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Memory {
    pub s: f32,
    pub d: f32,
    pub sf: f32,
}

impl Memory {
    const ZERO: Memory = Memory { s: 0.0, d: 0.0, sf: 0.0 };
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Item {
    pub memory: Memory,
    pub interval: f32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Version {
    Fsrs6,
    Fsrs7,
}

#[derive(Clone, Debug)]
pub struct Model {
    pub version: Version,
    w: Vec<f32>,
}

fn clamp(v: f32, lo: f32, hi: f32) -> f32 {
    v.clamp(lo, hi)
}

impl Model {
    /// `FSRS::new`：补全参数（空 = FSRS-7 默认；17 / 19 / 21 = FSRS-6；34 = FSRS-7）、校验有限、裁剪。
    pub fn new(params: &[f32]) -> Result<Model, String> {
        let version = if params.is_empty() || params.len() == 34 { Version::Fsrs7 } else { Version::Fsrs6 };
        let mut w: Vec<f32> = match (version, params.len()) {
            (Version::Fsrs7, 0) => FSRS7_DEFAULT.to_vec(),
            (Version::Fsrs7, _) => params.to_vec(),
            (Version::Fsrs6, 17) => {
                let mut p = params.to_vec();
                p[4] = fmaf(p[5], 2.0, p[4]);
                p[5] = logf(fmaf(p[5], 3.0, 1.0)) / 3.0;
                p[6] += 0.5;
                p.extend_from_slice(&[0.0, 0.0, 0.0, FSRS5_DEFAULT_DECAY]);
                p
            }
            (Version::Fsrs6, 19) => {
                let mut p = params.to_vec();
                p.extend_from_slice(&[0.0, FSRS5_DEFAULT_DECAY]);
                p
            }
            (Version::Fsrs6, 21) => params.to_vec(),
            (_, n) => return Err(format!("invalid parameter count {n}")),
        };
        if w.iter().any(|v| !v.is_finite()) {
            return Err("parameters must be finite".into());
        }
        match version {
            Version::Fsrs7 => clip7(&mut w),
            Version::Fsrs6 => clip6(&mut w),
        }
        Ok(Model { version, w })
    }

    /// 某算法的默认参数（fsrs7 / fsrs6）。
    pub fn defaults(version: Version) -> &'static [f32] {
        match version {
            Version::Fsrs6 => &FSRS6_DEFAULT,
            Version::Fsrs7 => &FSRS7_DEFAULT,
        }
    }

    fn init_stability(&self, rating: u32) -> f32 {
        self.w[(rating.saturating_sub(1).min(3)) as usize]
    }

    fn init_difficulty(&self, rating: u32) -> f32 {
        let w = &self.w;
        match self.version {
            Version::Fsrs6 => w[4] - expf(w[5] * rating.saturating_sub(1) as f32) + 1.0,
            Version::Fsrs7 => w[4] - expf(w[5] * (rating as usize - 1) as f32) + 1.0,
        }
    }

    pub fn step(&self, delta_t: f32, rating: u32, state: Memory, nth: usize) -> Memory {
        let last = Memory {
            s: clamp(state.s, S_MIN, S_MAX),
            d: clamp(state.d, D_MIN, D_MAX),
            sf: clamp(state.sf, S_MIN, S_MAX),
        };
        let mut next = match self.version {
            Version::Fsrs6 => v6_next_state(&self.w, last, delta_t, rating),
            Version::Fsrs7 => v7_next_state(&self.w, last, delta_t, rating as usize),
        };
        if nth == 0 && state.s == 0.0 {
            let r = rating.clamp(1, 4);
            next.s = clamp(self.init_stability(r), S_MIN, S_MAX);
            next.d = clamp(self.init_difficulty(r), D_MIN, D_MAX);
            next.sf = if self.version == Version::Fsrs7 { clamp(next.s * 0.8, S_MIN, S_MAX) } else { next.s };
        }
        if rating == 0 { last } else { next }
    }

    fn init_from_first(&self, rating: u32) -> Memory {
        if rating == 0 {
            return Memory { s: S_MIN, d: D_MIN, sf: S_MIN };
        }
        let r = rating.clamp(1, 4);
        let s = clamp(self.init_stability(r), S_MIN, S_MAX);
        Memory {
            s,
            d: clamp(self.init_difficulty(r), D_MIN, D_MAX),
            sf: if self.version == Version::Fsrs7 { clamp(s * 0.8, S_MIN, S_MAX) } else { s },
        }
    }

    /// `FSRS::memory_state`（`forward_reviews` + 校验有限）。
    pub fn memory_state(&self, reviews: &[(u32, f32)], starting: Option<Memory>) -> Result<Memory, String> {
        let (mut state, start) = match starting {
            Some(s) => (s, 0),
            None if reviews.is_empty() => (Memory::ZERO, 0),
            None => (self.init_from_first(reviews[0].0), 1),
        };
        for (i, &(rating, dt)) in reviews.iter().enumerate().skip(start) {
            state = self.step(dt, rating, state, i);
        }
        self.validate(state)
    }

    fn validate(&self, m: Memory) -> Result<Memory, String> {
        if m.s.is_finite() && m.d.is_finite() && (self.version == Version::Fsrs6 || m.sf.is_finite()) {
            Ok(m)
        } else {
            Err("invalid memory state".into())
        }
    }

    pub fn forgetting_curve(&self, t: f32, m: Memory) -> f32 {
        match self.version {
            Version::Fsrs6 => v6_forgetting_curve(&self.w, t, m.s),
            Version::Fsrs7 => v7_forgetting_curve(&self.w, t, m),
        }
    }

    pub fn next_interval(&self, m: Memory, desired_retention: f32) -> f32 {
        match self.version {
            Version::Fsrs6 => v6_next_interval(&self.w, m.s, desired_retention),
            Version::Fsrs7 => v7_next_interval(&self.w, m, desired_retention),
        }
    }

    /// `FSRS::next_states_with_elapsed_days`：四个评分（again..easy）的记忆状态与间隔。
    pub fn next_states(&self, current: Option<Memory>, desired_retention: f32, days_elapsed: f32) -> Result<[Item; 4], String> {
        let (cur, nth) = match current {
            Some(s) => (s, 1),
            None => (Memory::ZERO, 0),
        };
        let mut out = [Item { memory: Memory::ZERO, interval: 0.0 }; 4];
        for rating in 1..=4u32 {
            let memory = self.validate(self.step(days_elapsed, rating, cur, nth))?;
            out[rating as usize - 1] = Item { memory, interval: self.next_interval(memory, desired_retention) };
        }
        Ok(out)
    }

    /// `FSRS::memory_state_from_sm2`。
    pub fn memory_state_from_sm2(&self, ease: f32, interval: f32, sm2_retention: f32) -> Result<Memory, String> {
        match self.version {
            Version::Fsrs6 => {
                let w = &self.w;
                let decay = -w[20];
                let factor = powf(0.9, 1.0 / decay) - 1.0;
                let s = interval.max(S_MIN) * factor / (powf(sm2_retention, 1.0 / decay) - 1.0);
                let d = 11.0 - (ease - 1.0) / (expf(w[8]) * powf(s, -w[9]) * expm1f((1.0 - sm2_retention) * w[10]));
                if !s.is_finite() || !d.is_finite() {
                    Err("invalid sm2 input".into())
                } else {
                    Ok(Memory { s, d: clamp(d, D_MIN, D_MAX), sf: s })
                }
            }
            Version::Fsrs7 => v7_from_sm2(&self.w, interval, sm2_retention),
        }
    }
}

// ---------------------------------------------------------------- 参数裁剪

fn clip6(p: &mut [f32]) {
    // ModelConfig::default(): num_relearning_steps = 1, enable_short_term = true。
    let w17_w18_ceiling = 2.0f32;
    let w19_floor = 0.01;
    let clamps: [(f32, f32); 21] = [
        (S_MIN, INIT_S_MAX),
        (S_MIN, INIT_S_MAX),
        (S_MIN, INIT_S_MAX),
        (S_MIN, INIT_S_MAX),
        (D_MIN, D_MAX),
        (0.001, 4.0),
        (0.001, 4.0),
        (0.001, 0.75),
        (0.0, 4.5),
        (0.0, 0.8),
        (0.001, 3.5),
        (0.001, 5.0),
        (0.001, 0.25),
        (0.001, 0.9),
        (0.0, 4.0),
        (0.0, 1.0),
        (1.0, 6.0),
        (0.0, w17_w18_ceiling),
        (0.0, w17_w18_ceiling),
        (w19_floor, 0.8),
        (0.1, 0.8),
    ];
    for (w, (lo, hi)) in p.iter_mut().zip(clamps) {
        *w = w.clamp(lo, hi);
    }
}

fn clamp_safe(value: f32, low: f32, high: f32) -> f32 {
    let low = if low.is_finite() { low } else { 0.0 };
    let high = if high.is_finite() { high } else { low };
    let (low, high) = if low <= high { (low, high) } else { (high, low) };
    let value = if value.is_finite() { value } else { low };
    value.clamp(low, high)
}

fn clip7(p: &mut [f32]) {
    p[0] = clamp_safe(p[0], S_MIN, INIT_S_MAX / 2.0);
    p[1] = clamp_safe(p[1], p[0], INIT_S_MAX);
    p[2] = clamp_safe(p[2], p[1], INIT_S_MAX);
    p[3] = clamp_safe(p[3], p[2], INIT_S_MAX);
    p[4] = clamp_safe(p[4], 1.0, 10.0);
    p[5] = clamp_safe(p[5], 0.001, 4.0);
    p[6] = clamp_safe(p[6], 0.1, 4.0);
    p[7] = clamp_safe(p[7], 0.0, 4.0);
    p[8] = clamp_safe(p[8], 0.0, 1.2);
    p[9] = clamp_safe(p[9], 0.3, 3.0);
    p[10] = clamp_safe(p[10], 0.01, 1.5);
    p[11] = clamp_safe(p[11], 0.1, 1.0);
    p[12] = clamp_safe(p[12], 0.0, 3.5);
    p[13] = clamp_safe(p[13], 0.0, 1.0);
    p[14] = clamp_safe(p[14], 1.0, 7.0);
    p[15] = clamp_safe(p[15], 0.0, 4.0);
    p[16] = clamp_safe(p[16], 0.0, 2.0);
    p[17] = clamp_safe(p[17], 0.5, 6.0);
    p[18] = clamp_safe(p[18], 0.001, 1.5);
    p[19] = clamp_safe(p[19], 0.001, 1.0);
    p[20] = clamp_safe(p[20], 0.0, 5.0);
    p[21] = clamp_safe(p[21], 0.0, 1.0);
    p[22] = clamp_safe(p[22], 1.0, 7.0);
    p[23] = clamp_safe(p[23], 0.01, 0.25);
    p[24] = clamp_safe(p[24], 0.01, 0.95);
    p[25] = clamp_safe(p[25], 0.2, 0.85);
    p[26] = clamp_safe(p[26], p[25].max(0.5), 0.99);
    p[27] = clamp_safe(p[27], 0.01, 1.0);
    p[28] = clamp_safe(p[28], 0.1, 1.0);
    p[29] = clamp_safe(p[29], 0.0, 0.9);
    p[30] = clamp_safe(p[30], 0.1, 1.1);
    p[31] = clamp_safe(p[31], 0.0, 1.0);
    p[32] = clamp_safe(p[32], 0.0, 0.6);
    p[33] = clamp_safe(p[33], 0.0, 0.6);
}

// ---------------------------------------------------------------- FSRS-6（model_v6.rs）

fn v6_forgetting_curve(w: &[f32], t: f32, s: f32) -> f32 {
    let s = s.max(S_MIN);
    let decay = -w[20];
    let factor = powf(0.9, 1.0 / decay) - 1.0;
    let t = roundf(t.max(0.0));
    powf(fmaf(t / s, factor, 1.0), decay)
}

fn v6_next_interval(w: &[f32], stability: f32, desired_retention: f32) -> f32 {
    let stability = stability.max(S_MIN);
    let dr = desired_retention.clamp(0.0001, 0.9999);
    let decay = -w[20];
    let factor = powf(0.9, 1.0 / decay) - 1.0;
    (stability / factor * (powf(dr, 1.0 / decay) - 1.0)).clamp(0.0, S_MAX)
}

fn v6_success(w: &[f32], s: f32, r: f32, d: f32, rating: usize) -> f32 {
    let hard_penalty = if rating == 2 { w[15] } else { 1.0 };
    let easy_bonus = if rating == 4 { w[16] } else { 1.0 };
    (s * (expf(w[8]) * (11.0 - d) * powf(s, -w[9]) * (expf((1.0 - r) * w[10]) - 1.0) * hard_penalty * easy_bonus + 1.0))
        .clamp(S_MIN, S_MAX)
}

fn v6_failure(w: &[f32], s: f32, r: f32, d: f32) -> f32 {
    let new_s_min = s / expf(w[17] * w[18]);
    let new_s = w[11] * powf(d, -w[12]) * (powf(s + 1.0, w[13]) - 1.0) * expf((1.0 - r) * w[14]);
    new_s.min(new_s_min).clamp(S_MIN, S_MAX)
}

fn v6_init_difficulty(w: &[f32], rating: usize) -> f32 {
    w[4] - expf(w[5] * rating.saturating_sub(1) as f32) + 1.0
}

fn v6_next_difficulty(w: &[f32], d: f32, rating: usize) -> f32 {
    let delta_d = -w[6] * (rating as f32 - 3.0);
    let new_d = d + ((10.0 - d) / 9.0) * delta_d;
    (w[7] * v6_init_difficulty(w, 4) + (1.0 - w[7]) * new_d).clamp(D_MIN, D_MAX)
}

fn v6_next_state(w: &[f32], state: Memory, delta_t: f32, rating: u32) -> Memory {
    let rating = rating.clamp(1, 4) as usize;
    let delta_t = roundf(delta_t.max(0.0));
    let s = state.s.clamp(S_MIN, S_MAX);
    let d = state.d.clamp(D_MIN, D_MAX);
    let r = v6_forgetting_curve(w, delta_t, s);
    let stability = if delta_t == 0.0 {
        let sinc = expf(w[17] * (rating as f32 - 3.0 + w[18])) * powf(s, -w[19]);
        (s * if rating >= 2 { sinc.max(1.0) } else { sinc }).clamp(S_MIN, S_MAX)
    } else if rating == 1 {
        v6_failure(w, s, r, d)
    } else {
        v6_success(w, s, r, d, rating)
    };
    Memory { s: stability, d: v6_next_difficulty(w, d, rating), sf: stability }
}

// ---------------------------------------------------------------- FSRS-7（model_v7.rs）

const DR_MIN: f32 = 0.0001;
const DR_MAX: f32 = 0.9999;
const INTERVAL_NEWTON_ITERS: usize = 7;
const BISECTION_ITERS: usize = 50;
const MIN_T: f32 = 1.0 / 86_400.0;
const RETENTION_TOLERANCE: f32 = 1e-6;

fn v7_init_difficulty(w: &[f32], rating: usize) -> f32 {
    w[4] - expf(w[5] * (rating - 1) as f32) + 1.0
}

fn v7_next_difficulty(w: &[f32], d: f32, rating: usize, retention: f32) -> f32 {
    let rating = rating.clamp(1, 4);
    let delta_d = -w[6] * (rating as f32 - 3.0);
    let delta_d = if rating == 1 { delta_d * (retention + 0.1) } else { delta_d };
    let new_d = d + (10.0 - d) * delta_d / 9.0;
    (v7_init_difficulty(w, 4) * 0.01 + new_d * 0.99).clamp(D_MIN, D_MAX)
}

fn v7_stability_for_set(w: &[f32], last_s: f32, last_d: f32, r: f32, rating: usize, start: usize) -> f32 {
    let rating = rating.clamp(1, 4);
    let hard_penalty = if rating == 2 { w[start + 6] } else { 1.0 };
    let easy_bonus = if rating == 4 { w[start + 7] } else { 1.0 };
    let new_s_fail = w[start + 3] * (powf(last_s + 1.0, w[start + 4]) - 1.0) * expf((1.0 - r) * w[start + 5]);
    let pls = last_s.min(new_s_fail);
    let sinc = expf(w[start] - 1.5)
        * (11.0 - last_d)
        * powf(last_s, -w[start + 1])
        * (expf((1.0 - r) * w[start + 2]) - 1.0)
        * hard_penalty
        * easy_bonus
        + 1.0;
    let new_s_success = pls.max(last_s * sinc);
    if rating > 1 { new_s_success } else { pls }.clamp(S_MIN, S_MAX)
}

fn v7_fast_recall(w: &[f32], t: f32, s_fast: f32) -> f32 {
    let t = t.max(0.0);
    let s_fast = s_fast.clamp(S_MIN, S_MAX);
    let decay1 = -(w[23] * powf(s_fast, w[33] - 0.3)).clamp(0.01, 0.95);
    let factor1 = expf((logf(w[25]) / decay1).min(60.0)) - 1.0;
    powf(1.0 + factor1 * (t / s_fast), decay1)
}

fn v7_next_state(w: &[f32], state: Memory, delta_t: f32, rating: usize) -> Memory {
    let delta_t = delta_t.max(0.0);
    let rating = rating.clamp(1, 4);
    let r = v7_forgetting_curve(w, delta_t, state);
    let new_s_slow = v7_stability_for_set(w, state.s, state.d, r, rating, 7);
    let r_fast = v7_fast_recall(w, delta_t, state.sf);
    let new_s_fast = v7_stability_for_set(w, state.sf, state.d, r_fast, rating, 15);
    let new_s_fast = if rating == 1 { new_s_fast.min(new_s_slow * 0.8) } else { new_s_fast };
    Memory { s: new_s_slow, d: v7_next_difficulty(w, state.d, rating, r), sf: new_s_fast.clamp(S_MIN, S_MAX) }
}

fn v7_forgetting_curve(w: &[f32], t: f32, state: Memory) -> f32 {
    let t = t.max(0.0);
    let s = state.s.max(S_MIN);
    let s_fast = state.sf.max(S_MIN);
    let d = state.d.clamp(D_MIN, D_MAX);
    let decay1 = -(w[23] * powf(s_fast, w[33] - 0.3)).clamp(0.01, 0.95);
    let factor1 = expf((logf(w[25]) / decay1).min(60.0)) - 1.0;
    let r1 = powf(1.0 + factor1 * (t / s_fast), decay1);
    let decay2 = -w[24].clamp(0.01, 0.95);
    let factor2 = powf(w[26], 1.0 / decay2) - 1.0;
    let d_timescale = expf((d - 5.0) * (w[32] - 0.3));
    let r2 = powf(1.0 + factor2 * d_timescale * (t / s), decay2);
    let weight1 = w[27] * powf(s_fast, -w[29]);
    let weight2 = w[28] * powf(s, w[30]) * expf((d - 5.0) * (w[31] - 0.5));
    let retention = (weight1 * r1 + weight2 * r2) / (weight1 + weight2);
    fmaf(retention, 1.0 - 2e-5, 1e-5)
}

fn v7_curve_and_derivative(w: &[f32], t: f32, state: Memory) -> (f32, f32) {
    let t = t.max(0.0);
    let s = state.s.max(S_MIN);
    let s_fast = state.sf.max(S_MIN);
    let d = state.d.clamp(D_MIN, D_MAX);
    let decay1 = -(w[23] * powf(s_fast, w[33] - 0.3)).clamp(0.01, 0.95);
    let factor1 = expf((logf(w[25]) / decay1).min(60.0)) - 1.0;
    let b1 = 1.0 + factor1 * (t / s_fast);
    let r1 = powf(b1, decay1);
    let dr1_dt = decay1 * powf(b1, decay1 - 1.0) * factor1 / s_fast;
    let decay2 = -w[24].clamp(0.01, 0.95);
    let factor2 = powf(w[26], 1.0 / decay2) - 1.0;
    let d_timescale = expf((d - 5.0) * (w[32] - 0.3));
    let b2 = 1.0 + factor2 * d_timescale * (t / s);
    let r2 = powf(b2, decay2);
    let dr2_dt = decay2 * powf(b2, decay2 - 1.0) * factor2 * d_timescale / s;
    let weight1 = w[27] * powf(s_fast, -w[29]);
    let weight2 = w[28] * powf(s, w[30]) * expf((d - 5.0) * (w[31] - 0.5));
    let weight_sum = (weight1 + weight2).max(1e-9);
    let retention = (weight1 * r1 + weight2 * r2) / weight_sum;
    let derivative = (weight1 * dr1_dt + weight2 * dr2_dt) / weight_sum;
    (fmaf(retention, 1.0 - 2e-5, 1e-5), derivative * (1.0 - 2e-5))
}

fn v7_bisection(w: &[f32], state: Memory, desired_retention: f32) -> f32 {
    let dr = desired_retention.clamp(DR_MIN, DR_MAX);
    if dr >= DR_MAX {
        return 0.0;
    }
    let mut low = 0.0f32;
    let mut high = state.s.max(state.sf).max(1.0);
    while v7_forgetting_curve(w, high, state) > dr && high < S_MAX {
        high = (high * 2.0).min(S_MAX);
    }
    for _ in 0..BISECTION_ITERS {
        let mid = (low + high) * 0.5;
        if v7_forgetting_curve(w, mid, state) > dr {
            low = mid;
        } else {
            high = mid;
        }
    }
    ((low + high) * 0.5).clamp(0.0, S_MAX)
}

fn v7_next_interval(w: &[f32], state: Memory, desired_retention: f32) -> f32 {
    let dr = desired_retention.clamp(DR_MIN, DR_MAX);
    if dr >= DR_MAX {
        return 0.0;
    }
    let state = Memory { s: state.s.clamp(S_MIN, S_MAX), d: state.d.clamp(D_MIN, D_MAX), sf: state.sf.clamp(S_MIN, S_MAX) };
    let min_log_t = logf(MIN_T);
    let max_log_t = logf(S_MAX);
    let mut log_t = logf(state.s.max(state.sf).max(MIN_T));
    for _ in 0..INTERVAL_NEWTON_ITERS {
        log_t = log_t.clamp(min_log_t, max_log_t);
        let t = expf(log_t).clamp(MIN_T, S_MAX);
        let (r, derivative) = v7_curve_and_derivative(w, t, state);
        let df_du = (derivative * t).min(-1e-12);
        let step = ((r - dr) / df_du).clamp(-4.0, 4.0);
        log_t -= step;
        if !log_t.is_finite() {
            return v7_bisection(w, state, dr);
        }
    }
    let interval = expf(log_t).clamp(0.0, S_MAX);
    let r = v7_forgetting_curve(w, interval, state);
    if r.is_finite() && (r - dr).abs() <= 1e-3 { interval } else { v7_bisection(w, state, dr) }
}

fn v7_from_sm2(w: &[f32], interval: f32, sm2_retention: f32) -> Result<Memory, String> {
    if !interval.is_finite() || !sm2_retention.is_finite() || !(0.0..1.0).contains(&sm2_retention) {
        return Err("invalid sm2 input".into());
    }
    let interval = interval.max(S_MIN).clamp(S_MIN, S_MAX);
    let state_at = |log_s: f32| {
        let s = expf(log_s).clamp(S_MIN, S_MAX);
        Memory { s, d: 5.0, sf: (s * 0.8).clamp(S_MIN, S_MAX) }
    };
    let mut low = logf(S_MIN);
    let mut high = logf(S_MAX);
    let low_state = state_at(low);
    let high_state = state_at(high);
    let low_r = v7_forgetting_curve(w, interval, low_state);
    let high_r = v7_forgetting_curve(w, interval, high_state);
    if !low_r.is_finite() || !high_r.is_finite() {
        return Err("invalid sm2 input".into());
    }
    if sm2_retention <= low_r {
        return Ok(low_state);
    }
    if sm2_retention >= high_r {
        return Ok(high_state);
    }
    for _ in 0..BISECTION_ITERS {
        let mid = (low + high) * 0.5;
        let state = state_at(mid);
        let r = v7_forgetting_curve(w, interval, state);
        if !r.is_finite() {
            return Err("invalid sm2 input".into());
        }
        if (r - sm2_retention).abs() <= RETENTION_TOLERANCE {
            return Ok(state);
        }
        if r < sm2_retention {
            low = mid;
        } else {
            high = mid;
        }
    }
    Ok(state_at((low + high) * 0.5))
}

#[cfg(test)]
mod tests {
    use super::*;
    use fsrs::{MemoryState, FSRS};

    fn close(a: f32, b: f32) -> bool {
        a == b || (a - b).abs() <= 1e-5 * a.abs().max(b.abs()).max(1e-3)
    }

    /// FSRS-7 的间隔是牛顿迭代解出来的，末位差会被放大；几分钟级的极小间隔相对差可到 1e-5 量级
    /// （落成天数后没有影响），所以间隔用 1e-4 的相对容差。
    fn close_ivl(a: f32, b: f32) -> bool {
        (a - b).abs() <= 1e-4 * a.abs().max(b.abs()) + 1e-7
    }

    fn lcg(seed: &mut u64) -> f32 {
        *seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        ((*seed >> 40) as f32) / (1u64 << 24) as f32
    }

    /// 与 fsrs crate（同一 rev）对拍：随机记忆状态 × 随机间隔 × 四个评分 × 两个版本 × 随机参数扰动。
    /// 差别只能来自超越函数末位，用相对 1e-5 判；全部逐位相等最好，但不同 libm 不保证。
    #[test]
    fn matches_fsrs_crate_within_ulps() {
        let mut seed = 42u64;
        let mut identical = 0usize;
        let mut total = 0usize;
        for version in [Version::Fsrs6, Version::Fsrs7] {
            for _ in 0..40 {
                let mut params = Model::defaults(version).to_vec();
                for p in params.iter_mut() {
                    *p *= 0.85 + 0.3 * lcg(&mut seed);
                }
                let ours = Model::new(&params).unwrap();
                let theirs = FSRS::new(&params).unwrap();
                for _ in 0..40 {
                    let s = 0.05 + 400.0 * lcg(&mut seed);
                    let d = 1.0 + 9.0 * lcg(&mut seed);
                    let sf = s * (0.3 + 0.7 * lcg(&mut seed));
                    let elapsed = 60.0 * lcg(&mut seed) * lcg(&mut seed);
                    let dr = 0.7 + 0.29 * lcg(&mut seed);
                    let mem = Memory { s, d, sf };
                    let a = ours.next_states(Some(mem), dr, elapsed).unwrap();
                    let b = theirs
                        .next_states_with_elapsed_days(Some(MemoryState { stability: s, difficulty: d, stability_fast: sf }), dr, elapsed)
                        .unwrap();
                    for (x, y) in a.iter().zip([b.again, b.hard, b.good, b.easy]) {
                        total += 1;
                        assert!(close(x.memory.s, y.memory.stability), "{version:?} s {} vs {}", x.memory.s, y.memory.stability);
                        assert!(close(x.memory.d, y.memory.difficulty), "{version:?} d");
                        assert!(close(x.memory.sf, y.memory.stability_fast), "{version:?} sf");
                        assert!(close_ivl(x.interval, y.interval), "{version:?} ivl {} vs {}", x.interval, y.interval);
                        if x.memory.s == y.memory.stability && x.interval == y.interval {
                            identical += 1;
                        }
                    }
                }
                let new_a = ours.next_states(None, 0.9, 0.0).unwrap();
                let new_b = theirs.next_states_with_elapsed_days(None, 0.9, 0.0).unwrap();
                assert!(close_ivl(new_a[2].interval, new_b.good.interval));
                for (ease, ivl) in [(2.5f32, 10.0f32), (1.3, 1.0), (3.0, 200.0)] {
                    let x = ours.memory_state_from_sm2(ease, ivl, 0.9).unwrap();
                    let y = theirs.memory_state_from_sm2(ease, ivl, 0.9).unwrap();
                    assert!(close(x.s, y.stability) && close(x.d, y.difficulty));
                }
                let reviews = [(3u32, 0.0f32), (3, 2.0), (1, 9.0), (4, 3.5), (2, 20.0)];
                let x = ours.memory_state(&reviews, None).unwrap();
                let y = theirs
                    .memory_state(
                        fsrs::FSRSItem { reviews: reviews.iter().map(|&(rating, delta_t)| fsrs::FSRSReview { rating, delta_t }).collect() },
                        None,
                    )
                    .unwrap();
                assert!(close(x.s, y.stability) && close(x.d, y.difficulty), "history {x:?} vs {y:?}");
            }
        }
        // 大多数应当逐位相同（libm 与平台 libm 在常见输入上通常一致）。
        assert!(identical * 2 > total, "only {identical}/{total} bit-identical");
    }

    /// 固定向量（跨平台确定性，设计 §12.5）：这组输入的输出位模式写死在这里，任何平台、任何构建
    /// 算出来都必须一模一样。改动本文件的算法必须同时更新这里并说明原因。
    #[test]
    fn fixed_vector_bits() {
        let mut h = blake3::Hasher::new();
        let mut seed = 7u64;
        for version in [Version::Fsrs6, Version::Fsrs7] {
            let m = Model::new(Model::defaults(version)).unwrap();
            let mut mem: Option<Memory> = None;
            for i in 0..2000 {
                let rating = 1 + (lcg(&mut seed) * 4.0) as u32 % 4;
                let elapsed = if i == 0 { 0.0 } else { 40.0 * lcg(&mut seed) };
                let next = m.next_states(mem, 0.9, elapsed).unwrap();
                let it = next[rating as usize - 1];
                for v in [it.memory.s, it.memory.d, it.memory.sf, it.interval] {
                    h.update(&v.to_bits().to_le_bytes());
                }
                mem = Some(it.memory);
                if i % 97 == 0 {
                    mem = None;
                }
            }
        }
        let got = h.finalize().to_hex().to_string();
        // 首次生成于 Windows x64（本文件落地时）；其它平台由 CI 矩阵跑同一测试（设计 §12.5）。
        assert_eq!(got, FIXED_VECTOR_HASH, "deterministic FSRS output changed");
    }

    const FIXED_VECTOR_HASH: &str = "1b14c39546457d0d723c16d19fe33fcdafed4e098458b6c229406728dce3da19";
}
