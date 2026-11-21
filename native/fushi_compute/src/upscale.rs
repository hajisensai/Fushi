//! 漫画页超分引擎（设计文档 `docs/specs/2026-11-20-manga-upscale-design.md` §4）。
//!
//! Rust 持有全部状态：ORT 运行时、按档加载的模型会话、按「离当前页多远」排序的任务队列（含往后预取）、
//! 磁盘 LRU 缓存、一个后台工作线程。Dart 只发粗粒度命令（启动 / 配置档位 / 提交一页 / 换当前页 /
//! 清队列 / 查缓存）并经一个回调收事件（`NativeCallable.listener`，任意线程可调），不存镜像状态。
//!
//! 事件：`callback(kind, token)`，kind 见 [EVENT_DONE] 等；`token` 是提交时调用方给的值。

mod cache;
mod pipeline;
mod queue;
mod runtime;
mod tile;

use std::collections::HashMap;
use std::ffi::{CStr, c_char};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::thread;

use crate::{guard, hand_over_bytes, status};
use cache::DiskCache;
use pipeline::{Nets, Outcome, Tier};
use queue::{Job, Queue};
use runtime::{Backend, OnnxSr};
use tile::{SrNet, TileSpec};

/// 事件：这页超分完成，结果已在缓存里（[ffc_upscale_cached_path] 取路径）。
pub const EVENT_DONE: i32 = 1;
/// 事件：这页不做（轻量档没有文字框、太大），调用方继续用画质缩放。
pub const EVENT_SKIPPED: i32 = 2;
/// 事件：这页失败（坏图 / 推理出错）。
pub const EVENT_FAILED: i32 = 3;
/// 事件：任务被丢弃（翻走了、被同键任务替换、清队列）。
pub const EVENT_CANCELLED: i32 = 4;
/// 事件：模型加载失败（配置的档位不可用，token = 0）。
pub const EVENT_MODELS_FAILED: i32 = 5;

/// 返回码：ORT 运行时接不上（库不在 / 版本太旧）。
pub const UPSCALE_RUNTIME_UNAVAILABLE: i32 = -20;
/// 返回码：引擎还没 [ffc_upscale_start] / 没配置档位。
pub const UPSCALE_NOT_READY: i32 = -21;
/// 返回码：缓存里没有。
pub const UPSCALE_NOT_CACHED: i32 = -22;
/// 返回码：这个后端跑不了这一档（[tier_supported]）。
pub const UPSCALE_UNSUPPORTED: i32 = -23;
/// [ffc_upscale_submit] 的返回值：缓存里已经有了，不入队（也不发事件）。
pub const UPSCALE_ALREADY_CACHED: i32 = 1;
/// [ffc_upscale_submit] 的返回值：同键任务正在算，不重复入队（事件带的是先前那次提交的令牌）。
pub const UPSCALE_IN_PROGRESS: i32 = 2;
/// [ffc_upscale_submit] 的返回值：这个键本配置下已判过不做 / 失败过，不重复入队（也不发事件）。
pub const UPSCALE_SETTLED: i32 = 3;

/// [ffc_upscale_query]：引擎对这个键一无所知（该提交）。
pub const QUERY_UNKNOWN: i32 = 0;
/// [ffc_upscale_query]：结果在缓存里。
pub const QUERY_CACHED: i32 = 1;
/// [ffc_upscale_query]：在队列里或正在算。
pub const QUERY_PENDING: i32 = 2;
/// [ffc_upscale_query]：本配置下判过不做（继续用画质缩放）。
pub const QUERY_SKIPPED: i32 = 3;
/// [ffc_upscale_query]：本配置下失败过（不自动重试，换配置后清零）。
pub const QUERY_FAILED: i32 = 4;

/// 「判过不做 / 失败过」最多记多少个键（超了整表清空，最坏是重算一遍）。
const SETTLED_LIMIT: usize = 4096;

/// 一次最多接受的文字框（与 `FIT_HQ_MAX_TEXT_BOXES` 一致）。
pub const UPSCALE_MAX_TEXT_BOXES: usize = 4096;

/// 各模型的分块参数（设计文档 §4.2 实测：swin 块 384 / 上下文 64 交界无台阶；ArtCNN 感受野小，
/// 上下文 8 起与整张推理逐像素一致）。
const SWIN_SPEC: TileSpec = TileSpec { tile: 384, ctx: 64 };
const SWIN_ALIGN: usize = 64;
const ARTCNN_SPEC: TileSpec = TileSpec { tile: 512, ctx: 16 };
const ARTCNN_ALIGN: usize = 1;

type Callback = extern "C" fn(i32, u64);

