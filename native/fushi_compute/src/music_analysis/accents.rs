//! 每拍重音（folia `src/services/analysis/beatAccents.ts`，BEAT_ACCENTS_VERSION 10，逐条移植）：
//!
//! - `impact`：拍点那一下的突起（低 0.5 / 中 0.3 / 高 0.2 加权，占 40%）与前后约半秒整体有多响（占 60%），
//!   各自在全曲里按 p10–p90 归一后混合，再 ^0.7；
//! - `low` / `mid` / `high`：三段突起的占比；
//! - `rhythmic`：这一小节的打击成分占比低于全曲中位小节的 0.45 时为 0（只有喇叭、铺底的前奏不出拍点特效；
//!   全曲中位小节打击占比 < 0.15 的歌不做这道门）；模型拿不准拍子的一长段也置 0；
//! - `pulse`：模型数到比听感更细的一层时（复合拍子数八分音符、慢歌数成双倍速、按小节感受的华尔兹）
//!   只留每组的头一拍；鼓驱动的歌按段落把数出来的速度放回来；
//! - `track_scale`：整曲动感系数（中位突起映射到 0.45–1）。
//!
//! 输入：混音的 Beat This! 梅尔谱（50 fps）、拍点 / 强拍（秒）、每帧打击 / 总能量（HPSS，同一个 STFT）、
//! 模型路径上每拍的 beat logit（没有时只看突起）。folia 的 HPSS 在 GPU 上和 beat_this 同一次跑，
//! 这里是 [super::features::percussive] 的同型中值滤波。

use std::collections::HashSet;

use super::features::{MelBand, bt_fps};

const LOW_MAX_HZ: f64 = 150.0;
const MID_MAX_HZ: f64 = 2000.0;
const PEAK_BEFORE: i64 = 1;
const PEAK_AFTER: i64 = 2;
const BASE_FROM: i64 = 6;
const BASE_TO: i64 = 2;
const W_LOW: f64 = 0.5;
const W_MID: f64 = 0.3;
const W_HIGH: f64 = 0.2;
const LOUDNESS_HALF: i64 = 12;
const IMPACT_RISE_SHARE: f64 = 0.4;
const NORMALISE_LOW_PERCENTILE: f64 = 0.1;
const NORMALISE_HIGH_PERCENTILE: f64 = 0.9;
const IMPACT_CURVE: f64 = 0.7;
const MIN_BEATS: usize = 8;
pub(crate) const TRACK_SCALE_MIN: f64 = 0.45;
const TRACK_SCALE_RISE_LOW: f64 = 0.1;
const TRACK_SCALE_RISE_HIGH: f64 = 0.35;
pub(crate) const PERCUSSIVE_GATE: f64 = 0.45;
const MIN_BARS: usize = 4;
const FALLBACK_BAR_BEATS: usize = 4;

struct PulseGroup {
    size: usize,
    ratio: f64,
    rise_ratio: f64,
    min_bpm: f64,
}

const PULSE_GROUPS: [PulseGroup; 3] = [
    PulseGroup {
        size: 3,
        ratio: 1.2,
        rise_ratio: 1.2,
        min_bpm: 120.0,
    },
    PulseGroup {
        size: 2,
        ratio: 0.0,
        rise_ratio: 1.5,
        min_bpm: 90.0,
    },
    // 按小节感受的华尔兹（WHOLE_BAR_GROUP）。
    PulseGroup {
        size: 3,
        ratio: 1.2,
        rise_ratio: 1.5,
        min_bpm: 90.0,
    },
];
const MIN_PULSE_SPACING: f64 = 0.7;
const MIN_GATED_SHARE: f64 = 0.15;
const UNSURE_SHARE: f64 = 0.55;
const DRIVEN_TRACK_SHARE: f64 = 0.3;
const DRIVEN_OFFBEAT_SHARE: f64 = 0.6;
const DRIVEN_HALF: usize = 8;
const UNSURE_HALF: usize = 4;
const UNSURE_RUN: usize = 8;
const PULSE_CONFIDENCE_GAP: f64 = 0.7;
const MIN_PULSE_BARS: usize = 8;
const CONFIDENCE_HALF: i64 = 2;

/// 每帧（50 fps）打击 / 总能量。
pub(crate) struct PercussiveEnergy {
    pub(crate) percussive: Vec<f64>,
    pub(crate) total: Vec<f64>,
}

