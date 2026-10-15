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
//!   ffsrs_call / ffsrs_compute_parameters / ffsrs_free_string /
//!   ffsrs_zstd_decompress / ffsrs_free_bytes / ffsrs_abi_version

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
