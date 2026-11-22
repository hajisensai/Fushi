//! 频谱特征：包络（≈86 Hz：响度 / 低中高频段 / 人声频段 / 起音）、Beat This! 的对数梅尔谱
//! （50 Hz，模型输入契约）、HPSS（谐波 / 打击分离，鼓点退路用）。
//!
//! 输入一律是 [SAMPLE_RATE] 单声道 f32（[super::pcm] 从 44.1 kHz 立体声降采样）。

use super::fft::{Fft, hann};

/// 分析采样率：Beat This! 的契约采样率，也是包络 STFT 的采样率。
pub(crate) const SAMPLE_RATE: usize = 22050;

/// 包络 STFT：1024 点（21.5 Hz 一格、46 ms 窗，与 folia 播放器 `AnalyserNode`
/// fftSize 2048 @ 44.1 kHz 的频率分辨率、窗长相同）。
pub(crate) const ENV_NFFT: usize = 1024;
/// 包络步长：256 样本 = 86.13 帧 / 秒。
pub(crate) const ENV_HOP: usize = 256;

/// 包络帧率（帧 / 秒）。
pub(crate) fn env_fps() -> f64 {
    SAMPLE_RATE as f64 / ENV_HOP as f64
}

// ---- Beat This! 契约（folia src/services/analysis/beatThis.ts；数值是训练时的设定，不是调参旋钮）----

pub(crate) const BT_NFFT: usize = 1024;
pub(crate) const BT_HOP: usize = 441;
pub(crate) const BT_MELS: usize = 128;
const BT_FMIN: f64 = 30.0;
const BT_FMAX: f64 = 11000.0;
const BT_LOG_MULTIPLIER: f64 = 1000.0;
const BT_AMIN: f64 = 1e-10;

/// Beat This! 帧率：22050 / 441 = 50 帧 / 秒。
pub(crate) fn bt_fps() -> f64 {
    SAMPLE_RATE as f64 / BT_HOP as f64
}

/// Slaney 梅尔（torchaudio 默认）：1 kHz 以下线性、以上对数。
fn hz_to_mel(hz: f64) -> f64 {
    let f_sp = 200.0 / 3.0;
    if hz < 1000.0 {
        return hz / f_sp;
    }
    1000.0 / f_sp + (hz / 1000.0).ln() / (6.4f64.ln() / 27.0)
}

fn mel_to_hz(mel: f64) -> f64 {
    let f_sp = 200.0 / 3.0;
    let min_log_mel = 1000.0 / f_sp;
    if mel < min_log_mel {
        return f_sp * mel;
    }
    1000.0 * ((6.4f64.ln() / 27.0) * (mel - min_log_mel)).exp()
}

/// 一个梅尔带：在 FFT 格上的权重与非零区间。
pub(crate) struct MelBand {
    pub(crate) start: usize,
    pub(crate) weights: Vec<f64>,
    /// 三角形峰值处的频率（Hz）。
    pub(crate) centre_hz: f64,
}

/// 三角滤波器组：拐点在梅尔尺度上等距、三角形在**赫兹**上线性（torchaudio 的做法，无面积归一）。
pub(crate) fn mel_filterbank(
    n_mels: usize,
    n_fft: usize,
    sample_rate: usize,
    fmin: f64,
    fmax: f64,
) -> Vec<MelBand> {
    let bins = n_fft / 2 + 1;
    let (mel_min, mel_max) = (hz_to_mel(fmin), hz_to_mel(fmax));
    let corners: Vec<f64> = (0..n_mels + 2)
        .map(|i| mel_to_hz(mel_min + (mel_max - mel_min) * i as f64 / (n_mels + 1) as f64))
        .collect();
    (0..n_mels)
        .map(|band| {
            let (left, centre, right) = (corners[band], corners[band + 1], corners[band + 2]);
            let row: Vec<f64> = (0..bins)
                .map(|bin| {
                    let hz = bin as f64 * sample_rate as f64 / n_fft as f64;
                    let rising = if centre == left {
                        0.0
                    } else {
                        (hz - left) / (centre - left)
                    };
                    let falling = if right == centre {
                        0.0
                    } else {
                        (right - hz) / (right - centre)
                    };
                    rising.min(falling).max(0.0)
                })
                .collect();
            let start = row.iter().position(|w| *w != 0.0).unwrap_or(bins);
            let end = row.iter().rposition(|w| *w != 0.0).map_or(start, |e| e + 1);
            MelBand {
                start,
                weights: row[start..end].to_vec(),
                centre_hz: centre,
            }
        })
        .collect()
}

