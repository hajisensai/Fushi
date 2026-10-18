// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! Fushi RWKV-Instant 原生推理库：上游 RWKV 调度（kuma3-anki-core 的
//! `rslib/src/rwkv`，AGPL-3.0-or-later）推理核心的薄封装 + C ABI。
//!
//! 设计：
//! - 只做 **RWKV-Instant**：整段复习历史按时间顺序回放（[RwkvRuntime::replay]）进模型，
//!   维护 card / note / deck / preset / global 五层循环状态；排队时对候选卡做一次只算
//!   R（回忆概率）的批量查询（[RwkvRuntime::query]），R ≤ 目标保留率即到期。
//!   不做 RWKV-Curve（区间求解 / PAVA）、不做 workload 模拟、不碰 SQLite。
//! - 数值代码在 `src/rwkv/`，逐字搬自上游（见 UPSTREAM.md）；本文件只做输入校验、
//!   线程数控制、快照封装与 C ABI，**不含任何数值计算**。
//! - C ABI 热路径用 `#[repr(C)]` 结构体数组（[FrwkvReview]）而不是 JSON：
//!   全量回放可能是几百万条复习。
//! - 所有 `extern "C"` 函数都 `catch_unwind`，panic 不越过 FFI 边界；回放途中 panic
//!   的 runtime 标记为 poisoned（之后只接受 reset / restore / free）。
//! - 错误信息：返回码 < 0 时，[frwkv_last_error] 取本线程最近一次错误的可读文本。
//! - 一个 runtime 不是线程安全的：同一 runtime 的调用由调用方串行化；model 句柄可共享。
//!
//! 导出符号：
//!   frwkv_abi_version / frwkv_review_struct_size /
//!   frwkv_model_load / frwkv_model_free /
//!   frwkv_runtime_new / frwkv_runtime_free / frwkv_runtime_replay / frwkv_runtime_query /
//!   frwkv_runtime_snapshot / frwkv_runtime_restore / frwkv_runtime_reset / frwkv_runtime_stats /
//!   frwkv_last_error / frwkv_free_string / frwkv_free_bytes

use std::cell::RefCell;
use std::ffi::{c_char, CString};
use std::io;
use std::panic::{catch_unwind, AssertUnwindSafe};

// 上游在 `cfg(test)` 下额外编译 aarch64/macOS 的批量查询路径（给它自己的对拍测试用），
// 本 crate 的测试在 tests/ 里、不调用它们，x86 上的 lib test 构建就只剩 dead_code 告警。
// let_and_return：删掉上游 `cfg(test)` 打点语句后，`let heads = ..; heads` 这类写法留了下来；
// manual_is_multiple_of：上游 aarch64 内核里的 `x % n == 0`。数值代码保持逐字搬运，不为 lint 改写。
#[cfg_attr(test, allow(dead_code))]
#[allow(clippy::let_and_return, clippy::manual_is_multiple_of)]
mod rwkv;

pub use rwkv::{ReviewInput, RwkvInference, RwkvModel, RwkvStats, StatePrecision};

/// C ABI 版本。Dart 侧加载时比对，不一致视为库不可用（不崩）。
pub const ABI_VERSION: i32 = 1;

/// 搬运来源（写进 UPSTREAM.md，运行时可查）。
pub const UPSTREAM_REPO: &str = "https://github.com/Pedrubik2000/kuma3-anki-core";
pub const UPSTREAM_SHA: &str = "c639bcec696f2317f9bb9a736d433b9d6c0d9c56";
/// 通用预训练权重（`RWKV_trained_on_5000_10000.bin`，11,082,637 字节）的 SHA-256。
pub const MODEL_SHA256: &str = "749ad1ad18d5b6ef8c4185802fa0c1e4a14e67cd7874f3efeaae355fffb1b9ec";

// ---------------------------------------------------------------------------
// Rust API
// ---------------------------------------------------------------------------

