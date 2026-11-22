//! `ffc_mana_*`：整首歌的离线音频分析（全屏歌词动画的音频信号，folia `src/services/analysis/` 的对应物）。
//!
//! 产出（[format] 一种格式，DSP 与模型两条路一样）：≈86 Hz 包络（响度 / 低中高频段 / 起音 / 人声）、
//! 拍点 / 强拍 / BPM / 每小节拍数、鼓点（时间 / 强度 / 底鼓·军鼓·镲片）、人声起音。
//!
//! 引擎是**进程级单例**（与 [crate::upscale] 同型）：一个后台工作线程 + 一条 FIFO 队列（加急的插队），
//! Dart 只发粗粒度命令（配置模型 / 提交 / 取消），事件经一个回调回到 Dart（`NativeCallable.listener`），
//! 每一步做完把完整结果原子写到调用方给的路径（Dart 整份读进来按偏移切 TypedData，逐帧取值不跨 FFI）。
//! 解码不在这里：Dart 经统一 FFmpeg 后端把音轨解成 44.1 kHz 立体声 s16le 临时文件再提交（[pcm]）。
//!
//! 模型（Beat This! / htdemucs，[models]）是可选下载项：没配置时只跑 DSP 退路（[pipeline]）。

pub(crate) mod accents;
pub(crate) mod beats;
pub(crate) mod drums;
pub(crate) mod features;
pub(crate) mod fft;
pub(crate) mod format;
pub(crate) mod models;
pub(crate) mod pcm;
pub(crate) mod pipeline;
pub(crate) mod vocal;

use std::collections::VecDeque;
use std::ffi::{CStr, c_char};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};

use crate::{guard, hand_over_bytes, status};
use format::Analysis;
use pipeline::{ModelPaths, Sink};

use crate::upscale::runtime::Backend;

/// 事件回调：`(kind, token, value)`。
pub type ManaCallback = extern "C" fn(kind: i32, token: u64, value: u32);

/// 开始分析这首（出队）。
pub const EVENT_STARTED: i32 = 1;
/// 进度：`value = stage << 16 | permille`（stage 见 `pipeline::STAGE_*`）。
pub const EVENT_PROGRESS: i32 = 2;
/// 一步做完、结果文件已更新：`value = flags`。
pub const EVENT_UPDATED: i32 = 3;
/// 全部做完：`value = flags`（最后一次 UPDATED 之后发）。
pub const EVENT_DONE: i32 = 4;
/// 失败（读不了 PCM / 写不了结果）；详情 [ffc_mana_last_error]。
pub const EVENT_FAILED: i32 = 5;
/// 取消。
pub const EVENT_CANCELLED: i32 = 6;
/// 模型那一步失败了、结果留 DSP 的（之后照常 DONE）；详情 [ffc_mana_last_error]。
pub const EVENT_MODEL_FAILED: i32 = 7;
/// 加速执行器不行、这个模型改用 CPU（结果不受影响，只是慢）：`value` = 失败的执行器代码。
/// 每个进程每个模型每个执行器只发一次；原因在 [ffc_mana_last_error]。
pub const EVENT_BACKEND_FALLBACK: i32 = 8;

/// 提交标志：插到队头。
pub const SUBMIT_URGENT: u32 = 1;
/// 提交标志：做完（不论成败）删掉输入的 PCM 临时文件。
pub const SUBMIT_DELETE_INPUT: u32 = 2;
/// 提交标志：只跑 DSP（不用模型）。
pub const SUBMIT_DSP_ONLY: u32 = 4;

/// 原生返回码（本域）：ORT 接不上（模型被禁用，只剩 DSP）。
pub const STATUS_RUNTIME_UNAVAILABLE: i32 = -20;
/// 引擎没启动。
pub const STATUS_NOT_STARTED: i32 = -21;
/// 取消：令牌不在队列里也不在跑。
pub const STATUS_UNKNOWN_TOKEN: i32 = 1;

struct Job {
    token: u64,
    pcm: PathBuf,
    out: PathBuf,
    flags: u32,
}