/// Beat This! 的 128 带滤波器组。
pub(crate) fn bt_filterbank() -> Vec<MelBand> {
    mel_filterbank(BT_MELS, BT_NFFT, SAMPLE_RATE, BT_FMIN, BT_FMAX)
}

/// 反射补边（numpy `reflect` / torch 默认：不重复边缘样本），帧 `i` 居中于样本 `i * hop`。
fn reflect_padded(signal: &[f32], pad: usize) -> Vec<f64> {
    let n = signal.len();
    let mut out = vec![0.0f64; n + 2 * pad];
    if n == 0 {
        return out;
    }
    for i in 0..pad {
        out[i] = f64::from(signal[(pad - i).min(n - 1)]);
        let tail = n.saturating_sub(1).saturating_sub(pad - i);
        let last = out.len() - 1 - i;
        out[last] = f64::from(signal[tail]);
    }
    for (slot, v) in out[pad..pad + n].iter_mut().zip(signal) {
        *slot = f64::from(*v);
    }
    out
}

/// 居中 STFT 的帧数（torch `center=True`）。
pub(crate) fn centred_frames(samples: usize, n_fft: usize, hop: usize) -> usize {
    let padded = samples + n_fft;
    if padded < n_fft {
        return 0;
    }
    (padded - n_fft) / hop + 1
}

/// 幅度谱图（帧 × (n_fft/2+1)，行优先），Hann 窗、居中、按 √n_fft 归一（torchaudio 约定）。
pub(crate) struct Spectrogram {
    pub(crate) frames: usize,
    pub(crate) bins: usize,
    pub(crate) mag: Vec<f32>,
}

impl Spectrogram {
    pub(crate) fn row(&self, frame: usize) -> &[f32] {
        &self.mag[frame * self.bins..(frame + 1) * self.bins]
    }
}

/// [Spectrogram]（Beat This! 的 STFT：1024 点、hop 441）。`cancel` 返回 true 时提前停（返回 None）。
pub(crate) fn bt_spectrogram(mono: &[f32], cancel: &dyn Fn() -> bool) -> Option<Spectrogram> {
    let padded = reflect_padded(mono, BT_NFFT / 2);
    let frames = centred_frames(mono.len(), BT_NFFT, BT_HOP);
    let bins = BT_NFFT / 2 + 1;
    let mut mag = vec![0.0f32; frames * bins];
    let window = hann(BT_NFFT);
    let mut fft = Fft::new(BT_NFFT);
    let mut frame_buf = vec![0.0f64; BT_NFFT];
    let mut power = vec![0.0f64; bins];
    let scale = 1.0 / (BT_NFFT as f64).sqrt();
    for frame in 0..frames {
        if frame % 2048 == 0 && cancel() {
            return None;
        }
        let start = frame * BT_HOP;
        for i in 0..BT_NFFT {
            frame_buf[i] = padded[start + i] * window[i];
        }
        fft.power(&frame_buf, &mut power);
        for (slot, p) in mag[frame * bins..(frame + 1) * bins].iter_mut().zip(&power) {
            *slot = (p.sqrt() * scale) as f32;
        }
    }
    Some(Spectrogram { frames, bins, mag })
}

/// 幅度谱 → Beat This! 的对数梅尔（帧 × 128，`log1p(1000 · max(e, 1e-10))`）。
pub(crate) fn bt_log_mel(spec: &Spectrogram, bank: &[MelBand]) -> Vec<f32> {
    let mut out = vec![0.0f32; spec.frames * bank.len()];
    for frame in 0..spec.frames {
        let row = spec.row(frame);
        for (b, band) in bank.iter().enumerate() {
            let mut e = 0.0f64;
            for (k, w) in band.weights.iter().enumerate() {
                e += f64::from(row[band.start + k]) * w;
            }
            out[frame * bank.len() + b] = (BT_LOG_MULTIPLIER * e.max(BT_AMIN)).ln_1p() as f32;
        }
    }
    out
}

