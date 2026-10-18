//! Fushi SRS 排程内核：fsrs-rs 的薄 C ABI。
//!
//! 设计（docs/specs/2026-10-14-fushi-srs-design.md「PR1」）：
//! - 五个平台 + 无头服务端都调这一份 Rust，不维护第二套公式。
//! - 每个接口带 algorithm（"fsrs6" / "fsrs7"），两种算法编进同一个库。
//! - 请求 / 响应走 UTF-8 JSON：签名少、Dart 侧不用为每个结构体写 FFI 布局，
//!   未发版的 fsrs-rs API 变化只影响这一层（Dart 不感知 rev）。
//! - elapsed 一律是**小数天**（f32）：FSRS-7 的优势来自当天内复习（含当天复习那张表），
//!   传整数天会把它抹掉（第六轮审查第 12 条）。FSRS-6 在 fsrs-rs 内部按 Anki 口径取整。
//! - 响应恒为 `{"ok": <结果>}` 或 `{"error": "<原因>"}`；任何 panic 都被接住转成 error，不越过 FFI 边界。
//!
//! 导出符号（与 packages/fushi_srs/lib/src/ffi/fushi_fsrs_bindings.dart 的 lookup 名一一对应）：
//!   ffsrs_call / ffsrs_compute_parameters / ffsrs_retrievability_batch / ffsrs_free_string /
//!   ffsrs_zstd_decompress / ffsrs_free_bytes / ffsrs_abi_version /
//!   ffsrs_search_corpus_new / ffsrs_search_corpus_free / ffsrs_search_corpus_set_ints /
//!   ffsrs_search_corpus_set_floats / ffsrs_search_corpus_match / ffsrs_search_dupe_norm_batch
//!   （Anki 搜索的逐卡求值与查重规范形，见 search.rs）

pub mod search;