/// 每拍重音。
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Accents {
    pub(crate) impact: Vec<f32>,
    pub(crate) low: Vec<f32>,
    pub(crate) mid: Vec<f32>,
    pub(crate) high: Vec<f32>,
    pub(crate) rhythmic: Vec<bool>,
    pub(crate) pulse: Vec<bool>,
    pub(crate) track_scale: f32,
}

impl Accents {
    /// 没有重音信息时的中性值（每拍满强度、三段均分、都有节奏、都是听感拍）。
    pub(crate) fn neutral(beats: usize) -> Self {
        Self {
            impact: vec![1.0; beats],
            low: vec![1.0 / 3.0; beats],
            mid: vec![1.0 / 3.0; beats],
            high: vec![1.0 / 3.0; beats],
            rhythmic: vec![true; beats],
            pulse: vec![true; beats],
            track_scale: 1.0,
        }
    }
}

/// folia 统计诊断行（`[BeatMeter]`）里的量，测试与真文件验证打印用。
#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct BeatMeter {
    pub(crate) bpm: f64,
    pub(crate) usual: usize,
    pub(crate) group: usize,
    pub(crate) unsure: usize,
    pub(crate) driven: usize,
}

fn round3(v: f64) -> f64 {
    (v * 1000.0).round() / 1000.0
}

/// folia `percentile`：`sorted[round(p · (n − 1))]`。
fn percentile(sorted: &[f64], p: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let at = (p * (sorted.len() - 1) as f64)
        .round()
        .clamp(0.0, (sorted.len() - 1) as f64);
    sorted[at as usize]
}

fn sorted(values: &[f64]) -> Vec<f64> {
    let mut v = values.to_vec();
    v.sort_by(f64::total_cmp);
    v
}

fn median(values: &[f64]) -> f64 {
    percentile(&sorted(values), 0.5)
}

fn normaliser(sorted: &[f64]) -> Option<impl Fn(f64) -> f64> {
    let floor = percentile(sorted, NORMALISE_LOW_PERCENTILE);
    let ceiling = percentile(sorted, NORMALISE_HIGH_PERCENTILE);
    if !(ceiling - floor > 1e-6) {
        return None;
    }
    Some(move |v: f64| ((v - floor) / (ceiling - floor)).clamp(0.0, 1.0))
}

/// 时间的身份键（拍点 / 强拍按同一浮点值相等；化成微秒避免比较浮点）。
fn key(t: f64) -> i64 {
    (t * 1e6).round() as i64
}

struct Bands {
    low: Vec<f64>,
    mid: Vec<f64>,
    high: Vec<f64>,
    all: Vec<f64>,
}

fn split_bands(mel: &[f32], frames: usize, bank: &[MelBand]) -> Bands {
    let n = bank.len();
    let of: Vec<u8> = bank
        .iter()
        .map(|b| {
            if b.centre_hz < LOW_MAX_HZ {
                0
            } else if b.centre_hz < MID_MAX_HZ {
                1
            } else {
                2
            }
        })
        .collect();
    let mut counts = [0usize; 3];
    for o in &of {
        counts[*o as usize] += 1;
    }
    let mut out = Bands {
        low: vec![0.0; frames],
        mid: vec![0.0; frames],
        high: vec![0.0; frames],
        all: vec![0.0; frames],
    };
    for f in 0..frames {
        let mut s = [0.0f64; 3];
        for b in 0..n {
            s[of[b] as usize] += f64::from(mel[f * n + b]);
        }
        out.low[f] = if counts[0] > 0 {
            s[0] / counts[0] as f64
        } else {
            0.0
        };
        out.mid[f] = if counts[1] > 0 {
            s[1] / counts[1] as f64
        } else {
            0.0
        };
        out.high[f] = if counts[2] > 0 {
            s[2] / counts[2] as f64
        } else {
            0.0
        };
        out.all[f] = (s[0] + s[1] + s[2]) / n as f64;
    }
    out
}

fn clamp_at(track: &[f64], at: i64) -> f64 {
    let last = track.len() as i64 - 1;
    track[at.clamp(0, last) as usize]
}