/// 一个用户（一个 collection）的 RWKV 状态 + 跑它用的线程池。
pub struct RwkvRuntime {
    inference: RwkvInference,
    /// `None` = rayon 全局池（核数个线程）。
    pool: Option<rayon::ThreadPool>,
    /// 回放途中 panic 过：状态可能只更新了一半。
    poisoned: bool,
}

/// [RwkvRuntime] 的错误。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RwkvError {
    /// 输入不合法（整批未应用）。
    Input(String),
    /// 快照 / 权重字节损坏或不匹配。
    Data(String),
    /// 之前一次调用 panic，状态不可信；需 reset 或 restore。
    Poisoned,
}

impl std::fmt::Display for RwkvError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Input(message) => write!(f, "invalid input: {message}"),
            Self::Data(message) => write!(f, "invalid data: {message}"),
            Self::Poisoned => write!(
                f,
                "runtime state is unusable after an earlier panic; reset or restore a snapshot"
            ),
        }
    }
}

impl std::error::Error for RwkvError {}

impl From<io::Error> for RwkvError {
    fn from(error: io::Error) -> Self {
        Self::Data(error.to_string())
    }
}

impl RwkvRuntime {
    /// `threads == 0`：用 rayon 全局池；否则建一个专用池（墨水屏 / 低端机可传 1）。
    /// 线程数不影响数值：上游的并行全是逐行 map，没有跨线程浮点归约。
    pub fn new(
        model: &RwkvModel,
        precision: StatePrecision,
        threads: usize,
    ) -> Result<Self, RwkvError> {
        let pool = if threads == 0 {
            None
        } else {
            Some(
                rayon::ThreadPoolBuilder::new()
                    .num_threads(threads)
                    .thread_name(|index| format!("fushi-rwkv-{index}"))
                    .build()
                    .map_err(|error| RwkvError::Data(format!("thread pool: {error}")))?,
            )
        };
        Ok(Self {
            inference: RwkvInference::new(model, precision),
            pool,
            poisoned: false,
        })
    }

    pub fn precision(&self) -> StatePrecision {
        self.inference.precision()
    }

    /// 按时间顺序追加一批已答复习（`is_query` 被忽略并当作 false）。
    ///
    /// 校验整批通过才应用（否则 [RwkvError::Input]，状态不变）：
    /// - `ease`：`None`（无评分的 revlog 行，与上游一样被跳过）或 1..=4；
    /// - 有评分的行必须带 `day_offset`，且不早于上一条已回放复习的 `day_offset`；
    /// - `current_elapsed_days` / `current_elapsed_seconds`：`None` 或 ≥ -1（-1 = 首次）；
    /// - `duration_millis`：`None` 或 ≥ 0；`card_type`：`None` 或 0..=5。
    ///
    /// `record_predictions = true` 时返回每条有评分行**作答前**的 R（下标为该行在
    /// `reviews` 中的位置）；与上游 `warm_up_reviews` 完全一致。
    pub fn replay(
        &mut self,
        reviews: &[ReviewInput],
        record_predictions: bool,
    ) -> Result<Vec<(usize, f32)>, RwkvError> {
        if self.poisoned {
            return Err(RwkvError::Poisoned);
        }
        let mut last_day = self.inference.last_day_offset();
        let mut inputs = Vec::with_capacity(reviews.len());
        for (index, review) in reviews.iter().enumerate() {
            let mut input = review.clone();
            input.is_query = false;
            if input.ease.is_some() {
                validate_answer(&input, last_day)
                    .map_err(|message| RwkvError::Input(format!("review {index}: {message}")))?;
                last_day = input.day_offset;
            }
            inputs.push(input);
        }
        let Self {
            inference,
            pool,
            poisoned,
        } = self;
        let outcome = catch_unwind(AssertUnwindSafe(|| {
            install(pool, || {
                inference.warm_up_reviews(inputs, record_predictions)
            })
        }));
        match outcome {
            Ok(result) => Ok(result?),
            Err(panic) => {
                *poisoned = true;
                std::panic::resume_unwind(panic)
            }
        }
    }