/// 这一档在这个后端上能不能跑（设计文档 §4.2 实测）：
/// - 轻量档（ArtCNN）各后端都行；
/// - 高质量档（swin_unet）只在 DirectML 上：CPU 一页 50～90 秒不可用；CoreML（ORT 1.23，MLProgram）建
///   swin 会话报「Failed to build the model execution plan … error code: -14」（各 compute units 都一样），
///   NeuralNetwork 格式则段错误；XNNPACK / 安卓未实测。
fn tier_supported(tier: Tier, backend: Backend) -> bool {
    match tier {
        Tier::Light => true,
        Tier::High => backend == Backend::DirectMl,
    }
}

#[derive(Clone, PartialEq, Eq)]
struct Config {
    tier: Tier,
    backend: Backend,
    inside: Option<PathBuf>,
    outside: PathBuf,
}

struct State {
    queue: Queue,
    cache: Option<DiskCache>,
    callback: Option<Callback>,
    config: Option<Config>,
    /// 配置变了，工作线程下一个任务前重载模型。
    generation: u64,
    /// 工作线程正在算的键。
    running: Option<String>,
    /// 本配置下判过不做（[QUERY_SKIPPED]）/ 失败过（[QUERY_FAILED]）的键；换配置清空。
    settled: HashMap<String, i32>,
}

impl State {
    fn new() -> Self {
        Self {
            queue: Queue::new(),
            cache: None,
            callback: None,
            config: None,
            generation: 0,
            running: None,
            settled: HashMap::new(),
        }
    }

    /// 引擎对 `key` 的认知（[QUERY_UNKNOWN] 等）；没启动 / 没配置返回 [UPSCALE_NOT_READY]。
    fn query(&self, key: &str) -> i32 {
        if self.config.is_none() || self.cache.is_none() {
            return UPSCALE_NOT_READY;
        }
        if self.cache.as_ref().is_some_and(|c| c.contains(key)) {
            return QUERY_CACHED;
        }
        if self.running.as_deref() == Some(key) || self.queue.contains(key) {
            return QUERY_PENDING;
        }
        self.settled.get(key).copied().unwrap_or(QUERY_UNKNOWN)
    }

    fn settle(&mut self, key: String, outcome: i32) {
        if self.settled.len() >= SETTLED_LIMIT {
            self.settled.clear();
        }
        self.settled.insert(key, outcome);
    }
}

struct Engine {
    state: Mutex<State>,
    wake: Condvar,
}

static ENGINE: OnceLock<Arc<Engine>> = OnceLock::new();

fn engine() -> &'static Arc<Engine> {
    ENGINE.get_or_init(|| {
        let engine = Arc::new(Engine {
            state: Mutex::new(State::new()),
            wake: Condvar::new(),
        });
        let worker = Arc::clone(&engine);
        thread::Builder::new()
            .name("fushi-upscale".into())
            .spawn(move || worker_loop(&worker))
            .expect("spawn upscale worker");
        engine
    })
}

fn emit(callback: Option<Callback>, kind: i32, token: u64) {
    if let Some(cb) = callback {
        cb(kind, token);
    }
}

fn emit_all(callback: Option<Callback>, kind: i32, tokens: Vec<u64>) {
    for t in tokens {
        emit(callback, kind, t);
    }
}

fn cpu_threads() -> usize {
    thread::available_parallelism()
        .map(|n| (n.get() / 2).clamp(1, 6))
        .unwrap_or(2)
}

fn load_nets(config: &Config) -> Result<Nets, String> {
    let threads = cpu_threads();
    let load = |path: &Path,
                align: usize,
                spec: TileSpec|
     -> Result<(Box<dyn SrNet + Send>, TileSpec), String> {
        let calib = spec.tile + 2 * spec.ctx + 64;
        let net = OnnxSr::load(path, config.backend, align, calib, threads)?;
        Ok((Box::new(net), spec))
    };
    match config.tier {
        Tier::Light => Ok(Nets {
            tier: Tier::Light,
            inside: None,
            outside: load(&config.outside, ARTCNN_ALIGN, ARTCNN_SPEC)?,
        }),
        Tier::High => {
            let inside = config
                .inside
                .as_deref()
                .ok_or("high tier needs the text model")?;
            Ok(Nets {
                tier: Tier::High,
                inside: Some(load(inside, SWIN_ALIGN, SWIN_SPEC)?),
                outside: load(&config.outside, SWIN_ALIGN, SWIN_SPEC)?,
            })
        }
    }
}

