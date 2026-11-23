//! 节拍网格：两条路出同一种结果（拍点 / 强拍的秒数 + BPM + 每小节拍数）。
//!
//! - **模型**（Beat This!，folia `src/services/analysis/beatThis.ts` 的后处理逐条移植）：
//!   1500 帧分块、两端各丢 6 帧、先到的块优先拼回；拍点 = 正 logit 的 7 帧局部极大、相邻合并；
//!   强拍吸附到最近的拍点。没有 DBN——那是论文的要点，这里不加任何平滑。
//! - **退路**（模型没下载 / 跑失败）：起音包络 → 自相关估速（对数正态先验，中心 120 BPM）→
//!   Ellis 2007 动态规划跟拍（librosa `beat_track` 同一套：紧度 100、首尾弱拍裁掉）→
//!   强拍按「低频起音」最强的相位定（3 / 4 拍两种小节都试）。

use super::features::quantile;

/// 模型一次能吃的帧数（30 s @ 50 fps）。导出的图拒绝更长的输入。
pub(crate) const MODEL_CHUNK_FRAMES: usize = 1500;
/// 每块两端丢掉的帧数（块边上的帧上下文只有一半）。
const BORDER_FRAMES: i64 = 6;

/// 一块：起始帧（可为负：开头补零）、帧数、补零后的数据。
pub(crate) struct MelChunk {
    pub(crate) start: i64,
    pub(crate) frames: usize,
    pub(crate) data: Vec<f32>,
}

/// 各块起点（参考实现原样：步长 1500 − 12，最后一块拉回到与结尾对齐）。
fn chunk_starts(frames: usize) -> Vec<i64> {
    let stride = MODEL_CHUNK_FRAMES as i64 - 2 * BORDER_FRAMES;
    let frames = frames as i64;
    let mut starts = Vec::new();
    let mut start = -BORDER_FRAMES;
    while start < frames - BORDER_FRAMES {
        starts.push(start);
        start += stride;
    }
    if starts.is_empty() {
        return vec![-BORDER_FRAMES];
    }
    if frames > stride {
        let last = starts.len() - 1;
        starts[last] = frames - (MODEL_CHUNK_FRAMES as i64 - BORDER_FRAMES);
    }
    starts
}

/// 把整首梅尔谱切成模型块（folia `splitForModel`）。
pub(crate) fn split_for_model(mel: &[f32], frames: usize, bands: usize) -> Vec<MelChunk> {
    if frames == 0 {
        return Vec::new();
    }
    chunk_starts(frames)
        .into_iter()
        .map(|start| {
            let from = start.max(0) as usize;
            let to = ((start + MODEL_CHUNK_FRAMES as i64).min(frames as i64)).max(0) as usize;
            let left_pad = (-start).max(0) as usize;
            let right_pad = (start + MODEL_CHUNK_FRAMES as i64 - frames as i64)
                .clamp(0, BORDER_FRAMES) as usize;
            let body = to.saturating_sub(from);
            let n = left_pad + body + right_pad;
            let mut data = vec![0.0f32; n * bands];
            if to > from {
                data[left_pad * bands..(left_pad + body) * bands]
                    .copy_from_slice(&mel[from * bands..to * bands]);
            }
            MelChunk {
                start,
                frames: n,
                data,
            }
        })
        .collect()
}

/// 一块的预测。
pub(crate) struct ChunkPrediction {
    pub(crate) start: i64,
    pub(crate) frames: usize,
    pub(crate) beat: Vec<f32>,
    pub(crate) downbeat: Vec<f32>,
}

/// 把各块拼回整首（重叠处先到的块赢：倒序写入）。没被任何块覆盖的帧是 −1000。
pub(crate) fn aggregate_chunks(preds: &[ChunkPrediction], frames: usize) -> (Vec<f32>, Vec<f32>) {
    let mut beat = vec![-1000.0f32; frames];
    let mut downbeat = vec![-1000.0f32; frames];
    for chunk in preds.iter().rev() {
        let wide = chunk.frames as i64 >= 2 * BORDER_FRAMES;
        let from = if wide { BORDER_FRAMES as usize } else { 0 };
        let to = if wide {
            chunk.frames - BORDER_FRAMES as usize
        } else {
            chunk.frames
        };
        for offset in from..to {
            let target = chunk.start + offset as i64;
            if target < 0 || target >= frames as i64 {
                continue;
            }
            beat[target as usize] = chunk.beat[offset];
            downbeat[target as usize] = chunk.downbeat[offset];
        }
    }
    (beat, downbeat)
}

