//! 一首歌的分析：三步，每步结束都交出一份**完整**结果（同一种格式），读者随时拿到的都是能用的：
//!
//! 1. **DSP**（总是跑，几秒）：包络、起音、退路节拍网格、HPSS 鼓点、混音人声频段；
//! 2. **Beat This!**（模型在时）：拍点 / 强拍 / BPM 换成模型的；
//! 3. **htdemucs**（模型在时）：鼓点换成鼓轨上挑的（没鼓的歌不给鼓点），人声换成人声轨包络。
//!
//! 已有结果（`prior`）里由模型算出的部分不重算、也不会被这次的 DSP 结果盖掉：只补缺的那一步。

use std::path::PathBuf;

use super::beats::{self, ChunkPrediction};
use super::drums;
use super::features::{self, ENV_HOP, SAMPLE_RATE};
use super::format::{
    self, Analysis, FLAG_BEATS_MODEL, FLAG_DRUMLESS, FLAG_DRUMS_MODEL, FLAG_VOCAL_MODEL,
};
use super::models::{BeatThis, Htdemucs};
use super::pcm::{StereoPcm, decimate_to_analysis_rate};
use super::vocal;

/// 步骤编号（进度事件里带）。
pub(crate) const STAGE_DSP: u32 = 1;
pub(crate) const STAGE_BEATS: u32 = 2;
pub(crate) const STAGE_STEMS: u32 = 3;

/// 本次可用的模型。
#[derive(Clone, Debug, Default)]
pub(crate) struct ModelPaths {
    pub(crate) beat_this: Option<PathBuf>,
    pub(crate) htdemucs: Option<PathBuf>,
    pub(crate) threads: usize,
}

/// 分析的出口：进度、阶段性结果、取消。
pub(crate) trait Sink {
    fn progress(&mut self, stage: u32, permille: u32);
    /// 一步做完的完整结果。
    fn publish(&mut self, analysis: &Analysis) -> Result<(), String>;
    fn cancelled(&self) -> bool;
    /// 模型那一步失败了（结果照常往下走，只是这一步留 DSP 的）。
    fn warn(&mut self, message: String);
}

const CANCELLED: &str = "cancelled";

fn env_frame_ms(frame: usize) -> f64 {
    frame as f64 * ENV_HOP as f64 * 1000.0 / SAMPLE_RATE as f64
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
    let bank = features::bt_filterbank();
    sink.progress(STAGE_DSP, 450);
    if sink.cancelled() {
        return Err(CANCELLED.into());
    }
    let fps = features::env_fps();
    let (grid, bpm, meter) = beats::dsp_grid(&env.onset_raw, &env.low_onset_raw, fps);
    let perc = features::percussive(&spec, &|| sink.cancelled()).ok_or(CANCELLED)?;
    let perc_mel = features::bt_log_mel(&perc, &bank);
    drop(perc);
    let hits = drums::pick_drum_hits(&perc_mel, spec.frames, &bank, features::bt_fps());
    drop(perc_mel);
    sink.progress(STAGE_DSP, 900);

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
        hits_ms: hits.iter().map(|h| format::ms(h.time_s)).collect(),
        hit_strength: hits.iter().map(|h| h.strength).collect(),
        hit_kind: hits.iter().map(|h| h.kind).collect(),
        vocal_onsets_ms: Vec::new(),
        duration_ms: pcm.duration_ms(),
    };
    // 已有的模型结果原样留下。
    if let Some(p) = prior.as_ref().filter(|p| p.frames() == a.frames()) {
        if p.flags & FLAG_BEATS_MODEL != 0 {
            a.flags |= FLAG_BEATS_MODEL;
            a.bpm = p.bpm;
            a.beats_per_bar = p.beats_per_bar;
            a.beats_ms = p.beats_ms.clone();
            a.downbeats_ms = p.downbeats_ms.clone();
        }
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
    sink.progress(STAGE_DSP, 1000);
    sink.publish(&a)?;

    // ---- 2. Beat This! ----
    if let (Some(path), true) = (&models.beat_this, a.flags & FLAG_BEATS_MODEL == 0) {
        sink.progress(STAGE_BEATS, 0);
        let mel = features::bt_log_mel(&spec, &bank);
        match run_beat_this(path, models.threads, &mel, spec.frames, sink) {
            Ok(Some((grid, bpm, meter))) => {
                a.flags |= FLAG_BEATS_MODEL;
                a.bpm = bpm;
                a.beats_per_bar = meter;
                a.beats_ms = grid.beats.iter().map(|t| format::ms(*t)).collect();
                a.downbeats_ms = grid.downbeats.iter().map(|t| format::ms(*t)).collect();
                sink.publish(&a)?;
            }
            Ok(None) => return Err(CANCELLED.into()),
            Err(e) => sink.warn(format!("beat_this: {e}")),
        }
    }
    drop(spec);

    // ---- 3. htdemucs ----
    let want_stems =
        a.flags & (FLAG_DRUMS_MODEL | FLAG_VOCAL_MODEL) != FLAG_DRUMS_MODEL | FLAG_VOCAL_MODEL;
    if let (Some(path), true) = (&models.htdemucs, want_stems) {
        sink.progress(STAGE_STEMS, 0);
        match run_stems(path, models.threads, pcm, &mono44, &mut a, sink) {
            Ok(true) => sink.publish(&a)?,
            Ok(false) => return Err(CANCELLED.into()),
            Err(e) => sink.warn(format!("htdemucs: {e}")),
        }
    }
    Ok(a)
}

