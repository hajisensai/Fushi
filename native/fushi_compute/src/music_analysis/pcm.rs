//! 输入 PCM：Dart 经统一 FFmpeg 后端把音轨解成 44.1 kHz 立体声 s16le 的临时 raw 文件
//! （`-ac 2 -ar 44100 -f s16le`），这里整份读进来；分析用的 22.05 kHz 单声道由
//! [decimate_to_analysis_rate] 降采样（htdemucs 要原始的 44.1 kHz 立体声）。

use std::io::Read;
use std::path::Path;

/// 输入采样率（htdemucs 的契约采样率）。
pub(crate) const INPUT_RATE: usize = 44100;

/// 最多分析这么长（超长的直播录音 / 整张专辑一轨不值得、也占不起内存）。
pub(crate) const MAX_SECONDS: usize = 20 * 60;

/// 44.1 kHz 立体声。
pub(crate) struct StereoPcm {
    pub(crate) left: Vec<f32>,
    pub(crate) right: Vec<f32>,
}

impl StereoPcm {
    pub(crate) fn len(&self) -> usize {
        self.left.len()
    }

    /// (L + R) / 2。
    pub(crate) fn mono(&self) -> Vec<f32> {
        self.left
            .iter()
            .zip(&self.right)
            .map(|(l, r)| 0.5 * (l + r))
            .collect()
    }

    pub(crate) fn duration_ms(&self) -> u32 {
        (self.len() as u64 * 1000 / INPUT_RATE as u64) as u32
    }
}

/// 读 s16le 交错立体声 raw 文件（超过 [MAX_SECONDS] 的部分不读）。
pub(crate) fn read_s16le_stereo(path: &Path) -> std::io::Result<StereoPcm> {
    let file = std::fs::File::open(path)?;
    let cap = (MAX_SECONDS * INPUT_RATE * 4) as u64;
    let mut bytes = Vec::new();
    file.take(cap).read_to_end(&mut bytes)?;
    Ok(from_s16le_stereo(&bytes))
}

pub(crate) fn from_s16le_stereo(bytes: &[u8]) -> StereoPcm {
    let frames = bytes.len() / 4;
    let mut left = Vec::with_capacity(frames);
    let mut right = Vec::with_capacity(frames);
    for f in bytes.chunks_exact(4) {
        left.push(f32::from(i16::from_le_bytes([f[0], f[1]])) / 32768.0);
        right.push(f32::from(i16::from_le_bytes([f[2], f[3]])) / 32768.0);
    }
    StereoPcm { left, right }
}

/// 抗混叠低通的抽头数（奇数，线性相位，群延迟 (N−1)/2 个输入样本——居中卷积，不引入延迟）。
const TAPS: usize = 127;
/// 截止频率（44.1 kHz 下的归一化频率，周 / 样本）：约 10.1 kHz，过渡带收在新奈奎斯特 11.025 kHz 前。
const CUTOFF: f64 = 0.229;

fn lowpass_kernel() -> Vec<f64> {
    let m = (TAPS - 1) as f64 / 2.0;
    let mut k: Vec<f64> = (0..TAPS)
        .map(|i| {
            let x = i as f64 - m;
            let sinc = if x == 0.0 {
                2.0 * CUTOFF
            } else {
                (2.0 * std::f64::consts::PI * CUTOFF * x).sin() / (std::f64::consts::PI * x)
            };
            // Blackman 窗。
            let w = 0.42 - 0.5 * (2.0 * std::f64::consts::PI * i as f64 / (TAPS - 1) as f64).cos()
                + 0.08 * (4.0 * std::f64::consts::PI * i as f64 / (TAPS - 1) as f64).cos();
            sinc * w
        })
        .collect();
    let sum: f64 = k.iter().sum();
    for v in &mut k {
        *v /= sum;
    }
    k
}

/// 44.1 kHz → 22.05 kHz（低通后隔一取一，样本 `i` 对齐输入样本 `2i`）。
pub(crate) fn decimate_to_analysis_rate(signal: &[f32]) -> Vec<f32> {
    let kernel = lowpass_kernel();
    let half = (TAPS / 2) as i64;
    let n = signal.len() as i64;
    (0..signal.len().div_ceil(2))
        .map(|o| {
            let centre = 2 * o as i64;
            let mut acc = 0.0f64;
            for (j, w) in kernel.iter().enumerate() {
                let at = centre + j as i64 - half;
                if at >= 0 && at < n {
                    acc += f64::from(signal[at as usize]) * w;
                }
            }
            acc as f32
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_interleaved_s16() {
        let bytes = [0x00, 0x40, 0x00, 0xC0, 0xFF, 0x7F, 0x00, 0x80];
        let pcm = from_s16le_stereo(&bytes);
        assert_eq!(pcm.left, vec![0.5, 32767.0 / 32768.0]);
        assert_eq!(pcm.right, vec![-0.5, -1.0]);
        assert_eq!(pcm.mono()[0], 0.0);
    }

    #[test]
    fn decimation_keeps_passband_and_kills_alias() {
        let tone = |hz: f64| -> Vec<f32> {
            (0..INPUT_RATE)
                .map(|i| {
                    (2.0 * std::f64::consts::PI * hz * i as f64 / INPUT_RATE as f64).sin() as f32
                })
                .collect()
        };
        let rms = |v: &[f32]| -> f64 {
            let mid = &v[2000..v.len() - 2000];
            (mid.iter().map(|x| f64::from(*x).powi(2)).sum::<f64>() / mid.len() as f64).sqrt()
        };
        let pass = decimate_to_analysis_rate(&tone(1000.0));
        assert!((rms(&pass) - 0.7071).abs() < 0.01, "{}", rms(&pass));
        // 16 kHz 会折叠到 6.05 kHz：必须压下去。
        let alias = decimate_to_analysis_rate(&tone(16000.0));
        assert!(rms(&alias) < 0.01, "{}", rms(&alias));
    }
}