use std::ffi::{c_char, CStr, CString};
use std::io::Read;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicI64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use fsrs::{
    CombinedProgressState, ComputeParametersInput, ComputeParametersVersion, FSRSItem, FSRSReview,
    MemoryState, DEFAULT_PARAMETERS, FSRS, FSRS6_DEFAULT_PARAMETERS,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// C ABI 版本。Dart 侧加载时比对，不一致视为库不可用（不崩）。
pub const ABI_VERSION: i32 = 1;

/// 钉定的 fsrs-rs 源码版本，写进参数组的 algorithmRev。
pub const FSRS_RS_REV: &str = "0a5737406a0c5c7a5259b144738cbe4a0b649d76";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Algorithm {
    Fsrs6,
    Fsrs7,
}

impl Algorithm {
    fn parse(value: &str) -> Result<Self, String> {
        match value {
            "fsrs6" => Ok(Self::Fsrs6),
            "fsrs7" => Ok(Self::Fsrs7),
            other => Err(format!("unknown algorithm: {other}")),
        }
    }

    fn param_len(self) -> usize {
        match self {
            Self::Fsrs6 => 21,
            Self::Fsrs7 => 34,
        }
    }

    fn defaults(self) -> Vec<f32> {
        match self {
            Self::Fsrs6 => FSRS6_DEFAULT_PARAMETERS.to_vec(),
            Self::Fsrs7 => DEFAULT_PARAMETERS.to_vec(),
        }
    }

    fn compute_version(self) -> ComputeParametersVersion {
        match self {
            Self::Fsrs6 => ComputeParametersVersion::Fsrs6,
            Self::Fsrs7 => ComputeParametersVersion::Fsrs7,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
pub struct Memory {
    /// stability（天）
    pub s: f32,
    /// difficulty（1..10）
    pub d: f32,
    /// FSRS-7 的快速稳定性分量；FSRS-6 恒等于 s。
    #[serde(default)]
    pub sf: Option<f32>,
}

impl Memory {
    fn to_fsrs(self) -> MemoryState {
        MemoryState {
            stability: self.s,
            difficulty: self.d,
            stability_fast: self.sf.unwrap_or(self.s),
        }
    }

    fn from_fsrs(state: MemoryState) -> Self {
        Self {
            s: state.stability,
            d: state.difficulty,
            sf: Some(state.stability_fast),
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize)]
pub struct Review {
    pub rating: u32,
    /// 距上一次评分的天数（小数）；第一条必须为 0。
    #[serde(rename = "deltaT")]
    pub delta_t: f32,
}

fn parse_items(value: &Value) -> Result<Vec<FSRSItem>, String> {
    let items: Vec<Vec<Review>> =
        serde_json::from_value(value.clone()).map_err(|e| format!("bad items: {e}"))?;
    Ok(items
        .into_iter()
        .filter(|reviews| !reviews.is_empty())
        .map(|reviews| FSRSItem {
            reviews: reviews
                .into_iter()
                .map(|r| FSRSReview {
                    rating: r.rating,
                    delta_t: r.delta_t,
                })
                .collect(),
        })
        .collect())
}

/// 参数校验：个数必须与算法一致，取值有限；空 = 该算法默认参数。
/// Dart 侧「参数加载校验」（#4278）与 PR3b 导入校验都走这里。
fn build_model(algorithm: Algorithm, params: Option<&Value>) -> Result<FSRS, String> {
    let params: Vec<f32> = match params {
        None | Some(Value::Null) => algorithm.defaults(),
        Some(value) => {
            serde_json::from_value(value.clone()).map_err(|e| format!("bad params: {e}"))?
        }
    };
    let params = if params.is_empty() {
        algorithm.defaults()
    } else {
        params
    };
    if params.len() != algorithm.param_len() {
        return Err(format!(
            "invalid parameter count {} for {:?} (expected {})",
            params.len(),
            algorithm,
            algorithm.param_len()
        ));
    }
    if params.iter().any(|v| !v.is_finite()) {
        return Err("parameters must be finite".into());
    }
    FSRS::new(&params).map_err(|e| format!("invalid parameters: {e:?}"))
}

fn str_field<'a>(req: &'a Value, key: &str) -> Result<&'a str, String> {
    req.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("missing string field `{key}`"))
}

fn f32_field(req: &Value, key: &str) -> Result<f32, String> {
    req.get(key)
        .and_then(Value::as_f64)
        .map(|v| v as f32)
        .ok_or_else(|| format!("missing number field `{key}`"))
}

fn memory_field(req: &Value, key: &str) -> Result<Option<Memory>, String> {
    match req.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(v) => serde_json::from_value(v.clone())
            .map(Some)
            .map_err(|e| format!("bad `{key}`: {e}")),
    }
}

fn dispatch(req: &Value) -> Result<Value, String> {
    let op = str_field(req, "op")?;
    match op {
        "version" => Ok(json!({ "abi": ABI_VERSION, "fsrsRev": FSRS_RS_REV })),
        "defaults" => {
            let algorithm = Algorithm::parse(str_field(req, "algorithm")?)?;
            Ok(json!({ "params": algorithm.defaults(), "count": algorithm.param_len() }))
        }
        "validate" => {
            let algorithm = Algorithm::parse(str_field(req, "algorithm")?)?;
            build_model(algorithm, req.get("params"))?;
            Ok(json!(true))
        }
        "next_states" => {
            let algorithm = Algorithm::parse(str_field(req, "algorithm")?)?;
            let model = build_model(algorithm, req.get("params"))?;
            let retention = f32_field(req, "desiredRetention")?;
            let elapsed = f32_field(req, "elapsedDays").unwrap_or(0.0).max(0.0);
            let memory = memory_field(req, "memory")?.map(Memory::to_fsrs);
            let next = model
                .next_states_with_elapsed_days(memory, retention, elapsed)
                .map_err(|e| format!("next_states: {e:?}"))?;
            let item = |s: &fsrs::ItemState| {
                json!({ "memory": Memory::from_fsrs(s.memory), "interval": s.interval })
            };
            Ok(json!({
                "again": item(&next.again),
                "hard": item(&next.hard),
                "good": item(&next.good),
                "easy": item(&next.easy),
            }))
        }
        "memory_state" => {
            // 由历史重建记忆状态（铁律 A ②③）。starting = 锚点换算出的起点（可空 = 新卡）。
            let algorithm = Algorithm::parse(str_field(req, "algorithm")?)?;
            let model = build_model(algorithm, req.get("params"))?;
            let reviews: Vec<Review> = serde_json::from_value(
                req.get("reviews").cloned().unwrap_or(Value::Array(vec![])),
            )
            .map_err(|e| format!("bad reviews: {e}"))?;
            let starting = memory_field(req, "starting")?.map(Memory::to_fsrs);
            if reviews.is_empty() {
                return Ok(match starting {
                    Some(s) => json!(Memory::from_fsrs(s)),
                    None => Value::Null,
                });
            }
            let item = FSRSItem {
                reviews: reviews
                    .into_iter()
                    .map(|r| FSRSReview {
                        rating: r.rating,
                        delta_t: r.delta_t,
                    })
                    .collect(),
            };
            let state = model
                .memory_state(item, starting)
                .map_err(|e| format!("memory_state: {e:?}"))?;
            Ok(json!(Memory::from_fsrs(state)))
        }
        "memory_state_from_sm2" => {
            let algorithm = Algorithm::parse(str_field(req, "algorithm")?)?;
            let model = build_model(algorithm, req.get("params"))?;
            let ease = f32_field(req, "easeFactor")?;
            let interval = f32_field(req, "interval")?;
            let retention = f32_field(req, "sm2Retention")?;
            let state = model
                .memory_state_from_sm2(ease, interval, retention)
                .map_err(|e| format!("memory_state_from_sm2: {e:?}"))?;
            Ok(json!(Memory::from_fsrs(state)))
        }
        "retrievability" => {
            let algorithm = Algorithm::parse(str_field(req, "algorithm")?)?;
            let model = build_model(algorithm, req.get("params"))?;
            let memory = memory_field(req, "memory")?
                .ok_or_else(|| "missing `memory`".to_string())?;
            let elapsed = f32_field(req, "elapsedDays")?;
            Ok(json!(model.current_retrievability(memory.to_fsrs(), elapsed)))
        }
        "next_interval" => {
            let algorithm = Algorithm::parse(str_field(req, "algorithm")?)?;
            let model = build_model(algorithm, req.get("params"))?;
            let retention = f32_field(req, "desiredRetention")?;
            let memory = memory_field(req, "memory")?
                .ok_or_else(|| "missing `memory`".to_string())?;
            Ok(json!(model.next_interval(
                Some(memory.s),
                retention,
                3
            )))
        }
        "evaluate" => {
            // 训练集内评估：只用于展示「当前参数在这份数据上的 log loss」。
            // 跨算法 / 新旧参数的采用判定一律用 evaluate_tss（外样本），见 PR6。
            let algorithm = Algorithm::parse(str_field(req, "algorithm")?)?;
            let model = build_model(algorithm, req.get("params"))?;
            let items = parse_items(req.get("items").unwrap_or(&Value::Null))?;
            let eval = model
                .evaluate(items, |_| true)
                .map_err(|e| format!("evaluate: {e:?}"))?;
            Ok(json!({ "logLoss": eval.log_loss, "rmseBins": eval.rmse_bins }))
        }
        "evaluate_tss" => {
            // 时间序列切分的外样本评估（第六轮审查第 11 条）：每折只用之前的数据训练、在之后的数据上评估，
            // FSRS-7 34 个参数在训练集内过拟合的优势不会被算进去。items 必须按复习时间排好序。
            let algorithm = Algorithm::parse(str_field(req, "algorithm")?)?;
            let items = parse_items(req.get("items").unwrap_or(&Value::Null))?;
            let input = ComputeParametersInput {
                train_set: items,
                model_version: algorithm.compute_version(),
                ..Default::default()
            };
            let eval = fsrs::evaluate_with_time_series_splits(input, |_| true)
                .map_err(|e| format!("evaluate_tss: {e:?}"))?;
            Ok(json!({ "logLoss": eval.log_loss, "rmseBins": eval.rmse_bins }))
        }
        other => Err(format!("unknown op: {other}")),
    }
}

fn respond(result: Result<Value, String>) -> *mut c_char {
    let body = match result {
        Ok(v) => json!({ "ok": v }),
        Err(e) => json!({ "error": e }),
    };
    CString::new(body.to_string())
        .unwrap_or_else(|_| CString::new("{\"error\":\"nul in response\"}").unwrap())
        .into_raw()
}

fn read_request(request: *const c_char) -> Result<Value, String> {
    if request.is_null() {
        return Err("null request".into());
    }
    let text = unsafe { CStr::from_ptr(request) }
        .to_str()
        .map_err(|e| format!("request is not utf-8: {e}"))?;
    serde_json::from_str(text).map_err(|e| format!("request is not json: {e}"))
}

/// 通用入口：请求 JSON → 响应 JSON。返回值必须用 [ffsrs_free_string] 释放。
#[no_mangle]
pub extern "C" fn ffsrs_call(request: *const c_char) -> *mut c_char {
    let outcome = catch_unwind(AssertUnwindSafe(|| read_request(request).and_then(|r| dispatch(&r))));
    respond(outcome.unwrap_or_else(|_| Err("panic in fushi_fsrs".into())))
}

/// 参数优化（同步、阻塞，调用方放后台 isolate）。
///
/// - `cancel`：调用方持有的 int32，任意线程写非 0 即请求取消；取消后返回 `{"error":"cancelled"}`，不留半成品。
/// - `progress`：长度 2 的 int64 数组 [已处理, 总数]，本函数运行中持续写入，可从别的 isolate 读。
///   两者都可为空指针。
///
/// 请求：`{"algorithm":"fsrs7","items":[[{"rating":3,"deltaT":0},...],...],"cardIds":[...]?}`
/// 响应：`{"ok":{"params":[...],"count":N}}`
#[no_mangle]
pub extern "C" fn ffsrs_compute_parameters(
    request: *const c_char,
    cancel: *const AtomicI32,
    progress: *const AtomicI64,
) -> *mut c_char {
    let cancel_addr = cancel as usize;
    let progress_addr = progress as usize;
    let outcome = catch_unwind(AssertUnwindSafe(|| -> Result<Value, String> {
        let req = read_request(request)?;
        let algorithm = Algorithm::parse(str_field(&req, "algorithm")?)?;
        let items = parse_items(req.get("items").unwrap_or(&Value::Null))?;
        if items.is_empty() {
            return Err("not enough data".into());
        }
        let card_ids: Option<Vec<i64>> = match req.get("cardIds") {
            None | Some(Value::Null) => None,
            Some(v) => Some(serde_json::from_value(v.clone()).map_err(|e| format!("bad cardIds: {e}"))?),
        };
        let state = CombinedProgressState::new_shared();
        let done = Arc::new(AtomicBool::new(false));
        let watcher = spawn_watcher(state.clone(), done.clone(), cancel_addr, progress_addr);
        let input = ComputeParametersInput {
            train_set: items,
            card_ids,
            progress: Some(state.clone()),
            model_version: algorithm.compute_version(),
            ..Default::default()
        };
        let result = fsrs::compute_parameters(input);
        done.store(true, Ordering::SeqCst);
        let _ = watcher.join();
        let cancelled = cancel_addr != 0
            && unsafe { &*(cancel_addr as *const AtomicI32) }.load(Ordering::SeqCst) != 0;
        if cancelled {
            return Err("cancelled".into());
        }
        let params = result.map_err(|e| format!("compute_parameters: {e:?}"))?;
        Ok(json!({ "params": params, "count": params.len() }))
    }));
    respond(outcome.unwrap_or_else(|_| Err("panic in fushi_fsrs".into())))
}

fn spawn_watcher(
    state: Arc<Mutex<CombinedProgressState>>,
    done: Arc<AtomicBool>,
    cancel_addr: usize,
    progress_addr: usize,
) -> thread::JoinHandle<()> {
    thread::spawn(move || loop {
        let finished = done.load(Ordering::SeqCst);
        if let Ok(mut s) = state.lock() {
            if cancel_addr != 0
                && unsafe { &*(cancel_addr as *const AtomicI32) }.load(Ordering::SeqCst) != 0
            {
                s.want_abort = true;
            }
            if progress_addr != 0 {
                let p = progress_addr as *const AtomicI64;
                unsafe {
                    (*p).store(s.current() as i64, Ordering::SeqCst);
                    (*p.add(1)).store(s.total() as i64, Ordering::SeqCst);
                }
            }
        }
        if finished {
            break;
        }
        thread::sleep(Duration::from_millis(50));
    })
}

/// 批量可提取度：同一组参数下一次算完一整批卡（统计页）。
///
/// 逐张走 [ffsrs_call] 时，每张卡都要做一遍请求编码与参数解析，这部分开销占了大头
/// （2 万张卡约 0.5 s）。这里参数只解析一次、模型只建一次，卡片数据走 f32 数组。
///
/// - `model`：`{"algorithm", "params"}` JSON，字段含义同 [ffsrs_call]；
/// - `s` / `d` / `elapsed`：长度为 `n` 的 f32 数组（stability、difficulty、距上次复习的小数天）；
/// - `sf`：FSRS-7 快速稳定性分量，长度 `n`；可为空指针，等同于逐张取 `s`；
/// - `out`：调用方分配、长度 `n` 的 f32 数组，逐张写入结果。
///
/// 返回 `{"ok": n}` 或 `{"error": "…"}`，必须用 [ffsrs_free_string] 释放；出错时 `out` 的内容未定义。
/// 结果与逐张调 `retrievability` op 逐位一致。
#[no_mangle]
pub extern "C" fn ffsrs_retrievability_batch(
    model: *const c_char,
    s: *const f32,
    d: *const f32,
    sf: *const f32,
    elapsed: *const f32,
    n: usize,
    out: *mut f32,
) -> *mut c_char {
    let outcome = catch_unwind(AssertUnwindSafe(|| -> Result<Value, String> {
        let req = read_request(model)?;
        let algorithm = Algorithm::parse(str_field(&req, "algorithm")?)?;
        let model = build_model(algorithm, req.get("params"))?;
        if n == 0 {
            return Ok(json!(0));
        }
        if s.is_null() || d.is_null() || elapsed.is_null() || out.is_null() {
            return Err("null buffer".into());
        }
        let (s, d, elapsed, out) = unsafe {
            (
                std::slice::from_raw_parts(s, n),
                std::slice::from_raw_parts(d, n),
                std::slice::from_raw_parts(elapsed, n),
                std::slice::from_raw_parts_mut(out, n),
            )
        };
        let sf = (!sf.is_null()).then(|| unsafe { std::slice::from_raw_parts(sf, n) });
        for i in 0..n {
            let memory = Memory {
                s: s[i],
                d: d[i],
                sf: sf.map(|v| v[i]),
            };
            out[i] = model.current_retrievability(memory.to_fsrs(), elapsed[i]);
        }
        Ok(json!(n))
    }));
    respond(outcome.unwrap_or_else(|_| Err("panic in fushi_fsrs".into())))
}

/// 释放 [ffsrs_call] / [ffsrs_compute_parameters] 返回的字符串。
#[no_mangle]
pub extern "C" fn ffsrs_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe { drop(CString::from_raw(ptr)) };
    }
}