    /// 批量查询当前 R。返回与 `queries` 等长；不合法的行给 `NaN`：
    /// 缺 `day_offset`、`day_offset` 早于最后一条已回放复习、
    /// `current_elapsed_*` < -1，或模型算出非有限值 / 不在 [0, 1]。
    /// `ease` / `duration_millis` / `card_type` 对查询无意义，被忽略。
    ///
    /// 注意：查询**不是纯函数**——第一次见到的 card/note/deck/preset id 会从上游的
    /// ID 编码随机流里取一段编码（与上游一致）。同一组调用顺序 → 同一结果。
    pub fn query(&mut self, queries: &[ReviewInput]) -> Result<Vec<f32>, RwkvError> {
        if self.poisoned {
            return Err(RwkvError::Poisoned);
        }
        let last_day = self.inference.last_day_offset();
        let mut out = vec![f32::NAN; queries.len()];
        let mut valid_rows = Vec::with_capacity(queries.len());
        let mut inputs = Vec::with_capacity(queries.len());
        for (index, query) in queries.iter().enumerate() {
            if !query_is_valid(query, last_day) {
                continue;
            }
            let mut input = query.clone();
            input.is_query = true;
            input.ease = None;
            input.duration_millis = None;
            valid_rows.push(index);
            inputs.push(input);
        }
        if inputs.is_empty() {
            return Ok(out);
        }
        let Self {
            inference,
            pool,
            poisoned,
        } = self;
        let outcome = catch_unwind(AssertUnwindSafe(|| {
            install(pool, || {
                inference.predict_retrievability_many_from_warm_up(inputs)
            })
        }));
        let values = match outcome {
            Ok(result) => result?,
            Err(panic) => {
                // 查询只会改 ID 编码表；保守起见同样视为不可信。
                *poisoned = true;
                std::panic::resume_unwind(panic)
            }
        };
        for (row, value) in valid_rows.into_iter().zip(values) {
            if value.is_finite() && (0.0..=1.0).contains(&value) {
                out[row] = value;
            }
        }
        Ok(out)
    }

    /// 无损快照（格式见 [RwkvInference::snapshot]）。
    pub fn snapshot(&self) -> Result<Vec<u8>, RwkvError> {
        if self.poisoned {
            return Err(RwkvError::Poisoned);
        }
        Ok(self.inference.snapshot())
    }

    /// 用快照替换当前状态（同时解除 poisoned）。失败时状态不变。
    pub fn restore(&mut self, bytes: &[u8]) -> Result<(), RwkvError> {
        self.inference.restore_snapshot(bytes)?;
        self.poisoned = false;
        Ok(())
    }

    /// 回到新建时的空状态（同时解除 poisoned）。
    pub fn reset(&mut self) {
        self.inference.reset();
        self.poisoned = false;
    }

    pub fn stats(&self) -> RwkvStats {
        self.inference.stats()
    }
}

fn install<R: Send>(pool: &Option<rayon::ThreadPool>, f: impl FnOnce() -> R + Send) -> R {
    match pool {
        Some(pool) => pool.install(f),
        None => f(),
    }
}

fn validate_answer(input: &ReviewInput, last_day: Option<i64>) -> Result<(), String> {
    let ease = input.ease.unwrap_or(0);
    if !(1..=4).contains(&ease) {
        return Err(format!("ease {ease} is not 1..=4"));
    }
    let Some(day) = input.day_offset else {
        return Err("missing day_offset".into());
    };
    if let Some(last) = last_day {
        if day < last {
            return Err(format!(
                "day_offset {day} is earlier than the last replayed review ({last}); replay must be chronological"
            ));
        }
    }
    if input.current_elapsed_days.is_some_and(|d| d < -1)
        || input.current_elapsed_seconds.is_some_and(|s| s < -1)
    {
        return Err("elapsed values must be >= -1".into());
    }
    if input.duration_millis.is_some_and(|d| d < 0) {
        return Err("negative duration_millis".into());
    }
    if input.card_type.is_some_and(|t| !(0..=5).contains(&t)) {
        return Err("card_type must be 0..=5".into());
    }
    Ok(())
}

