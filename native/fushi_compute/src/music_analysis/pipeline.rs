//! 一首歌的分析：三步，每步结束都交出一份**完整**结果（同一种格式），读者随时拿到的都是能用的：
//!
//! 1. **DSP**（总是跑，几秒）：包络、起音、退路节拍网格、HPSS 鼓点、混音人声频段、每拍重音（不带模型置信度）；
//! 2. **Beat This!**（模型在时）：拍点 / 强拍 / BPM 换成模型的，每拍重音按模型 logit 重算（拿不准的段落置门）；
//! 3. **htdemucs**（模型在时）：鼓点换成鼓轨上挑的（没鼓的歌不给鼓点），人声换成人声轨包络。分离边跑边出：
//!    定稿的前缀够 10 秒后约每秒交一次部分结果（`FLAG_STEMS_PARTIAL` + `stems_until_ms`，之后的部分仍是
//!    DSP 的），最后一次交完整结果。
//!
//! 已有结果（`prior`）里由模型算出的部分不重算、也不会被这次的 DSP 结果盖掉：只补缺的那一步。
//! 拍点只在 prior 的管线版本不旧于当前时才算定稿（旧版没有按 logit 算的重音，Beat This! 要再跑一次）；
//! 分离结果只在不是部分结果时才算定稿。
//!
//! 模型用请求的执行器跑（[ModelPaths::backend]）；建会话失败在 [models::open_session] 里退回 CPU，
//! 建好之后跑模型失败（不支持的算子、驱动错误）由 [with_fallback] 记失效、用 CPU 重跑这一步。

use std::path::PathBuf;
use std::time::{Duration, Instant};

use super::accents::{self, Accents, PercussiveEnergy};
use super::beats::{self, ChunkPrediction};
use super::drums::{self, DrumHit};
use super::features::{self, ENV_HOP, MelBand, SAMPLE_RATE};
use super::format::{
    self, Analysis, FLAG_BEATS_MODEL, FLAG_DRUMLESS, FLAG_DRUMS_MODEL, FLAG_STEMS_PARTIAL,
    FLAG_VOCAL_MODEL, PIPELINE_VERSION,
};
use super::models::{self, BeatThis, Htdemucs, ModelKind, SeparationProgress};
use super::pcm::{INPUT_RATE, StereoPcm, decimate_to_analysis_rate};
use super::vocal;
use crate::upscale::runtime::Backend;

/// 步骤编号（进度事件里带）。
pub(crate) const STAGE_DSP: u32 = 1;
pub(crate) const STAGE_BEATS: u32 = 2;
pub(crate) const STAGE_STEMS: u32 = 3;

/// 定稿的分离前缀至少这么长才开始交部分结果（folia 同为 10 s）。
const PARTIAL_FIRST_S: f64 = 10.0;
/// 部分结果的最小间隔（墙钟，folia 约每秒重挑一次）。
const PARTIAL_EVERY: Duration = Duration::from_secs(1);

/// 本次可用的模型。
#[derive(Clone, Debug)]
pub(crate) struct ModelPaths {
    pub(crate) beat_this: Option<PathBuf>,
    pub(crate) htdemucs: Option<PathBuf>,
    pub(crate) threads: usize,
    /// 请求的执行器（不可用 / 失败时退回 CPU）。
    pub(crate) backend: Backend,
}

impl Default for ModelPaths {
    fn default() -> Self {
        Self {
            beat_this: None,
            htdemucs: None,
            threads: 0,
            backend: Backend::Cpu,
        }
    }
}

/// 分析的出口：进度、阶段性结果、取消。
pub(crate) trait Sink {
    fn progress(&mut self, stage: u32, permille: u32);
    /// 一步做完的完整结果（或分离途中的部分结果，见 FLAG_STEMS_PARTIAL）。
    fn publish(&mut self, analysis: &Analysis) -> Result<(), String>;
    fn cancelled(&self) -> bool;
    /// 模型那一步失败了（结果照常往下走，只是这一步留 DSP 的）。
    fn warn(&mut self, message: String);
    /// 加速执行器不行、退回 CPU（每个进程每个模型每个执行器只来一次）。
    fn backend_fallback(&mut self, backend: Backend, message: String);
}

const CANCELLED: &str = "cancelled";

fn env_frame_ms(frame: usize) -> f64 {
    frame as f64 * ENV_HOP as f64 * 1000.0 / SAMPLE_RATE as f64
}

fn seconds(ms: &[i32]) -> Vec<f64> {
    ms.iter().map(|v| f64::from(*v) / 1000.0).collect()
}

