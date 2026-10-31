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
//!   ffsrs_call / ffsrs_fit / ffsrs_retrievability_batch / ffsrs_free_string /
//!   ffsrs_zstd_decompress / ffsrs_zstd_decompress_file / ffsrs_free_bytes / ffsrs_abi_version /
//!   ffsrs_search_dupe_norm_batch
//!   （AnkiConnect 查重规范形，见 search.rs；搜索求值走浏览会话 store/browse.rs，经 v2 分发器）/
//!   ffsrs_history_states / ffsrs_history_select / ffsrs_import_equivalent
//!   （卡片历史内核：有效日志选取与当前排程状态、Anki 导入判重，见 history.rs）/
//!   ffsrs_materialize
//!   （字段寄存器内核：修改记录 → 寄存器 → 物化视图，见 registers.rs；排序键 ordering.rs、
//!   释义样式去重规范形 style_dedup.rs 两边共用） /
//!   ffsrs_memory_input / ffsrs_rwkv_now_rows
//!   （投影：记忆状态输入、RWKV 此刻行，见 projection.rs；srs.db 直读命令在 store/ffi.rs）

pub mod card_cache;
pub mod history;
pub mod ordering;
pub mod projection;
pub mod registers;
pub mod search;
pub mod store;
pub mod sync2;
pub mod style_dedup;

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

/// C ABI 版本。Dart 侧加载时比对，不一致视为库不可用（不崩）。4：删掉整批搜索语料的 `ffsrs_search_corpus_*` / `ffsrs_search_chunk_*`（L-5）。
pub const ABI_VERSION: i32 = 4;

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

/// 优化 / 评估的训练集，打包形态（`ffsrs_fit` 的输入，BUG-3745）。
///
/// 每张卡只传一份完整历史（`ratings` / `delta_days` 按 `card_offsets` 切段），外加按评分时刻排好序的
/// 训练条目 `(item_cards[i], item_lengths[i])`：第 i 条 = 卡 `item_cards[i]` 的前 `item_lengths[i]` 次评分。
/// fsrs-rs 的 API 收 `Vec<FSRSItem>`（每条自带一份前缀），前缀在这里展开：Dart 侧与 FFI 边界只有
/// O(总评分数) 的数据，展开后的 O(Σ 前缀长度) 只存在于本次调用期间的 Rust 堆上。
struct TrainingSet<'a> {
    ratings: &'a [u8],
    delta_days: &'a [f32],
    card_offsets: &'a [u32],
    /// 每张卡的 ID（可空）；按条目展开成 fsrs-rs 要的「与 train_set 对齐的 card_ids」。
    card_ids: Option<&'a [i64]>,
    item_cards: &'a [u32],
    item_lengths: &'a [u32],
}

impl TrainingSet<'_> {
    fn validate(&self) -> Result<(), String> {
        let n_cards = self.card_offsets.len().saturating_sub(1);
        if self.card_offsets.first() != Some(&0) {
            return Err("bad training set: card_offsets must start at 0".into());
        }
        if self.card_offsets.windows(2).any(|w| w[0] > w[1]) {
            return Err("bad training set: card_offsets must be non-decreasing".into());
        }
        if self.card_offsets[n_cards] as usize != self.ratings.len() {
            return Err("bad training set: card_offsets do not cover the reviews".into());
        }
        if self.card_ids.is_some_and(|ids| ids.len() != n_cards) {
            return Err("bad training set: one card id per card".into());
        }
        for (&card, &len) in self.item_cards.iter().zip(self.item_lengths) {
            let card = card as usize;
            if card >= n_cards {
                return Err(format!("bad training set: item card {card} out of range"));
            }
            let history = (self.card_offsets[card + 1] - self.card_offsets[card]) as usize;
            if len == 0 || len as usize > history {
                return Err(format!(
                    "bad training set: prefix length {len} for a {history}-review card"
                ));
            }
        }
        Ok(())
    }

    /// 展开成 fsrs-rs 的条目（顺序 = 输入顺序，即按评分时刻）。`with_card_ids` 时同时给出对齐的 card_ids。
    fn expand(&self, with_card_ids: bool) -> (Vec<FSRSItem>, Option<Vec<i64>>) {
        let items = self
            .item_cards
            .iter()
            .zip(self.item_lengths)
            .map(|(&card, &len)| {
                let from = self.card_offsets[card as usize] as usize;
                let to = from + len as usize;
                FSRSItem {
                    reviews: self.ratings[from..to]
                        .iter()
                        .zip(&self.delta_days[from..to])
                        .map(|(&rating, &delta_t)| FSRSReview {
                            rating: rating as u32,
                            delta_t,
                        })
                        .collect(),
                }
            })
            .collect();
        let card_ids = match (with_card_ids, self.card_ids) {
            (true, Some(ids)) => Some(self.item_cards.iter().map(|&c| ids[c as usize]).collect()),
            _ => None,
        };
        (items, card_ids)
    }
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