fn query_is_valid(input: &ReviewInput, last_day: Option<i64>) -> bool {
    let Some(day) = input.day_offset else {
        return false;
    };
    if last_day.is_some_and(|last| day < last) {
        return false;
    }
    !(input.current_elapsed_days.is_some_and(|d| d < -1)
        || input.current_elapsed_seconds.is_some_and(|s| s < -1))
}

// ---------------------------------------------------------------------------
// C ABI
// ---------------------------------------------------------------------------

/// 成功。
pub const FRWKV_OK: i32 = 0;
/// 空指针 / 未知 precision 等调用错误。
pub const FRWKV_ERR_ARGUMENT: i32 = -1;
/// 输入行不合法（整批未应用）。
pub const FRWKV_ERR_INPUT: i32 = -2;
/// 快照 / 权重字节损坏或不匹配。
pub const FRWKV_ERR_DATA: i32 = -3;
/// 内部 panic（已接住）。
pub const FRWKV_ERR_PANIC: i32 = -4;
/// runtime 在之前的 panic 后不可用：调 reset 或 restore。
pub const FRWKV_ERR_POISONED: i32 = -5;

/// [FrwkvReview::present] 的位：对应字段有值（否则视为上游的 `None`）。
pub const FRWKV_HAS_NOTE_ID: u32 = 1 << 0;
pub const FRWKV_HAS_DECK_ID: u32 = 1 << 1;
pub const FRWKV_HAS_PRESET_ID: u32 = 1 << 2;
pub const FRWKV_HAS_DURATION: u32 = 1 << 3;
pub const FRWKV_HAS_CARD_TYPE: u32 = 1 << 4;
pub const FRWKV_HAS_DAY_OFFSET: u32 = 1 << 5;
pub const FRWKV_HAS_ELAPSED_DAYS: u32 = 1 << 6;
pub const FRWKV_HAS_ELAPSED_SECONDS: u32 = 1 << 7;
const FRWKV_KNOWN_BITS: u32 = (1 << 8) - 1;

/// precision 参数：f32 状态 / int8 紧凑 card+note 状态。
pub const FRWKV_PRECISION_F32: i32 = 0;
pub const FRWKV_PRECISION_INT8: i32 = 8;

/// 一条复习（回放）或一条查询，80 字节，字段语义见 README.md。
/// 可选字段由 `present` 位标记；`ease == 0` 表示无评分（回放时跳过，查询时忽略）。
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct FrwkvReview {
    pub card_id: i64,
    pub note_id: i64,
    pub deck_id: i64,
    pub preset_id: i64,
    pub duration_millis: i64,
    pub card_type: i64,
    pub day_offset: i64,
    pub elapsed_days: i64,
    pub elapsed_seconds: i64,
    pub present: u32,
    pub ease: u8,
    pub reserved: [u8; 3],
}

const _: () = assert!(std::mem::size_of::<FrwkvReview>() == 80);

impl FrwkvReview {
    fn field(&self, bit: u32, value: i64) -> Option<i64> {
        (self.present & bit != 0).then_some(value)
    }