#[derive(Default)]
struct State {
    callback: Option<ManaCallback>,
    queue: VecDeque<Job>,
    running: Option<(u64, Arc<AtomicBool>)>,
    models: ModelPaths,
    worker: bool,
    last_error: String,
}

struct Engine {
    state: Mutex<State>,
    wake: Condvar,
}

fn engine() -> &'static Engine {
    static ENGINE: OnceLock<Engine> = OnceLock::new();
    ENGINE.get_or_init(|| Engine {
        state: Mutex::new(State::default()),
        wake: Condvar::new(),
    })
}

fn lock() -> std::sync::MutexGuard<'static, State> {
    engine().state.lock().unwrap_or_else(|p| p.into_inner())
}

fn emit(kind: i32, token: u64, value: u32) {
    let cb = lock().callback;
    if let Some(cb) = cb {
        cb(kind, token, value);
    }
}

fn set_error(message: String) {
    lock().last_error = message;
}

/// 结果写文件 + 发事件的出口。
struct FileSink {
    token: u64,
    out: PathBuf,
    cancel: Arc<AtomicBool>,
    last_progress: (u32, u32),
}

impl Sink for FileSink {
    fn progress(&mut self, stage: u32, permille: u32) {
        // 同一步里进度至少走 1% 才发，免得 htdemucs 那一步之外刷屏。
        if stage == self.last_progress.0 && permille < self.last_progress.1 + 10 && permille != 1000
        {
            return;
        }
        self.last_progress = (stage, permille);
        emit(
            EVENT_PROGRESS,
            self.token,
            (stage << 16) | permille.min(1000),
        );
    }

    fn publish(&mut self, analysis: &Analysis) -> Result<(), String> {
        format::write_atomic(&self.out, &analysis.encode())
            .map_err(|e| format!("write {}: {e}", self.out.display()))?;
        emit(EVENT_UPDATED, self.token, analysis.flags);
        Ok(())
    }

    fn cancelled(&self) -> bool {
        self.cancel.load(Ordering::Relaxed)
    }

    fn warn(&mut self, message: String) {
        set_error(message);
        emit(EVENT_MODEL_FAILED, self.token, 0);
    }

    fn backend_fallback(&mut self, backend: Backend, message: String) {
        set_error(message);
        emit(EVENT_BACKEND_FALLBACK, self.token, backend as u32);
    }
}

/// 已有结果（只认同版本、同管线版本的）。
fn read_prior(out: &Path) -> Option<Analysis> {
    std::fs::read(out).ok().and_then(|b| Analysis::decode(&b))
}

/// 跑一个任务（工作线程与同步入口共用）。
fn run_job(job: &Job, models: &ModelPaths, sink: &mut dyn Sink) -> Result<Analysis, String> {
    let pcm =
        pcm::read_s16le_stereo(&job.pcm).map_err(|e| format!("read {}: {e}", job.pcm.display()))?;
    if pcm.len() == 0 {
        return Err("empty pcm".into());
    }
    let models = if job.flags & SUBMIT_DSP_ONLY != 0 {
        ModelPaths::default()
    } else {
        models.clone()
    };
    pipeline::analyze(&pcm, &models, read_prior(&job.out), sink)
}

fn worker_loop() {
    loop {
        let (job, cancel, models) = {
            let mut st = lock();
            loop {
                if let Some(job) = st.queue.pop_front() {
                    let cancel = Arc::new(AtomicBool::new(false));
                    st.running = Some((job.token, cancel.clone()));
                    let models = st.models.clone();
                    break (job, cancel, models);
                }
                st = engine().wake.wait(st).unwrap_or_else(|p| p.into_inner());
            }
        };
        emit(EVENT_STARTED, job.token, 0);
        let mut sink = FileSink {
            token: job.token,
            out: job.out.clone(),
            cancel: cancel.clone(),
            last_progress: (0, 0),
        };
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            run_job(&job, &models, &mut sink)
        }))
        .unwrap_or_else(|_| Err("panic".into()));
        if job.flags & SUBMIT_DELETE_INPUT != 0 {
            let _ = std::fs::remove_file(&job.pcm);
        }
        lock().running = None;
        match result {
            Ok(a) => emit(EVENT_DONE, job.token, a.flags),
            Err(_) if cancel.load(Ordering::Relaxed) => emit(EVENT_CANCELLED, job.token, 0),
            Err(e) => {
                set_error(e);
                emit(EVENT_FAILED, job.token, 0);
            }
        }
    }
}

