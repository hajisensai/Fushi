//! 鼓点（folia `src/services/analysis/drumHitPicking.ts` 移植）：鼓声梅尔谱上分底鼓 / 军鼓 / 镲片
//! 三段找突起，每个鼓点记时间、类别、强度（相对本频段第 99 百分位的突起，封顶 1）。
//!
//! 模型路径的输入是 htdemucs 鼓轨的 Beat This! 梅尔谱；退路是混音经 HPSS 留下的打击成分的同一种梅尔谱
//! （[super::features::percussive]）。帧窗常数是 folia 在 50 fps 上定的，这里按秒换算（50 fps 时完全相同）。

use super::features::MelBand;

/// 鼓点类别。
pub(crate) const KICK: u8 = 0;
#[allow(dead_code)] // 写进结果文件的类别值（Dart 侧按值读），Rust 里只比较底鼓 / 镲片。
pub(crate) const SNARE: u8 = 1;
pub(crate) const HAT: u8 = 2;

const KICK_MAX_HZ: f64 = 150.0;
const SNARE_MAX_HZ: f64 = 4000.0;
const HAT_MIN_HZ: f64 = 6000.0;
const HIT_TOP: f64 = 0.99;
const HIT_ONSET_FLOOR: f32 = 0.15;
/// 50 fps 下的帧数（folia 原值）。
const PEAK_BEFORE_50: f64 = 1.0;
const PEAK_AFTER_50: f64 = 2.0;
const BASE_FROM_50: f64 = 6.0;
const BASE_TO_50: f64 = 2.0;
const PEAK_HALF_50: f64 = 3.0;
const MIN_HIT_GAP_S: f64 = 0.09;

/// 一个鼓点。
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct DrumHit {
    pub(crate) time_s: f64,
    pub(crate) strength: f32,
    pub(crate) kind: u8,
}

fn frames_at(fps: f64, at50: f64) -> usize {
    (at50 * fps / 50.0)
        .round()
        .max(if at50 > 0.0 { 1.0 } else { 0.0 }) as usize
}

/// 每帧：中心落在 [from, to) Hz 的梅尔带平均。
fn band_track(mel: &[f32], frames: usize, bank: &[MelBand], from: f64, to: f64) -> Vec<f32> {
    let bands: Vec<usize> = bank
        .iter()
        .enumerate()
        .filter(|(_, b)| b.centre_hz >= from && b.centre_hz < to)
        .map(|(i, _)| i)
        .collect();
    let n = bank.len();
    (0..frames)
        .map(|f| {
            if bands.is_empty() {
                return 0.0;
            }
            bands.iter().map(|b| mel[f * n + b]).sum::<f32>() / bands.len() as f32
        })
        .collect()
}

struct Windows {
    before: usize,
    after: usize,
    base_from: usize,
    base_to: usize,
    half: usize,
}

fn rise_at(track: &[f32], frame: usize, w: &Windows) -> f32 {
    let n = track.len() as i64;
    let f = frame as i64;
    let mut peak = 0.0f32;
    for at in f - w.before as i64..=f + w.after as i64 {
        if at >= 0 && at < n {
            peak = peak.max(track[at as usize]);
        }
    }
    let (mut base, mut count) = (0.0f32, 0usize);
    for at in f - w.base_from as i64..=f - w.base_to as i64 {
        if at >= 0 && at < n {
            base += track[at as usize];
            count += 1;
        }
    }
    (peak - if count > 0 { base / count as f32 } else { 0.0 }).max(0.0)
}

fn rise_shares(track: &[f32], w: &Windows) -> Vec<f32> {
    let rise: Vec<f32> = (0..track.len()).map(|f| rise_at(track, f, w)).collect();
    let mut loud: Vec<f32> = rise.iter().cloned().filter(|v| *v > 0.0).collect();
    loud.sort_by(f32::total_cmp);
    let top = if loud.is_empty() {
        0.0
    } else {
        loud[((HIT_TOP * loud.len() as f64).floor() as usize).min(loud.len() - 1)]
    };
    let top = if top > 0.0 { top } else { 1.0 };
    rise.iter().map(|v| (v / top).min(1.0)).collect()
}

/// 梅尔谱（帧 × bank.len()）上挑鼓点。
pub(crate) fn pick_drum_hits(
    mel: &[f32],
    frames: usize,
    bank: &[MelBand],
    fps: f64,
) -> Vec<DrumHit> {
    let w = Windows {
        before: frames_at(fps, PEAK_BEFORE_50),
        after: frames_at(fps, PEAK_AFTER_50),
        base_from: frames_at(fps, BASE_FROM_50),
        base_to: frames_at(fps, BASE_TO_50),
        half: frames_at(fps, PEAK_HALF_50),
    };
    let tracks = [
        band_track(mel, frames, bank, 0.0, KICK_MAX_HZ),
        band_track(mel, frames, bank, KICK_MAX_HZ, SNARE_MAX_HZ),
        band_track(mel, frames, bank, HAT_MIN_HZ, f64::INFINITY),
    ];
    let bands: Vec<Vec<f32>> = tracks.iter().map(|t| rise_shares(t, &w)).collect();
    let mut top = vec![0.0f32; frames];
    let mut kind_of = vec![0u8; frames];
    for f in 0..frames {
        for (k, band) in bands.iter().enumerate() {
            if band[f] > top[f] {
                top[f] = band[f];
                kind_of[f] = k as u8;
            }
        }
    }
    let mut hits: Vec<DrumHit> = Vec::new();
    for f in 0..frames {
        let share = top[f];
        if share < HIT_ONSET_FLOOR {
            continue;
        }
        let lo = f.saturating_sub(w.half);
        let hi = (f + w.half).min(frames - 1);
        let peak = (lo..=hi).all(|at| !(top[at] > share || (top[at] == share && at < f)));
        if !peak {
            continue;
        }
        let time = f as f64 / fps;
        if let Some(last) = hits.last_mut() {
            if time - last.time_s < MIN_HIT_GAP_S {
                if share > last.strength {
                    *last = DrumHit {
                        time_s: time,
                        strength: share,
                        kind: kind_of[f],
                    };
                }
                continue;
            }
        }
        hits.push(DrumHit {
            time_s: time,
            strength: share,
            kind: kind_of[f],
        });
    }
    hits
}

