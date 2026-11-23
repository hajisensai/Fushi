//! 人声包络（folia `src/services/analysis/vocalEnvelope.ts` 移植）：人声轨每 20 ms 一帧的 RMS dB
//! （40 ms 窗）、整首第 97 百分位当 `top`、起音按 Beat This! 梅尔谱的正谱通量找峰（音尾在落的帧不算）。
//! 只在有 htdemucs 人声分轨时用；没有分轨时人声是混音的 1–3.5 kHz 频段（[super::features::Envelope]）。

/// 50 fps（Beat This! 帧率）。
pub(crate) const VOCAL_FPS: f64 = 50.0;
/// 44.1 kHz 下一帧 20 ms。
const FRAME: usize = 882;
const TOP_SHARE: f64 = 0.97;
/// 低于 `top` 这么多就不算在唱（也是 0–1 映射的量程）。
pub(crate) const SINGING_DB: f32 = 28.0;
const PEAK_REACH: usize = 3;
const AVERAGE_BEFORE: usize = 10;
const ONSET_DELTA: f64 = 0.7;
const FALLING_DB: f32 = 3.0;
const ONSET_GAP: usize = 3;

/// 人声包络。
pub(crate) struct VocalEnvelope {
    /// 每 20 ms 一帧的 dB。
    pub(crate) db: Vec<f32>,
    pub(crate) top: f32,
    /// 起音帧号（50 fps）。
    pub(crate) onsets: Vec<usize>,
}

/// 44.1 kHz 单声道人声轨 → 每帧 RMS dB（帧前后各一帧的 40 ms 窗）。
pub(crate) fn vocal_levels(stem: &[f32], frames: usize) -> Vec<f32> {
    (0..frames)
        .map(|frame| {
            let from = frame as i64 * FRAME as i64 - FRAME as i64;
            let lo = from.max(0) as usize;
            let hi = ((from + 2 * FRAME as i64).max(0) as usize).min(stem.len());
            let sum: f64 = stem[lo.min(hi)..hi]
                .iter()
                .map(|v| f64::from(*v) * f64::from(*v))
                .sum();
            (10.0 * (sum / (2 * FRAME) as f64 + 1e-12).log10()) as f32
        })
        .collect()
}

/// 梅尔谱（帧 × bands）的正谱通量（每帧相对上一帧各带上升量的平均）。
pub(crate) fn spectral_flux(mel: &[f32], frames: usize, bands: usize) -> Vec<f32> {
    let mut flux = vec![0.0f32; frames];
    for f in 1..frames {
        let mut sum = 0.0f32;
        for b in 0..bands {
            let rise = mel[f * bands + b] - mel[(f - 1) * bands + b];
            if rise > 0.0 {
                sum += rise;
            }
        }
        flux[f] = sum / bands as f32;
    }
    flux
}

/// folia `pickVocalOnsets`（整首版：from = 0）。
pub(crate) fn pick_vocal_onsets(flux: &[f32], db: &[f32], top: f32) -> Vec<usize> {
    let n = flux.len().min(db.len());
    if n == 0 {
        return Vec::new();
    }
    let mean = flux[..n].iter().map(|v| f64::from(*v)).sum::<f64>() / n as f64;
    let variance = flux[..n]
        .iter()
        .map(|v| (f64::from(*v) - mean).powi(2))
        .sum::<f64>()
        / n as f64;
    let delta = ONSET_DELTA * variance.sqrt();
    let mut onsets = Vec::new();
    let mut last: Option<usize> = None;
    let mut frame = PEAK_REACH;
    while frame + PEAK_REACH < n {
        let f = frame;
        frame += 1;
        if db[f] <= top - SINGING_DB || last.is_some_and(|l| f - l < ONSET_GAP) {
            continue;
        }
        if db[f + 1] < db[f - 1] - FALLING_DB {
            continue;
        }
        if !(f - PEAK_REACH..=f + PEAK_REACH).all(|at| flux[at] <= flux[f]) {
            continue;
        }
        let from = f.saturating_sub(AVERAGE_BEFORE);
        let local: f64 = flux[from..=f + PEAK_REACH]
            .iter()
            .map(|v| f64::from(*v))
            .sum();
        if f64::from(flux[f]) < local / (f + PEAK_REACH + 1 - from) as f64 + delta {
            continue;
        }
        onsets.push(f);
        last = Some(f);
    }
    onsets
}

/// 人声轨（44.1 kHz 单声道）+ 它的 Beat This! 梅尔谱 → 包络。
pub(crate) fn vocal_envelope(
    stem: &[f32],
    mel: &[f32],
    mel_frames: usize,
    bands: usize,
) -> VocalEnvelope {
    let db = vocal_levels(stem, mel_frames);
    let top = super::features::quantile(&db, TOP_SHARE);
    let flux = spectral_flux(mel, mel_frames, bands);
    let onsets = pick_vocal_onsets(&flux, &db, top);
    VocalEnvelope { db, top, onsets }
}

/// dB → 0–1（`top − SINGING_DB` 以下为 0，`top` 为 1）。
pub(crate) fn level01(db: f32, top: f32) -> f32 {
    ((db - (top - SINGING_DB)) / SINGING_DB).clamp(0.0, 1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn levels_follow_loudness() {
        let mut stem = vec![0.0f32; 44100];
        for v in stem[22050..].iter_mut() {
            *v = 0.5;
        }
        let db = vocal_levels(&stem, 50);
        assert!(db[5] < -100.0);
        assert!((db[40] - 20.0 * 0.5f32.log10()).abs() < 0.1);
        assert_eq!(level01(db[40], db[40]), 1.0);
        assert_eq!(level01(db[5], db[40]), 0.0);
    }

    #[test]
    fn onsets_at_flux_peaks_while_singing() {
        let n = 200;
        let db = vec![-10.0f32; n];
        let mut flux = vec![0.01f32; n];
        for at in [20, 60, 100, 140] {
            flux[at] = 1.0;
        }
        let onsets = pick_vocal_onsets(&flux, &db, -10.0);
        assert_eq!(onsets, vec![20, 60, 100, 140]);
        // 不在唱（低于 top − 28 dB）就没有起音。
        let quiet = vec![-60.0f32; n];
        assert!(pick_vocal_onsets(&flux, &quiet, -10.0).is_empty());
    }
}