fn worker_loop(engine: &Engine) {
    let mut nets: Option<(u64, Nets)> = None;
    loop {
        let (job, config, generation, callback) = {
            let mut state = engine.state.lock().unwrap_or_else(|e| e.into_inner());
            loop {
                if state.config.is_some() && state.cache.is_some() {
                    if let Some(job) = state.queue.pop() {
                        state.running = Some(job.key.clone());
                        break (
                            job,
                            state.config.clone().unwrap(),
                            state.generation,
                            state.callback,
                        );
                    }
                }
                state = engine.wake.wait(state).unwrap_or_else(|e| e.into_inner());
            }
        };
        if nets.as_ref().map(|n| n.0) != Some(generation) {
            nets = None;
            let loaded =
                std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| load_nets(&config)))
                    .unwrap_or_else(|p| Err(format!("panic: {}", panic_message(p.as_ref()))));
            match loaded {
                Ok(loaded) => nets = Some((generation, loaded)),
                Err(e) => {
                    log_error(&format!("load models: {e}"));
                    emit(callback, EVENT_MODELS_FAILED, 0);
                    emit(callback, EVENT_FAILED, job.token);
                    // 同一配置不反复重载：清掉队列，等调用方换配置。
                    let dropped = {
                        let mut state = engine.state.lock().unwrap_or_else(|e| e.into_inner());
                        state.running = None;
                        state.queue.clear()
                    };
                    emit_all(callback, EVENT_CANCELLED, dropped);
                    continue;
                }
            }
        }
        let (_, loaded) = nets.as_mut().expect("nets loaded");
        // 一页出 panic 不能带走工作线程（之后所有页都不会再做）：按这页失败处理、记下原因。
        let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            pipeline::process(&job.data, &job.boxes, loaded)
        }))
        .unwrap_or_else(|p| Err(format!("panic: {}", panic_message(p.as_ref()))));
        let mut state = engine.state.lock().unwrap_or_else(|e| e.into_inner());
        let kind = match outcome {
            Ok(Outcome::Done(jpeg)) => match state.cache.as_mut().map(|c| c.put(&job.key, &jpeg)) {
                Some(Ok(_)) => EVENT_DONE,
                Some(Err(e)) => {
                    log_error(&format!("cache write: {e}"));
                    EVENT_FAILED
                }
                None => EVENT_FAILED,
            },
            Ok(Outcome::Skipped) => EVENT_SKIPPED,
            Err(e) => {
                log_error(&format!("page {}: {e}", job.page));
                EVENT_FAILED
            }
        };
        state.running = None;
        // 配置在算的过程中变了：结论属于旧配置，不记。
        if state.generation == generation {
            match kind {
                EVENT_SKIPPED => state.settle(job.key, QUERY_SKIPPED),
                EVENT_FAILED => state.settle(job.key, QUERY_FAILED),
                _ => {}
            }
        }
        let callback = state.callback;
        drop(state);
        emit(callback, kind, job.token);
    }
}

/// 最近一条错误（[ffc_upscale_last_error] 取走）：引擎在原生线程里出错时 Dart 收到的只是事件码，原因靠它进
/// app 的错误日志（stderr 在发布版里没人看得到）。
static LAST_ERROR: Mutex<Option<String>> = Mutex::new(None);

fn log_error(message: &str) {
    eprintln!("[fushi_upscale] {message}");
    *LAST_ERROR.lock().unwrap_or_else(|e| e.into_inner()) = Some(message.to_string());
}

fn panic_message(payload: &(dyn std::any::Any + Send)) -> String {
    payload
        .downcast_ref::<&str>()
        .map(|s| s.to_string())
        .or_else(|| payload.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "panic".into())
}

unsafe fn opt_str<'a>(p: *const c_char) -> Result<Option<&'a str>, i32> {
    if p.is_null() {
        return Ok(None);
    }
    CStr::from_ptr(p)
        .to_str()
        .map(Some)
        .map_err(|_| status::INVALID_ARGUMENT)
}

/// 启动（或更新）引擎：接上 ORT（`ort_path` 为空 = 从本进程符号找，只在 Apple 上可用），打开缓存目录
/// （`cache_bytes` 上限），登记事件回调。可重复调用；ORT 只接第一次。
///
/// # Safety
/// 字符串为 NUL 结尾 UTF-8；`callback` 在引擎存活期间一直可调（`NativeCallable.listener`）。
#[no_mangle]
pub unsafe extern "C" fn ffc_upscale_start(
    ort_path: *const c_char,
    cache_dir: *const c_char,
    cache_bytes: u64,
    callback: Option<Callback>,
) -> i32 {
    guard(|| {
        let Ok(ort_path) = opt_str(ort_path) else {
            return status::INVALID_ARGUMENT;
        };
        let Ok(Some(cache_dir)) = opt_str(cache_dir) else {
            return status::NULL_ARGUMENT;
        };
        if let Err(e) = runtime::ensure_loaded(ort_path) {
            log_error(&e);
            return UPSCALE_RUNTIME_UNAVAILABLE;
        }
        let engine = engine();
        let mut state = engine.state.lock().unwrap_or_else(|e| e.into_inner());
        match state.cache.as_mut() {
            Some(cache) => cache.set_limit(cache_bytes),
            None => match DiskCache::open(Path::new(cache_dir), cache_bytes) {
                Ok(c) => state.cache = Some(c),
                Err(e) => {
                    log_error(&format!("cache dir: {e}"));
                    return status::BAD_INPUT;
                }
            },
        }
        state.callback = callback;
        engine.wake.notify_all();
        status::OK
    })
}