fn rise_at(track: &[f64], frame: i64) -> f64 {
    if track.is_empty() {
        return 0.0;
    }
    let mut peak = f64::NEG_INFINITY;
    for at in frame - PEAK_BEFORE..=frame + PEAK_AFTER {
        peak = peak.max(clamp_at(track, at));
    }
    let mut base = 0.0;
    for at in frame - BASE_FROM..=frame - BASE_TO {
        base += clamp_at(track, at);
    }
    base /= (BASE_FROM - BASE_TO + 1) as f64;
    (peak - base).max(0.0)
}

fn loudness_at(track: &[f64], frame: i64) -> f64 {
    if track.is_empty() {
        return 0.0;
    }
    let mut sum = 0.0;
    for at in frame - LOUDNESS_HALF..=frame + LOUDNESS_HALF {
        sum += clamp_at(track, at);
    }
    sum / (2 * LOUDNESS_HALF + 1) as f64
}

fn bar_starts(beats: &[f64], downbeats: &[f64]) -> Vec<usize> {
    if downbeats.len() >= 2 {
        let set: HashSet<i64> = downbeats.iter().map(|t| key(*t)).collect();
        return (0..beats.len())
            .filter(|&i| i == 0 || set.contains(&key(beats[i])))
            .collect();
    }
    (0..beats.len()).step_by(FALLBACK_BAR_BEATS).collect()
}

fn downbeat_starts(beats: &[f64], downbeats: &[f64]) -> Vec<usize> {
    let set: HashSet<i64> = downbeats.iter().map(|t| key(*t)).collect();
    (0..beats.len())
        .filter(|&i| set.contains(&key(beats[i])))
        .collect()
}

fn track_percussive_share(energy: Option<&PercussiveEnergy>) -> Option<f64> {
    let e = energy?;
    let hit: f64 = e.percussive.iter().sum();
    let all: f64 = e.total.iter().sum();
    (all > 0.0).then(|| hit / all)
}

/// 每小节第一拍与它的打击占比。
fn bar_percussive_shares(
    e: &PercussiveEnergy,
    beats: &[f64],
    downbeats: &[f64],
) -> (Vec<usize>, Vec<f64>) {
    let starts = bar_starts(beats, downbeats);
    if starts.len() < MIN_BARS {
        return (starts, Vec::new());
    }
    let fps = bt_fps();
    let len = e.total.len();
    let step = |t: f64| ((t * fps).floor().max(0.0) as usize).min(len);
    let last_gap = if beats.len() > 1 {
        beats[beats.len() - 1] - beats[beats.len() - 2]
    } else {
        0.5
    };
    let shares = starts
        .iter()
        .enumerate()
        .map(|(bar, &first)| {
            let from = step(beats[first]);
            let until = if bar + 1 < starts.len() {
                step(beats[starts[bar + 1]])
            } else {
                step(beats[beats.len() - 1] + last_gap)
            };
            let (mut hit, mut all) = (0.0, 0.0);
            for f in from..until.max(from) {
                hit += e.percussive[f];
                all += e.total[f];
            }
            if all > 0.0 { hit / all } else { 0.0 }
        })
        .collect();
    (starts, shares)
}

fn rhythmic_beats(
    energy: Option<&PercussiveEnergy>,
    beats: &[f64],
    downbeats: &[f64],
) -> Vec<bool> {
    let mut rhythmic = vec![true; beats.len()];
    let Some(e) = energy else {
        return rhythmic;
    };
    let (starts, shares) = bar_percussive_shares(e, beats, downbeats);
    if shares.is_empty() {
        return rhythmic;
    }
    let usual = median(&shares);
    if usual < MIN_GATED_SHARE {
        return rhythmic;
    }
    let threshold = usual * PERCUSSIVE_GATE;
    for (bar, &first) in starts.iter().enumerate() {
        if shares[bar] >= threshold {
            continue;
        }
        let end = if bar + 1 < starts.len() {
            starts[bar + 1]
        } else {
            beats.len()
        };
        for r in &mut rhythmic[first..end] {
            *r = false;
        }
    }
    rhythmic
}

/// 每拍的 beat logit（拍点 ±2 帧内的峰值）。
pub(crate) fn beat_confidence(logits: &[f32], beats: &[f64]) -> Vec<f64> {
    let fps = bt_fps();
    beats
        .iter()
        .map(|t| {
            let frame = (t * fps).round() as i64;
            let mut peak = f64::NEG_INFINITY;
            for at in frame - CONFIDENCE_HALF..=frame + CONFIDENCE_HALF {
                if at >= 0 && (at as usize) < logits.len() {
                    peak = peak.max(f64::from(logits[at as usize]));
                }
            }
            if peak.is_finite() { round3(peak) } else { 0.0 }
        })
        .collect()
}