    /// 转成上游的 `ReviewInput`。未知的 `present` 位 → `None`。
    pub fn to_input(&self, is_query: bool) -> Option<ReviewInput> {
        if self.present & !FRWKV_KNOWN_BITS != 0 {
            return None;
        }
        Some(ReviewInput {
            card_id: self.card_id,
            note_id: self.field(FRWKV_HAS_NOTE_ID, self.note_id),
            deck_id: self.field(FRWKV_HAS_DECK_ID, self.deck_id),
            preset_id: self.field(FRWKV_HAS_PRESET_ID, self.preset_id),
            is_query,
            ease: (self.ease != 0).then_some(self.ease),
            duration_millis: self.field(FRWKV_HAS_DURATION, self.duration_millis),
            card_type: self.field(FRWKV_HAS_CARD_TYPE, self.card_type),
            day_offset: self.field(FRWKV_HAS_DAY_OFFSET, self.day_offset),
            current_elapsed_days: self.field(FRWKV_HAS_ELAPSED_DAYS, self.elapsed_days),
            current_elapsed_seconds: self.field(FRWKV_HAS_ELAPSED_SECONDS, self.elapsed_seconds),
        })
    }

    /// [Self::to_input] 的反向（测试与 Rust 调用方构造用）。
    pub fn from_input(input: &ReviewInput) -> Self {
        let mut row = Self {
            card_id: input.card_id,
            ease: input.ease.unwrap_or(0),
            ..Self::default()
        };
        let mut set = |bit: u32, value: Option<i64>, slot: &mut i64| {
            if let Some(value) = value {
                row.present |= bit;
                *slot = value;
            }
        };
        let (mut note, mut deck, mut preset, mut duration, mut card_type) = (0, 0, 0, 0, 0);
        let (mut day, mut elapsed_days, mut elapsed_seconds) = (0, 0, 0);
        set(FRWKV_HAS_NOTE_ID, input.note_id, &mut note);
        set(FRWKV_HAS_DECK_ID, input.deck_id, &mut deck);
        set(FRWKV_HAS_PRESET_ID, input.preset_id, &mut preset);
        set(FRWKV_HAS_DURATION, input.duration_millis, &mut duration);
        set(FRWKV_HAS_CARD_TYPE, input.card_type, &mut card_type);
        set(FRWKV_HAS_DAY_OFFSET, input.day_offset, &mut day);
        set(
            FRWKV_HAS_ELAPSED_DAYS,
            input.current_elapsed_days,
            &mut elapsed_days,
        );
        set(
            FRWKV_HAS_ELAPSED_SECONDS,
            input.current_elapsed_seconds,
            &mut elapsed_seconds,
        );
        row.note_id = note;
        row.deck_id = deck;
        row.preset_id = preset;
        row.duration_millis = duration;
        row.card_type = card_type;
        row.day_offset = day;
        row.elapsed_days = elapsed_days;
        row.elapsed_seconds = elapsed_seconds;
        row
    }
}

/// [frwkv_runtime_stats] 的输出。
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct FrwkvStats {
    pub reviews: i64,
    pub cards: u64,
    pub notes: u64,
    pub decks: u64,
    pub presets: u64,
    pub card_state_bytes: u64,
    pub note_state_bytes: u64,
    pub shared_state_bytes: u64,
    pub feature_state_bytes: u64,
}

/// 不透明句柄：解析好的网络。
pub struct FrwkvModel(RwkvModel);

/// 不透明句柄：一个 [RwkvRuntime]。
pub struct FrwkvRuntime(RwkvRuntime);

thread_local! {
    static LAST_ERROR: RefCell<Option<String>> = const { RefCell::new(None) };
}

fn set_last_error(message: String) {
    LAST_ERROR.with(|slot| *slot.borrow_mut() = Some(message));
}

fn panic_message(panic: &(dyn std::any::Any + Send)) -> String {
    if let Some(text) = panic.downcast_ref::<&str>() {
        format!("panic: {text}")
    } else if let Some(text) = panic.downcast_ref::<String>() {
        format!("panic: {text}")
    } else {
        "panic".to_owned()
    }
}

fn error_code(error: &RwkvError) -> i32 {
    match error {
        RwkvError::Input(_) => FRWKV_ERR_INPUT,
        RwkvError::Data(_) => FRWKV_ERR_DATA,
        RwkvError::Poisoned => FRWKV_ERR_POISONED,
    }
}

