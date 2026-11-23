//! 两个 ONNX 模型（都是 MIT，按需下载、sha256 钉死，见 Dart 侧 `music_audio_analysis_models.dart`）：
//!
//! - **Beat This!**（CPJKU，ISMIR 2024，final0）：输入 `input_spectrogram` [1, T, 128]（T ≤ 1500），
//!   输出 `beat` / `downbeat` [1, T] 的 logit。
//! - **htdemucs**（Meta Research）：输入 `mix` [1, 2, 172032]（44.1 kHz 立体声 3.9 s，STFT / iSTFT 在图里），
//!   输出 `stems` [1, 4, 2, 172032]，行序 drums / bass / other / vocals。分段与三角窗叠加照参考实现
//!   （demucs_onnx `_chunked_separate_single`，folia `electron/analysis/htdemucs.cjs`）：步长 3/4 段、
//!   重叠的 1/4 线性渐变、除以总权重。
//!
//! ORT 不另带：用 [crate::upscale::runtime] 接上的本进程那一份；执行器与超分同一套选择
//! （[runtime::session_builder]：Windows DirectML / Apple CoreML MLProgram / Android XNNPACK，调用方传哪个用哪个）。
//! 加速执行器建会话失败（或跑模型失败，见 [super::pipeline]）就退回 CPU，并记进 [disable_backend]：
//! 同一进程同一模型不再试那个执行器，失败原因只报一次。

use std::path::Path;

use std::sync::Mutex;

use ort::session::Session;
use ort::value::TensorRef;

use crate::upscale::runtime::{self, Backend};

fn err<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

/// 模型种类（执行器失效表的键）。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) enum ModelKind {
    BeatThis,
    Htdemucs,
}

static DISABLED: Mutex<Vec<(ModelKind, Backend)>> = Mutex::new(Vec::new());

/// 这个模型在这个执行器上失败过：本进程之后直接走 CPU。返回 true = 第一次记（调用方据此只报一次）。
pub(crate) fn disable_backend(kind: ModelKind, backend: Backend) -> bool {
    let mut list = DISABLED.lock().unwrap_or_else(|e| e.into_inner());
    if list.contains(&(kind, backend)) {
        return false;
    }
    list.push((kind, backend));
    true
}

fn backend_disabled(kind: ModelKind, backend: Backend) -> bool {
    DISABLED
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .contains(&(kind, backend))
}

/// 建好的会话与实际用上的执行器；`fallback` = 这次退回了 CPU 且是第一次（要报的原因）。
pub(crate) struct Opened {
    pub(crate) session: Session,
    pub(crate) backend: Backend,
    pub(crate) fallback: Option<String>,
}

/// 按请求的执行器建会话；它不可用（ORT 里没有）就静默用 CPU，可用但建会话失败就退回 CPU 并记失效。
pub(crate) fn open_session(
    kind: ModelKind,
    path: &Path,
    threads: usize,
    wanted: Backend,
) -> Result<Opened, String> {
    let commit = |backend: Backend| -> Result<Session, String> {
        runtime::session_builder(backend, threads)?
            .commit_from_file(path)
            .map_err(|e| format!("{}: {e}", path.display()))
    };
    let mut fallback = None;
    if wanted != Backend::Cpu
        && !backend_disabled(kind, wanted)
        && runtime::backend_available(wanted)
    {
        match commit(wanted) {
            Ok(session) => {
                return Ok(Opened {
                    session,
                    backend: wanted,
                    fallback: None,
                });
            }
            Err(e) => {
                if disable_backend(kind, wanted) {
                    fallback = Some(format!("{kind:?} on {wanted:?} failed, using CPU: {e}"));
                }
            }
        }
    }
    Ok(Opened {
        session: commit(Backend::Cpu)?,
        backend: Backend::Cpu,
        fallback,
    })
}

/// Beat This! 会话。
pub(crate) struct BeatThis {
    session: Session,
    pub(crate) backend: Backend,
}

impl BeatThis {
    /// 返回会话与（第一次退回 CPU 时的）原因。
    pub(crate) fn load(
        path: &Path,
        threads: usize,
        backend: Backend,
    ) -> Result<(Self, Option<String>), String> {
        let opened = open_session(ModelKind::BeatThis, path, threads, backend)?;
        let names: Vec<&str> = opened.session.outputs().iter().map(|o| o.name()).collect();
        if !names.contains(&"beat") || !names.contains(&"downbeat") {
            return Err(format!("beat_this outputs {names:?}"));
        }
        Ok((
            Self {
                session: opened.session,
                backend: opened.backend,
            },
            opened.fallback,
        ))
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
    pub(crate) backend: Backend,
}

/// 分离结果：鼓轨与人声轨（44.1 kHz，左右声道平均成单声道——下游只看单声道）。
pub(crate) struct Stems {
    pub(crate) drums: Vec<f32>,
    pub(crate) vocals: Vec<f32>,
}

/// 分离进度：第 `done` / `chunks` 段跑完，`drums` / `vocals` 是已定稿的前缀（44.1 kHz 单声道，最终值）。
pub(crate) struct SeparationProgress<'a> {
    pub(crate) done: usize,
    pub(crate) chunks: usize,
    pub(crate) drums: &'a [f32],
    pub(crate) vocals: &'a [f32],
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
    /// 返回会话与（第一次退回 CPU 时的）原因。
    pub(crate) fn load(
        path: &Path,
        threads: usize,
        backend: Backend,
    ) -> Result<(Self, Option<String>), String> {
        let opened = open_session(ModelKind::Htdemucs, path, threads, backend)?;
        let session = opened.session;
        // 段长焊死在图里（形状、位置表、叠加归一都按一段切），从模型读，不在这里另写一份。
        let segment = session
            .inputs()
            .first()
            .and_then(|i| i.dtype().tensor_shape().and_then(|s| s.get(2).copied()))
            .filter(|s| *s > 0)
            .ok_or("htdemucs input is not [1, 2, segment]")? as usize;
        Ok((
            Self {
                session,
                segment,
                backend: opened.backend,
            },
            opened.fallback,
        ))
    }

    /// 一共几段（进度用）。
    pub(crate) fn segments_for(&self, total: usize) -> usize {
        let stride = self.segment - self.segment / 4;
        total.div_ceil(stride).max(1)
    }

    /// 整首分离。每段跑完回调一次 `on_segment(&进度)`，返回 false 即取消（返回 Err("cancelled")）。
    ///
    /// 进度里带**已定稿的前缀**：第 c 段之后的段都从 `(c + 1) · 步长` 起，前面的样本不会再被叠加，
    /// 就地除以权重后即最终值——调用方可以拿它边分边出结果（folia 的流式鼓点同理）。
    pub(crate) fn separate(
        &mut self,
        left: &[f32],
        right: &[f32],
        on_segment: &mut dyn FnMut(&SeparationProgress<'_>) -> bool,
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
        let mut finalized = 0usize;
        for c in 0..chunks {
            let start = c * stride;
            let end = (start + segment).min(total);
            if end > start {
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
            }
            let done = if c + 1 == chunks {
                total
            } else {
                ((c + 1) * stride).min(total)
            };
            for i in finalized..done {
                let w = weight[i].max(1e-8);
                drums[i] /= w;
                vocals[i] /= w;
            }
            finalized = done;
            let progress = SeparationProgress {
                done: c + 1,
                chunks,
                drums: &drums[..finalized],
                vocals: &vocals[..finalized],
            };
            if !on_segment(&progress) {
                return Err("cancelled".into());
            }
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
