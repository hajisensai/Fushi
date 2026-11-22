//! 两个 ONNX 模型（都是 MIT，按需下载、sha256 钉死，见 Dart 侧 `music_audio_analysis_models.dart`）：
//!
//! - **Beat This!**（CPJKU，ISMIR 2024，final0）：输入 `input_spectrogram` [1, T, 128]（T ≤ 1500），
//!   输出 `beat` / `downbeat` [1, T] 的 logit。
//! - **htdemucs**（Meta Research）：输入 `mix` [1, 2, 172032]（44.1 kHz 立体声 3.9 s，STFT / iSTFT 在图里），
//!   输出 `stems` [1, 4, 2, 172032]，行序 drums / bass / other / vocals。分段与三角窗叠加照参考实现
//!   （demucs_onnx `_chunked_separate_single`，folia `electron/analysis/htdemucs.cjs`）：步长 3/4 段、
//!   重叠的 1/4 线性渐变、除以总权重。
//!
//! ORT 不另带：用 [crate::upscale::runtime] 接上的本进程那一份（CPU 执行器；音频分析在后台慢慢跑，
//! 不抢 GPU）。

use std::path::Path;

use ort::session::Session;
use ort::session::builder::GraphOptimizationLevel;
use ort::value::TensorRef;

use crate::upscale::runtime;

fn err<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

fn cpu_session(path: &Path, threads: usize) -> Result<Session, String> {
    let environment = runtime::environment()?;
    Session::builder(&environment)
        .map_err(err)?
        .with_optimization_level(GraphOptimizationLevel::Level3)
        .map_err(err)?
        .with_intra_threads(threads.max(1))
        .map_err(err)?
        .commit_from_file(path)
        .map_err(|e| format!("{}: {e}", path.display()))
}

/// Beat This! 会话。
pub(crate) struct BeatThis {
    session: Session,
}

impl BeatThis {
    pub(crate) fn load(path: &Path, threads: usize) -> Result<Self, String> {
        let session = cpu_session(path, threads)?;
        let names: Vec<&str> = session.outputs().iter().map(|o| o.name()).collect();
        if !names.contains(&"beat") || !names.contains(&"downbeat") {
            return Err(format!("beat_this outputs {names:?}"));
        }
        Ok(Self { session })
    }

    /// 一块梅尔谱（frames × 128）→ (beat, downbeat) logit。
    pub(crate) fn run(
        &mut self,
        mel: &[f32],
        frames: usize,
    ) -> Result<(Vec<f32>, Vec<f32>), String> {
        let tensor = TensorRef::from_array_view(([1usize, frames, 128], mel)).map_err(err)?;
        let outputs = self
            .session
            .run(ort::inputs!["input_spectrogram" => tensor])
            .map_err(err)?;
        let take = |name: &str| -> Result<Vec<f32>, String> {
            let (_, data) = outputs[name].try_extract_tensor::<f32>().map_err(err)?;
            if data.len() != frames {
                return Err(format!("{name}: {} values for {frames} frames", data.len()));
            }
            Ok(data.to_vec())
        };
        Ok((take("beat")?, take("downbeat")?))
    }
}

/// htdemucs 的分轨行号。
const DRUMS: usize = 0;
const VOCALS: usize = 3;
const SOURCES: usize = 4;

/// htdemucs 会话。
pub(crate) struct Htdemucs {
    session: Session,
    segment: usize,
}

/// 分离结果：鼓轨与人声轨（44.1 kHz，左右声道平均成单声道——下游只看单声道）。
pub(crate) struct Stems {
    pub(crate) drums: Vec<f32>,
    pub(crate) vocals: Vec<f32>,
}

/// 参考实现的三角叠加窗：两端各 1/4 段线性渐变。
pub(crate) fn overlap_window(segment: usize) -> Vec<f32> {
    let overlap = segment / 4;
    let mut win = vec![1.0f32; segment];
    for i in 0..overlap {
        let ramp = i as f32 / (overlap - 1) as f32;
        win[i] = ramp;
        win[segment - 1 - i] = ramp;
    }
    win
}

impl Htdemucs {
    pub(crate) fn load(path: &Path, threads: usize) -> Result<Self, String> {
        let session = cpu_session(path, threads)?;
        // 段长焊死在图里（形状、位置表、叠加归一都按一段切），从模型读，不在这里另写一份。
        let segment = session
            .inputs()
            .first()
            .and_then(|i| i.dtype().tensor_shape().and_then(|s| s.get(2).copied()))
            .filter(|s| *s > 0)
            .ok_or("htdemucs input is not [1, 2, segment]")? as usize;
        Ok(Self { session, segment })
    }

    /// 一共几段（进度用）。
    pub(crate) fn segments_for(&self, total: usize) -> usize {
        let stride = self.segment - self.segment / 4;
        total.div_ceil(stride).max(1)
    }

    /// 整首分离。`on_segment(i, n)` 每段完成回调一次，返回 false 即取消（返回 Err("cancelled")）。
    pub(crate) fn separate(
        &mut self,
        left: &[f32],
        right: &[f32],
        on_segment: &mut dyn FnMut(usize, usize) -> bool,
    ) -> Result<Stems, String> {
        let total = left.len();
        let segment = self.segment;
        let win = overlap_window(segment);
        let stride = segment - segment / 4;
        let chunks = self.segments_for(total);
        let mut drums = vec![0.0f32; total];
        let mut vocals = vec![0.0f32; total];
        let mut weight = vec![0.0f32; total];
        let mut input = vec![0.0f32; 2 * segment];
        for c in 0..chunks {
            let start = c * stride;
            let end = (start + segment).min(total);
            if end <= start {
                break;
            }
            let n = end - start;
            input.fill(0.0);
            input[..n].copy_from_slice(&left[start..end]);
            input[segment..segment + n].copy_from_slice(&right[start..end]);
            let tensor =
                TensorRef::from_array_view(([1usize, 2, segment], &input[..])).map_err(err)?;
            let outputs = self
                .session
                .run(ort::inputs!["mix" => tensor])
                .map_err(err)?;
            let (_, stems) = outputs[0].try_extract_tensor::<f32>().map_err(err)?;
            if stems.len() != SOURCES * 2 * segment {
                return Err(format!("htdemucs output has {} values", stems.len()));
            }
            for (source, out) in [(DRUMS, &mut drums), (VOCALS, &mut vocals)] {
                let l = &stems[(source * 2) * segment..(source * 2 + 1) * segment];
                let r = &stems[(source * 2 + 1) * segment..(source * 2 + 2) * segment];
                for i in 0..n {
                    out[start + i] += 0.5 * (l[i] + r[i]) * win[i];
                }
            }
            for i in 0..n {
                weight[start + i] += win[i];
            }
            if !on_segment(c + 1, chunks) {
                return Err("cancelled".into());
            }
        }
        for i in 0..total {
            let w = weight[i].max(1e-8);
            drums[i] /= w;
            vocals[i] /= w;
        }
        Ok(Stems { drums, vocals })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn overlap_window_ramps_quarter_each_side() {
        let w = overlap_window(16);
        assert_eq!(w[0], 0.0);
        assert_eq!(w[3], 1.0);
        assert_eq!(w[8], 1.0);
        assert_eq!(w[15], 0.0);
        assert!((w[1] - 1.0 / 3.0).abs() < 1e-6);
    }
}