/// 跑 `f`，把 `Err` / panic 转成返回码 + last error。
fn guarded(f: impl FnOnce() -> Result<(), (i32, String)>) -> i32 {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(())) => FRWKV_OK,
        Ok(Err((code, message))) => {
            set_last_error(message);
            code
        }
        Err(panic) => {
            set_last_error(panic_message(panic.as_ref()));
            FRWKV_ERR_PANIC
        }
    }
}

fn argument(message: &str) -> (i32, String) {
    (FRWKV_ERR_ARGUMENT, message.to_owned())
}

fn rwkv_error(error: RwkvError) -> (i32, String) {
    (error_code(&error), error.to_string())
}

/// 空指针 + 长度 0 视为空切片。
///
/// # Safety
/// 非空时 `ptr` 必须指向 `len` 个有效元素。
unsafe fn slice_or_empty<'a, T>(ptr: *const T, len: usize) -> Option<&'a [T]> {
    if len == 0 {
        Some(&[])
    } else if ptr.is_null() {
        None
    } else {
        Some(std::slice::from_raw_parts(ptr, len))
    }
}

#[no_mangle]
pub extern "C" fn frwkv_abi_version() -> i32 {
    ABI_VERSION
}

/// `sizeof(FrwkvReview)`；Dart 侧用来核对结构体布局。
#[no_mangle]
pub extern "C" fn frwkv_review_struct_size() -> usize {
    std::mem::size_of::<FrwkvReview>()
}

/// 从内存里的 `ARWKVWEIGHTS1` 权重文件建模型。失败返回空指针（见 [frwkv_last_error]）。
/// 返回的句柄用 [frwkv_model_free] 释放；runtime 持有自己的引用，释放 model 不影响已建的 runtime。
///
/// # Safety
/// `bytes` 必须指向 `len` 个可读字节。
#[no_mangle]
pub unsafe extern "C" fn frwkv_model_load(bytes: *const u8, len: usize) -> *mut FrwkvModel {
    let mut model = None;
    let code = guarded(|| {
        let bytes = slice_or_empty(bytes, len).ok_or_else(|| argument("null weights"))?;
        let parsed = RwkvModel::from_bytes(bytes)
            .map_err(|error| (FRWKV_ERR_DATA, format!("weights: {error}")))?;
        model = Some(Box::new(FrwkvModel(parsed)));
        Ok(())
    });
    match model {
        Some(model) if code == FRWKV_OK => Box::into_raw(model),
        _ => std::ptr::null_mut(),
    }
}

/// # Safety
/// `model` 必须是 [frwkv_model_load] 返回且未释放过的句柄（或空指针）。
#[no_mangle]
pub unsafe extern "C" fn frwkv_model_free(model: *mut FrwkvModel) {
    if !model.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(model))));
    }
}

/// 新建 runtime。`precision`：[FRWKV_PRECISION_F32] / [FRWKV_PRECISION_INT8]；
/// `threads`：0 = 全部核心，1 = 单线程（墨水屏 / 省电）。失败返回空指针。
///
/// # Safety
/// `model` 必须是有效的 [FrwkvModel] 句柄。
#[no_mangle]
pub unsafe extern "C" fn frwkv_runtime_new(
    model: *const FrwkvModel,
    precision: i32,
    threads: u32,
) -> *mut FrwkvRuntime {
    let mut runtime = None;
    let code = guarded(|| {
        let model = model.as_ref().ok_or_else(|| argument("null model"))?;
        let precision = match precision {
            FRWKV_PRECISION_F32 => StatePrecision::F32,
            FRWKV_PRECISION_INT8 => StatePrecision::Int8,
            other => return Err(argument(&format!("unsupported precision {other}"))),
        };
        let created =
            RwkvRuntime::new(&model.0, precision, threads as usize).map_err(rwkv_error)?;
        runtime = Some(Box::new(FrwkvRuntime(created)));
        Ok(())
    });
    match runtime {
        Some(runtime) if code == FRWKV_OK => Box::into_raw(runtime),
        _ => std::ptr::null_mut(),
    }
}