/// zstd 解码（.apkg 新格式）。成功返回新分配的缓冲区并写 `out_len`；失败返回空指针。
/// 返回的缓冲区必须用 [ffsrs_free_bytes] 释放。
#[no_mangle]
pub extern "C" fn ffsrs_zstd_decompress(
    data: *const u8,
    len: usize,
    out_len: *mut usize,
) -> *mut u8 {
    let outcome = catch_unwind(AssertUnwindSafe(|| -> Option<Vec<u8>> {
        if data.is_null() || out_len.is_null() {
            return None;
        }
        let input = unsafe { std::slice::from_raw_parts(data, len) };
        zstd_decompress(input).ok()
    }));
    match outcome.ok().flatten() {
        Some(bytes) => {
            let boxed = bytes.into_boxed_slice();
            unsafe { *out_len = boxed.len() };
            Box::into_raw(boxed) as *mut u8
        }
        None => std::ptr::null_mut(),
    }
}

pub fn zstd_decompress(input: &[u8]) -> Result<Vec<u8>, String> {
    let mut decoder = ruzstd::decoding::StreamingDecoder::new(input).map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    decoder.read_to_end(&mut out).map_err(|e| e.to_string())?;
    Ok(out)
}

/// 释放 [ffsrs_zstd_decompress] 返回的缓冲区。
#[no_mangle]
pub extern "C" fn ffsrs_free_bytes(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        unsafe { drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len))) };
    }
}