/// 相距 ≤ `width` 帧的峰合并成它们的滑动平均（folia `deduplicate`）。
fn deduplicate(peaks: &[usize], width: f64) -> Vec<usize> {
    if peaks.is_empty() {
        return Vec::new();
    }
    let mut merged = Vec::new();
    let mut mean = peaks[0] as f64;
    let mut count = 1.0;
    for &peak in &peaks[1..] {
        if peak as f64 - mean <= width {
            count += 1.0;
            mean += (peak as f64 - mean) / count;
        } else {
            merged.push(js_round(mean) as usize);
            mean = peak as f64;
            count = 1.0;
        }
    }
    merged.push(js_round(mean) as usize);
    merged
}

/// JS `Math.round`（.5 向 +∞）。
fn js_round(v: f64) -> f64 {
    (v + 0.5).floor()
}

/// 正 logit、7 帧内最大。
fn pick_peaks(logits: &[f32]) -> Vec<usize> {
    let mut peaks = Vec::new();
    for (i, &v) in logits.iter().enumerate() {
        if !(v > 0.0) {
            continue;
        }
        let lo = i.saturating_sub(3);
        let hi = (i + 3).min(logits.len() - 1);
        if logits[lo..=hi].iter().all(|o| *o <= v) {
            peaks.push(i);
        }
    }
    deduplicate(&peaks, 1.0)
}

/// 拍点网格（秒）。
#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct BeatGrid {
    pub(crate) beats: Vec<f64>,
    pub(crate) downbeats: Vec<f64>,
}

/// Beat This! 的 logit → 拍点 / 强拍（folia `beatsFromLogits`）。
pub(crate) fn beats_from_logits(beat: &[f32], downbeat: &[f32], fps: f64) -> BeatGrid {
    let beats: Vec<f64> = pick_peaks(beat)
        .into_iter()
        .map(|f| f as f64 / fps)
        .collect();
    let downs: Vec<f64> = pick_peaks(downbeat)
        .into_iter()
        .map(|f| f as f64 / fps)
        .collect();
    if beats.is_empty() {
        return BeatGrid::default();
    }
    let mut snapped: Vec<f64> = downs
        .iter()
        .map(|&t| {
            let mut best = beats[0];
            for &b in &beats {
                if (b - t).abs() < (best - t).abs() {
                    best = b;
                }
            }
            best
        })
        .collect();
    snapped.sort_by(f64::total_cmp);
    snapped.dedup();
    BeatGrid {
        beats,
        downbeats: snapped,
    }
}

fn median(values: &mut [f64]) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    values.sort_by(f64::total_cmp);
    let m = values.len() / 2;
    Some(if values.len() % 2 == 1 {
        values[m]
    } else {
        (values[m - 1] + values[m]) / 2.0
    })
}

/// 少于这么多拍不估速（folia `MIN_BEATS`）。
const MIN_BEATS: usize = 8;

/// BPM = 60 / 相邻拍间隔中位数（folia `gridFromBeats`：中位数不受漏拍影响）。
pub(crate) fn bpm_of(beats: &[f64]) -> Option<f64> {
    if beats.len() < MIN_BEATS {
        return None;
    }
    let mut iv: Vec<f64> = beats.windows(2).map(|w| w[1] - w[0]).collect();
    let period = median(&mut iv)?;
    (period > 0.0).then(|| 60.0 / period)
}