/// # Safety
/// `runtime` 必须是 [frwkv_runtime_new] 返回且未释放过的句柄（或空指针）。
#[no_mangle]
pub unsafe extern "C" fn frwkv_runtime_free(runtime: *mut FrwkvRuntime) {
    if !runtime.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(runtime))));
    }
}

/// 按时间顺序追加 `count` 条已答复习。`out_predictions` 可为空；非空时须能写 `count` 个
/// f32：每条有评分行写入它**作答前**的 R，无评分行（`ease == 0`）写 NaN。
/// 任一行不合法 → [FRWKV_ERR_INPUT]，整批不应用。
///
/// # Safety
/// `runtime` 有效；`reviews` 指向 `count` 个 [FrwkvReview]；`out_predictions` 为空或可写 `count` 个 f32。
#[no_mangle]
pub unsafe extern "C" fn frwkv_runtime_replay(
    runtime: *mut FrwkvRuntime,
    reviews: *const FrwkvReview,
    count: usize,
    out_predictions: *mut f32,
) -> i32 {
    guarded(|| {
        let runtime = runtime.as_mut().ok_or_else(|| argument("null runtime"))?;
        let rows = slice_or_empty(reviews, count).ok_or_else(|| argument("null reviews"))?;
        let inputs = rows
            .iter()
            .enumerate()
            .map(|(index, row)| {
                row.to_input(false).ok_or_else(|| {
                    (
                        FRWKV_ERR_INPUT,
                        format!("invalid input: review {index}: unknown present bits"),
                    )
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        let record = !out_predictions.is_null();
        let predictions = runtime.0.replay(&inputs, record).map_err(rwkv_error)?;
        if record {
            let out = std::slice::from_raw_parts_mut(out_predictions, count);
            out.fill(f32::NAN);
            for (index, value) in predictions {
                out[index] = value;
            }
        }
        Ok(())
    })
}

/// 批量查询当前 R，写 `count` 个 f32 到 `out_retrievability`；不合法的行写 NaN
/// （规则见 README.md「查询」）。
///
/// # Safety
/// `runtime` 有效；`queries` 指向 `count` 个 [FrwkvReview]；`out_retrievability` 可写 `count` 个 f32。
#[no_mangle]
pub unsafe extern "C" fn frwkv_runtime_query(
    runtime: *mut FrwkvRuntime,
    queries: *const FrwkvReview,
    count: usize,
    out_retrievability: *mut f32,
) -> i32 {
    guarded(|| {
        let runtime = runtime.as_mut().ok_or_else(|| argument("null runtime"))?;
        let rows = slice_or_empty(queries, count).ok_or_else(|| argument("null queries"))?;
        if count > 0 && out_retrievability.is_null() {
            return Err(argument("null output"));
        }
        // 未知 present 位的行：给一个必然不合法的输入（无 day_offset）→ NaN。
        let inputs: Vec<ReviewInput> = rows
            .iter()
            .map(|row| {
                row.to_input(true).unwrap_or(ReviewInput {
                    card_id: row.card_id,
                    note_id: None,
                    deck_id: None,
                    preset_id: None,
                    is_query: true,
                    ease: None,
                    duration_millis: None,
                    card_type: None,
                    day_offset: None,
                    current_elapsed_days: None,
                    current_elapsed_seconds: None,
                })
            })
            .collect();
        let values = runtime.0.query(&inputs).map_err(rwkv_error)?;
        if count > 0 {
            std::slice::from_raw_parts_mut(out_retrievability, count).copy_from_slice(&values);
        }
        Ok(())
    })
}

/// 导出无损快照。成功时 `*out_bytes` / `*out_len` 指向新分配的缓冲区，用 [frwkv_free_bytes] 释放。
///
/// # Safety
/// `runtime` 有效；`out_bytes` / `out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn frwkv_runtime_snapshot(
    runtime: *const FrwkvRuntime,
    out_bytes: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guarded(|| {
        let runtime = runtime.as_ref().ok_or_else(|| argument("null runtime"))?;
        if out_bytes.is_null() || out_len.is_null() {
            return Err(argument("null output"));
        }
        let bytes = runtime.0.snapshot().map_err(rwkv_error)?.into_boxed_slice();
        *out_len = bytes.len();
        *out_bytes = Box::into_raw(bytes) as *mut u8;
        Ok(())
    })
}

/// 用快照替换 runtime 状态（precision 必须一致）。失败时状态不变。
///
/// # Safety
/// `runtime` 有效；`bytes` 指向 `len` 个可读字节。
#[no_mangle]
pub unsafe extern "C" fn frwkv_runtime_restore(
    runtime: *mut FrwkvRuntime,
    bytes: *const u8,
    len: usize,
) -> i32 {
    guarded(|| {
        let runtime = runtime.as_mut().ok_or_else(|| argument("null runtime"))?;
        let bytes = slice_or_empty(bytes, len).ok_or_else(|| argument("null snapshot"))?;
        runtime.0.restore(bytes).map_err(rwkv_error)
    })
}

/// 清空 runtime（等同新建）。
///
/// # Safety
/// `runtime` 有效。
#[no_mangle]
pub unsafe extern "C" fn frwkv_runtime_reset(runtime: *mut FrwkvRuntime) -> i32 {
    guarded(|| {
        let runtime = runtime.as_mut().ok_or_else(|| argument("null runtime"))?;
        runtime.0.reset();
        Ok(())
    })
}

/// # Safety
/// `runtime` 有效；`out` 可写。
#[no_mangle]
pub unsafe extern "C" fn frwkv_runtime_stats(
    runtime: *const FrwkvRuntime,
    out: *mut FrwkvStats,
) -> i32 {
    guarded(|| {
        let runtime = runtime.as_ref().ok_or_else(|| argument("null runtime"))?;
        let out = out.as_mut().ok_or_else(|| argument("null output"))?;
        let stats = runtime.0.stats();
        *out = FrwkvStats {
            reviews: stats.reviews,
            cards: stats.cards as u64,
            notes: stats.notes as u64,
            decks: stats.decks as u64,
            presets: stats.presets as u64,
            card_state_bytes: stats.card_state_bytes as u64,
            note_state_bytes: stats.note_state_bytes as u64,
            shared_state_bytes: stats.shared_state_bytes as u64,
            feature_state_bytes: stats.feature_state_bytes as u64,
        };
        Ok(())
    })
}

/// 本线程最近一次失败的可读错误（UTF-8，新分配，用 [frwkv_free_string] 释放）；没有则空指针。
#[no_mangle]
pub extern "C" fn frwkv_last_error() -> *mut c_char {
    catch_unwind(|| {
        LAST_ERROR.with(|slot| match slot.borrow().as_deref() {
            Some(message) => CString::new(message.replace('\0', " "))
                .map(CString::into_raw)
                .unwrap_or(std::ptr::null_mut()),
            None => std::ptr::null_mut(),
        })
    })
    .unwrap_or(std::ptr::null_mut())
}

/// 释放 [frwkv_last_error] 返回的字符串。
///
/// # Safety
/// `ptr` 必须来自 [frwkv_last_error]（或为空）。
#[no_mangle]
pub unsafe extern "C" fn frwkv_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(CString::from_raw(ptr))));
    }
}

/// 释放 [frwkv_runtime_snapshot] 返回的缓冲区。
///
/// # Safety
/// `ptr` / `len` 必须来自 [frwkv_runtime_snapshot]（或 `ptr` 为空）。
#[no_mangle]
pub unsafe extern "C" fn frwkv_free_bytes(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| {
            drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)))
        }));
    }
}