/// 每帧（50 fps）打击 / 总能量：HPSS 前后同一个 STFT 的幅度平方和。
fn percussive_energy(
    spec: &features::Spectrogram,
    perc: &features::Spectrogram,
) -> PercussiveEnergy {
    let sum_sq = |s: &features::Spectrogram, f: usize| -> f64 {
        s.row(f).iter().map(|v| f64::from(*v) * f64::from(*v)).sum()
    };
    PercussiveEnergy {
        percussive: (0..perc.frames).map(|f| sum_sq(perc, f)).collect(),
        total: (0..spec.frames).map(|f| sum_sq(spec, f)).collect(),
    }
}

/// 重音所需的混音特征（DSP 一步算一次，Beat This! 之后重算重音再用）。
struct AccentInputs {
    mel: Vec<f32>,
    frames: usize,
    bank: Vec<MelBand>,
    energy: PercussiveEnergy,
}

impl AccentInputs {
    fn compute(
        &self,
        beats_ms: &[i32],
        downbeats_ms: &[i32],
        confidence: Option<&[f64]>,
    ) -> Accents {
        accents::compute(
            &self.mel,
            self.frames,
            &self.bank,
            &seconds(beats_ms),
            &seconds(downbeats_ms),
            Some(&self.energy),
            confidence,
        )
        .0
    }
}

fn set_hits(a: &mut Analysis, hits: &[DrumHit]) {
    a.hits_ms = hits.iter().map(|h| format::ms(h.time_s)).collect();
    a.hit_strength = hits.iter().map(|h| h.strength).collect();
    a.hit_kind = hits.iter().map(|h| h.kind).collect();
}