/// 本进程的 ORT 能不能用这个后端（0 CPU / 1 DirectML / 2 CoreML / 3 XNNPACK）。1 = 能，0 = 不能
/// （含 ORT 还没接上）。
#[no_mangle]
pub extern "C" fn ffc_upscale_backend_available(backend: u32) -> i32 {
    guard(|| match Backend::from_code(backend) {
        Some(b) => runtime::backend_available(b) as i32,
        None => 0,
    })
}

/// 这一档（1 轻量 / 2 高质量）在这个后端（0 CPU / 1 DirectML / 2 CoreML / 3 XNNPACK）上能不能跑：1 能，0 不能
/// （[tier_supported]）。调用方据此在下载模型之前就决定降档。
#[no_mangle]
pub extern "C" fn ffc_upscale_tier_supported(tier: u32, backend: u32) -> i32 {
    guard(
        || match (Tier::from_code(tier), Backend::from_code(backend)) {
            (Some(t), Some(b)) => tier_supported(t, b) as i32,
            _ => 0,
        },
    )
}

/// 配置档位（1 轻量 / 2 高质量）、后端与模型文件：轻量档 `outside` = ArtCNN C4F32，`inside` 为空；
/// 高质量档 `inside` = swin_unet art scale2x，`outside` = swin_unet art noise1_scale2x。配置变了才重载
/// 模型（在工作线程里、下一页之前）。
///
/// # Safety
/// 字符串为 NUL 结尾 UTF-8。
#[no_mangle]
pub unsafe extern "C" fn ffc_upscale_configure(
    tier: u32,
    backend: u32,
    inside_model: *const c_char,
    outside_model: *const c_char,
) -> i32 {
    guard(|| {
        let (Some(tier), Some(backend)) = (Tier::from_code(tier), Backend::from_code(backend))
        else {
            return status::INVALID_ARGUMENT;
        };
        let (Ok(inside), Ok(Some(outside))) = (opt_str(inside_model), opt_str(outside_model))
        else {
            return status::NULL_ARGUMENT;
        };
        if tier == Tier::High && inside.is_none() {
            return status::NULL_ARGUMENT;
        }
        if !tier_supported(tier, backend) {
            return UPSCALE_UNSUPPORTED;
        }
        let config = Config {
            tier,
            backend,
            inside: inside.map(PathBuf::from),
            outside: PathBuf::from(outside),
        };
        let engine = engine();
        let mut state = engine.state.lock().unwrap_or_else(|e| e.into_inner());
        if state.config.as_ref() != Some(&config) {
            state.config = Some(config);
            state.generation += 1;
            state.settled.clear();
        }
        engine.wake.notify_all();
        status::OK
    })
}

/// 提交一页：`key` 是缓存键（调用方保证含页身份、档位、文字框签名、模型版本），`page` 用于排优先级，
/// `data` 是原图字节（复制进队列），`boxes` 是 `box_count` 个归一化 `[x0, y0, x1, y1]`。缓存里已有返回
/// [UPSCALE_ALREADY_CACHED]（不入队、不发事件）；否则入队返回 OK，之后必有一个事件带回 `token`。
///
/// # Safety
/// 指针按给定长度可读；`key` 为 NUL 结尾 UTF-8。
#[no_mangle]
pub unsafe extern "C" fn ffc_upscale_submit(
    token: u64,
    key: *const c_char,
    page: i32,
    data: *const u8,
    len: usize,
    boxes: *const f32,
    box_count: usize,
) -> i32 {
    guard(|| {
        let Ok(Some(key)) = opt_str(key) else {
            return status::NULL_ARGUMENT;
        };
        if data.is_null() || len == 0 || (box_count > 0 && boxes.is_null()) {
            return status::NULL_ARGUMENT;
        }
        if box_count > UPSCALE_MAX_TEXT_BOXES {
            return status::INVALID_ARGUMENT;
        }
        let engine = engine();
        let mut state = engine.state.lock().unwrap_or_else(|e| e.into_inner());
        match state.query(key) {
            UPSCALE_NOT_READY => return UPSCALE_NOT_READY,
            QUERY_CACHED => return UPSCALE_ALREADY_CACHED,
            QUERY_SKIPPED | QUERY_FAILED => return UPSCALE_SETTLED,
            QUERY_PENDING if state.running.as_deref() == Some(key) => return UPSCALE_IN_PROGRESS,
            _ => {}
        }
        let boxes: Vec<[f32; 4]> = if box_count == 0 {
            Vec::new()
        } else {
            std::slice::from_raw_parts(boxes, box_count * 4)
                .chunks_exact(4)
                .map(|b| [b[0], b[1], b[2], b[3]])
                .collect()
        };
        let job = Job {
            token,
            key: key.to_string(),
            page,
            data: std::slice::from_raw_parts(data, len).to_vec(),
            boxes,
        };
        let dropped = state.queue.push(job);
        let callback = state.callback;
        drop(state);
        engine.wake.notify_all();
        emit_all(callback, EVENT_CANCELLED, dropped);
        status::OK
    })
}