unsafe fn opt_path(p: *const c_char) -> Option<PathBuf> {
    if p.is_null() {
        return None;
    }
    let s = CStr::from_ptr(p).to_str().ok()?;
    (!s.is_empty()).then(|| PathBuf::from(s))
}

#[no_mangle]
pub extern "C" fn ffc_mana_format_version() -> u32 {
    format::FORMAT_VERSION
}

#[no_mangle]
pub extern "C" fn ffc_mana_pipeline_version() -> u32 {
    format::PIPELINE_VERSION
}

/// 启动引擎（幂等；再调只换回调）。
#[no_mangle]
pub extern "C" fn ffc_mana_start(callback: Option<ManaCallback>) -> i32 {
    guard(|| {
        let Some(callback) = callback else {
            return status::NULL_ARGUMENT;
        };
        let mut st = lock();
        st.callback = Some(callback);
        if !st.worker {
            let spawned = std::thread::Builder::new()
                .name("fushi-music-analysis".into())
                .spawn(worker_loop);
            if spawned.is_err() {
                return status::IO_ERROR;
            }
            st.worker = true;
        }
        status::OK
    })
}

/// 配置模型（之后出队的任务生效）。两个模型都为空时不碰 ORT；否则先接上 ORT（`ort_path` 为空 = 从本进程
/// 符号找，Apple 静态链接），接不上返回 [STATUS_RUNTIME_UNAVAILABLE] 并清空模型（只剩 DSP）。
///
/// `backend` 与超分同一套代码（`ffc_upscale_backend_available`：0 CPU / 1 DirectML / 2 CoreML / 3 XNNPACK）：
/// 这份 ORT 里没有就静默用 CPU；有但建会话或跑模型失败就退回 CPU，发一次 [EVENT_BACKEND_FALLBACK]。
///
/// # Safety
/// 字符串参数为空或指向 NUL 结尾的 UTF-8。
#[no_mangle]
pub unsafe extern "C" fn ffc_mana_configure(
    ort_path: *const c_char,
    beat_this_model: *const c_char,
    htdemucs_model: *const c_char,
    threads: u32,
    backend: u32,
) -> i32 {
    guard(|| {
        let models = ModelPaths {
            beat_this: opt_path(beat_this_model),
            htdemucs: opt_path(htdemucs_model),
            threads: threads.max(1) as usize,
            backend: Backend::from_code(backend).unwrap_or(Backend::Cpu),
        };
        if models.beat_this.is_some() || models.htdemucs.is_some() {
            let ort = opt_path(ort_path);
            let ort = ort.as_deref().and_then(Path::to_str);
            if let Err(e) = crate::upscale::runtime::ensure_loaded(ort) {
                let mut st = lock();
                st.models = ModelPaths::default();
                st.last_error = e;
                return STATUS_RUNTIME_UNAVAILABLE;
            }
        }
        lock().models = models;
        status::OK
    })
}

/// 提交一首：`pcm_path` 是 44.1 kHz 立体声 s16le raw 文件，结果写到 `out_path`（已有结果里由模型算出的
/// 部分保留、只补缺的那一步）。之后必有一个带 `token` 的 DONE / FAILED / CANCELLED 事件。
///
/// # Safety
/// 两个路径非空、NUL 结尾 UTF-8。
#[no_mangle]
pub unsafe extern "C" fn ffc_mana_submit(
    token: u64,
    pcm_path: *const c_char,
    out_path: *const c_char,
    flags: u32,
) -> i32 {
    guard(|| {
        let (Some(pcm), Some(out)) = (opt_path(pcm_path), opt_path(out_path)) else {
            return status::NULL_ARGUMENT;
        };
        let mut st = lock();
        if !st.worker {
            return STATUS_NOT_STARTED;
        }
        let job = Job {
            token,
            pcm,
            out,
            flags,
        };
        if flags & SUBMIT_URGENT != 0 {
            st.queue.push_front(job);
        } else {
            st.queue.push_back(job);
        }
        engine().wake.notify_one();
        status::OK
    })
}