// ---------------------------------------------------------------- Anki 搜索（search.rs）

fn set_error(error_out: *mut *mut c_char, message: &str) {
    if !error_out.is_null() {
        let text = CString::new(message.replace('\0', " ")).unwrap_or_default();
        unsafe { *error_out = text.into_raw() };
    }
}

/// 建一批卡的搜索语料（布局见 `search::Corpus::new`）。失败返回空指针，并在 `error_out`
/// （可空）写一条用 [ffsrs_free_string] 释放的错误串。句柄用 [ffsrs_search_corpus_free] 释放。
#[no_mangle]
pub extern "C" fn ffsrs_search_corpus_new(
    text: *const u8,
    text_len: usize,
    layout: *const u32,
    layout_len: usize,
    error_out: *mut *mut c_char,
) -> *mut search::Corpus {
    let outcome = catch_unwind(AssertUnwindSafe(|| -> Result<search::Corpus, String> {
        if (text.is_null() && text_len > 0) || layout.is_null() {
            return Err("null buffer".into());
        }
        let text: &[u8] = if text_len == 0 { &[] } else { unsafe { std::slice::from_raw_parts(text, text_len) } };
        let layout = unsafe { std::slice::from_raw_parts(layout, layout_len) };
        search::Corpus::new(text, layout)
    }));
    match outcome.unwrap_or_else(|_| Err("panic in fushi_fsrs".into())) {
        Ok(corpus) => Box::into_raw(Box::new(corpus)),
        Err(e) => {
            set_error(error_out, &e);
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "C" fn ffsrs_search_corpus_free(corpus: *mut search::Corpus) {
    if !corpus.is_null() {
        unsafe { drop(Box::from_raw(corpus)) };
    }
}

/// 设整数列（`search::IntColumn`），`n` 必须等于卡数。成功 0，失败 -1。
#[no_mangle]
pub extern "C" fn ffsrs_search_corpus_set_ints(
    corpus: *mut search::Corpus,
    column: i32,
    data: *const i64,
    n: usize,
) -> i32 {
    let outcome = catch_unwind(AssertUnwindSafe(|| -> Result<(), String> {
        if corpus.is_null() || (data.is_null() && n > 0) || column < 0 {
            return Err("null".into());
        }
        let data: &[i64] = if n == 0 { &[] } else { unsafe { std::slice::from_raw_parts(data, n) } };
        unsafe { &mut *corpus }.set_ints(column as usize, data)
    }));
    if matches!(outcome, Ok(Ok(()))) { 0 } else { -1 }
}

/// 设小数列（`search::FloatColumn`，NaN = 没有值），`n` 必须等于卡数。成功 0，失败 -1。
#[no_mangle]
pub extern "C" fn ffsrs_search_corpus_set_floats(
    corpus: *mut search::Corpus,
    column: i32,
    data: *const f64,
    n: usize,
) -> i32 {
    let outcome = catch_unwind(AssertUnwindSafe(|| -> Result<(), String> {
        if corpus.is_null() || (data.is_null() && n > 0) || column < 0 {
            return Err("null".into());
        }
        let data: &[f64] = if n == 0 { &[] } else { unsafe { std::slice::from_raw_parts(data, n) } };
        unsafe { &mut *corpus }.set_floats(column as usize, data)
    }));
    if matches!(outcome, Ok(Ok(()))) { 0 } else { -1 }
}

/// 对整批卡求值一条搜索（`query` 是语法树 JSON，见 `search::Node`）：`out[i]` 写 1 / 0，
/// `n` 必须等于卡数。返回 `{"ok":命中数}` 或 `{"error","kind":"syntax"|"internal","at"}`，
/// 由 [ffsrs_free_string] 释放。
#[no_mangle]
pub extern "C" fn ffsrs_search_corpus_match(
    corpus: *const search::Corpus,
    query: *const c_char,
    out: *mut u8,
    n: usize,
) -> *mut c_char {
    let outcome = catch_unwind(AssertUnwindSafe(|| -> Result<usize, search::SearchError> {
        let internal = |m: &str| search::SearchError { kind: "internal", reason: m.into(), at: String::new() };
        if corpus.is_null() || query.is_null() || (out.is_null() && n > 0) {
            return Err(internal("null"));
        }
        let query = unsafe { CStr::from_ptr(query) }.to_str().map_err(|_| internal("query is not UTF-8"))?;
        let out: &mut [u8] = if n == 0 { &mut [] } else { unsafe { std::slice::from_raw_parts_mut(out, n) } };
        unsafe { &*corpus }.search(query, out)
    }));
    let value = match outcome {
        Ok(Ok(hits)) => json!({ "ok": hits }),
        Ok(Err(e)) => json!({ "error": e.reason, "kind": e.kind, "at": e.at }),
        Err(_) => json!({ "error": "panic in fushi_fsrs", "kind": "internal", "at": "" }),
    };
    CString::new(value.to_string()).unwrap().into_raw()
}

/// AnkiConnect 查重的首字段规范形（样式去重 → 去 HTML → trim），批量：输入第 i 个串 =
/// `text[offs[i]..offs[i+1]]`（`offs` 长 n+1）。成功返回 `[u32 LE 偏移 × (n+1)][UTF-8 结果]`
/// 并写 `out_len`，用 [ffsrs_free_bytes] 释放；失败返回空指针。
#[no_mangle]
pub extern "C" fn ffsrs_search_dupe_norm_batch(
    text: *const u8,
    text_len: usize,
    offs: *const u32,
    n: usize,
    out_len: *mut usize,
) -> *mut u8 {
    let outcome = catch_unwind(AssertUnwindSafe(|| -> Option<Vec<u8>> {
        if (text.is_null() && text_len > 0) || offs.is_null() || out_len.is_null() {
            return None;
        }
        let text: &[u8] = if text_len == 0 { &[] } else { unsafe { std::slice::from_raw_parts(text, text_len) } };
        let text = std::str::from_utf8(text).ok()?;
        let offs = unsafe { std::slice::from_raw_parts(offs, n + 1) };
        let mut header = Vec::with_capacity((n + 1) * 4);
        let mut body = String::new();
        header.extend_from_slice(&0u32.to_le_bytes());
        for w in offs.windows(2) {
            let (a, b) = (w[0] as usize, w[1] as usize);
            if a > b || !text.is_char_boundary(a) || !text.is_char_boundary(b) || b > text.len() {
                return None;
            }
            body.push_str(&search::dupe_norm(&text[a..b]));
            header.extend_from_slice(&u32::try_from(body.len()).ok()?.to_le_bytes());
        }
        header.extend_from_slice(body.as_bytes());
        Some(header)
    }));
    match outcome.ok().flatten() {
        Some(bytes) => {
            let boxed = bytes.into_boxed_slice();
            unsafe { *out_len = boxed.len() };
            Box::into_raw(boxed) as *mut u8
        }
        None => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn ffsrs_abi_version() -> i32 {
    ABI_VERSION
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(req: Value) -> Value {
        let c = CString::new(req.to_string()).unwrap();
        let out = ffsrs_call(c.as_ptr());
        let text = unsafe { CStr::from_ptr(out) }.to_str().unwrap().to_string();
        ffsrs_free_string(out);
        serde_json::from_str(&text).unwrap()
    }

    #[test]
    fn defaults_have_expected_lengths() {
        let v6 = call(json!({"op":"defaults","algorithm":"fsrs6"}));
        assert_eq!(v6["ok"]["count"], 21);
        let v7 = call(json!({"op":"defaults","algorithm":"fsrs7"}));
        assert_eq!(v7["ok"]["count"], 34);
    }

    #[test]
    fn next_states_new_card_orders_intervals() {
        for alg in ["fsrs6", "fsrs7"] {
            let r = call(json!({"op":"next_states","algorithm":alg,"desiredRetention":0.9,"elapsedDays":0}));
            let ok = &r["ok"];
            let again = ok["again"]["interval"].as_f64().unwrap();
            let good = ok["good"]["interval"].as_f64().unwrap();
            let easy = ok["easy"]["interval"].as_f64().unwrap();
            assert!(again < good && good < easy, "{alg}: {r}");
        }
    }

    #[test]
    fn rejects_wrong_param_count() {
        let r = call(json!({"op":"validate","algorithm":"fsrs7","params":[1.0,2.0]}));
        assert!(r.get("error").is_some());
        let six = call(json!({"op":"defaults","algorithm":"fsrs6"}));
        let r = call(json!({"op":"validate","algorithm":"fsrs7","params":six["ok"]["params"]}));
        assert!(r.get("error").is_some(), "fsrs6 params must not validate as fsrs7");
    }

    #[test]
    fn memory_state_from_history_matches_stepwise() {
        let r = call(json!({"op":"memory_state","algorithm":"fsrs6","reviews":[
            {"rating":3,"deltaT":0},{"rating":3,"deltaT":3},{"rating":1,"deltaT":10}]}));
        assert!(r["ok"]["s"].as_f64().unwrap() > 0.0, "{r}");
    }

    #[test]
    fn fractional_elapsed_changes_fsrs7_result() {
        let mem = json!({"s":1.0,"d":5.0,"sf":1.0});
        let a = call(json!({"op":"next_states","algorithm":"fsrs7","desiredRetention":0.9,"elapsedDays":0.1,"memory":mem}));
        let b = call(json!({"op":"next_states","algorithm":"fsrs7","desiredRetention":0.9,"elapsedDays":0.9,"memory":mem}));
        assert_ne!(a["ok"]["good"]["memory"]["s"], b["ok"]["good"]["memory"]["s"]);
    }

    #[test]
    fn retrievability_batch_matches_single_calls() {
        for alg in ["fsrs6", "fsrs7"] {
            let s: Vec<f32> = (0..200).map(|i| 0.5 + (i % 50) as f32 * 3.7).collect();
            let d: Vec<f32> = (0..200).map(|i| 1.0 + (i % 9) as f32).collect();
            let sf: Vec<f32> = s.iter().map(|v| v * 0.6).collect();
            let e: Vec<f32> = (0..200).map(|i| (i % 40) as f32 * 0.33).collect();
            let mut out = vec![0f32; s.len()];
            let model = CString::new(json!({"algorithm": alg}).to_string()).unwrap();
            let resp = ffsrs_retrievability_batch(
                model.as_ptr(),
                s.as_ptr(),
                d.as_ptr(),
                sf.as_ptr(),
                e.as_ptr(),
                s.len(),
                out.as_mut_ptr(),
            );
            let text = unsafe { CStr::from_ptr(resp) }.to_str().unwrap().to_string();
            ffsrs_free_string(resp);
            assert_eq!(text, format!("{{\"ok\":{}}}", s.len()), "{alg}");
            for i in 0..s.len() {
                let one = call(json!({"op":"retrievability","algorithm":alg,
                    "memory":{"s":s[i],"d":d[i],"sf":sf[i]},"elapsedDays":e[i]}));
                assert_eq!(one["ok"].as_f64().unwrap() as f32, out[i], "{alg} #{i}");
            }
        }
    }

    #[test]
    fn retrievability_batch_rejects_bad_input() {
        let mut out = [0f32; 1];
        let one = [1f32];
        let model = CString::new(json!({"algorithm":"fsrs7","params":[1.0]}).to_string()).unwrap();
        let resp = ffsrs_retrievability_batch(
            model.as_ptr(),
            one.as_ptr(),
            one.as_ptr(),
            std::ptr::null(),
            one.as_ptr(),
            1,
            out.as_mut_ptr(),
        );
        let text = unsafe { CStr::from_ptr(resp) }.to_str().unwrap().to_string();
        ffsrs_free_string(resp);
        assert!(text.contains("error"), "{text}");
        let model = CString::new(json!({"algorithm":"fsrs7"}).to_string()).unwrap();
        let resp = ffsrs_retrievability_batch(
            model.as_ptr(),
            std::ptr::null(),
            one.as_ptr(),
            std::ptr::null(),
            one.as_ptr(),
            1,
            out.as_mut_ptr(),
        );
        let text = unsafe { CStr::from_ptr(resp) }.to_str().unwrap().to_string();
        ffsrs_free_string(resp);
        assert!(text.contains("null buffer"), "{text}");
    }

    #[test]
    fn unknown_op_is_error_not_panic() {
        let r = call(json!({"op":"nope"}));
        assert!(r["error"].as_str().unwrap().contains("unknown op"));
    }

    #[test]
    fn zstd_roundtrip() {
        let payload: Vec<u8> = (0..50_000u32).flat_map(|i| (i % 251).to_le_bytes()).collect();
        let frame = ruzstd::encoding::compress_to_vec(
            payload.as_slice(),
            ruzstd::encoding::CompressionLevel::Fastest,
        );
        assert!(frame.len() < payload.len());
        let mut out_len = 0usize;
        let ptr = ffsrs_zstd_decompress(frame.as_ptr(), frame.len(), &mut out_len);
        assert!(!ptr.is_null());
        let out = unsafe { std::slice::from_raw_parts(ptr, out_len) }.to_vec();
        ffsrs_free_bytes(ptr, out_len);
        assert_eq!(out, payload);
        // 损坏的帧返回空指针，不 panic。
        let bad = [0x28u8, 0xb5, 0x2f, 0xfd, 0xff];
        assert!(ffsrs_zstd_decompress(bad.as_ptr(), bad.len(), &mut out_len).is_null());
    }
}