/// 引擎对一个缓存键的认知：[QUERY_UNKNOWN] / [QUERY_CACHED] / [QUERY_PENDING] / [QUERY_SKIPPED] /
/// [QUERY_FAILED]；没启动 / 没配置返回 [UPSCALE_NOT_READY]。调用方据此决定要不要读原图来提交。
///
/// # Safety
/// `key` 为 NUL 结尾 UTF-8。
#[no_mangle]
pub unsafe extern "C" fn ffc_upscale_query(key: *const c_char) -> i32 {
    guard(|| {
        let Ok(Some(key)) = opt_str(key) else {
            return status::NULL_ARGUMENT;
        };
        engine()
            .state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .query(key)
    })
}

/// 换当前页（`window` = 往后预取几页），窗口外的任务丢弃（发 [EVENT_CANCELLED]）。
#[no_mangle]
pub extern "C" fn ffc_upscale_focus(page: i32, window: u32) -> i32 {
    guard(|| {
        let engine = engine();
        let mut state = engine.state.lock().unwrap_or_else(|e| e.into_inner());
        let dropped = state.queue.set_focus(page, window.min(64) as i32);
        let callback = state.callback;
        drop(state);
        emit_all(callback, EVENT_CANCELLED, dropped);
        status::OK
    })
}

/// 清空队列（换书 / 关阅读器 / 关掉超分），被丢的任务发 [EVENT_CANCELLED]。
#[no_mangle]
pub extern "C" fn ffc_upscale_clear() -> i32 {
    guard(|| {
        let engine = engine();
        let mut state = engine.state.lock().unwrap_or_else(|e| e.into_inner());
        let dropped = state.queue.clear();
        let callback = state.callback;
        drop(state);
        emit_all(callback, EVENT_CANCELLED, dropped);
        status::OK
    })
}

/// 取走最近一条错误（UTF-8，[crate::ffc_free_bytes] 释放）；没有返回 [UPSCALE_NOT_CACHED]。
///
/// # Safety
/// 输出指针可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_upscale_last_error(out_ptr: *mut *mut u8, out_len: *mut usize) -> i32 {
    guard(|| {
        if out_ptr.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        match LAST_ERROR.lock().unwrap_or_else(|e| e.into_inner()).take() {
            Some(message) => {
                hand_over_bytes(message.into_bytes(), out_ptr, out_len);
                status::OK
            }
            None => UPSCALE_NOT_CACHED,
        }
    })
}