/// 整首分析。返回最终结果（已经经 [Sink::publish] 交出）。
pub(crate) fn analyze(
    pcm: &StereoPcm,
    models: &ModelPaths,
    prior: Option<Analysis>,
    sink: &mut dyn Sink,
) -> Result<Analysis, String> {
    // ---- 1. DSP ----
    sink.progress(STAGE_DSP, 0);
    let mono44 = pcm.mono();
    let mono22 = decimate_to_analysis_rate(&mono44);
    if sink.cancelled() {
        return Err(CANCELLED.into());
    }
    let env = features::envelope(&mono22, &|| sink.cancelled()).ok_or(CANCELLED)?;
    sink.progress(STAGE_DSP, 300);
    if sink.cancelled() {
        return Err(CANCELLED.into());
    }
    let spec = features::bt_spectrogram(&mono22, &|| sink.cancelled()).ok_or(CANCELLED)?;
    drop(mono22);
    let bank = features::bt_filterbank();
    sink.progress(STAGE_DSP, 450);
    if sink.cancelled() {
        return Err(CANCELLED.into());
    }
    let fps = features::env_fps();
    let (grid, bpm, meter) = beats::dsp_grid(&env.onset_raw, &env.low_onset_raw, fps);
    let perc = features::percussive(&spec, &|| sink.cancelled()).ok_or(CANCELLED)?;
    let energy = percussive_energy(&spec, &perc);
    let perc_mel = features::bt_log_mel(&perc, &bank);
    drop(perc);
    let hits = drums::pick_drum_hits(&perc_mel, spec.frames, &bank, features::bt_fps());
    drop(perc_mel);
    let mix = AccentInputs {
        mel: features::bt_log_mel(&spec, &bank),
        frames: spec.frames,
        bank,
        energy,
    };
    drop(spec);
    sink.progress(STAGE_DSP, 800);

    let mut a = Analysis {
        flags: 0,
        frame_rate: fps as f32,
        onset: features::normalize_onset(&env.onset_raw),
        power: env.power,
        low: env.low,
        mid: env.mid,
        high: env.high,
        vocal: env.vocal_band,
        bpm,
        beats_per_bar: meter,
        beats_ms: grid.beats.iter().map(|t| format::ms(*t)).collect(),
        downbeats_ms: grid.downbeats.iter().map(|t| format::ms(*t)).collect(),
        duration_ms: pcm.duration_ms(),
        ..Default::default()
    };
    set_hits(&mut a, &hits);
    let dsp = a.clone();
    // 已有的模型结果原样留下。
    let mut beats_final = false;
    if let Some(p) = prior.as_ref().filter(|p| p.frames() == a.frames()) {
        if p.flags & FLAG_BEATS_MODEL != 0 {
            a.flags |= FLAG_BEATS_MODEL;
            a.bpm = p.bpm;
            a.beats_per_bar = p.beats_per_bar;
            a.beats_ms = p.beats_ms.clone();
            a.downbeats_ms = p.downbeats_ms.clone();
            beats_final = p.pipeline_version >= PIPELINE_VERSION
                && p.accents.impact.len() == p.beats_ms.len();
            if beats_final {
                a.accents = p.accents.clone();
            }
        }
        if p.flags & FLAG_STEMS_PARTIAL == 0 {
            if p.flags & FLAG_DRUMS_MODEL != 0 {
                a.flags |= p.flags & (FLAG_DRUMS_MODEL | FLAG_DRUMLESS);
                a.hits_ms = p.hits_ms.clone();
                a.hit_strength = p.hit_strength.clone();
                a.hit_kind = p.hit_kind.clone();
            }
            if p.flags & FLAG_VOCAL_MODEL != 0 {
                a.flags |= FLAG_VOCAL_MODEL;
                a.vocal = p.vocal.clone();
                a.vocal_onsets_ms = p.vocal_onsets_ms.clone();
            }
        }
    }
    if !beats_final {
        a.accents = mix.compute(&a.beats_ms, &a.downbeats_ms, None);
    }
    sink.progress(STAGE_DSP, 1000);
    sink.publish(&a)?;

    // ---- 2. Beat This! ----
    if let (Some(path), false) = (&models.beat_this, beats_final) {
        sink.progress(STAGE_BEATS, 0);
        let result = with_fallback(
            ModelKind::BeatThis,
            models.backend,
            sink,
            |backend, sink| {
                run_beat_this(path, models.threads, backend, &mix.mel, mix.frames, sink)
            },
        );
        match result {
            Ok(Some((grid, bpm, meter, logits))) => {
                a.flags |= FLAG_BEATS_MODEL;
                a.bpm = bpm;
                a.beats_per_bar = meter;
                a.beats_ms = grid.beats.iter().map(|t| format::ms(*t)).collect();
                a.downbeats_ms = grid.downbeats.iter().map(|t| format::ms(*t)).collect();
                let confidence = accents::beat_confidence(&logits, &seconds(&a.beats_ms));
                a.accents = mix.compute(&a.beats_ms, &a.downbeats_ms, Some(&confidence));
                sink.publish(&a)?;
            }
            Ok(None) => return Err(CANCELLED.into()),
            Err(e) => sink.warn(format!("beat_this: {e}")),
        }
    }
    drop(mix);

    // ---- 3. htdemucs ----
    let want_stems =
        a.flags & (FLAG_DRUMS_MODEL | FLAG_VOCAL_MODEL) != FLAG_DRUMS_MODEL | FLAG_VOCAL_MODEL;
    if let (Some(path), true) = (&models.htdemucs, want_stems) {
        sink.progress(STAGE_STEMS, 0);
        let before = a.clone();
        let result = with_fallback(
            ModelKind::Htdemucs,
            models.backend,
            sink,
            |backend, sink| {
                a = before.clone();
                run_stems(
                    path,
                    models.threads,
                    backend,
                    pcm,
                    &mono44,
                    &dsp,
                    &mut a,
                    sink,
                )
            },
        );
        match result {
            Ok(Some(())) => sink.publish(&a)?,
            Ok(None) => return Err(CANCELLED.into()),
            Err(e) => {
                // 中途交过部分结果：退回分离前的样子，别把半截留在文件里。
                if a != before {
                    a = before;
                    sink.publish(&a)?;
                }
                sink.warn(format!("htdemucs: {e}"));
            }
        }
    }
    Ok(a)
}

/// 一步模型的失败：带上当时用的执行器，供 [with_fallback] 判要不要换 CPU 重跑。
#[derive(Debug)]
pub(crate) enum StepError {
    Cancelled,
    /// 建会话 / 读模型这类与执行器无关的失败。
    Plain(String),
    /// 在这个执行器上跑模型失败。
    Run(Backend, String),
}

impl From<String> for StepError {
    fn from(e: String) -> Self {
        Self::Plain(e)
    }
}

/// 用请求的执行器跑一步模型；加速执行器上跑失败就记失效（只报一次）、用 CPU 再跑这一步。
/// `Ok(None)` = 取消。
fn with_fallback<T>(
    kind: ModelKind,
    backend: Backend,
    sink: &mut dyn Sink,
    mut step: impl FnMut(Backend, &mut dyn Sink) -> Result<T, StepError>,
) -> Result<Option<T>, String> {
    let finish = |r: Result<T, StepError>| match r {
        Ok(v) => Ok(Some(v)),
        Err(StepError::Cancelled) => Ok(None),
        Err(StepError::Plain(e)) | Err(StepError::Run(_, e)) => Err(e),
    };
    match step(backend, sink) {
        Err(StepError::Run(used, message)) if used != Backend::Cpu => {
            if models::disable_backend(kind, used) {
                sink.backend_fallback(
                    used,
                    format!("{kind:?} on {used:?} failed, using CPU: {message}"),
                );
            }
            finish(step(Backend::Cpu, sink))
        }
        other => finish(other),
    }
}