// ---- 没鼓判断（folia drumCoverage）----

/// 能量帧：44.1 kHz 下 10 ms。
pub(crate) const ENERGY_HOP: usize = 441;
const SHARE_WINDOW: usize = 25;
const SHARE_AUDIBLE: f64 = 0.05;
const DRUMS_PLAYING_SHARE: f64 = 0.03;
/// 鼓声在有声窗口里的占比低于它就当没鼓（htdemucs 照样会分出一条「鼓」，那是漏进来的贝斯）。
pub(crate) const DRUMLESS_COVERAGE: f64 = 0.08;

/// 每 [ENERGY_HOP] 样本的能量和。
pub(crate) fn energy_frames(signal: &[f32]) -> Vec<f64> {
    let mut out = vec![0.0f64; signal.len().div_ceil(ENERGY_HOP)];
    for (i, v) in signal.iter().enumerate() {
        out[i / ENERGY_HOP] += f64::from(*v) * f64::from(*v);
    }
    out
}

/// 有鼓的有声窗口占比。
pub(crate) fn drum_coverage(drum: &[f64], mix: &[f64]) -> f64 {
    let mut windows: Vec<(f64, f64)> = Vec::new();
    let mut from = 0;
    while from < mix.len() {
        let to = (from + SHARE_WINDOW).min(mix.len());
        let d: f64 = (from..to)
            .map(|i| drum.get(i).copied().unwrap_or(0.0))
            .sum();
        let m: f64 = mix[from..to].iter().sum();
        windows.push((d, m));
        from += SHARE_WINDOW;
    }
    let mut mixes: Vec<f64> = windows.iter().map(|w| w.1).collect();
    mixes.sort_by(f64::total_cmp);
    let q = if mixes.is_empty() {
        0.0
    } else {
        mixes[((0.5 * mixes.len() as f64).floor() as usize).min(mixes.len() - 1)]
    };
    let floor = q * SHARE_AUDIBLE;
    let audible: Vec<&(f64, f64)> = windows
        .iter()
        .filter(|w| w.1 > floor && w.1 > 0.0)
        .collect();
    if audible.is_empty() {
        return 0.0;
    }
    audible
        .iter()
        .filter(|w| w.0 >= DRUMS_PLAYING_SHARE * w.1)
        .count() as f64
        / audible.len() as f64
}

#[cfg(test)]
mod tests {
    use super::super::features::bt_filterbank;
    use super::*;

    #[test]
    fn picks_kicks_and_hats_from_synthetic_mel() {
        let bank = bt_filterbank();
        let frames = 500;
        let mut mel = vec![0.0f32; frames * bank.len()];
        let kick_bands: Vec<usize> = (0..bank.len())
            .filter(|&b| bank[b].centre_hz < 150.0)
            .collect();
        let hat_bands: Vec<usize> = (0..bank.len())
            .filter(|&b| bank[b].centre_hz >= 6000.0)
            .collect();
        for k in (20..frames).step_by(25) {
            for b in &kick_bands {
                mel[k * bank.len() + b] = 5.0;
                mel[(k + 1) * bank.len() + b] = 3.0;
            }
        }
        for h in (32..frames).step_by(25) {
            for b in &hat_bands {
                mel[h * bank.len() + b] = 2.0;
            }
        }
        let hits = pick_drum_hits(&mel, frames, &bank, 50.0);
        let kicks = hits.iter().filter(|h| h.kind == KICK).count();
        let hats = hits.iter().filter(|h| h.kind == HAT).count();
        assert!(kicks >= 18, "kicks {kicks} {hits:?}");
        assert!(hats >= 17, "hats {hats}");
        // 两次之间至少 90 ms。
        assert!(
            hits.windows(2)
                .all(|w| w[1].time_s - w[0].time_s >= MIN_HIT_GAP_S - 1e-9)
        );
        assert!(hits.iter().all(|h| h.strength > 0.0 && h.strength <= 1.0));
    }

    #[test]
    fn coverage_tells_drumless_from_drums() {
        let mix = vec![1.0f64; 1000];
        let none = vec![0.001f64; 1000];
        let some = vec![0.2f64; 1000];
        assert!(drum_coverage(&none, &mix) < DRUMLESS_COVERAGE);
        assert!(drum_coverage(&some, &mix) > 0.9);
    }
}