/// 缓存命中时把结果文件路径（UTF-8）交给调用方（[crate::ffc_free_bytes] 释放），并刷新为最近使用。
///
/// # Safety
/// `key` 为 NUL 结尾 UTF-8；输出指针可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_upscale_cached_path(
    key: *const c_char,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        let Ok(Some(key)) = opt_str(key) else {
            return status::NULL_ARGUMENT;
        };
        if out_ptr.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        let engine = engine();
        let mut state = engine.state.lock().unwrap_or_else(|e| e.into_inner());
        let Some(cache) = state.cache.as_mut() else {
            return UPSCALE_NOT_READY;
        };
        match cache.get(key) {
            Some(path) => {
                hand_over_bytes(
                    path.to_string_lossy().into_owned().into_bytes(),
                    out_ptr,
                    out_len,
                );
                status::OK
            }
            None => UPSCALE_NOT_CACHED,
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    /// 真模型测试的素材（不入库）：`FUSHI_UPSCALE_ORT` = onnxruntime 动态库路径，`FUSHI_UPSCALE_MODELS` =
    /// 含 `swin_unet_art_scale2x.onnx` / `swin_unet_art_noise1_scale2x.onnx` / `ArtCNN_C4F32.onnx` 的目录，
    /// `FUSHI_UPSCALE_PAGE` = 一张低清漫画页。缺任何一个就跳过（CI 没有）。
    fn real_env() -> Option<(String, PathBuf, PathBuf)> {
        let ort = std::env::var("FUSHI_UPSCALE_ORT").ok()?;
        let models = PathBuf::from(std::env::var("FUSHI_UPSCALE_MODELS").ok()?);
        let page = PathBuf::from(std::env::var("FUSHI_UPSCALE_PAGE").ok()?);
        Some((ort, models, page))
    }

    fn real_ort(ort: &str) {
        let path = if ort == "self" { None } else { Some(ort) };
        runtime::ensure_loaded(path).expect("load onnxruntime");
    }

    fn gray(page: &Path, w: usize, h: usize) -> Vec<u8> {
        let img = image::open(page).unwrap().into_luma8();
        let (iw, ih) = (img.width() as usize, img.height() as usize);
        let (w, h) = (w.min(iw), h.min(ih));
        (0..h)
            .flat_map(|y| (0..w).map(move |x| (y, x)))
            .map(|(y, x)| img.get_pixel(x as u32, y as u32)[0])
            .collect()
    }

    fn load(models: &Path, file: &str, backend: Backend, align: usize, spec: TileSpec) -> OnnxSr {
        OnnxSr::load(
            &models.join(file),
            backend,
            align,
            spec.tile + 2 * spec.ctx + 64,
            cpu_threads(),
        )
        .expect("load model")
    }

    /// 交界一像素跳变（相对参照）与非交界列的比值；> 2 就是看得见的接缝。
    fn seam_ratio(out: &[f32], reference: &[f32], h2: usize, w2: usize, step: usize) -> f32 {
        let jump = |k: usize| -> f32 {
            (0..h2)
                .map(|y| {
                    ((out[y * w2 + k] - out[y * w2 + k - 1])
                        - (reference[y * w2 + k] - reference[y * w2 + k - 1]))
                        .abs()
                })
                .sum::<f32>()
                / h2 as f32
        };
        let seams: Vec<f32> = (step..w2).step_by(step).map(jump).collect();
        let ctrl: Vec<f32> = (step / 2..w2).step_by(step).map(jump).collect();
        (seams.iter().sum::<f32>() / seams.len() as f32)
            / (ctrl.iter().sum::<f32>() / ctrl.len() as f32).max(1e-6)
    }

    /// 真模型接缝回归：swin 按引擎的分块参数切块的结果，与整张一块推理比，交界处没有台阶。
    #[test]
    #[ignore = "needs FUSHI_UPSCALE_ORT / FUSHI_UPSCALE_MODELS / FUSHI_UPSCALE_PAGE"]
    fn real_model_swin_tiles_have_no_visible_seams() {
        let Some((ort, models, page)) = real_env() else {
            return;
        };
        real_ort(&ort);
        let (w, h) = (640usize, 768usize);
        let px = gray(&page, w, h);
        let input: Vec<f32> = px.iter().flat_map(|v| [*v as f32 / 255.0; 1]).collect();
        let rgb = [input.as_slice(), input.as_slice(), input.as_slice()].concat();
        let backend = env_backend().unwrap_or(Backend::Cpu);
        for file in [
            "swin_unet_art_noise1_scale2x.onnx",
            "swin_unet_art_scale2x.onnx",
        ] {
            let whole_spec = TileSpec { tile: 1024, ctx: 0 };
            let mut whole = load(&models, file, backend, SWIN_ALIGN, whole_spec);
            let reference = tile::upscale_tiled(&mut whole, &rgb, h, w, whole_spec, None).unwrap();
            let mut net = load(&models, file, backend, SWIN_ALIGN, SWIN_SPEC);
            let tiled = tile::upscale_tiled(&mut net, &rgb, h, w, SWIN_SPEC, None).unwrap();
            let n = 4 * w * h;
            let ratio = seam_ratio(
                &tiled[..n],
                &reference[..n],
                2 * h,
                2 * w,
                2 * SWIN_SPEC.tile,
            );
            eprintln!("{file}: seam/control jump ratio {ratio:.2}");
            assert!(ratio < 2.0, "{file}: visible seam, ratio {ratio}");
        }
    }

    /// DirectML 与 CPU 输出一致（模型已离线改写掉 DML 上会全零的负 Pad，设计文档 §4.2）。
    #[test]
    #[ignore = "needs FUSHI_UPSCALE_ORT (Windows: DirectML core) / FUSHI_UPSCALE_MODELS / FUSHI_UPSCALE_PAGE"]
    fn real_model_accelerated_backend_matches_cpu() {
        let Some((ort, models, page)) = real_env() else {
            return;
        };
        real_ort(&ort);
        let accel = env_backend().unwrap_or(if cfg!(windows) {
            Backend::DirectMl
        } else if cfg!(any(target_os = "macos", target_os = "ios")) {
            Backend::CoreMl
        } else {
            Backend::Xnnpack
        });
        if !runtime::backend_available(accel) {
            eprintln!("{accel:?} not available in this onnxruntime; skipped");
            return;
        }
        let (w, h) = (384usize, 384usize);
        let px = gray(&page, w, h);
        let swin = tier_supported(Tier::High, accel);
        for (file, align, spec) in [
            ("swin_unet_art_scale2x.onnx", SWIN_ALIGN, SWIN_SPEC),
            ("swin_unet_art_noise1_scale2x.onnx", SWIN_ALIGN, SWIN_SPEC),
            ("ArtCNN_C4F32.onnx", ARTCNN_ALIGN, ARTCNN_SPEC),
        ]
        .into_iter()
        .filter(|(file, _, _)| swin || !file.starts_with("swin"))
        {
            let mut cpu: Box<dyn SrNet + Send> =
                Box::new(load(&models, file, Backend::Cpu, align, spec));
            let mut fast: Box<dyn SrNet + Send> = Box::new(load(&models, file, accel, align, spec));
            let a = pipeline_one(&mut cpu, spec, &px, w, h);
            let b = pipeline_one(&mut fast, spec, &px, w, h);
            let max = a
                .iter()
                .zip(&b)
                .map(|(x, y)| (*x as i32 - *y as i32).abs())
                .max()
                .unwrap();
            let mean = a
                .iter()
                .zip(&b)
                .map(|(x, y)| (*x as i32 - *y as i32).abs() as f64)
                .sum::<f64>()
                / a.len() as f64;
            eprintln!("{file}: {accel:?} vs CPU max {max} mean {mean:.4}");
            assert!(
                mean < 0.05 && max <= 8,
                "{file}: {accel:?} diverges from CPU (max {max}, mean {mean})"
            );
            assert!(
                b.iter().any(|v| *v > 0),
                "{file}: {accel:?} produced an all-black image"
            );
        }
    }

    /// `FUSHI_UPSCALE_BACKEND` = cpu / dml / coreml / xnnpack。
    fn env_backend() -> Option<Backend> {
        match std::env::var("FUSHI_UPSCALE_BACKEND").ok()?.as_str() {
            "cpu" => Some(Backend::Cpu),
            "dml" => Some(Backend::DirectMl),
            "coreml" => Some(Backend::CoreMl),
            "xnnpack" => Some(Backend::Xnnpack),
            _ => None,
        }
    }

    fn pipeline_one(
        net: &mut Box<dyn SrNet + Send>,
        spec: TileSpec,
        px: &[u8],
        w: usize,
        h: usize,
    ) -> Vec<u8> {
        let input: Vec<f32> = px.iter().map(|v| *v as f32 / 255.0).collect();
        let planes = if net.channels() == 3 {
            [input.as_slice(), input.as_slice(), input.as_slice()].concat()
        } else {
            input
        };
        let out = tile::upscale_tiled(net.as_mut(), &planes, h, w, spec, None).unwrap();
        out[..4 * w * h]
            .iter()
            .map(|v| (v * 255.0).round().clamp(0.0, 255.0) as u8)
            .collect()
    }

    /// 单页耗时（各平台实测用）：`FUSHI_UPSCALE_BACKEND` = cpu / dml / coreml / xnnpack。打印两档的单页秒数
    /// 并把结果写到 `FUSHI_UPSCALE_OUT`（目录，可选）。
    #[test]
    #[ignore = "benchmark; needs FUSHI_UPSCALE_ORT / FUSHI_UPSCALE_MODELS / FUSHI_UPSCALE_PAGE"]
    fn real_model_page_timing() {
        let Some((ort, models, page)) = real_env() else {
            return;
        };
        real_ort(&ort);
        let backend = env_backend().unwrap_or(Backend::Cpu);
        let data = std::fs::read(&page).unwrap();
        let (px, w, h, ch, _) = crate::image::decode_opaque(&data).unwrap();
        // 典型对话页的文字框：右上与中部两块。
        let boxes = [[0.62f32, 0.05, 0.92, 0.35], [0.15, 0.45, 0.4, 0.7]];
        for tier in [Tier::Light, Tier::High]
            .into_iter()
            .filter(|t| tier_supported(*t, backend) || backend == Backend::Cpu)
        {
            let config = Config {
                tier,
                backend,
                inside: Some(models.join("swin_unet_art_scale2x.onnx")),
                outside: models.join(if tier == Tier::High {
                    "swin_unet_art_noise1_scale2x.onnx"
                } else {
                    "ArtCNN_C4F32.onnx"
                }),
            };
            let t0 = Instant::now();
            let mut nets = load_nets(&config).unwrap();
            let load = t0.elapsed().as_secs_f64();
            let t1 = Instant::now();
            let out = pipeline::upscale_pixels(
                &px,
                w as usize,
                h as usize,
                ch as usize,
                &boxes,
                &mut nets,
            )
            .unwrap()
            .unwrap();
            let first = t1.elapsed().as_secs_f64();
            let t2 = Instant::now();
            let _ = pipeline::upscale_pixels(
                &px,
                w as usize,
                h as usize,
                ch as usize,
                &boxes,
                &mut nets,
            )
            .unwrap();
            let second = t2.elapsed().as_secs_f64();
            eprintln!(
                "TIMING backend={backend:?} tier={tier:?} page={w}x{h} load={load:.2}s first={first:.2}s steady={second:.2}s"
            );
            assert_eq!(out.len(), 4 * w as usize * h as usize * ch as usize);
            assert!(
                out.iter().any(|v| *v < 64) && out.iter().any(|v| *v > 192),
                "output looks blank"
            );
            if let Ok(dir) = std::env::var("FUSHI_UPSCALE_OUT") {
                let jpeg = crate::image::encode_fit_jpeg(&out, 2 * w, 2 * h, ch as usize, 94, None)
                    .unwrap();
                std::fs::write(
                    Path::new(&dir).join(format!("{backend:?}-{tier:?}.jpg")),
                    jpeg,
                )
                .unwrap();
            }
        }
    }

    #[test]
    fn ffi_rejects_bad_arguments_before_touching_the_runtime() {
        unsafe {
            assert_eq!(
                ffc_upscale_configure(9, 0, std::ptr::null(), c"x".as_ptr()),
                status::INVALID_ARGUMENT
            );
            assert_eq!(
                ffc_upscale_configure(2, 0, std::ptr::null(), c"x".as_ptr()),
                status::NULL_ARGUMENT
            );
            assert_eq!(
                ffc_upscale_submit(
                    1,
                    std::ptr::null(),
                    0,
                    [1u8].as_ptr(),
                    1,
                    std::ptr::null(),
                    0
                ),
                status::NULL_ARGUMENT
            );
            assert_eq!(
                ffc_upscale_submit(1, c"k".as_ptr(), 0, [1u8].as_ptr(), 1, std::ptr::null(), 1),
                status::NULL_ARGUMENT
            );
            let mut p: *mut u8 = std::ptr::null_mut();
            let mut n = 0usize;
            assert_eq!(
                ffc_upscale_cached_path(std::ptr::null(), &mut p, &mut n),
                status::NULL_ARGUMENT
            );
        }
        assert_eq!(ffc_upscale_backend_available(42), 0);
        assert_eq!(
            unsafe { ffc_upscale_query(std::ptr::null()) },
            status::NULL_ARGUMENT
        );
        assert_eq!(ffc_upscale_tier_supported(1, 2), 1);
        assert_eq!(ffc_upscale_tier_supported(2, 1), 1);
        assert_eq!(ffc_upscale_tier_supported(2, 0), 0);
        assert_eq!(ffc_upscale_tier_supported(2, 2), 0);
        assert_eq!(ffc_upscale_tier_supported(9, 0), 0);
        assert_eq!(
            unsafe { ffc_upscale_configure(2, 2, c"a".as_ptr(), c"b".as_ptr()) },
            UPSCALE_UNSUPPORTED
        );
    }

    /// 引擎自己记住「正在算 / 判过不做 / 失败过」：调用方查一次就知道要不要读原图提交，换配置清零。
    #[test]
    fn state_query_tracks_pending_running_and_settled_keys() {
        let dir = std::env::temp_dir().join(format!("fushi_upscale_state_{}", std::process::id()));
        let mut state = State::new();
        assert_eq!(state.query("a"), UPSCALE_NOT_READY);
        state.cache = Some(DiskCache::open(&dir, 1 << 20).unwrap());
        state.config = Some(Config {
            tier: Tier::Light,
            backend: Backend::Cpu,
            inside: None,
            outside: PathBuf::from("m"),
        });
        assert_eq!(state.query("a"), QUERY_UNKNOWN);
        let job = |key: &str| Job {
            token: 1,
            key: key.into(),
            page: 0,
            data: vec![1],
            boxes: Vec::new(),
        };
        let _ = state.queue.push(job("a"));
        assert_eq!(state.query("a"), QUERY_PENDING);
        let popped = state.queue.pop().unwrap();
        state.running = Some(popped.key.clone());
        assert_eq!(state.query("a"), QUERY_PENDING);
        state.running = None;
        state.settle("a".into(), QUERY_SKIPPED);
        state.settle("b".into(), QUERY_FAILED);
        assert_eq!(state.query("a"), QUERY_SKIPPED);
        assert_eq!(state.query("b"), QUERY_FAILED);
        state.cache.as_mut().unwrap().put("c", b"jpeg").unwrap();
        assert_eq!(state.query("c"), QUERY_CACHED);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