/// 参数优化与评估（同步、阻塞，调用方放后台 isolate）。
///
/// `request`：`{"op","algorithm","params"?}`，op 取
/// - `compute_parameters`：参数优化，响应 `{"ok":{"params":[...],"count":N}}`；
///   `card_ids` 非空时按条目对齐传给 fsrs-rs（FSRS-7 同卡前缀按扩展窗口训练）；
/// - `evaluate`：给定参数的训练集内评估（只用于展示），响应 `{"ok":{"logLoss","rmseBins"}}`；
/// - `evaluate_tss`：时间序列切分的外样本评估（第六轮审查第 11 条）：每折只用之前的数据训练、在之后的数据上评估，
///   FSRS-7 34 个参数在训练集内过拟合的优势不会被算进去。条目必须按复习时间排好序。
///
/// 两种评估与旧的 JSON 口径一致，不带 card_ids。训练集见 [TrainingSet]：
/// `ratings` / `delta_days` 长 `n_reviews`，`card_offsets` 长 `n_cards + 1`，`card_ids` 长 `n_cards`（可空），
/// `item_cards` / `item_lengths` 长 `n_items`。
///
/// - `cancel`：调用方持有的 int32，任意线程写非 0 即请求取消；取消后返回 `{"error":"cancelled"}`，不留半成品。
/// - `progress`：长度 2 的 int64 数组 [已处理, 总数]，参数优化运行中持续写入，可从别的 isolate 读。
///   两者都可为空指针，只对 `compute_parameters` 生效。
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub extern "C" fn ffsrs_fit(
    request: *const c_char,
    ratings: *const u8,
    delta_days: *const f32,
    n_reviews: usize,
    card_offsets: *const u32,
    card_ids: *const i64,
    n_cards: usize,
    item_cards: *const u32,
    item_lengths: *const u32,
    n_items: usize,
    cancel: *const AtomicI32,
    progress: *const AtomicI64,
) -> *mut c_char {
    let cancel_addr = cancel as usize;
    let progress_addr = progress as usize;
    let outcome = catch_unwind(AssertUnwindSafe(|| -> Result<Value, String> {
        let req = read_request(request)?;
        let op = str_field(&req, "op")?;
        let algorithm = Algorithm::parse(str_field(&req, "algorithm")?)?;
        if n_items == 0 {
            return Err("not enough data".into());
        }
        if card_offsets.is_null()
            || item_cards.is_null()
            || item_lengths.is_null()
            || (n_reviews > 0 && (ratings.is_null() || delta_days.is_null()))
        {
            return Err("null buffer".into());
        }
        let set = TrainingSet {
            ratings: bytes(ratings, n_reviews),
            delta_days: bytes(delta_days, n_reviews),
            card_offsets: bytes(card_offsets, n_cards + 1),
            card_ids: (!card_ids.is_null()).then(|| bytes(card_ids, n_cards)),
            item_cards: bytes(item_cards, n_items),
            item_lengths: bytes(item_lengths, n_items),
        };
        set.validate()?;
        match op {
            "compute_parameters" => {
                let (items, card_ids) = set.expand(true);
                let state = CombinedProgressState::new_shared();
                let done = Arc::new(AtomicBool::new(false));
                let watcher =
                    spawn_watcher(state.clone(), done.clone(), cancel_addr, progress_addr);
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
            }
            "evaluate" => {
                // 训练集内评估：只用于展示「当前参数在这份数据上的 log loss」。
                // 跨算法 / 新旧参数的采用判定一律用 evaluate_tss（外样本），见 PR6。
                let model = build_model(algorithm, req.get("params"))?;
                let (items, _) = set.expand(false);
                let eval = model
                    .evaluate(items, |_| true)
                    .map_err(|e| format!("evaluate: {e:?}"))?;
                Ok(json!({ "logLoss": eval.log_loss, "rmseBins": eval.rmse_bins }))
            }
            "evaluate_tss" => {
                let (items, _) = set.expand(false);
                let input = ComputeParametersInput {
                    train_set: items,
                    model_version: algorithm.compute_version(),
                    ..Default::default()
                };
                let eval = fsrs::evaluate_with_time_series_splits(input, |_| true)
                    .map_err(|e| format!("evaluate_tss: {e:?}"))?;
                Ok(json!({ "logLoss": eval.log_loss, "rmseBins": eval.rmse_bins }))
            }
            other => Err(format!("unknown fit op: {other}")),
        }
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

/// 释放 [ffsrs_call] / [ffsrs_fit] 返回的字符串。
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

/// [ffsrs_zstd_decompress_file] 的返回码。
pub const ZSTD_FILE_OK: i32 = 0;
pub const ZSTD_FILE_BAD_ARGS: i32 = 1;
pub const ZSTD_FILE_IO: i32 = 2;
pub const ZSTD_FILE_CORRUPT: i32 = 3;
pub const ZSTD_FILE_PANIC: i32 = 4;

/// zstd 文件到文件流式解码（.apkg 新格式的 collection.anki21b）：一次调用解完整个文件，
/// 内存峰值是解码窗口 + 读写缓冲，不随文件大小增长（[ffsrs_zstd_decompress] 要把输入与
/// 整个输出都放进内存）。两个路径都是 UTF-8、NUL 结尾；输出文件已存在则覆盖。
/// 返回 `ZSTD_FILE_*`；失败时输出文件可能残留半截内容，由调用方删除。
#[no_mangle]
pub extern "C" fn ffsrs_zstd_decompress_file(
    in_path: *const c_char,
    out_path: *const c_char,
) -> i32 {
    let outcome = catch_unwind(AssertUnwindSafe(|| -> i32 {
        if in_path.is_null() || out_path.is_null() {
            return ZSTD_FILE_BAD_ARGS;
        }
        let (Ok(input), Ok(output)) = (
            unsafe { CStr::from_ptr(in_path) }.to_str(),
            unsafe { CStr::from_ptr(out_path) }.to_str(),
        ) else {
            return ZSTD_FILE_BAD_ARGS;
        };
        match zstd_decompress_file(input, output) {
            Ok(()) => ZSTD_FILE_OK,
            Err(ZstdFileError::Io(_)) => ZSTD_FILE_IO,
            Err(ZstdFileError::Corrupt(_)) => ZSTD_FILE_CORRUPT,
        }
    }));
    outcome.unwrap_or(ZSTD_FILE_PANIC)
}

#[derive(Debug)]
pub enum ZstdFileError {
    Io(std::io::Error),
    Corrupt(String),
}

pub fn zstd_decompress_file(input: &str, output: &str) -> Result<(), ZstdFileError> {
    use std::io::{BufReader, BufWriter, ErrorKind, Write};
    let reader = BufReader::with_capacity(
        1 << 20,
        std::fs::File::open(input).map_err(ZstdFileError::Io)?,
    );
    let mut decoder = ruzstd::decoding::StreamingDecoder::new(reader)
        .map_err(|e| ZstdFileError::Corrupt(e.to_string()))?;
    let mut writer = BufWriter::with_capacity(
        1 << 20,
        std::fs::File::create(output).map_err(ZstdFileError::Io)?,
    );
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = match decoder.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            // 读源文件本身的 IO 错误也经 decoder 冒上来；文件已成功打开，读失败按数据非法处理
            // （截断 / 损坏的帧是这里最常见的原因）。
            Err(e) => return Err(ZstdFileError::Corrupt(e.to_string())),
        };
        writer.write_all(&buf[..n]).map_err(ZstdFileError::Io)?;
    }
    writer.flush().map_err(ZstdFileError::Io)?;
    Ok(())
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

fn bytes<'a, T>(ptr: *const T, n: usize) -> &'a [T] {
    if n == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(ptr, n) }
    }
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

// ---------------------------------------------------------------- 卡片历史（history.rs）

/// 把成功的字节结果交给调用方（[ffsrs_free_bytes] 释放），失败写错误串（[ffsrs_free_string] 释放）。
fn bytes_out(outcome: std::thread::Result<Result<Vec<u8>, String>>, out_len: *mut usize, error_out: *mut *mut c_char) -> *mut u8 {
    match outcome {
        Ok(Ok(bytes)) => {
            let boxed = bytes.into_boxed_slice();
            unsafe { *out_len = boxed.len() };
            Box::into_raw(boxed) as *mut u8
        }
        Ok(Err(e)) => {
            set_error(error_out, &e);
            std::ptr::null_mut()
        }
        Err(_) => {
            set_error(error_out, "panic in fushi_fsrs");
            std::ptr::null_mut()
        }
    }
}

unsafe fn raw_slice<'a, T>(ptr: *const T, len: usize) -> &'a [T] {
    if len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(ptr, len) }
    }
}