fn read_beat_meter(
    rises: &[f64],
    beats: &[f64],
    downbeats: &[f64],
    confidence: Option<&[f64]>,
) -> BeatMeter {
    let gaps: Vec<f64> = beats.windows(2).map(|w| w[1] - w[0]).collect();
    let gap = median(&gaps);
    let mut meter = BeatMeter {
        bpm: if gap > 0.0 { (60.0 / gap).round() } else { 0.0 },
        usual: 0,
        group: 1,
        unsure: 0,
        driven: 0,
    };
    let starts = downbeat_starts(beats, downbeats);
    if starts.len() < 2 {
        return meter;
    }
    // 最常见的小节长度（并列时先出现的那个：folia 按 Map 插入序稳定排序）。
    let mut counts: Vec<(usize, usize)> = Vec::new();
    for w in starts.windows(2) {
        let len = w[1] - w[0];
        match counts.iter_mut().find(|(l, _)| *l == len) {
            Some(entry) => entry.1 += 1,
            None => counts.push((len, 1)),
        }
    }
    let (usual, bars) = counts.iter().fold(
        (0, 0),
        |best, &(l, c)| if c > best.1 { (l, c) } else { best },
    );
    meter.usual = usual;
    if usual == 0 {
        return meter;
    }
    let mut by_position = vec![0.0f64; usual];
    let mut logits: Vec<Vec<f64>> = vec![Vec::new(); usual];
    for w in starts.windows(2) {
        if w[1] - w[0] != usual {
            continue;
        }
        for pos in 0..usual {
            by_position[pos] += rises[w[0] + pos] / bars as f64;
            if let Some(c) = confidence {
                logits[pos].push(c[w[0] + pos]);
            }
        }
    }
    let conf_by_position: Vec<f64> = logits.iter().map(|l| median(l)).collect();
    if bars < MIN_PULSE_BARS {
        return meter;
    }
    let stands_out = |head: usize, needed: f64| -> bool {
        let before = (head + usual - 1) % usual;
        let after = (head + 1) % usual;
        if needed > 0.0
            && !(by_position[head] > needed * by_position[before].max(by_position[after]))
        {
            return false;
        }
        confidence.is_none()
            || conf_by_position[head] - conf_by_position[before].max(conf_by_position[after])
                > PULSE_CONFIDENCE_GAP
    };
    let found = PULSE_GROUPS.iter().find(|g| {
        if usual % g.size != 0 || meter.bpm < g.min_bpm {
            return false;
        }
        let needed = if confidence.is_some() {
            g.ratio
        } else {
            g.rise_ratio
        };
        if usual == g.size {
            return stands_out(0, needed);
        }
        (g.size..usual)
            .step_by(g.size)
            .all(|head| stands_out(head, needed))
    });
    if let Some(g) = found {
        meter.group = g.size;
    }
    meter
}

fn group_heads(meter: &BeatMeter, beats: &[f64], downbeats: &[f64]) -> Vec<bool> {
    let mut pulse = vec![true; beats.len()];
    let group = meter.group;
    if group == 1 {
        return pulse;
    }
    let starts = downbeat_starts(beats, downbeats);
    if starts.is_empty() {
        return pulse;
    }
    for (i, p) in pulse.iter_mut().enumerate().take(starts[0]) {
        *p = (starts[0] - i) % group == 0;
    }
    for (bar, &start) in starts.iter().enumerate() {
        let end = if bar + 1 < starts.len() {
            starts[bar + 1]
        } else {
            beats.len()
        };
        for (i, p) in pulse.iter_mut().enumerate().take(end).skip(start) {
            *p = (i - start) % group == 0;
        }
    }
    pulse
}