/// 每小节拍数：强拍间隔按拍数取整的中位数（2–12 之外的不算；没有强拍时 4）。
pub(crate) fn beats_per_bar(grid: &BeatGrid) -> u32 {
    let Some(bpm) = bpm_of(&grid.beats) else {
        return 4;
    };
    let period = 60.0 / bpm;
    let mut spans: Vec<f64> = grid
        .downbeats
        .windows(2)
        .map(|w| ((w[1] - w[0]) / period).round())
        .filter(|s| (2.0..=12.0).contains(s))
        .collect();
    match median(&mut spans) {
        Some(m) if m >= 2.0 => m.round() as u32,
        _ => 4,
    }
}

// ---- DSP 退路 ----

/// 估速范围。
const MIN_BPM: f64 = 40.0;
const MAX_BPM: f64 = 240.0;
/// 先验中心与宽度（八度）：librosa `tempo` 的默认值。
const PRIOR_BPM: f64 = 120.0;
const PRIOR_STD_OCTAVES: f64 = 1.0;
/// 跟拍紧度（librosa 默认 100）。
const TIGHTNESS: f64 = 100.0;

/// 去掉约 1 s 滑动平均后的起音（只留比周围突出的部分），再除标准差。
fn detrended(onset: &[f32], fps: f64) -> Vec<f64> {
    let n = onset.len();
    let half = (fps * 0.5).round() as usize;
    let mut prefix = vec![0.0f64; n + 1];
    for i in 0..n {
        prefix[i + 1] = prefix[i] + f64::from(onset[i]);
    }
    let raw: Vec<f64> = (0..n)
        .map(|i| {
            let lo = i.saturating_sub(half);
            let hi = (i + half + 1).min(n);
            let mean = (prefix[hi] - prefix[lo]) / (hi - lo) as f64;
            (f64::from(onset[i]) - mean).max(0.0)
        })
        .collect();
    // 再用 σ ≈ 1 帧的小高斯抹一下：拍距不是整帧时，单帧尖峰的自相关只在「两拍」的滞后上对得齐，
    // 会把速度估成一半。
    const KERNEL: [f64; 5] = [0.135, 0.607, 1.0, 0.607, 0.135];
    let mut out: Vec<f64> = (0..n)
        .map(|i| {
            let mut acc = 0.0;
            for (k, w) in KERNEL.iter().enumerate() {
                let at = i as i64 + k as i64 - 2;
                if at >= 0 && (at as usize) < n {
                    acc += raw[at as usize] * w;
                }
            }
            acc
        })
        .collect();
    let var = out.iter().map(|v| v * v).sum::<f64>() / n.max(1) as f64;
    let std = var.sqrt();
    if std > 0.0 {
        for v in &mut out {
            *v /= std;
        }
    }
    out
}

/// 自相关估速（BPM）；起音太弱 / 太短为 None。
pub(crate) fn estimate_tempo(onset: &[f32], fps: f64) -> Option<f64> {
    let o = detrended(onset, fps);
    let n = o.len();
    let min_lag = (60.0 * fps / MAX_BPM).floor().max(1.0) as usize;
    let max_lag = (60.0 * fps / MIN_BPM).ceil() as usize;
    if n < max_lag * 4 {
        return None;
    }
    let mut best: Option<(f64, usize)> = None;
    let mut scores = vec![0.0f64; max_lag + 2];
    for lag in min_lag..=max_lag + 1 {
        let mut acc = 0.0;
        for i in lag..n {
            acc += o[i] * o[i - lag];
        }
        scores[lag] = acc / (n - lag) as f64;
    }
    for lag in min_lag..=max_lag {
        let bpm = 60.0 * fps / lag as f64;
        let prior = (-0.5 * ((bpm / PRIOR_BPM).log2() / PRIOR_STD_OCTAVES).powi(2)).exp();
        let s = scores[lag] * prior;
        if s > 0.0 && best.is_none_or(|(b, _)| s > b) {
            best = Some((s, lag));
        }
    }
    let (_, lag) = best?;
    // 抛物线插值到亚帧精度。
    let (a, b, c) = (scores[lag - 1], scores[lag], scores[lag + 1]);
    let denom = a - 2.0 * b + c;
    let shift = if denom.abs() > 1e-12 {
        (0.5 * (a - c) / denom).clamp(-0.5, 0.5)
    } else {
        0.0
    };
    Some(60.0 * fps / (lag as f64 + shift))
}