/// 整段的 Beat This! 对数梅尔谱（帧数, 数据）。
pub(crate) fn bt_mel_of(mono: &[f32], cancel: &dyn Fn() -> bool) -> Option<(usize, Vec<f32>)> {
    let spec = bt_spectrogram(mono, cancel)?;
    let bank = bt_filterbank();
    Some((spec.frames, bt_log_mel(&spec, &bank)))
}

// ---- HPSS（Fitzgerald 2010 中值滤波）----

/// 中值滤波的半宽（帧 / 格）：时间方向 8（50 fps 下约 0.34 s 的窗）、频率方向 8（约 370 Hz）。
const HPSS_HALF: usize = 8;

fn median_of(buf: &mut [f32]) -> f32 {
    let mid = buf.len() / 2;
    let (_, m, _) = buf.select_nth_unstable_by(mid, f32::total_cmp);
    *m
}

/// 打击成分的幅度谱（软掩膜，p = 2）：`S · P² / (P² + H²)`，P / H 分别是沿频率 / 沿时间的中值滤波。
pub(crate) fn percussive(spec: &Spectrogram, cancel: &dyn Fn() -> bool) -> Option<Spectrogram> {
    let (frames, bins) = (spec.frames, spec.bins);
    let mut harm = vec![0.0f32; frames * bins];
    let mut buf: Vec<f32> = Vec::with_capacity(2 * HPSS_HALF + 1);
    for bin in 0..bins {
        if bin % 64 == 0 && cancel() {
            return None;
        }
        for frame in 0..frames {
            buf.clear();
            let lo = frame.saturating_sub(HPSS_HALF);
            let hi = (frame + HPSS_HALF).min(frames.saturating_sub(1));
            for f in lo..=hi {
                buf.push(spec.mag[f * bins + bin]);
            }
            harm[frame * bins + bin] = median_of(&mut buf);
        }
    }
    let mut out = vec![0.0f32; frames * bins];
    for frame in 0..frames {
        if frame % 2048 == 0 && cancel() {
            return None;
        }
        let row = spec.row(frame);
        for bin in 0..bins {
            buf.clear();
            let lo = bin.saturating_sub(HPSS_HALF);
            let hi = (bin + HPSS_HALF).min(bins - 1);
            buf.extend_from_slice(&row[lo..=hi]);
            let p = median_of(&mut buf);
            let h = harm[frame * bins + bin];
            let (p2, h2) = (p * p, h * h);
            let mask = if p2 + h2 > 0.0 { p2 / (p2 + h2) } else { 0.0 };
            out[frame * bins + bin] = row[bin] * mask;
        }
    }
    Some(Spectrogram {
        frames,
        bins,
        mag: out,
    })
}

// ---- 包络（folia 播放器 AnalyserNode 的同型量）----

/// WebAudio `AnalyserNode` 默认 dB 区间：-100 dB → 0、-30 dB → 255。
const AN_MIN_DB: f64 = -100.0;
const AN_MAX_DB: f64 = -30.0;
/// folia 的 `smoothingTimeConstant = 0.6` 是按约 60 Hz 的取样定的；换算到本包络帧率。
fn smoothing() -> f64 {
    0.6f64.powf(60.0 / env_fps())
}

/// 整首的响度自适应：按整首 RMS 把电平挪到 [TARGET_RMS_DB]（流行母带的典型值），最多提 [MAX_BOOST_DB]、
/// 压 [MAX_CUT_DB]——古典 / 原声录音不至于整首暗淡，压得很响的母带也不至于整首顶满。
const TARGET_RMS_DB: f64 = -12.0;
const MAX_BOOST_DB: f64 = 18.0;
const MAX_CUT_DB: f64 = 6.0;

/// 起音谱的梅尔带数。
const ONSET_MELS: usize = 64;
/// 起音里「低频」的上限（底鼓 / 贝斯：强拍判定用）。
const LOW_ONSET_MAX_HZ: f64 = 200.0;