type GridResult = (beats::BeatGrid, Option<f64>, u32, Vec<f32>);

fn run_beat_this(
    path: &std::path::Path,
    threads: usize,
    backend: Backend,
    mel: &[f32],
    frames: usize,
    sink: &mut dyn Sink,
) -> Result<GridResult, StepError> {
    let (mut model, fallback) = BeatThis::load(path, threads, backend)?;
    if let Some(message) = fallback {
        sink.backend_fallback(backend, message);
    }
    let used = model.backend;
    let chunks = beats::split_for_model(mel, frames, features::BT_MELS);
    let mut preds = Vec::with_capacity(chunks.len());
    for (i, chunk) in chunks.iter().enumerate() {
        if sink.cancelled() {
            return Err(StepError::Cancelled);
        }
        let (beat, downbeat) = model
            .run(&chunk.data, chunk.frames)
            .map_err(|e| StepError::Run(used, e))?;
        preds.push(ChunkPrediction {
            start: chunk.start,
            frames: chunk.frames,
            beat,
            downbeat,
        });
        sink.progress(STAGE_BEATS, ((i + 1) * 1000 / chunks.len()) as u32);
    }
    let (beat, downbeat) = beats::aggregate_chunks(&preds, frames);
    let grid = beats::beats_from_logits(&beat, &downbeat, features::bt_fps());
    let bpm = beats::bpm_of(&grid.beats);
    let meter = beats::beats_per_bar(&grid);
    Ok((grid, bpm, meter, beat))
}

/// 已定稿前缀的 50 fps 梅尔谱，随前缀变长只补新的帧（部分结果用；最终结果整条重算）。
struct GrowingMel {
    frames: usize,
    mel: Vec<f32>,
}

/// 44.1 kHz 下一帧 = 882 个样本。
const MEL_STEP_44: usize = features::BT_HOP * 2;
/// 一帧要看到的右侧样本：半个帧窗（512 @ 22.05 kHz = 1024 @ 44.1 kHz）+ 抽取滤波器余量。
const MEL_REACH_44: usize = features::BT_NFFT + 256;
/// 从片段头重算时丢掉的帧（片段边缘的反射填充 / 滤波器起振只影响头两帧，留余量）。
const MEL_WARMUP: usize = 4;

impl GrowingMel {
    fn new() -> Self {
        Self {
            frames: 0,
            mel: Vec::new(),
        }
    }

    fn extend(&mut self, prefix: &[f32], bank: &[MelBand]) {
        if prefix.len() < MEL_REACH_44 {
            return;
        }
        let target = (prefix.len() - MEL_REACH_44) / MEL_STEP_44 + 1;
        if target <= self.frames {
            return;
        }
        let first = self.frames.saturating_sub(MEL_WARMUP);
        let d22 = decimate_to_analysis_rate(&prefix[first * MEL_STEP_44..]);
        let Some(spec) = features::bt_spectrogram(&d22, &|| false) else {
            return;
        };
        let mel = features::bt_log_mel(&spec, bank);
        let n = bank.len();
        let from = self.frames - first;
        let until = (target - first).min(spec.frames);
        if until > from {
            self.mel.extend_from_slice(&mel[from * n..until * n]);
            self.frames += until - from;
        }
    }
}

/// 人声轨 dB 包络（50 fps）插值到包络帧上，按 top 映射到 0–1；只写 `until_frame` 之前的帧。
fn apply_vocal(a: &mut Analysis, venv: &vocal::VocalEnvelope, until_frame: usize) {
    let last = venv.db.len().saturating_sub(1);
    for (i, slot) in a.vocal.iter_mut().enumerate().take(until_frame) {
        let at = env_frame_ms(i) / 1000.0 * vocal::VOCAL_FPS;
        let lo = (at.floor() as usize).min(last);
        let hi = (lo + 1).min(last);
        let t = (at - lo as f64).clamp(0.0, 1.0) as f32;
        let db = if venv.db.is_empty() {
            -120.0
        } else {
            venv.db[lo] * (1.0 - t) + venv.db[hi] * t
        };
        *slot = vocal::level01(db, venv.top);
    }
    a.vocal_onsets_ms = venv
        .onsets
        .iter()
        .map(|f| format::ms(*f as f64 / vocal::VOCAL_FPS))
        .collect();
}