/// 取消：在队列里的直接拿掉（立即发 CANCELLED）；正在跑的置取消标志（在下一个检查点停，之后发
/// CANCELLED，已写出的阶段性结果留着）。不认识的令牌返回 [STATUS_UNKNOWN_TOKEN]。
#[no_mangle]
pub extern "C" fn ffc_mana_cancel(token: u64) -> i32 {
    guard(|| {
        let removed = {
            let mut st = lock();
            if let Some((t, flag)) = &st.running {
                if *t == token {
                    flag.store(true, Ordering::Relaxed);
                    return status::OK;
                }
            }
            let (dropped, kept): (Vec<Job>, Vec<Job>) =
                st.queue.drain(..).partition(|j| j.token == token);
            st.queue = kept.into();
            // 带删除标志的排队任务：顺手删掉它的 PCM（不会再有人用）。
            for j in dropped
                .iter()
                .filter(|j| j.flags & SUBMIT_DELETE_INPUT != 0)
            {
                let _ = std::fs::remove_file(&j.pcm);
            }
            !dropped.is_empty()
        };
        if removed {
            emit(EVENT_CANCELLED, token, 0);
            status::OK
        } else {
            STATUS_UNKNOWN_TOKEN
        }
    })
}

/// 同步分析（不进队列、不发事件；用当前模型配置）：无头服务端与测试用。返回 0 或负的状态码。
///
/// # Safety
/// 两个路径非空、NUL 结尾 UTF-8。
#[no_mangle]
pub unsafe extern "C" fn ffc_mana_analyze_file(
    pcm_path: *const c_char,
    out_path: *const c_char,
    flags: u32,
) -> i32 {
    guard(|| {
        let (Some(pcm), Some(out)) = (opt_path(pcm_path), opt_path(out_path)) else {
            return status::NULL_ARGUMENT;
        };
        struct Quiet {
            out: PathBuf,
        }
        impl Sink for Quiet {
            fn progress(&mut self, _: u32, _: u32) {}
            fn publish(&mut self, a: &Analysis) -> Result<(), String> {
                format::write_atomic(&self.out, &a.encode()).map_err(|e| e.to_string())
            }
            fn cancelled(&self) -> bool {
                false
            }
            fn warn(&mut self, message: String) {
                set_error(message);
            }
            fn backend_fallback(&mut self, _: Backend, message: String) {
                set_error(message);
            }
        }
        let models = lock().models.clone();
        let job = Job {
            token: 0,
            pcm,
            out: out.clone(),
            flags,
        };
        match run_job(&job, &models, &mut Quiet { out }) {
            Ok(_) => status::OK,
            Err(e) => {
                set_error(e);
                status::IO_ERROR
            }
        }
    })
}