/// 包络一帧的原始量（0–1 前的中间值保留给节拍跟踪）。
pub(crate) struct Envelope {
    /// folia `audioPower`：`((bass + lowMid) / 2)³`。
    pub(crate) power: Vec<f32>,
    /// folia `bass`^1.8（20–150 Hz）。
    pub(crate) low: Vec<f32>,
    /// folia `lowMid` + `mid` 的平均 ^2（150–1200 Hz）。
    pub(crate) mid: Vec<f32>,
    /// folia `treble`^2（3.5–12 kHz）。
    pub(crate) high: Vec<f32>,
    /// folia `vocal` 频段（1–3.5 kHz）^1.5：没有人声分轨时的人声代理。
    pub(crate) vocal_band: Vec<f32>,
    /// 起音强度（正谱通量），未归一。节拍跟踪的输入。
    pub(crate) onset_raw: Vec<f32>,
    /// 只算 200 Hz 以下梅尔带的正谱通量（强拍判定）。
    pub(crate) low_onset_raw: Vec<f32>,
}

/// 整首 RMS（dBFS）。
pub(crate) fn rms_db(mono: &[f32]) -> f64 {
    if mono.is_empty() {
        return -120.0;
    }
    let sum: f64 = mono.iter().map(|v| f64::from(*v) * f64::from(*v)).sum();
    10.0 * (sum / mono.len() as f64 + 1e-12).log10()
}

/// 自适应增益（dB）。
pub(crate) fn adaptive_gain_db(mono: &[f32]) -> f64 {
    (TARGET_RMS_DB - rms_db(mono)).clamp(-MAX_CUT_DB, MAX_BOOST_DB)
}

fn blackman(n: usize) -> Vec<f64> {
    // WebAudio AnalyserNode 的窗：Blackman（α = 0.16）。
    let a0 = 0.42;
    let a1 = 0.5;
    let a2 = 0.08;
    (0..n)
        .map(|i| {
            let x = 2.0 * std::f64::consts::PI * i as f64 / n as f64;
            a0 - a1 * x.cos() + a2 * (2.0 * x).cos()
        })
        .collect()
}