/// 分离途中的部分结果：前缀内鼓点 / 人声换成分轨上算的，之后保留 DSP 的。
fn partial_update(
    a: &mut Analysis,
    dsp: &Analysis,
    progress: &SeparationProgress<'_>,
    mix_energy: &[f64],
    drum_mel: &GrowingMel,
    vocal_mel: &GrowingMel,
    bank: &[MelBand],
) {
    let until_s = drum_mel.frames.min(vocal_mel.frames) as f64 / features::bt_fps();
    let until_ms = format::ms(until_s).max(0);
    let drum_energy = drums::energy_frames(progress.drums);
    let mix_prefix = &mix_energy[..drum_energy.len().min(mix_energy.len())];
    let mut hits: Vec<DrumHit> =
        if drums::drum_coverage(&drum_energy, mix_prefix) < drums::DRUMLESS_COVERAGE {
            Vec::new()
        } else {
            drums::pick_drum_hits(&drum_mel.mel, drum_mel.frames, bank, features::bt_fps())
        };
    hits.retain(|h| format::ms(h.time_s) < until_ms);
    set_hits(a, &hits);
    // 前缀之后接着用 DSP 的鼓点。
    for (i, t) in dsp.hits_ms.iter().enumerate() {
        if *t >= until_ms {
            a.hits_ms.push(*t);
            a.hit_strength.push(dsp.hit_strength[i]);
            a.hit_kind.push(dsp.hit_kind[i]);
        }
    }
    let venv = vocal::vocal_envelope(
        progress.vocals,
        &vocal_mel.mel,
        vocal_mel.frames,
        features::BT_MELS,
    );
    let until_frame = (until_s * f64::from(a.frame_rate)).floor() as usize;
    a.vocal = dsp.vocal.clone();
    apply_vocal(a, &venv, until_frame);
    a.vocal_onsets_ms.retain(|t| *t < until_ms);
    a.flags = (a.flags & !FLAG_DRUMLESS) | FLAG_DRUMS_MODEL | FLAG_VOCAL_MODEL | FLAG_STEMS_PARTIAL;
    a.stems_until_ms = until_ms as u32;
}