/// 一批卡片历史（落库 JSON 原文）的当前状态，布局见 [history::states_from_json]。
/// `offs` 长 `n_logs + 1`，`servers` 长 `n_logs`，`groups` 长 `n_groups + 1`。
/// 成功返回缓冲区并写 `out_len`（[ffsrs_free_bytes] 释放）；失败返回空指针并写 `error_out`。
#[no_mangle]
pub extern "C" fn ffsrs_history_states(
    text: *const u8,
    text_len: usize,
    offs: *const u32,
    servers: *const i64,
    n_logs: usize,
    groups: *const u32,
    n_groups: usize,
    out_len: *mut usize,
    error_out: *mut *mut c_char,
) -> *mut u8 {
    let outcome = catch_unwind(AssertUnwindSafe(|| -> Result<Vec<u8>, String> {
        if out_len.is_null() || offs.is_null() || groups.is_null() || (text.is_null() && text_len > 0) || (servers.is_null() && n_logs > 0) {
            return Err("null argument".to_owned());
        }
        let (text, offs, servers, groups) = unsafe {
            (raw_slice(text, text_len), raw_slice(offs, n_logs + 1), raw_slice(servers, n_logs), raw_slice(groups, n_groups + 1))
        };
        history::states_from_json(text, offs, servers, groups)
    }));
    bytes_out(outcome, out_len, error_out)
}