/// 包络：每 [ENV_HOP] 样本一帧，帧居中于 `i * ENV_HOP`。
pub(crate) fn envelope(mono: &[f32], cancel: &dyn Fn() -> bool) -> Option<Envelope> {
    let frames = centred_frames(mono.len(), ENV_NFFT, ENV_HOP);
    let padded = reflect_padded(mono, ENV_NFFT / 2);
    let bins = ENV_NFFT / 2 + 1;
    let gain = 10f64.powf(adaptive_gain_db(mono) / 20.0);
    let window = blackman(ENV_NFFT);
    let hann_w = hann(ENV_NFFT);
    let mut fft = Fft::new(ENV_NFFT);
    let mut buf = vec![0.0f64; ENV_NFFT];
    let mut power = vec![0.0f64; bins];
    let mut smoothed = vec![0.0f64; bins];
    let mut db01 = vec![0.0f64; bins];
    let tau = smoothing();
    // folia getEnergy：`start = floor(minHz / 21.5)`、`end = floor(maxHz / 21.5)`，含两端。
    let range = |lo: f64, hi: f64| {
        let s = (lo / 21.5).floor() as usize;
        let e = ((hi / 21.5).floor() as usize).min(bins - 1);
        (s, e)
    };
    let (bass_r, low_mid_r, mid_r, vocal_r, treble_r) = (
        range(20.0, 150.0),
        range(150.0, 400.0),
        range(400.0, 1200.0),
        range(1000.0, 3500.0),
        range(3500.0, 12000.0),
    );
    let mean = |v: &[f64], (s, e): (usize, usize)| -> f64 {
        if e < s {
            return 0.0;
        }
        v[s..=e].iter().sum::<f64>() / (e - s + 1) as f64
    };
    let onset_bank = mel_filterbank(ONSET_MELS, ENV_NFFT, SAMPLE_RATE, 30.0, 11000.0);
    let low_bands = onset_bank
        .iter()
        .filter(|b| b.centre_hz < LOW_ONSET_MAX_HZ)
        .count()
        .max(1);
    let mut prev_mel = vec![0.0f64; ONSET_MELS];
    let mut mel = vec![0.0f64; ONSET_MELS];
    let mut env = Envelope {
        power: vec![0.0; frames],
        low: vec![0.0; frames],
        mid: vec![0.0; frames],
        high: vec![0.0; frames],
        vocal_band: vec![0.0; frames],
        onset_raw: vec![0.0; frames],
        low_onset_raw: vec![0.0; frames],
    };
    for frame in 0..frames {
        if frame % 4096 == 0 && cancel() {
            return None;
        }
        let start = frame * ENV_HOP;
        // AnalyserNode 那一路：Blackman 窗、|X| / N、逐格时间平滑、dB 映射到 0–1。
        for i in 0..ENV_NFFT {
            buf[i] = padded[start + i] * gain * window[i];
        }
        fft.power(&buf, &mut power);
        for k in 0..bins {
            let mag = power[k].sqrt() / ENV_NFFT as f64;
            smoothed[k] = tau * smoothed[k] + (1.0 - tau) * mag;
            let db = 20.0 * (smoothed[k] + 1e-20).log10();
            db01[k] = ((db - AN_MIN_DB) / (AN_MAX_DB - AN_MIN_DB)).clamp(0.0, 1.0);
        }
        let bass = mean(&db01, bass_r);
        let low_mid = mean(&db01, low_mid_r);
        let mid = mean(&db01, mid_r);
        let vocal = mean(&db01, vocal_r);
        let treble = mean(&db01, treble_r);
        env.power[frame] = ((bass + low_mid) / 2.0).powf(3.0) as f32;
        env.low[frame] = bass.powf(1.8) as f32;
        env.mid[frame] = ((low_mid + mid) / 2.0).powf(2.0) as f32;
        env.high[frame] = treble.powf(2.0) as f32;
        env.vocal_band[frame] = vocal.powf(1.5) as f32;

        // 起音那一路：Hann 窗、对数梅尔的正通量（与 Beat This! 同一种压缩）。
        for i in 0..ENV_NFFT {
            buf[i] = padded[start + i] * hann_w[i];
        }
        fft.power(&buf, &mut power);
        let scale = 1.0 / (ENV_NFFT as f64).sqrt();
        for (b, band) in onset_bank.iter().enumerate() {
            let mut e = 0.0;
            for (k, w) in band.weights.iter().enumerate() {
                e += power[band.start + k].sqrt() * scale * w;
            }
            mel[b] = (BT_LOG_MULTIPLIER * e.max(BT_AMIN)).ln_1p();
        }
        if frame > 0 {
            let mut flux = 0.0;
            let mut low_flux = 0.0;
            for b in 0..ONSET_MELS {
                let rise = (mel[b] - prev_mel[b]).max(0.0);
                flux += rise;
                if b < low_bands {
                    low_flux += rise;
                }
            }
            env.onset_raw[frame] = (flux / ONSET_MELS as f64) as f32;
            env.low_onset_raw[frame] = (low_flux / low_bands as f64) as f32;
        }
        std::mem::swap(&mut prev_mel, &mut mel);
    }
    Some(env)
}

/// 起音强度归一到 0–1：除以整首第 99 百分位（≥ 一个小下限，静音曲不至于放大噪声）。
pub(crate) fn normalize_onset(raw: &[f32]) -> Vec<f32> {
    let top = quantile(raw, 0.99).max(1e-3);
    raw.iter().map(|v| (v / top).clamp(0.0, 1.0)).collect()
}