type GridResult = (beats::BeatGrid, Option<f64>, u32);

/// Ok(None) = 取消。
fn run_beat_this(
    path: &std::path::Path,
    threads: usize,
    mel: &[f32],
    frames: usize,
    sink: &mut dyn Sink,
) -> Result<Option<GridResult>, String> {
    let mut model = BeatThis::load(path, threads)?;
    let chunks = beats::split_for_model(mel, frames, features::BT_MELS);
    let mut preds = Vec::with_capacity(chunks.len());
    for (i, chunk) in chunks.iter().enumerate() {
        if sink.cancelled() {
            return Ok(None);
        }
        let (beat, downbeat) = model.run(&chunk.data, chunk.frames)?;
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
    Ok(Some((grid, bpm, meter)))
}

/// Ok(false) = 取消。
fn run_stems(
    path: &std::path::Path,
    threads: usize,
    pcm: &StereoPcm,
    mono44: &[f32],
    a: &mut Analysis,
    sink: &mut dyn Sink,
) -> Result<bool, String> {
    let mut model = Htdemucs::load(path, threads)?;
    let mut cancelled = false;
    let stems = {
        let mut on_segment = |i: usize, n: usize| -> bool {
            sink.progress(STAGE_STEMS, (i * 950 / n) as u32);
            if sink.cancelled() {
                cancelled = true;
                return false;
            }
            true
        };
        match model.separate(&pcm.left, &pcm.right, &mut on_segment) {
            Ok(s) => s,
            Err(_) if cancelled => return Ok(false),
            Err(e) => return Err(e),
        }
    };
    drop(model);
    let bank = features::bt_filterbank();

    // 鼓点：没鼓的歌不给（htdemucs 照样分出一条「鼓」，那是漏进来的贝斯）。
    let coverage = drums::drum_coverage(
        &drums::energy_frames(&stems.drums),
        &drums::energy_frames(mono44),
    );
    a.flags &= !FLAG_DRUMLESS;
    if coverage < drums::DRUMLESS_COVERAGE {
        a.flags |= FLAG_DRUMLESS;
        a.hits_ms.clear();
        a.hit_strength.clear();
        a.hit_kind.clear();
    } else {
        let d22 = decimate_to_analysis_rate(&stems.drums);
        let (frames, mel) = features::bt_mel_of(&d22, &|| false).ok_or(CANCELLED)?;
        let hits = drums::pick_drum_hits(&mel, frames, &bank, features::bt_fps());
        a.hits_ms = hits.iter().map(|h| format::ms(h.time_s)).collect();
        a.hit_strength = hits.iter().map(|h| h.strength).collect();
        a.hit_kind = hits.iter().map(|h| h.kind).collect();
    }
    a.flags |= FLAG_DRUMS_MODEL;
    if sink.cancelled() {
        return Ok(false);
    }

    // 人声：人声轨的 dB 包络（50 fps）插值到包络帧上，按整首 top 映射到 0–1。
    let v22 = decimate_to_analysis_rate(&stems.vocals);
    let (vframes, vmel) = features::bt_mel_of(&v22, &|| false).ok_or(CANCELLED)?;
    let venv = vocal::vocal_envelope(&stems.vocals, &vmel, vframes, features::BT_MELS);
    for (i, slot) in a.vocal.iter_mut().enumerate() {
        let at = env_frame_ms(i) / 1000.0 * vocal::VOCAL_FPS;
        let lo = (at.floor() as usize).min(venv.db.len().saturating_sub(1));
        let hi = (lo + 1).min(venv.db.len().saturating_sub(1));
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
    a.flags |= FLAG_VOCAL_MODEL;
    sink.progress(STAGE_STEMS, 1000);
    Ok(true)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::super::pcm::INPUT_RATE;
    use super::*;

    pub(crate) struct Collect {
        pub(crate) published: Vec<Analysis>,
        pub(crate) progress: Vec<(u32, u32)>,
        pub(crate) warnings: Vec<String>,
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
    }

    /// 合成一段「鼓 + 持续音」：120 BPM，每拍一下低频敲击（强拍更响），上面一条 440 Hz 长音。
    pub(crate) fn synthetic_song(secs: f64, bpm: f64) -> StereoPcm {
        let n = (secs * INPUT_RATE as f64) as usize;
        let mut left = vec![0.0f32; n];
        let period = 60.0 / bpm;
        let mut k = 0;
        let mut t = 0.5;
        while t < secs - 0.3 {
            let at = (t * INPUT_RATE as f64) as usize;
            let amp = if k % 4 == 0 { 0.9 } else { 0.5 };
            for i in 0..(0.15 * INPUT_RATE as f64) as usize {
                if at + i >= n {
                    break;
                }
                let tt = i as f64 / INPUT_RATE as f64;
                let env = (-tt * 30.0).exp();
                left[at + i] += (amp * env * (2.0 * std::f64::consts::PI * 60.0 * tt).sin()) as f32;
                // 敲击头上一点噪声样的高频。
                if i < 200 {
                    left[at + i] += (amp
                        * 0.4
                        * if (i * 7919) % 3 == 0 { 1.0 } else { -1.0 }
                        * (-tt * 400.0).exp()) as f32;
                }
            }
            k += 1;
            t += period;
        }
        for (i, v) in left.iter_mut().enumerate() {
            *v += 0.1
                * (2.0 * std::f64::consts::PI * 440.0 * i as f64 / INPUT_RATE as f64).sin() as f32;
        }
        StereoPcm {
            right: left.clone(),
            left,
        }
    }

    #[test]
    fn dsp_only_finds_tempo_and_drums() {
        let pcm = synthetic_song(20.0, 120.0);
        let mut sink = Collect {
            published: Vec::new(),
            progress: Vec::new(),
            warnings: Vec::new(),
        };
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
    }

    #[test]
    fn prior_model_results_survive_a_dsp_rerun() {
        let pcm = synthetic_song(10.0, 120.0);
        let mut sink = Collect {
            published: Vec::new(),
            progress: Vec::new(),
            warnings: Vec::new(),
        };
        let first = analyze(&pcm, &ModelPaths::default(), None, &mut sink).unwrap();
        let mut prior = first.clone();
        prior.flags = FLAG_BEATS_MODEL;
        prior.beats_ms = vec![1, 2, 3];
        prior.bpm = Some(99.0);
        let again = analyze(&pcm, &ModelPaths::default(), Some(prior), &mut sink).unwrap();
        assert_eq!(again.flags, FLAG_BEATS_MODEL);
        assert_eq!(again.beats_ms, vec![1, 2, 3]);
        assert_eq!(again.bpm, Some(99.0));
    }
}