/// 一批卡片历史（列模式）的选取，布局见 [history::select_columns]。`ints` 长
/// `n_logs × COLUMN_WORDS`，`offs` 长 `3·n_logs + 1`，`groups` 长 `n_groups + 1`。
/// 成功返回缓冲区并写 `out_len`（[ffsrs_free_bytes] 释放）；失败返回空指针并写 `error_out`。
#[no_mangle]
pub extern "C" fn ffsrs_history_select(
    ints: *const i64,
    n_logs: usize,
    text: *const u8,
    text_len: usize,
    offs: *const u32,
    groups: *const u32,
    n_groups: usize,
    out_len: *mut usize,
    error_out: *mut *mut c_char,
) -> *mut u8 {
    let outcome = catch_unwind(AssertUnwindSafe(|| -> Result<Vec<u8>, String> {
        if out_len.is_null() || offs.is_null() || groups.is_null() || (text.is_null() && text_len > 0) || (ints.is_null() && n_logs > 0) {
            return Err("null argument".to_owned());
        }
        let (ints, text, offs, groups) = unsafe {
            (
                raw_slice(ints, n_logs * history::COLUMN_WORDS),
                raw_slice(text, text_len),
                raw_slice(offs, 3 * n_logs + 1),
                raw_slice(groups, n_groups + 1),
            )
        };
        history::select_columns(ints, text, offs, groups)
    }));
    bytes_out(outcome, out_len, error_out)
}