fn pulse_from_meter(meter: &BeatMeter, beats: &[f64], downbeats: &[f64]) -> Vec<bool> {
    let mut pulse = group_heads(meter, beats, downbeats);
    let gaps: Vec<f64> = beats.windows(2).map(|w| w[1] - w[0]).collect();
    let gap = median(&gaps);
    if !(gap > 0.0) || beats.len() < MIN_BEATS {
        return pulse;
    }
    let spacing = MIN_PULSE_SPACING * gap * meter.group as f64;
    let set: HashSet<i64> = downbeats.iter().map(|t| key(*t)).collect();
    let mut last: Option<usize> = None;
    for i in 0..beats.len() {
        if !pulse[i] {
            continue;
        }
        match last {
            None => last = Some(i),
            Some(l) if beats[i] - beats[l] >= spacing => last = Some(i),
            Some(l) => {
                if set.contains(&key(beats[i])) && !set.contains(&key(beats[l])) {
                    pulse[l] = false;
                    last = Some(i);
                } else {
                    pulse[i] = false;
                }
            }
        }
    }
    pulse
}

fn unsure_beats(confidence: Option<&[f64]>, pulse: &[bool]) -> Vec<bool> {
    let mut unsure = vec![false; pulse.len()];
    let Some(conf) = confidence else {
        return unsure;
    };
    let felt: Vec<usize> = (0..pulse.len()).filter(|&i| pulse[i]).collect();
    if felt.len() < UNSURE_RUN {
        return unsure;
    }
    let logits: Vec<f64> = felt.iter().map(|&i| conf[i]).collect();
    let floor = UNSURE_SHARE * percentile(&sorted(&logits), 0.75);
    let low: Vec<bool> = (0..logits.len())
        .map(|at| {
            let around =
                &logits[at.saturating_sub(UNSURE_HALF)..(at + UNSURE_HALF + 1).min(logits.len())];
            (around.iter().sum::<f64>() / around.len() as f64) < floor
        })
        .collect();
    let mut start: Option<usize> = None;
    for at in 0..=low.len() {
        if at < low.len() && low[at] {
            start.get_or_insert(at);
            continue;
        }
        if let Some(s) = start {
            if at - s >= UNSURE_RUN {
                for u in &mut unsure[felt[s]..=felt[at - 1]] {
                    *u = true;
                }
            }
        }
        start = None;
    }
    unsure
}

fn restore_driven_beats(
    pulse: &mut [bool],
    group: usize,
    confidence: Option<&[f64]>,
    percussive_share: Option<f64>,
    unsure: &[bool],
) -> usize {
    let (Some(conf), Some(share)) = (confidence, percussive_share) else {
        return 0;
    };
    if group != 2 || share < DRIVEN_TRACK_SHARE {
        return 0;
    }
    let felt: Vec<usize> = (0..pulse.len()).filter(|&i| pulse[i]).collect();
    let groups: Vec<(usize, Vec<usize>)> = felt
        .windows(2)
        .map(|w| (w[0], (w[0] + 1..w[1]).collect()))
        .filter(|(head, _)| !unsure.get(*head).copied().unwrap_or(false))
        .collect();
    let mean = |v: &[f64]| v.iter().sum::<f64>() / v.len() as f64;
    let driven: Vec<bool> = (0..groups.len())
        .map(|at| {
            let around =
                &groups[at.saturating_sub(DRIVEN_HALF)..(at + DRIVEN_HALF + 1).min(groups.len())];
            let offbeats: Vec<f64> = around
                .iter()
                .flat_map(|(_, b)| b.iter().map(|&i| conf[i]))
                .collect();
            if offbeats.is_empty() {
                return false;
            }
            let heads = mean(&around.iter().map(|(h, _)| conf[*h]).collect::<Vec<f64>>());
            heads > 0.0 && mean(&offbeats) >= DRIVEN_OFFBEAT_SHARE * heads
        })
        .collect();
    let mut restored = 0;
    for (at, (_, between)) in groups.iter().enumerate() {
        if !driven[at] {
            continue;
        }
        for &i in between {
            pulse[i] = true;
            restored += 1;
        }
    }
    restored
}

fn track_scale(median_rise: f64) -> f64 {
    if !(median_rise > 0.0) {
        return TRACK_SCALE_MIN;
    }
    let amount =
        (median_rise - TRACK_SCALE_RISE_LOW) / (TRACK_SCALE_RISE_HIGH - TRACK_SCALE_RISE_LOW);
    round3(TRACK_SCALE_MIN + (1.0 - TRACK_SCALE_MIN) * amount.clamp(0.0, 1.0))
}