#[allow(clippy::too_many_arguments)]
fn run_stems(
    path: &std::path::Path,
    threads: usize,
    backend: Backend,
    pcm: &StereoPcm,
    mono44: &[f32],
    dsp: &Analysis,
    a: &mut Analysis,
    sink: &mut dyn Sink,
) -> Result<(), StepError> {
    let (mut model, fallback) = Htdemucs::load(path, threads, backend)?;
    if let Some(message) = fallback {
        sink.backend_fallback(backend, message);
    }
    let used = model.backend;
    let bank = features::bt_filterbank();
    let mix_energy = drums::energy_frames(mono44);
    let mut cancelled = false;
    let mut publish_error: Option<String> = None;
    let stems = {
        let mut drum_mel = GrowingMel::new();
        let mut vocal_mel = GrowingMel::new();
        let mut last = Instant::now();
        let first_at = (PARTIAL_FIRST_S * INPUT_RATE as f64) as usize;
        let mut on_segment = |p: &SeparationProgress<'_>| -> bool {
            sink.progress(STAGE_STEMS, (p.done * 950 / p.chunks) as u32);
            if sink.cancelled() {
                cancelled = true;
                return false;
            }
            if p.done < p.chunks && p.drums.len() >= first_at && last.elapsed() >= PARTIAL_EVERY {
                drum_mel.extend(p.drums, &bank);
                vocal_mel.extend(p.vocals, &bank);
                partial_update(a, dsp, p, &mix_energy, &drum_mel, &vocal_mel, &bank);
                if let Err(e) = sink.publish(a) {
                    publish_error = Some(e);
                    return false;
                }
                last = Instant::now();
            }
            true
        };
        match model.separate(&pcm.left, &pcm.right, &mut on_segment) {
            Ok(s) => s,
            Err(_) if cancelled => return Err(StepError::Cancelled),
            Err(_) if publish_error.is_some() => {
                return Err(StepError::Plain(publish_error.unwrap_or_default()));
            }
            Err(e) => return Err(StepError::Run(used, e)),
        }
    };
    drop(model);

    // 鼓点：没鼓的歌不给（htdemucs 照样分出一条「鼓」，那是漏进来的贝斯）。
    let coverage = drums::drum_coverage(&drums::energy_frames(&stems.drums), &mix_energy);
    a.flags &= !(FLAG_DRUMLESS | FLAG_STEMS_PARTIAL);
    a.stems_until_ms = 0;
    if coverage < drums::DRUMLESS_COVERAGE {
        a.flags |= FLAG_DRUMLESS;
        set_hits(a, &[]);
    } else {
        let d22 = decimate_to_analysis_rate(&stems.drums);
        let (frames, mel) = features::bt_mel_of(&d22, &|| false).ok_or(StepError::Cancelled)?;
        let hits = drums::pick_drum_hits(&mel, frames, &bank, features::bt_fps());
        set_hits(a, &hits);
    }
    a.flags |= FLAG_DRUMS_MODEL;
    if sink.cancelled() {
        return Err(StepError::Cancelled);
    }

    // 人声：人声轨的 dB 包络（50 fps）插值到包络帧上，按整首 top 映射到 0–1。
    let v22 = decimate_to_analysis_rate(&stems.vocals);
    let (vframes, vmel) = features::bt_mel_of(&v22, &|| false).ok_or(StepError::Cancelled)?;
    let venv = vocal::vocal_envelope(&stems.vocals, &vmel, vframes, features::BT_MELS);
    let n = a.vocal.len();
    apply_vocal(a, &venv, n);
    a.flags |= FLAG_VOCAL_MODEL;
    sink.progress(STAGE_STEMS, 1000);
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub(crate) struct Collect {
        pub(crate) published: Vec<Analysis>,
        pub(crate) progress: Vec<(u32, u32)>,
        pub(crate) warnings: Vec<String>,
    }

    impl Collect {
        pub(crate) fn new() -> Self {
            Self {
                published: Vec::new(),
                progress: Vec::new(),
                warnings: Vec::new(),
            }
        }
    }

    impl Sink for Collect {
        fn progress(&mut self, stage: u32, permille: u32) {
            self.progress.push((stage, permille));
        }
        fn publish(&mut self, analysis: &Analysis) -> Result<(), String> {
            self.published.push(analysis.clone());
            Ok(())
        }
        fn cancelled(&self) -> bool {
            false
        }
        fn warn(&mut self, message: String) {
            self.warnings.push(message);
        }
        fn backend_fallback(&mut self, _backend: Backend, message: String) {
            self.warnings.push(message);
        }
    }

    /// 合成一段「鼓 + 持续音」：每拍一下低频敲击（强拍更响），上面一条 440 Hz 长音。
    pub(crate) fn synthetic_song(secs: f64, bpm: f64) -> StereoPcm {
        let left = synthetic_drums(secs, bpm, 0.5);
        let mut left = left;
        for (i, v) in left.iter_mut().enumerate() {
            *v += 0.1
                * (2.0 * std::f64::consts::PI * 440.0 * i as f64 / INPUT_RATE as f64).sin() as f32;
        }
        StereoPcm {
            right: left.clone(),
            left,
        }
    }

    /// 只有敲击的单声道信号（从 `from` 秒起每拍一下）。
    fn synthetic_drums(secs: f64, bpm: f64, from: f64) -> Vec<f32> {
        let n = (secs * INPUT_RATE as f64) as usize;
        let mut out = vec![0.0f32; n];
        let period = 60.0 / bpm;
        let mut k = 0;
        let mut t = from;
        while t < secs - 0.3 {
            let at = (t * INPUT_RATE as f64) as usize;
            let amp = if k % 4 == 0 { 0.9 } else { 0.5 };
            for i in 0..(0.15 * INPUT_RATE as f64) as usize {
                if at + i >= n {
                    break;
                }
                let tt = i as f64 / INPUT_RATE as f64;
                let env = (-tt * 30.0).exp();
                out[at + i] += (amp * env * (2.0 * std::f64::consts::PI * 60.0 * tt).sin()) as f32;
                // 敲击头上一点噪声样的高频。
                if i < 200 {
                    out[at + i] += (amp
                        * 0.4
                        * if (i * 7919) % 3 == 0 { 1.0 } else { -1.0 }
                        * (-tt * 400.0).exp()) as f32;
                }
            }
            k += 1;
            t += period;
        }
        out
    }

    #[test]
    fn dsp_only_finds_tempo_and_drums() {
        let pcm = synthetic_song(20.0, 120.0);
        let mut sink = Collect::new();
        let a = analyze(&pcm, &ModelPaths::default(), None, &mut sink).unwrap();
        assert_eq!(sink.published.len(), 1);
        assert_eq!(a.flags, 0);
        let bpm = a.bpm.unwrap();
        assert!((bpm - 120.0).abs() < 2.0, "bpm {bpm}");
        assert!(a.beats_ms.len() >= 30, "{} beats", a.beats_ms.len());
        // 拍点离真实敲击（0.5 s + k·0.5 s）不超过 40 ms。
        for b in &a.beats_ms {
            let off = (*b as f64 - 500.0).rem_euclid(500.0);
            assert!(off.min(500.0 - off) < 40.0, "beat {b}");
        }
        assert!(a.hits_ms.len() >= 30, "{} hits", a.hits_ms.len());
        assert_eq!(a.frames(), a.vocal.len());
        assert!((a.frame_rate - 86.13).abs() < 0.01);
        assert!(a.power.iter().cloned().fold(0.0f32, f32::max) > 0.1);
        assert_eq!(a.duration_ms, 20000);
        assert_eq!(sink.progress.last(), Some(&(STAGE_DSP, 1000)));
        // 每拍重音：与拍点等长，全是鼓的歌每拍都有节奏，track_scale 在 folia 的区间里。
        assert_eq!(a.accents.impact.len(), a.beats_ms.len());
        assert_eq!(a.accents.pulse.len(), a.beats_ms.len());
        assert!(a.accents.rhythmic.iter().all(|r| *r));
        assert!((0.45..=1.0).contains(&a.accents.track_scale));
        assert!(a.accents.impact.iter().any(|v| *v < 0.99));
    }

    #[test]
    fn prior_model_results_survive_a_dsp_rerun() {
        let pcm = synthetic_song(10.0, 120.0);
        let mut sink = Collect::new();
        let first = analyze(&pcm, &ModelPaths::default(), None, &mut sink).unwrap();
        let mut prior = first.clone();
        prior.flags = FLAG_BEATS_MODEL;
        prior.beats_ms = vec![1, 2, 3];
        prior.accents = Accents::neutral(3);
        prior.accents.track_scale = 0.5;
        prior.bpm = Some(99.0);
        let again = analyze(&pcm, &ModelPaths::default(), Some(prior.clone()), &mut sink).unwrap();
        assert_eq!(again.flags, FLAG_BEATS_MODEL);
        assert_eq!(again.beats_ms, vec![1, 2, 3]);
        assert_eq!(again.bpm, Some(99.0));
        assert_eq!(
            again.accents.track_scale, 0.5,
            "current-pipeline accents are kept"
        );

        // 旧管线写的：拍点留下，重音按当前算法重算（模型在时 Beat This! 会再跑一次）。
        prior.pipeline_version = 1;
        let old = analyze(&pcm, &ModelPaths::default(), Some(prior), &mut sink).unwrap();
        assert_eq!(old.beats_ms, vec![1, 2, 3]);
        assert_eq!(old.accents.impact.len(), 3);
        assert_eq!(old.accents.track_scale, 1.0, "few beats are flat");
    }

    #[test]
    fn partial_stem_results_are_not_kept_as_prior() {
        let pcm = synthetic_song(10.0, 120.0);
        let mut sink = Collect::new();
        let mut prior = analyze(&pcm, &ModelPaths::default(), None, &mut sink).unwrap();
        prior.flags = FLAG_DRUMS_MODEL | FLAG_VOCAL_MODEL | FLAG_STEMS_PARTIAL;
        prior.hits_ms = vec![7];
        prior.hit_strength = vec![1.0];
        prior.hit_kind = vec![0];
        let again = analyze(&pcm, &ModelPaths::default(), Some(prior), &mut sink).unwrap();
        assert_eq!(again.flags & (FLAG_DRUMS_MODEL | FLAG_STEMS_PARTIAL), 0);
        assert_ne!(again.hits_ms, vec![7]);
    }

    #[test]
    fn growing_mel_matches_the_whole_computation() {
        let signal = synthetic_drums(12.0, 120.0, 0.3);
        let bank = features::bt_filterbank();
        let d22 = decimate_to_analysis_rate(&signal);
        let (frames, whole) = features::bt_mel_of(&d22, &|| false).unwrap();
        let mut grown = GrowingMel::new();
        for until in [3.1, 3.2, 7.7, 12.0] {
            grown.extend(&signal[..(until * INPUT_RATE as f64) as usize], &bank);
        }
        assert!(
            grown.frames + 3 >= frames - 1 && grown.frames <= frames,
            "{} / {frames}",
            grown.frames
        );
        let n = bank.len();
        let mut worst = 0.0f32;
        for f in 0..grown.frames {
            for b in 0..n {
                worst = worst.max((grown.mel[f * n + b] - whole[f * n + b]).abs());
            }
        }
        assert!(worst < 1e-3, "max mel difference {worst}");
    }

    #[test]
    fn partial_update_splices_stem_results_before_the_cut() {
        let pcm = synthetic_song(20.0, 120.0);
        let mut sink = Collect::new();
        let dsp = analyze(&pcm, &ModelPaths::default(), None, &mut sink).unwrap();
        // 「鼓轨」：同一套敲击，只到 12 s 定稿。
        let drums_full = synthetic_drums(20.0, 120.0, 0.5);
        let done = 12 * INPUT_RATE;
        // 「人声轨」：前 6 s 一条 220 Hz 长音，之后静音。
        let vocals: Vec<f32> = (0..done)
            .map(|i| {
                let t = i as f64 / INPUT_RATE as f64;
                if t < 6.0 {
                    0.3 * (2.0 * std::f64::consts::PI * 220.0 * t).sin() as f32
                } else {
                    0.0
                }
            })
            .collect();
        let progress = SeparationProgress {
            done: 3,
            chunks: 7,
            drums: &drums_full[..done],
            vocals: &vocals,
        };
        let bank = features::bt_filterbank();
        let mut drum_mel = GrowingMel::new();
        let mut vocal_mel = GrowingMel::new();
        drum_mel.extend(progress.drums, &bank);
        vocal_mel.extend(progress.vocals, &bank);
        let mut a = dsp.clone();
        let mix_energy = drums::energy_frames(&pcm.mono());
        partial_update(
            &mut a,
            &dsp,
            &progress,
            &mix_energy,
            &drum_mel,
            &vocal_mel,
            &bank,
        );
        assert_ne!(a.flags & FLAG_STEMS_PARTIAL, 0);
        assert_ne!(a.flags & FLAG_DRUMS_MODEL, 0);
        let cut = a.stems_until_ms as i32;
        assert!((11_900..=12_000).contains(&cut), "cut {cut}");
        assert!(a.hits_ms.windows(2).all(|w| w[0] <= w[1]));
        assert!(a.hits_ms.iter().filter(|t| **t < cut).count() >= 15);
        // 切点之后原样是 DSP 的。
        let after: Vec<i32> = a.hits_ms.iter().copied().filter(|t| *t >= cut).collect();
        let dsp_after: Vec<i32> = dsp.hits_ms.iter().copied().filter(|t| *t >= cut).collect();
        assert_eq!(after, dsp_after);
        // 人声：前缀里按人声轨（唱的那段满、静音那段空），切点之后是 DSP 的人声频段。
        let fr = f64::from(a.frame_rate);
        let cut_frame = (f64::from(cut) / 1000.0 * fr) as usize;
        assert!(
            a.vocal[(1.0 * fr) as usize..(5.0 * fr) as usize]
                .iter()
                .all(|v| *v > 0.8)
        );
        assert!(
            a.vocal[(7.0 * fr) as usize..(11.0 * fr) as usize]
                .iter()
                .all(|v| *v < 0.2)
        );
        assert_eq!(a.vocal[cut_frame + 2..], dsp.vocal[cut_frame + 2..]);
    }

    #[test]
    fn a_run_failure_on_an_accelerator_retries_on_cpu_once() {
        let mut sink = Collect::new();
        let mut tried = Vec::new();
        let r: Result<Option<u32>, String> = with_fallback(
            ModelKind::BeatThis,
            Backend::DirectMl,
            &mut sink,
            |backend, _| {
                tried.push(backend);
                if backend == Backend::Cpu {
                    Ok(7)
                } else {
                    Err(StepError::Run(backend, "unsupported op".into()))
                }
            },
        );
        assert_eq!(r, Ok(Some(7)));
        assert_eq!(tried, vec![Backend::DirectMl, Backend::Cpu]);
        assert_eq!(sink.warnings.len(), 1);
        // 同一进程再失败不再报（失效表已记），CPU 上的失败直接报错。
        let r: Result<Option<u32>, String> = with_fallback(
            ModelKind::BeatThis,
            Backend::DirectMl,
            &mut sink,
            |backend, _| Err(StepError::Run(backend, "boom".into())),
        );
        assert_eq!(r, Err("boom".into()));
        assert_eq!(sink.warnings.len(), 1);
        let r: Result<Option<u32>, String> =
            with_fallback(ModelKind::BeatThis, Backend::Cpu, &mut sink, |_, _| {
                Err(StepError::Cancelled)
            });
        assert_eq!(r, Ok(None));
    }
}