/// Ellis 动态规划跟拍（librosa `__beat_tracker` 同一套），返回拍点帧号。
pub(crate) fn track_beats(onset: &[f32], fps: f64, bpm: f64) -> Vec<usize> {
    let n = onset.len();
    if n == 0 || !(bpm > 0.0) {
        return Vec::new();
    }
    let period = 60.0 * fps / bpm;
    // 起音 / 标准差，再用宽 period/32 的高斯平滑（librosa `__beat_local_score`）。
    let mean = onset.iter().map(|v| f64::from(*v)).sum::<f64>() / n as f64;
    let std = (onset
        .iter()
        .map(|v| (f64::from(*v) - mean).powi(2))
        .sum::<f64>()
        / n as f64)
        .sqrt()
        .max(1e-12);
    let norm: Vec<f64> = onset.iter().map(|v| f64::from(*v) / std).collect();
    let p = period.round().max(1.0) as i64;
    let kernel: Vec<f64> = (-p..=p)
        .map(|k| (-0.5 * (k as f64 * 32.0 / period).powi(2)).exp())
        .collect();
    let mut local = vec![0.0f64; n];
    for i in 0..n as i64 {
        let mut acc = 0.0;
        for (j, w) in kernel.iter().enumerate() {
            let at = i + j as i64 - p;
            if at >= 0 && at < n as i64 {
                acc += norm[at as usize] * w;
            }
        }
        local[i as usize] = acc;
    }
    // 候选前驱：t − 2·period … t − period/2。
    let lo = (2.0 * period).round() as i64;
    let hi = (period / 2.0).round().max(1.0) as i64;
    let txwt: Vec<f64> = (hi..=lo)
        .map(|d| -TIGHTNESS * (d as f64 / period).ln().powi(2))
        .collect();
    let max_local = local.iter().cloned().fold(f64::MIN, f64::max);
    let mut cum = vec![0.0f64; n];
    let mut back = vec![-1i64; n];
    let mut first = true;
    for i in 0..n {
        let mut best = f64::NEG_INFINITY;
        let mut arg = -1i64;
        for (k, d) in (hi..=lo).enumerate() {
            let prev = i as i64 - d;
            let score = if prev >= 0 {
                cum[prev as usize] + txwt[k]
            } else {
                txwt[k]
            };
            if score > best {
                best = score;
                arg = prev;
            }
        }
        if !best.is_finite() {
            best = 0.0;
        }
        cum[i] = local[i] + best;
        if first && local[i] < 0.01 * max_local {
            back[i] = -1;
        } else {
            back[i] = if arg >= 0 { arg } else { -1 };
            first = false;
        }
    }
    // 最后一拍：累积分的局部极大里、超过它们中位数一半的最后一个。
    let maxima: Vec<usize> = (1..n.saturating_sub(1))
        .filter(|&i| cum[i] >= cum[i - 1] && cum[i] > cum[i + 1])
        .collect();
    if maxima.is_empty() {
        return Vec::new();
    }
    let mut vals: Vec<f64> = maxima.iter().map(|&i| cum[i]).collect();
    let med = median(&mut vals).unwrap_or(0.0);
    let Some(&last) = maxima.iter().rev().find(|&&i| cum[i] >= 0.5 * med) else {
        return Vec::new();
    };
    let mut beats = vec![last];
    let mut at = back[last];
    while at >= 0 {
        beats.push(at as usize);
        at = back[at as usize];
    }
    beats.reverse();
    // 裁掉首尾的弱拍（librosa `__trim_beats`：Hann(5) 平滑后的局部分低于其 RMS 的一半）。
    let smooth: Vec<f64> = beats
        .iter()
        .enumerate()
        .map(|(j, _)| {
            let w = [0.25, 0.75, 1.0, 0.75, 0.25];
            let mut acc = 0.0;
            for (o, wv) in w.iter().enumerate() {
                let k = j as i64 + o as i64 - 2;
                if k >= 0 && (k as usize) < beats.len() {
                    acc += local[beats[k as usize]] * wv;
                }
            }
            acc
        })
        .collect();
    let rms = (smooth.iter().map(|v| v * v).sum::<f64>() / smooth.len().max(1) as f64).sqrt();
    let threshold = 0.5 * rms;
    let start = smooth.iter().position(|v| *v >= threshold).unwrap_or(0);
    let end = smooth
        .iter()
        .rposition(|v| *v >= threshold)
        .map_or(beats.len(), |e| e + 1);
    beats[start..end.max(start)].to_vec()
}