/// 整曲每拍重音（folia `computeBeatAccents`）。`mel` 是混音的 Beat This! 梅尔谱（帧 × bank.len()）。
pub(crate) fn compute(
    mel: &[f32],
    frames: usize,
    bank: &[MelBand],
    beats: &[f64],
    downbeats: &[f64],
    energy: Option<&PercussiveEnergy>,
    confidence: Option<&[f64]>,
) -> (Accents, BeatMeter) {
    let tracks = split_bands(mel, frames, bank);
    let fps = bt_fps();
    struct Rise {
        low: f64,
        mid: f64,
        high: f64,
        raw: f64,
        loudness: f64,
    }
    let rises: Vec<Rise> = beats
        .iter()
        .map(|t| {
            let f = (t * fps).round() as i64;
            let (low, mid, high) = (
                rise_at(&tracks.low, f),
                rise_at(&tracks.mid, f),
                rise_at(&tracks.high, f),
            );
            Rise {
                low,
                mid,
                high,
                raw: low * W_LOW + mid * W_MID + high * W_HIGH,
                loudness: loudness_at(&tracks.all, f),
            }
        })
        .collect();
    let raws: Vec<f64> = rises.iter().map(|r| r.raw).collect();
    let mut meter = read_beat_meter(&raws, beats, downbeats, confidence);
    let mut rhythmic = rhythmic_beats(energy, beats, downbeats);
    let mut pulse = pulse_from_meter(&meter, beats, downbeats);
    let sorted_raw = sorted(&raws);
    let rise = normaliser(&sorted_raw);
    let loud = normaliser(&sorted(
        &rises.iter().map(|r| r.loudness).collect::<Vec<f64>>(),
    ));
    let flat = beats.len() < MIN_BEATS || (rise.is_none() && loud.is_none());
    let rise_share = if loud.is_none() {
        1.0
    } else if rise.is_none() {
        0.0
    } else {
        IMPACT_RISE_SHARE
    };
    let mut acc = Accents {
        impact: Vec::with_capacity(beats.len()),
        low: Vec::with_capacity(beats.len()),
        mid: Vec::with_capacity(beats.len()),
        high: Vec::with_capacity(beats.len()),
        rhythmic: Vec::new(),
        pulse: Vec::new(),
        track_scale: 1.0,
    };
    for r in &rises {
        let mixed = rise_share * rise.as_ref().map_or(0.0, |f| f(r.raw))
            + (1.0 - rise_share) * loud.as_ref().map_or(0.0, |f| f(r.loudness));
        acc.impact.push(if flat {
            1.0
        } else {
            round3(mixed.powf(IMPACT_CURVE)) as f32
        });
        let sum = r.low + r.mid + r.high;
        let share = |v: f64| {
            (if sum > 0.0 {
                round3(v / sum)
            } else {
                round3(1.0 / 3.0)
            }) as f32
        };
        acc.low.push(share(r.low));
        acc.mid.push(share(r.mid));
        acc.high.push(share(r.high));
    }
    if beats.len() >= MIN_BEATS {
        acc.track_scale = track_scale(median(&raws)) as f32;
    }
    let unsure = unsure_beats(confidence, &pulse);
    for (i, u) in unsure.iter().enumerate() {
        if *u {
            rhythmic[i] = false;
        }
    }
    meter.unsure = unsure.iter().filter(|u| **u).count();
    meter.driven = restore_driven_beats(
        &mut pulse,
        meter.group,
        confidence,
        track_percussive_share(energy),
        &unsure,
    );
    acc.rhythmic = rhythmic;
    acc.pulse = pulse;
    (acc, meter)
}

#[cfg(test)]
mod tests {
    use super::super::features::bt_filterbank;
    use super::*;

    /// 50 fps 的合成梅尔谱：每拍一下突起，`accent(k)` 决定第 k 拍的高度。
    fn synth(
        beats: &[f64],
        frames: usize,
        accent: impl Fn(usize) -> f32,
    ) -> (Vec<f32>, Vec<MelBand>) {
        let bank = bt_filterbank();
        let n = bank.len();
        let mut mel = vec![1.0f32; frames * n];
        for (k, t) in beats.iter().enumerate() {
            let f = (t * 50.0).round() as usize;
            for at in f..(f + 3).min(frames) {
                for b in 0..n {
                    mel[at * n + b] += accent(k);
                }
            }
        }
        (mel, bank)
    }