/// 排序后取 `share` 处的值（folia `quantile`：`sorted[floor(share * n)]`）。
pub(crate) fn quantile(values: &[f32], share: f64) -> f32 {
    if values.is_empty() {
        return 0.0;
    }
    let mut sorted = values.to_vec();
    sorted.sort_by(f32::total_cmp);
    sorted[((share * sorted.len() as f64).floor() as usize).min(sorted.len() - 1)]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn never() -> bool {
        false
    }

    fn tone(hz: f64, secs: f64, amp: f32) -> Vec<f32> {
        let n = (secs * SAMPLE_RATE as f64) as usize;
        (0..n)
            .map(|i| {
                amp * (2.0 * std::f64::consts::PI * hz * i as f64 / SAMPLE_RATE as f64).sin() as f32
            })
            .collect()
    }

    #[test]
    fn mel_matches_beat_this_contract_frame_count() {
        let mono = vec![0.0f32; SAMPLE_RATE * 2];
        let (frames, data) = bt_mel_of(&mono, &never).unwrap();
        // 居中 STFT：len / hop + 1。
        assert_eq!(frames, SAMPLE_RATE * 2 / BT_HOP + 1);
        assert_eq!(data.len(), frames * BT_MELS);
        // 全静音 → log1p(1000 · 1e-10)。
        let floor = (1000.0f64 * 1e-10).ln_1p() as f32;
        assert!(data.iter().all(|v| (*v - floor).abs() < 1e-9));
    }

    #[test]
    fn filterbank_has_128_bands_inside_range() {
        let bank = bt_filterbank();
        assert_eq!(bank.len(), BT_MELS);
        assert!(bank[0].centre_hz > 30.0 && bank[0].centre_hz < 60.0);
        assert!(bank[127].centre_hz < 11000.0 && bank[127].centre_hz > 10000.0);
        // torchaudio：每带非零的格不空。
        assert!(bank.iter().all(|b| !b.weights.is_empty()));
    }

    #[test]
    fn bass_tone_lights_low_band_not_high() {
        let mono = tone(80.0, 2.0, 0.5);
        let env = envelope(&mono, &never).unwrap();
        let f = env.power.len() / 2;
        assert!(env.low[f] > 0.5, "low {}", env.low[f]);
        assert!(env.high[f] < 0.05, "high {}", env.high[f]);
        assert!(env.power[f] > 0.05);
    }

    #[test]
    fn treble_tone_lights_high_band() {
        // 高频段是 3.5–12 kHz 几百格的平均（folia getEnergy），单个纯音点不亮它：用一片 4–10 kHz 的密集正弦。
        let n = SAMPLE_RATE * 2;
        let mut mono = vec![0.0f32; n];
        let mut hz = 4000.0;
        let mut seed = 1u32;
        while hz < 10000.0 {
            seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12345);
            let phase = f64::from(seed >> 8) / f64::from(1u32 << 24) * std::f64::consts::TAU;
            for (i, v) in mono.iter_mut().enumerate() {
                *v += (0.01
                    * (std::f64::consts::TAU * hz * i as f64 / SAMPLE_RATE as f64 + phase).sin())
                    as f32;
            }
            hz += 25.0;
        }
        let env = envelope(&mono, &never).unwrap();
        let f = env.power.len() / 2;
        assert!(env.high[f] > 0.25, "high {}", env.high[f]);
        assert!(env.low[f] < 0.1, "low {}", env.low[f]);
    }

    #[test]
    fn clicks_produce_onsets_at_click_frames() {
        let mut mono = vec![0.0f32; SAMPLE_RATE * 3];
        let click_every = SAMPLE_RATE / 2;
        for c in 1..6 {
            let at = c * click_every;
            for i in 0..64 {
                mono[at + i] = if i % 2 == 0 { 0.8 } else { -0.8 };
            }
        }
        let env = envelope(&mono, &never).unwrap();
        let onset = normalize_onset(&env.onset_raw);
        for c in 1..6 {
            let frame = (c * click_every) as f64 / ENV_HOP as f64;
            let lo = frame as usize - 3;
            let peak = onset[lo..lo + 7].iter().cloned().fold(0.0f32, f32::max);
            assert!(peak > 0.5, "click {c}: {peak}");
        }
    }

    #[test]
    fn hpss_separates_click_from_tone() {
        let mut mono = tone(440.0, 3.0, 0.3);
        let at = SAMPLE_RATE * 3 / 2;
        for i in 0..32 {
            mono[at + i] += if i % 2 == 0 { 0.9 } else { -0.9 };
        }
        let spec = bt_spectrogram(&mono, &never).unwrap();
        let perc = percussive(&spec, &never).unwrap();
        let bin_440 = (440.0 * BT_NFFT as f64 / SAMPLE_RATE as f64).round() as usize;
        let quiet = 20;
        // 稳态音在打击谱里几乎没了。
        assert!(perc.row(quiet)[bin_440] < spec.row(quiet)[bin_440] * 0.1);
        // 敲击那一帧的高频格大多留在打击谱里。
        let hit = at / BT_HOP;
        let high_bin = 300;
        let kept = (hit - 1..=hit + 1)
            .map(|f| perc.row(f)[high_bin])
            .fold(0.0f32, f32::max);
        let orig = (hit - 1..=hit + 1)
            .map(|f| spec.row(f)[high_bin])
            .fold(0.0f32, f32::max);
        assert!(kept > orig * 0.5, "{kept} vs {orig}");
    }
}