/// 强拍：试每小节 3 / 4 拍的每个相位，取「这些拍上的低频起音（+ 一半全频起音）平均」最突出的那个。
/// 3 拍要比 4 拍明显好（[THREE_MARGIN]）才选 3。返回 (强拍帧号, 每小节拍数)。
pub(crate) fn dsp_downbeats(
    beats: &[usize],
    low_onset: &[f32],
    onset: &[f32],
) -> (Vec<usize>, u32) {
    const THREE_MARGIN: f64 = 1.15;
    if beats.len() < 8 {
        return (Vec::new(), 4);
    }
    let low_top = f64::from(quantile(low_onset, 0.99)).max(1e-6);
    let top = f64::from(quantile(onset, 0.99)).max(1e-6);
    let feature: Vec<f64> = beats
        .iter()
        .map(|&b| {
            let lo = b.saturating_sub(2);
            let hi = (b + 2).min(onset.len().saturating_sub(1));
            let l = low_onset[lo..=hi].iter().cloned().fold(0.0f32, f32::max);
            let o = onset[lo..=hi].iter().cloned().fold(0.0f32, f32::max);
            f64::from(l) / low_top + 0.5 * f64::from(o) / top
        })
        .collect();
    let overall = feature.iter().sum::<f64>() / feature.len() as f64;
    let best = |meter: usize| -> (f64, usize) {
        (0..meter)
            .map(|phase| {
                let picked: Vec<f64> = feature
                    .iter()
                    .enumerate()
                    .filter(|(i, _)| i % meter == phase)
                    .map(|(_, v)| *v)
                    .collect();
                let mean = picked.iter().sum::<f64>() / picked.len().max(1) as f64;
                (mean - overall, phase)
            })
            .max_by(|a, b| a.0.total_cmp(&b.0))
            .unwrap_or((0.0, 0))
    };
    let (s4, p4) = best(4);
    let (s3, p3) = best(3);
    let (meter, phase) = if s3 > 0.0 && s3 > s4.max(0.0) * THREE_MARGIN {
        (3, p3)
    } else {
        (4, p4)
    };
    let downs = beats
        .iter()
        .enumerate()
        .filter(|(i, _)| i % meter == phase)
        .map(|(_, b)| *b)
        .collect();
    (downs, meter as u32)
}