    fn grid(n: usize, period: f64, bar: usize) -> (Vec<f64>, Vec<f64>) {
        let beats: Vec<f64> = (0..n).map(|k| 1.0 + k as f64 * period).collect();
        let downs = beats.iter().step_by(bar).copied().collect();
        (beats, downs)
    }

    #[test]
    fn strong_beats_get_more_impact() {
        let (beats, downs) = grid(64, 0.5, 4);
        let (mel, bank) = synth(&beats, 50 * 40, |k| if k % 4 == 0 { 3.0 } else { 1.0 });
        let (acc, meter) = compute(&mel, 50 * 40, &bank, &beats, &downs, None, None);
        assert_eq!(acc.impact.len(), 64);
        assert!(acc.impact[4] > acc.impact[5], "{:?}", &acc.impact[..8]);
        assert!(acc.impact.iter().all(|v| (0.0..=1.0).contains(v)));
        assert_eq!(meter.usual, 4);
        assert_eq!(meter.bpm, 120.0);
        // 4/4 且速度正常：每拍都是听感拍。
        assert!(acc.pulse.iter().all(|p| *p));
        assert!(acc.rhythmic.iter().all(|r| *r));
        assert!((acc.low[4] + acc.mid[4] + acc.high[4] - 1.0).abs() < 0.01);
        assert!(acc.track_scale >= TRACK_SCALE_MIN as f32 && acc.track_scale <= 1.0);
    }

    #[test]
    fn compound_time_counted_in_eighths_keeps_group_heads() {
        // 6/8 数成每小节 6 个八分音符、160 BPM：组头（位置 0、3）明显突出 → 1 拍留 1、每 3 拍一个。
        let (beats, downs) = grid(120, 60.0 / 160.0, 6);
        let (mel, bank) = synth(&beats, 50 * 50, |k| if k % 3 == 0 { 3.0 } else { 1.0 });
        let (acc, meter) = compute(&mel, 50 * 50, &bank, &beats, &downs, None, None);
        assert_eq!(meter.group, 3);
        assert!(acc.pulse[0] && !acc.pulse[1] && !acc.pulse[2] && acc.pulse[3]);
        assert_eq!(acc.pulse.iter().filter(|p| **p).count(), 40);
    }

    #[test]
    fn percussion_free_bars_are_not_rhythmic() {
        let (beats, downs) = grid(64, 0.5, 4);
        let (mel, bank) = synth(&beats, 50 * 40, |_| 1.0);
        let frames = 50 * 40;
        // 前 4 小节（前 8 秒 + 起点 1 秒）只有铺底：打击占比 0.02；之后 0.5。
        let percussive = (0..frames)
            .map(|f| if (f as f64) / 50.0 < 9.0 { 0.02 } else { 0.5 })
            .collect();
        let e = PercussiveEnergy {
            percussive,
            total: vec![1.0; frames],
        };
        let (acc, _) = compute(&mel, frames, &bank, &beats, &downs, Some(&e), None);
        assert!(!acc.rhythmic[0] && !acc.rhythmic[15]);
        assert!(acc.rhythmic[16] && acc.rhythmic[63]);
    }

    #[test]
    fn unsure_stretch_is_gated_and_confidence_is_read_from_logits() {
        let (beats, downs) = grid(64, 0.5, 4);
        let (mel, bank) = synth(&beats, 50 * 40, |_| 1.0);
        let mut logits = vec![-5.0f32; 50 * 40];
        for (k, t) in beats.iter().enumerate() {
            logits[(t * 50.0).round() as usize] = if k < 16 { 2.0 } else { 7.0 };
        }
        let conf = beat_confidence(&logits, &beats);
        assert_eq!(conf[0], 2.0);
        assert_eq!(conf[20], 7.0);
        let (acc, meter) = compute(&mel, 50 * 40, &bank, &beats, &downs, None, Some(&conf));
        assert!(meter.unsure >= 8, "{meter:?}");
        assert!(!acc.rhythmic[0]);
        assert!(acc.rhythmic[40]);
    }

    #[test]
    fn few_beats_are_flat() {
        let (beats, downs) = grid(5, 0.5, 4);
        let (mel, bank) = synth(&beats, 200, |k| k as f32);
        let (acc, _) = compute(&mel, 200, &bank, &beats, &downs, None, None);
        assert!(acc.impact.iter().all(|v| *v == 1.0));
        assert_eq!(acc.track_scale, 1.0);
    }
}