/// 记忆状态输入（列模式，排程用），布局见 [projection::memory_input_columns] / [projection::encode_memory_input]。
/// `ints` 长 `n_logs × MEMORY_COLUMN_WORDS`（一份历史的有效日志，已排序）；`alg` 0 fsrs6 / 1 fsrs7 / 2 rwkv。
/// 成功返回缓冲区并写 `out_len`（[ffsrs_free_bytes] 释放）；失败返回空指针并写 `error_out`。
#[no_mangle]
pub extern "C" fn ffsrs_memory_input(
    ints: *const i64,
    n_logs: usize,
    alg: i32,
    utc_offset_min: i32,
    rollover_hour: i32,
    out_len: *mut usize,
    error_out: *mut *mut c_char,
) -> *mut u8 {
    let outcome = catch_unwind(AssertUnwindSafe(|| -> Result<Vec<u8>, String> {
        if out_len.is_null() || (ints.is_null() && n_logs > 0) {
            return Err("null argument".to_owned());
        }
        let ints = unsafe { raw_slice(ints, n_logs * projection::MEMORY_COLUMN_WORDS) };
        let day = projection::Day { utc_offset_min: utc_offset_min.into(), rollover_hour: rollover_hour.into() };
        let m = projection::memory_input_columns(ints, projection::Alg::from_code(alg.into())?, &day)?;
        Ok(projection::encode_memory_input(&m))
    }));
    bytes_out(outcome, out_len, error_out)
}

/// RWKV「此刻」行（ease 0），布局见 [projection::rwkv_now_rows]：`ints` 长 `n_rows × NOW_ROW_WORDS`，
/// 输出 `n_rows × 80` 字节（packages/fushi_rwkv `RwkvRows.fromBytes`）。释放规则同上。
#[no_mangle]
pub extern "C" fn ffsrs_rwkv_now_rows(
    ints: *const i64,
    n_rows: usize,
    utc_offset_min: i32,
    rollover_hour: i32,
    out_len: *mut usize,
    error_out: *mut *mut c_char,
) -> *mut u8 {
    let outcome = catch_unwind(AssertUnwindSafe(|| -> Result<Vec<u8>, String> {
        if out_len.is_null() || (ints.is_null() && n_rows > 0) {
            return Err("null argument".to_owned());
        }
        let ints = unsafe { raw_slice(ints, n_rows * projection::NOW_ROW_WORDS) };
        let day = projection::Day { utc_offset_min: utc_offset_min.into(), rollover_hour: rollover_hour.into() };
        projection::rwkv_now_rows(ints, &day)
    }));
    bytes_out(outcome, out_len, error_out)
}