/// 退路整条：起音 → 拍点 / 强拍（秒）+ BPM + 每小节拍数。
pub(crate) fn dsp_grid(onset: &[f32], low_onset: &[f32], fps: f64) -> (BeatGrid, Option<f64>, u32) {
    let Some(tempo) = estimate_tempo(onset, fps) else {
        return (BeatGrid::default(), None, 4);
    };
    let beats = track_beats(onset, fps, tempo);
    let (downs, meter) = dsp_downbeats(&beats, low_onset, onset);
    let grid = BeatGrid {
        beats: beats.iter().map(|f| *f as f64 / fps).collect(),
        downbeats: downs.iter().map(|f| *f as f64 / fps).collect(),
    };
    let bpm = bpm_of(&grid.beats).or(Some(tempo));
    (grid, bpm, meter)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chunk_starts_follow_reference() {
        assert_eq!(chunk_starts(100), vec![-6]);
        // 3000 帧：步长 1488，-6、1482，最后一块拉回到 3000 − 1494 = 1506。
        assert_eq!(chunk_starts(3000), vec![-6, 1482, 1506]);
    }

    #[test]
    fn split_and_aggregate_round_trip() {
        let frames = 3200;
        let mel: Vec<f32> = (0..frames * 2).map(|i| i as f32).collect();
        let chunks = split_for_model(&mel, frames, 2);
        assert!(chunks.iter().all(|c| c.frames <= MODEL_CHUNK_FRAMES));
        // 模型 = 恒等（取第 0 带当 logit），拼回来应等于原始第 0 带。
        let preds: Vec<ChunkPrediction> = chunks
            .iter()
            .map(|c| ChunkPrediction {
                start: c.start,
                frames: c.frames,
                beat: (0..c.frames).map(|f| c.data[f * 2]).collect(),
                downbeat: (0..c.frames).map(|f| c.data[f * 2 + 1]).collect(),
            })
            .collect();
        let (beat, down) = aggregate_chunks(&preds, frames);
        for f in 0..frames {
            assert_eq!(beat[f], (f * 2) as f32, "frame {f}");
            assert_eq!(down[f], (f * 2 + 1) as f32);
        }
    }

    #[test]
    fn logits_to_beats_snaps_downbeats() {
        let mut beat = vec![-5.0f32; 500];
        let mut down = vec![-5.0f32; 500];
        for b in (25..500).step_by(25) {
            beat[b] = 3.0;
            beat[b + 1] = 2.9; // 同一拍的相邻帧：不该多出一拍
        }
        for d in (25..500).step_by(100) {
            down[d + 2] = 2.0; // 偏两帧：吸到拍上
        }
        let grid = beats_from_logits(&beat, &down, 50.0);
        assert_eq!(grid.beats.len(), 19);
        assert!((grid.beats[0] - 0.5).abs() < 1e-9);
        assert_eq!(grid.downbeats.len(), 5);
        assert!(grid.downbeats.iter().all(|d| grid.beats.contains(d)));
        assert!((bpm_of(&grid.beats).unwrap() - 120.0).abs() < 1e-6);
        assert_eq!(beats_per_bar(&grid), 4);
    }

    fn click_onset(bpm: f64, fps: f64, secs: f64, accent_every: usize) -> (Vec<f32>, Vec<f32>) {
        let n = (secs * fps) as usize;
        let mut onset = vec![0.02f32; n];
        let mut low = vec![0.0f32; n];
        let period = 60.0 * fps / bpm;
        let mut k = 0usize;
        let mut t = 1.0 * fps;
        while (t as usize) < n {
            let at = t.round() as usize;
            onset[at] = 1.0;
            if k % accent_every == 0 {
                low[at] = 1.0;
            } else {
                low[at] = 0.1;
            }
            k += 1;
            t += period;
        }
        (onset, low)
    }

    #[test]
    fn dsp_tracks_a_steady_click_track() {
        let fps = 22050.0 / 256.0;
        for bpm in [92.0, 120.0, 138.0] {
            let (onset, low) = click_onset(bpm, fps, 30.0, 4);
            let (grid, est, meter) = dsp_grid(&onset, &low, fps);
            let est = est.unwrap();
            assert!((est - bpm).abs() < 2.0, "bpm {bpm} → {est}");
            assert!(grid.beats.len() > (30.0 * bpm / 60.0) as usize - 6);
            assert_eq!(meter, 4);
            // 强拍落在重音拍上：t = 1 s + 4k 拍。
            let period = 60.0 / bpm;
            for d in &grid.downbeats {
                let k = ((d - 1.0) / period).round() as i64;
                assert_eq!(k.rem_euclid(4), 0, "downbeat at {d}");
            }
        }
    }

    #[test]
    fn dsp_finds_waltz() {
        let fps = 22050.0 / 256.0;
        let (onset, low) = click_onset(150.0, fps, 30.0, 3);
        let (_, _, meter) = dsp_grid(&onset, &low, fps);
        assert_eq!(meter, 3);
    }

    #[test]
    fn silence_has_no_grid() {
        let fps = 22050.0 / 256.0;
        let (grid, bpm, _) = dsp_grid(&vec![0.0; 3000], &vec![0.0; 3000], fps);
        assert!(grid.beats.is_empty());
        assert!(bpm.is_none());
    }
}