/// 最近一次错误的 UTF-8 文本（Rust 分配，用 `ffc_free_bytes` 释放）。
///
/// # Safety
/// 两个出参非空且可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_mana_last_error(out_ptr: *mut *mut u8, out_len: *mut usize) -> i32 {
    guard(|| {
        if out_ptr.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        let text = lock().last_error.clone();
        hand_over_bytes(text.into_bytes(), out_ptr, out_len);
        status::OK
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    use std::sync::mpsc;

    static EVENTS: Mutex<Option<mpsc::Sender<(i32, u64, u32)>>> = Mutex::new(None);

    extern "C" fn on_event(kind: i32, token: u64, value: u32) {
        if let Some(tx) = EVENTS.lock().unwrap().as_ref() {
            let _ = tx.send((kind, token, value));
        }
    }

    fn write_pcm(path: &Path, pcm: &pcm::StereoPcm) {
        let mut bytes = Vec::with_capacity(pcm.len() * 4);
        for (l, r) in pcm.left.iter().zip(&pcm.right) {
            bytes.extend_from_slice(&((l.clamp(-1.0, 1.0) * 32767.0) as i16).to_le_bytes());
            bytes.extend_from_slice(&((r.clamp(-1.0, 1.0) * 32767.0) as i16).to_le_bytes());
        }
        std::fs::write(path, bytes).unwrap();
    }

    #[test]
    fn engine_runs_queue_and_reports_events() {
        let (tx, rx) = mpsc::channel();
        *EVENTS.lock().unwrap() = Some(tx);
        assert_eq!(ffc_mana_start(Some(on_event)), status::OK);
        let dir = std::env::temp_dir().join(format!("ffc_mana_test_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let pcm_path = dir.join("song.s16le");
        let out_path = dir.join("song.fma");
        write_pcm(&pcm_path, &pipeline::tests::synthetic_song(8.0, 120.0));
        let pcm_c = CString::new(pcm_path.to_str().unwrap()).unwrap();
        let out_c = CString::new(out_path.to_str().unwrap()).unwrap();
        unsafe {
            assert_eq!(
                ffc_mana_configure(std::ptr::null(), std::ptr::null(), std::ptr::null(), 1, 0),
                status::OK
            );
            assert_eq!(
                ffc_mana_submit(7, pcm_c.as_ptr(), out_c.as_ptr(), SUBMIT_DELETE_INPUT),
                status::OK
            );
        }
        let mut kinds = Vec::new();
        loop {
            let (kind, token, _) = rx.recv_timeout(std::time::Duration::from_secs(60)).unwrap();
            assert_eq!(token, 7);
            kinds.push(kind);
            if kind == EVENT_DONE || kind == EVENT_FAILED {
                break;
            }
        }
        assert_eq!(kinds.first(), Some(&EVENT_STARTED));
        assert!(kinds.contains(&EVENT_UPDATED));
        assert_eq!(kinds.last(), Some(&EVENT_DONE), "{kinds:?}");
        assert!(!pcm_path.exists(), "input deleted");
        let a = Analysis::decode(&std::fs::read(&out_path).unwrap()).unwrap();
        assert!(a.beats_ms.len() > 8);
        assert_eq!(ffc_mana_cancel(999), STATUS_UNKNOWN_TOKEN);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 真文件 + 模型的手动验证（不进 CI）：
    /// `FUSHI_MANA_PCM=<44.1k 立体声 s16le>`，可选 `FUSHI_MANA_ORT`（onnxruntime 动态库）、
    /// `FUSHI_MANA_BEAT_THIS` / `FUSHI_MANA_HTDEMUCS`（模型路径）。打印 BPM / 拍数 / 鼓点数与耗时。
    #[test]
    fn real_file_sanity() {
        let Ok(pcm) = std::env::var("FUSHI_MANA_PCM") else {
            return;
        };
        let models = ModelPaths {
            beat_this: std::env::var("FUSHI_MANA_BEAT_THIS")
                .ok()
                .map(PathBuf::from),
            htdemucs: std::env::var("FUSHI_MANA_HTDEMUCS").ok().map(PathBuf::from),
            threads: std::thread::available_parallelism()
                .map_or(4, |n| n.get() / 2)
                .max(1),
            // FUSHI_MANA_BACKEND = 0 CPU / 1 DirectML / 2 CoreML / 3 XNNPACK。
            backend: std::env::var("FUSHI_MANA_BACKEND")
                .ok()
                .and_then(|v| v.parse().ok())
                .and_then(Backend::from_code)
                .unwrap_or(Backend::Cpu),
        };
        if models.beat_this.is_some() || models.htdemucs.is_some() {
            let ort = std::env::var("FUSHI_MANA_ORT").ok();
            println!(
                "ort {:?}",
                crate::upscale::runtime::ensure_loaded(ort.as_deref())
            );
        }
        struct Print {
            t0: std::time::Instant,
            stage: u32,
            dsp_beats: Vec<i32>,
        }
        impl Sink for Print {
            fn progress(&mut self, stage: u32, permille: u32) {
                if stage != self.stage {
                    println!(
                        "[{:>6.2}s] stage {stage} start",
                        self.t0.elapsed().as_secs_f64()
                    );
                    self.stage = stage;
                }
                let _ = permille;
            }
            fn publish(&mut self, a: &Analysis) -> Result<(), String> {
                if a.flags & format::FLAG_BEATS_MODEL == 0 {
                    self.dsp_beats = a.beats_ms.clone();
                } else if !self.dsp_beats.is_empty() {
                    // DSP 退路对模型拍点的 F 值（±70 ms，MIREX 惯例）。
                    let hit = |xs: &[i32], ys: &[i32]| {
                        xs.iter()
                            .filter(|x| ys.iter().any(|y| (*x - y).abs() <= 70))
                            .count()
                    };
                    let p = hit(&self.dsp_beats, &a.beats_ms) as f64 / self.dsp_beats.len() as f64;
                    let r =
                        hit(&a.beats_ms, &self.dsp_beats) as f64 / a.beats_ms.len().max(1) as f64;
                    println!(
                        "DSP vs model beats: precision {p:.3} recall {r:.3} F {:.3}",
                        2.0 * p * r / (p + r).max(1e-9)
                    );
                }
                let iv: Vec<i32> = a.beats_ms.windows(2).map(|w| w[1] - w[0]).collect();
                println!(
                    "[{:>6.2}s] flags {:#06b} bpm {:?} meter {} beats {} downbeats {} hits {} (kick {} snare {} hat {}) vocal_onsets {} frames {} \
                     mean power {:.3} low {:.3} mid {:.3} high {:.3} vocal {:.3} | first beats {:?} | first downbeats {:?} | beat interval min {:?} max {:?}",
                    self.t0.elapsed().as_secs_f64(),
                    a.flags,
                    a.bpm,
                    a.beats_per_bar,
                    a.beats_ms.len(),
                    a.downbeats_ms.len(),
                    a.hits_ms.len(),
                    a.hit_kind.iter().filter(|k| **k == 0).count(),
                    a.hit_kind.iter().filter(|k| **k == 1).count(),
                    a.hit_kind.iter().filter(|k| **k == 2).count(),
                    a.vocal_onsets_ms.len(),
                    a.frames(),
                    a.power.iter().sum::<f32>() / a.frames() as f32,
                    a.low.iter().sum::<f32>() / a.frames() as f32,
                    a.mid.iter().sum::<f32>() / a.frames() as f32,
                    a.high.iter().sum::<f32>() / a.frames() as f32,
                    a.vocal.iter().sum::<f32>() / a.frames() as f32,
                    &a.beats_ms[..a.beats_ms.len().min(8)],
                    &a.downbeats_ms[..a.downbeats_ms.len().min(4)],
                    iv.iter().min(),
                    iv.iter().max(),
                );
                let acc = &a.accents;
                println!(
                    "           accents: track_scale {:.3} mean impact {:.3} rhythmic {}/{} pulse {}/{} | stems_until {} ms partial {}",
                    acc.track_scale,
                    acc.impact.iter().sum::<f32>() / acc.impact.len().max(1) as f32,
                    acc.rhythmic.iter().filter(|r| **r).count(),
                    acc.rhythmic.len(),
                    acc.pulse.iter().filter(|r| **r).count(),
                    acc.pulse.len(),
                    a.stems_until_ms,
                    a.flags & format::FLAG_STEMS_PARTIAL != 0,
                );
                if let Ok(out) = std::env::var("FUSHI_MANA_OUT") {
                    format::write_atomic(Path::new(&out), &a.encode())
                        .map_err(|e| e.to_string())?;
                }
                Ok(())
            }
            fn cancelled(&self) -> bool {
                false
            }
            fn warn(&mut self, message: String) {
                println!("WARN {message}");
            }
            fn backend_fallback(&mut self, backend: Backend, message: String) {
                println!("FALLBACK {backend:?}: {message}");
            }
        }
        let job = Job {
            token: 0,
            pcm: PathBuf::from(pcm),
            out: std::env::temp_dir().join("ffc_mana_real_file_sanity.fma"),
            flags: 0,
        };
        let _ = std::fs::remove_file(&job.out);
        let mut sink = Print {
            t0: std::time::Instant::now(),
            stage: 0,
            dsp_beats: Vec::new(),
        };
        run_job(&job, &models, &mut sink).unwrap();
    }
}