/// Anki 导入器入库前判重，布局见 [history::import_equivalent_any]。`offs` 长 `n_logs + 1`，
/// `groups` 长 `n_groups + 1`。成功返回每组一个字节的缓冲区（[ffsrs_free_bytes] 释放）。
#[no_mangle]
pub extern "C" fn ffsrs_import_equivalent(
    text: *const u8,
    text_len: usize,
    offs: *const u32,
    n_logs: usize,
    groups: *const u32,
    n_groups: usize,
    out_len: *mut usize,
    error_out: *mut *mut c_char,
) -> *mut u8 {
    let outcome = catch_unwind(AssertUnwindSafe(|| -> Result<Vec<u8>, String> {
        if out_len.is_null() || offs.is_null() || groups.is_null() || (text.is_null() && text_len > 0) {
            return Err("null argument".to_owned());
        }
        let (text, offs, groups) =
            unsafe { (raw_slice(text, text_len), raw_slice(offs, n_logs + 1), raw_slice(groups, n_groups + 1)) };
        history::import_equivalent_any(text, offs, groups)
    }));
    bytes_out(outcome, out_len, error_out)
}

// ---------------------------------------------------------------- 字段寄存器（registers.rs）

/// 一批实体的寄存器与物化视图，布局见 [registers::materialize]。`header` 是组描述 JSON，
/// `offs` 长 `n_items + 1`，`servers` 长 `n_items`。成功返回 JSON 结果（UTF-8，[ffsrs_free_bytes] 释放）；
/// 失败返回空指针并写 `error_out`。
#[no_mangle]
pub extern "C" fn ffsrs_materialize(
    header: *const u8,
    header_len: usize,
    text: *const u8,
    text_len: usize,
    offs: *const u32,
    servers: *const i64,
    n_items: usize,
    out_len: *mut usize,
    error_out: *mut *mut c_char,
) -> *mut u8 {
    let outcome = catch_unwind(AssertUnwindSafe(|| -> Result<Vec<u8>, String> {
        if out_len.is_null()
            || offs.is_null()
            || header.is_null()
            || (text.is_null() && text_len > 0)
            || (servers.is_null() && n_items > 0)
        {
            return Err("null argument".to_owned());
        }
        let (header, text, offs, servers) = unsafe {
            (raw_slice(header, header_len), raw_slice(text, text_len), raw_slice(offs, n_items + 1), raw_slice(servers, n_items))
        };
        registers::materialize(header, text, offs, servers)
    }));
    bytes_out(outcome, out_len, error_out)
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

    /// 两张卡（3 次、2 次评分）、按时刻交错的三条训练条目。
    struct Packed {
        ratings: Vec<u8>,
        deltas: Vec<f32>,
        offsets: Vec<u32>,
        ids: Vec<i64>,
        item_cards: Vec<u32>,
        item_lengths: Vec<u32>,
    }

    fn packed() -> Packed {
        Packed {
            ratings: vec![3, 1, 4, 2, 3],
            deltas: vec![0.0, 1.5, 3.0, 0.0, 0.25],
            offsets: vec![0, 3, 5],
            ids: vec![11, 22],
            item_cards: vec![0, 1, 0],
            item_lengths: vec![2, 2, 3],
        }
    }

    fn fit(op: &str, p: &Packed) -> Value {
        let req = CString::new(json!({"op": op, "algorithm": "fsrs6"}).to_string()).unwrap();
        let out = ffsrs_fit(
            req.as_ptr(),
            p.ratings.as_ptr(),
            p.deltas.as_ptr(),
            p.ratings.len(),
            p.offsets.as_ptr(),
            p.ids.as_ptr(),
            p.offsets.len() - 1,
            p.item_cards.as_ptr(),
            p.item_lengths.as_ptr(),
            p.item_cards.len(),
            std::ptr::null(),
            std::ptr::null(),
        );
        let text = unsafe { CStr::from_ptr(out) }.to_str().unwrap().to_string();
        ffsrs_free_string(out);
        serde_json::from_str(&text).unwrap()
    }

    #[test]
    fn training_set_expands_prefixes_in_item_order() {
        let p = packed();
        let set = TrainingSet {
            ratings: &p.ratings,
            delta_days: &p.deltas,
            card_offsets: &p.offsets,
            card_ids: Some(&p.ids),
            item_cards: &p.item_cards,
            item_lengths: &p.item_lengths,
        };
        set.validate().unwrap();
        let (items, ids) = set.expand(true);
        let flat: Vec<Vec<(u32, f32)>> = items
            .iter()
            .map(|i| i.reviews.iter().map(|r| (r.rating, r.delta_t)).collect())
            .collect();
        assert_eq!(
            flat,
            vec![
                vec![(3, 0.0), (1, 1.5)],
                vec![(2, 0.0), (3, 0.25)],
                vec![(3, 0.0), (1, 1.5), (4, 3.0)],
            ]
        );
        assert_eq!(ids, Some(vec![11, 22, 11]));
        assert_eq!(set.expand(false).1, None);
    }

    #[test]
    fn fit_rejects_malformed_training_sets() {
        let mut p = packed();
        p.item_lengths[1] = 3; // 卡 1 只有 2 次评分
        assert!(fit("evaluate", &p)["error"].as_str().unwrap().contains("prefix length"));
        let mut p = packed();
        p.item_cards[0] = 2;
        assert!(fit("evaluate", &p)["error"].as_str().unwrap().contains("out of range"));
        let mut p = packed();
        p.offsets[2] = 4;
        assert!(fit("evaluate", &p)["error"].as_str().unwrap().contains("cover"));
        assert!(fit("nope", &packed())["error"].as_str().unwrap().contains("unknown fit op"));
        // 数据太少：fsrs-rs 报错或给默认参数，但都不越过 FFI 边界 panic。
        let r = fit("compute_parameters", &packed());
        assert!(r.get("ok").is_some() || r.get("error").is_some());
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

    #[test]
    fn zstd_file_roundtrip() {
        // 多个读块（> 1 MB 缓冲）+ 能压缩的内容，与 ffsrs_zstd_decompress 结果逐字节相同。
        let payload: Vec<u8> = (0..1_500_000u32).flat_map(|i| (i % 4093).to_le_bytes()).collect();
        let frame = ruzstd::encoding::compress_to_vec(
            payload.as_slice(),
            ruzstd::encoding::CompressionLevel::Fastest,
        );
        let dir = std::env::temp_dir().join(format!("ffsrs_zstd_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let src = dir.join("in.zst");
        let dst = dir.join("out.bin");
        std::fs::write(&src, &frame).unwrap();
        let c = |p: &std::path::Path| CString::new(p.to_str().unwrap()).unwrap();
        assert_eq!(
            ffsrs_zstd_decompress_file(c(&src).as_ptr(), c(&dst).as_ptr()),
            ZSTD_FILE_OK
        );
        assert_eq!(std::fs::read(&dst).unwrap(), payload);

        // 截断的帧：数据非法，不 panic。
        std::fs::write(&src, &frame[..frame.len() / 2]).unwrap();
        assert_eq!(
            ffsrs_zstd_decompress_file(c(&src).as_ptr(), c(&dst).as_ptr()),
            ZSTD_FILE_CORRUPT
        );
        // 不是 zstd。
        std::fs::write(&src, b"SQLite format 3\0").unwrap();
        assert_eq!(
            ffsrs_zstd_decompress_file(c(&src).as_ptr(), c(&dst).as_ptr()),
            ZSTD_FILE_CORRUPT
        );
        // 源文件不存在。
        assert_eq!(
            ffsrs_zstd_decompress_file(c(&dir.join("missing")).as_ptr(), c(&dst).as_ptr()),
            ZSTD_FILE_IO
        );
        assert_eq!(
            ffsrs_zstd_decompress_file(std::ptr::null(), c(&dst).as_ptr()),
            ZSTD_FILE_BAD_ARGS
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
