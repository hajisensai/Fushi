// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! Fushi RWKV 排程原生推理库：上游 RWKV 调度（kuma3-anki-core 的
//! `rslib/src/rwkv`，AGPL-3.0-or-later）推理核心的薄封装 + SM56 小模型 + C ABI。
//!
//! 设计：
//! - 整段复习历史按时间顺序回放（[RwkvRuntime::replay]）进模型，维护 card / note / deck /
//!   preset / global 五层循环状态；R（此刻回忆概率，即时头）用批量查询（[RwkvRuntime::query]）。
//! - 作答时排程读**曲线头**（[RwkvRuntime::next_intervals]，`curve.rs`）：每个评分一次假设作答，
//!   取这次作答之后的遗忘曲线第一次 ≤ 目标保留率的天数（上游 RWKV-Curve 的区间求解与 PAVA）。
//!   不做 workload 模拟、不碰 SQLite。
//! - 数值代码在 `src/rwkv/`，逐字搬自上游（见 UPSTREAM.md）；本文件只做输入校验、
//!   线程数控制、快照封装与 C ABI，**不含任何数值计算**。
//! - C ABI 热路径用 `#[repr(C)]` 结构体数组（[FrwkvReview]）而不是 JSON：
//!   全量回放可能是几百万条复习。
//! - 所有 `extern "C"` 函数都 `catch_unwind`，panic 不越过 FFI 边界；回放途中 panic
//!   的 runtime 标记为 poisoned（之后只接受 reset / restore / free）。
//! - 错误信息：返回码 < 0 时，[frwkv_last_error] 取本线程最近一次错误的可读文本
//!   （thread-local：Dart 侧须在同一段同步代码里紧接着取，中间不能 `await`）。
//! - 一个 runtime 不是线程安全的：同一 runtime 的调用由调用方串行化；model 句柄可共享。
//!
//! 导出符号：
//!   frwkv_abi_version / frwkv_review_struct_size /
//!   frwkv_model_load / frwkv_model_kind / frwkv_model_free /
//!   frwkv_runtime_new / frwkv_runtime_free / frwkv_runtime_replay / frwkv_runtime_query /
//!   frwkv_runtime_next_intervals /
//!   frwkv_runtime_append / frwkv_runtime_unappend /
//!   frwkv_runtime_scores_clear / frwkv_runtime_scores_lookup / frwkv_runtime_scores_update /
//!   frwkv_runtime_scores_requery / frwkv_runtime_scores_remove /
//!   frwkv_runtime_snapshot / frwkv_runtime_restore / frwkv_runtime_reset / frwkv_runtime_stats /
//!   frwkv_last_error / frwkv_free_string / frwkv_free_bytes

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
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
mod curve;

pub use curve::{answer_intervals, AnswerCurve};
pub use rwkv::small::{SmallHeads, SmallInference, SmallModel, SmallUndo};
pub use rwkv::{
    forecast_query, predict_curve, ReviewInput, RwkvInference, RwkvModel, RwkvStats, StatePrecision,
};

/// C ABI 版本。Dart 侧加载时比对，不一致视为库不可用（不崩）。
/// 2：加小模型（[ModelKind::Small]）、int4 精度、[FRWKV_PRECISION_DEFAULT]、`frwkv_model_kind`、
/// `frwkv_runtime_next_intervals`。
/// 3：撤销日志（`frwkv_runtime_append` / `frwkv_runtime_unappend`）与常驻分数表
/// （`frwkv_runtime_scores_clear` / `_lookup` / `_update`）。
/// 4：快照直接走文件的流式接口（`frwkv_runtime_snapshot_to_file` /
/// `frwkv_runtime_restore_from_file`），文件格式与 `frwkv_runtime_snapshot` 的字节逐位相同。
pub const ABI_VERSION: i32 = 4;

#[cfg(test)]
mod snapshot_tests;

/// 撤销日志最多留多少字节（小模型一条约 54 KB：卡 / 笔记两份紧凑状态 + 牌组 / 预设 / 全局三份
/// f32 状态，16 MB 约 300 条）。超出时丢最早的条目；撤得比这更深的由调用方全量重建。
pub const JOURNAL_MAX_BYTES: usize = 16 << 20;

/// 分数表的一项：查询时这张卡的「版本」（调用方给，例如最后一条有效日志的 hash）、查询行、
/// 锚点（这张卡最后一条保留评分的时刻，毫秒；没有 = -1）与 R。查询行与锚点让
/// [RwkvRuntime::scores_requery] 不必回到调用方读历史就能把整张表按新的「此刻」重算。
#[derive(Clone, Debug)]
struct ScoreEntry {
    version: u64,
    note_key: i64,
    query: ReviewInput,
    anchor_ms: i64,
    score: f32,
}

/// 搬运来源（写进 UPSTREAM.md，运行时可查）。
pub const UPSTREAM_REPO: &str = "https://github.com/Pedrubik2000/kuma3-anki-core";
pub const UPSTREAM_SHA: &str = "c639bcec696f2317f9bb9a736d433b9d6c0d9c56";
/// 通用预训练权重（`RWKV_trained_on_5000_10000.bin`，11,082,637 字节）的 SHA-256。
pub const MODEL_SHA256: &str = "749ad1ad18d5b6ef8c4185802fa0c1e4a14e67cd7874f3efeaae355fffb1b9ec";
/// 小模型 SM56 发布包 `sm56-package.zip`（JSchoreels/anki-rwkv release
/// `small-model-sm56-2026-10-24`，5,581,795 字节）的 SHA-256。权重是包里的
/// `sm56/weights.int8.bin`（推荐，436,391 字节）或 `sm56/weights.f32.bin`。
pub const SMALL_MODEL_PACKAGE_SHA256: &str =
    "7b1790f49fdabf1279510247cc9bc3bf3ac461b67cf0135ab8e51589b5efe71a";

// ---------------------------------------------------------------------------
// Rust API
// ---------------------------------------------------------------------------

/// 哪个网络。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ModelKind {
    /// 2,762,884 参数的上游模型（质量优先）。
    Large,
    /// 331,511 参数的 SM56 小模型（省内存；作者 723 个留出用户上 LogLoss 比大模型高 0.34% / 0.47%）。
    Small,
}

impl ModelKind {
    /// 推荐的状态精度：大模型 int8（与 f32 的 LogLoss 差 < 0.01%），小模型 int4。
    pub fn default_precision(self) -> StatePrecision {
        match self {
            Self::Large => StatePrecision::Int8,
            Self::Small => StatePrecision::Int4,
        }
    }

    /// 这个模型能不能用该精度。大模型不支持 int4：它 card 状态第一层的递推会放大量化误差，
    /// int4 下高频卡的状态指数增长直到 f32 溢出（tests/long_history.rs：每卡 1 万次复习时峰值
    /// 1.3e16，f32 为 3.7；最小二乘比例因子也救不回）。上游 kuma3 给大模型留了 int4 card 状态。
    /// 小模型 int4 与大模型 int8 在同样的历史上与 f32 同量级。
    pub fn supports(self, precision: StatePrecision) -> bool {
        !(self == Self::Large && precision == StatePrecision::Int4)
    }
}

/// 解析好的网络（大或小），可在多个 runtime 间共享。
#[derive(Clone)]
pub enum Model {
    Large(RwkvModel),
    Small(SmallModel),
}

impl Model {
    /// 按权重文件内容识别大 / 小模型：`ARWKVWEIGHTS1`（f32，大小模型都可）或
    /// `ARWKVWEIGHTS8PC1`（int8 逐行，小模型）。
    pub fn from_bytes(bytes: &[u8]) -> io::Result<Self> {
        if SmallModel::is_small_model_file(bytes)? {
            Ok(Self::Small(SmallModel::from_bytes(bytes)?))
        } else {
            Ok(Self::Large(RwkvModel::from_bytes(bytes)?))
        }
    }

    pub fn kind(&self) -> ModelKind {
        match self {
            Self::Large(_) => ModelKind::Large,
            Self::Small(_) => ModelKind::Small,
        }
    }
}

impl From<RwkvModel> for Model {
    fn from(model: RwkvModel) -> Self {
        Self::Large(model)
    }
}

impl From<SmallModel> for Model {
    fn from(model: SmallModel) -> Self {
        Self::Small(model)
    }
}

enum Engine {
    Large(RwkvInference),
    Small(SmallInference),
}

impl Engine {
    fn precision(&self) -> StatePrecision {
        match self {
            Self::Large(inference) => inference.precision(),
            Self::Small(inference) => inference.precision(),
        }
    }

    fn last_day_offset(&self) -> Option<i64> {
        match self {
            Self::Large(inference) => inference.last_day_offset(),
            Self::Small(inference) => inference.last_day_offset(),
        }
    }

    fn warm_up_reviews(
        &mut self,
        reviews: Vec<ReviewInput>,
        record_predictions: bool,
    ) -> io::Result<Vec<(usize, f32)>> {
        match self {
            Self::Large(inference) => inference.warm_up_reviews(reviews, record_predictions),
            Self::Small(inference) => inference.warm_up_reviews(reviews, record_predictions),
        }
    }

    fn predict(&mut self, inputs: Vec<ReviewInput>) -> io::Result<Vec<f32>> {
        match self {
            Self::Large(inference) => inference.predict_retrievability_many_from_warm_up(inputs),
            Self::Small(inference) => inference.predict_retrievability_many_from_warm_up(inputs),
        }
    }

    fn forecast(
        &mut self,
        answer: &ReviewInput,
        ratings: &[u8],
        queries: &[ReviewInput],
    ) -> io::Result<Vec<f32>> {
        match self {
            Self::Large(inference) => inference.forecast(answer, ratings, queries),
            Self::Small(inference) => inference.forecast(answer, ratings, queries),
        }
    }

    fn answer_curves(&mut self, answer: &ReviewInput) -> io::Result<[AnswerCurve; 4]> {
        Ok(match self {
            Self::Large(inference) => inference.answer_curves(answer)?.map(AnswerCurve::Large),
            Self::Small(inference) => inference.answer_curves(answer)?.map(AnswerCurve::Small),
        })
    }

    fn snapshot(&self) -> Vec<u8> {
        match self {
            Self::Large(inference) => inference.snapshot(),
            Self::Small(inference) => inference.snapshot(),
        }
    }

    fn restore_snapshot(&mut self, bytes: &[u8]) -> io::Result<()> {
        match self {
            Self::Large(inference) => inference.restore_snapshot(bytes),
            Self::Small(inference) => inference.restore_snapshot(bytes),
        }
    }

    fn write_snapshot(&self, out: &mut impl io::Write) -> io::Result<()> {
        match self {
            Self::Large(inference) => inference.write_snapshot(out),
            Self::Small(inference) => inference.write_snapshot(out),
        }
    }

    fn read_snapshot(&mut self, input: &mut impl io::Read, len: u64) -> io::Result<()> {
        match self {
            Self::Large(inference) => inference.read_snapshot(input, len),
            Self::Small(inference) => inference.read_snapshot(input, len),
        }
    }

    fn reset(&mut self) {
        match self {
            Self::Large(inference) => inference.reset(),
            Self::Small(inference) => inference.reset(),
        }
    }

    fn stats(&self) -> RwkvStats {
        match self {
            Self::Large(inference) => inference.stats(),
            Self::Small(inference) => inference.stats(),
        }
    }
}

/// 一个用户（一个 collection）的 RWKV 状态 + 跑它用的线程池。
pub struct RwkvRuntime {
    inference: Engine,
    kind: ModelKind,
    /// `None` = rayon 全局池（核数个线程）。
    pool: Option<rayon::ThreadPool>,
    /// 回放途中 panic 过：状态可能只更新了一半。
    poisoned: bool,
    /// 撤销日志（[Self::append] 追加、[Self::unappend] 弹出）：(调用方给的标签, 被覆盖的状态)，
    /// 最新的在末尾。别的改状态的调用（[Self::replay] / restore / reset）清空它。
    journal: Vec<(u64, SmallUndo)>,
    journal_bytes: usize,
    /// 常驻分数表：卡 id → 上次查询的 R（[Self::scores_update]）。回放 / 撤回一条复习时，
    /// 同一张卡与同一条笔记的项作废（它们的卡 / 笔记状态变了）；牌组 / 预设 / 全局状态的变化
    /// 不作废别的项——调用方在换日、换设置、同步合并后 [Self::scores_clear] 全量刷新。
    scores: HashMap<i64, ScoreEntry>,
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
    /// 这个模型不支持该操作（撤销日志只有小模型有）。
    Unsupported(String),
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
            Self::Unsupported(message) => write!(f, "unsupported: {message}"),
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
    pub fn new(model: &Model, precision: StatePrecision, threads: usize) -> Result<Self, RwkvError> {
        if !model.kind().supports(precision) {
            return Err(RwkvError::Input(format!(
                "{:?} model does not support {precision:?} state (its card states diverge; \
                 use int8)",
                model.kind()
            )));
        }
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
        let inference = match model {
            Model::Large(model) => Engine::Large(RwkvInference::new(model, precision)),
            Model::Small(model) => Engine::Small(SmallInference::new(model, precision)),
        };
        Ok(Self {
            inference,
            kind: model.kind(),
            pool,
            poisoned: false,
            journal: Vec::new(),
            journal_bytes: 0,
            scores: HashMap::new(),
        })
    }

    pub fn precision(&self) -> StatePrecision {
        self.inference.precision()
    }

    pub fn model_kind(&self) -> ModelKind {
        self.kind
    }

    /// Diagnostics: largest absolute WKV state value over every entity of
    /// each stream (card, deck, note, preset, user); small model only.
    #[doc(hidden)]
    pub fn state_peaks(&self) -> Option<[f32; 5]> {
        match &self.inference {
            Engine::Small(inference) => Some(std::array::from_fn(|s| inference.stream_peak(s))),
            Engine::Large(_) => None,
        }
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
        self.clear_journal();
        self.invalidate_scores(inputs.iter().filter(|input| input.ease.is_some()));
        let Self {
            inference,
            pool,
            poisoned,
            ..
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
            ..
        } = self;
        let outcome = catch_unwind(AssertUnwindSafe(|| {
            install(pool, || inference.predict(inputs))
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

    /// 「如果这张卡现在以各个评分作答」之后，在 `horizons`（作答后的调度日数，同一时刻）
    /// 各处查询的 R：`ratings.len() * horizons.len()` 个值，按评分分组。什么都不保存
    /// （状态与特征簿记原样）。`answer` 的校验同 [Self::replay]（`ease` 被逐个替换）。
    pub fn forecast(
        &mut self,
        answer: &ReviewInput,
        ratings: &[u8],
        horizons: &[i64],
    ) -> Result<Vec<f32>, RwkvError> {
        if self.poisoned {
            return Err(RwkvError::Poisoned);
        }
        if ratings.iter().any(|r| !(1..=4).contains(r)) {
            return Err(RwkvError::Input("ratings must be 1..=4".into()));
        }
        if horizons.iter().any(|&d| d < 1) {
            return Err(RwkvError::Input("horizons must be >= 1 day".into()));
        }
        let mut answer = answer.clone();
        answer.is_query = false;
        answer.ease = Some(1);
        validate_answer(&answer, self.inference.last_day_offset())
            .map_err(|message| RwkvError::Input(format!("answer: {message}")))?;
        let queries: Vec<ReviewInput> = horizons
            .iter()
            .map(|&days| forecast_query(&answer, days, days * 86_400))
            .collect();
        let Self {
            inference,
            pool,
            poisoned,
            ..
        } = self;
        let outcome = catch_unwind(AssertUnwindSafe(|| {
            install(pool, || inference.forecast(&answer, ratings, &queries))
        }));
        match outcome {
            Ok(result) => Ok(result?
                .into_iter()
                .map(|r| if r.is_finite() && (0.0..=1.0).contains(&r) { r } else { f32::NAN })
                .collect()),
            Err(panic) => {
                *poisoned = true;
                std::panic::resume_unwind(panic)
            }
        }
    }

    /// 作答时排程（RWKV-Curve，见 `curve.rs`）：对 Again / Hard / Good / Easy 各做一次假设作答
    /// （不保存），读那一行曲线头给出的遗忘曲线，间隔 = R 第一次 ≤ `target_retention` 的天数
    /// （向上取整，1..=`max_interval_days`；到上限仍高于目标给上限），评分顺序修正为不减。
    /// 返回天数与曲线在该天的 R。`answer` 的校验同 [Self::replay]（`ease` 被逐个替换）。
    pub fn next_intervals(
        &mut self,
        answer: &ReviewInput,
        target_retention: f32,
        max_interval_days: u32,
    ) -> Result<([u32; 4], [f32; 4]), RwkvError> {
        if !(target_retention > 0.0 && target_retention < 1.0) {
            return Err(RwkvError::Input("target_retention must be in (0, 1)".into()));
        }
        let max = max_interval_days.max(1);
        let curves = self.answer_curves(answer)?;
        let days = curve::answer_intervals(&curves, target_retention, max);
        let at = std::array::from_fn(|index| curves[index].retrievability(days[index] as f32 * 86_400.0));
        if at.iter().any(|r: &f32| !r.is_finite()) {
            return Err(RwkvError::Data("non-finite forgetting curve".into()));
        }
        Ok((days, at))
    }

    /// [Self::next_intervals] 用的四条遗忘曲线（Again..Easy 的假设作答，不保存）。测试 / 评测用。
    #[doc(hidden)]
    pub fn answer_curves(&mut self, answer: &ReviewInput) -> Result<[AnswerCurve; 4], RwkvError> {
        if self.poisoned {
            return Err(RwkvError::Poisoned);
        }
        let mut answer = answer.clone();
        answer.is_query = false;
        answer.ease = Some(1);
        validate_answer(&answer, self.inference.last_day_offset())
            .map_err(|message| RwkvError::Input(format!("answer: {message}")))?;
        let Self {
            inference,
            pool,
            poisoned,
            ..
        } = self;
        match catch_unwind(AssertUnwindSafe(|| install(pool, || inference.answer_curves(&answer)))) {
            Ok(curves) => Ok(curves?),
            Err(panic) => {
                *poisoned = true;
                std::panic::resume_unwind(panic)
            }
        }
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
        self.clear_journal();
        self.scores.clear();
        Ok(())
    }

    /// Writes the existing lossless snapshot format, flushes it and syncs it to
    /// disk. Use a temporary path and promote it only after success: I/O errors
    /// can leave a partial file, but never change the runtime.
    pub fn snapshot_to_file(&self, path: &std::path::Path) -> Result<(), RwkvError> {
        use std::io::Write;
        if self.poisoned {
            return Err(RwkvError::Poisoned);
        }
        let mut out = io::BufWriter::with_capacity(256 * 1024, std::fs::File::create(path)?);
        self.inference.write_snapshot(&mut out)?;
        out.flush()?;
        out.get_ref().sync_all()?;
        Ok(())
    }

    /// Restores a bounded file without materializing it in the caller. Format
    /// and I/O failures preserve state, poison flag, undo journal and scores.
    pub fn restore_from_file(&mut self, path: &std::path::Path) -> Result<(), RwkvError> {
        let file = std::fs::File::open(path)?;
        let len = file.metadata()?.len();
        let mut input = io::BufReader::with_capacity(256 * 1024, file);
        self.inference.read_snapshot(&mut input, len)?;
        self.poisoned = false;
        self.clear_journal();
        self.scores.clear();
        Ok(())
    }

    /// 回到新建时的空状态（同时解除 poisoned）。
    pub fn reset(&mut self) {
        self.inference.reset();
        self.poisoned = false;
        self.clear_journal();
        self.scores.clear();
    }

    fn clear_journal(&mut self) {
        self.journal.clear();
        self.journal_bytes = 0;
    }

    /// 作废这些复习的卡与笔记在分数表里的项。
    fn invalidate_scores<'a>(&mut self, reviews: impl Iterator<Item = &'a ReviewInput>) {
        if self.scores.is_empty() {
            return;
        }
        let mut cards = HashSet::new();
        let mut notes = HashSet::new();
        for review in reviews {
            cards.insert(review.card_id);
            notes.insert(note_key(review));
        }
        if cards.is_empty() {
            return;
        }
        self.scores
            .retain(|card, entry| !cards.contains(card) && !notes.contains(&entry.note_key));
    }

    /// 撤销日志里有几条（测试 / 诊断）。
    pub fn journal_len(&self) -> usize {
        self.journal.len()
    }

    /// 按时间顺序追加已答复习，每条记一条撤销日志（标签 `tags[i]`），之后可用 [Self::unappend]
    /// 原样撤回。状态与 [Self::replay] 同一批输入逐位相同（逐条处理；块边界不改结果）。
    /// 只有小模型支持（大模型返回 [RwkvError::Unsupported]，调用方改用 replay）；每行必须有
    /// 评分；校验同 [Self::replay]，整批通过才应用。
    pub fn append(&mut self, reviews: &[ReviewInput], tags: &[u64]) -> Result<(), RwkvError> {
        if self.poisoned {
            return Err(RwkvError::Poisoned);
        }
        if tags.len() != reviews.len() {
            return Err(RwkvError::Input("tags and reviews differ in length".into()));
        }
        if !matches!(self.inference, Engine::Small(_)) {
            return Err(RwkvError::Unsupported(
                "the undo journal needs the small model".into(),
            ));
        }
        let mut last_day = self.inference.last_day_offset();
        let mut inputs = Vec::with_capacity(reviews.len());
        for (index, review) in reviews.iter().enumerate() {
            let mut input = review.clone();
            input.is_query = false;
            if input.ease.is_none() {
                return Err(RwkvError::Input(format!("review {index}: no rating")));
            }
            validate_answer(&input, last_day)
                .map_err(|message| RwkvError::Input(format!("review {index}: {message}")))?;
            last_day = input.day_offset;
            inputs.push(input);
        }
        self.invalidate_scores(inputs.iter());
        let Self {
            inference,
            pool,
            poisoned,
            journal,
            journal_bytes,
            ..
        } = self;
        let Engine::Small(small) = inference else {
            unreachable!("checked above")
        };
        let outcome = catch_unwind(AssertUnwindSafe(|| {
            install(pool, || -> io::Result<()> {
                for (input, &tag) in inputs.into_iter().zip(tags) {
                    let undo = small.append_journaled(input)?;
                    *journal_bytes += undo.bytes();
                    journal.push((tag, undo));
                }
                Ok(())
            })
        }));
        match outcome {
            Ok(result) => {
                result?;
                self.trim_journal();
                Ok(())
            }
            Err(panic) => {
                *poisoned = true;
                std::panic::resume_unwind(panic)
            }
        }
    }

    fn trim_journal(&mut self) {
        let mut drop = 0;
        while drop < self.journal.len() && self.journal_bytes > JOURNAL_MAX_BYTES {
            self.journal_bytes -= self.journal[drop].1.bytes();
            drop += 1;
        }
        self.journal.drain(..drop);
    }

    /// 撤回最近一条 [Self::append]——仅当它的标签是 `tag`（返回 true）。否则（日志空、最近一条
    /// 不是它、或之后有过 replay / restore / reset）什么都不改、返回 false，调用方全量重建。
    /// 撤回后的状态与「从没回放过这条」逐位相同（ID 编码在之后没有新抽取时一并收回）。
    pub fn unappend(&mut self, tag: u64) -> Result<bool, RwkvError> {
        if self.poisoned {
            return Err(RwkvError::Poisoned);
        }
        if self.journal.last().map(|(top, _)| *top) != Some(tag) {
            return Ok(false);
        }
        let (_, undo) = self.journal.pop().expect("checked above");
        self.journal_bytes -= undo.bytes();
        let Engine::Small(small) = &mut self.inference else {
            unreachable!("only the small model journals")
        };
        let (card, note) = undo.affected();
        small.rewind(undo);
        self.scores
            .retain(|id, entry| *id != card && entry.note_key != note);
        Ok(true)
    }

    /// 清空分数表（换日 / 换设置 / 同步合并后全量刷新）。
    pub fn scores_clear(&mut self) {
        self.scores.clear();
    }

    /// 分数表里这些卡的 R：项存在且版本一致才算命中（`Some`）。不改状态。
    pub fn scores_lookup(&self, card_ids: &[i64], versions: &[u64]) -> Vec<Option<f32>> {
        card_ids
            .iter()
            .zip(versions)
            .map(|(id, version)| {
                self.scores
                    .get(id)
                    .filter(|entry| entry.version == *version)
                    .map(|entry| entry.score)
            })
            .collect()
    }

    /// 按 [Self::query] 算这些查询行的 R，记进分数表（键 = 卡 id，带 `versions[i]` 与锚点
    /// `anchors_ms[i]`），并返回。与直接 [Self::query] 同一批行逐位相同；每行的 R 不取决于同批
    /// 别的行（测试核对）。
    pub fn scores_update(
        &mut self,
        queries: &[ReviewInput],
        versions: &[u64],
        anchors_ms: &[i64],
    ) -> Result<Vec<f32>, RwkvError> {
        if versions.len() != queries.len() || anchors_ms.len() != queries.len() {
            return Err(RwkvError::Input(
                "versions / anchors and queries differ in length".into(),
            ));
        }
        let values = self.query(queries)?;
        for (((query, &version), &anchor_ms), &score) in
            queries.iter().zip(versions).zip(anchors_ms).zip(&values)
        {
            self.scores.insert(
                query.card_id,
                ScoreEntry {
                    version,
                    note_key: note_key(query),
                    query: query.clone(),
                    anchor_ms,
                    score,
                },
            );
        }
        Ok(values)
    }

    /// 全量刷新分数表（换日 / 定时防漂移）：把每一项的查询行改成「第 `today` 个调度日、此刻
    /// `now_ms`」再整批重查，版本不变。查询行的改法与调用方构造「此刻」行的规则一致（Dart
    /// `srsRwkvAddNowRow`）：`day_offset = today`；有锚点的行 `elapsed_days = today - 上次评分的
    /// 调度日`（由旧行的 `day_offset - elapsed_days` 得出）、`elapsed_seconds = (now - 锚点) / 1000`
    /// （向零截断，下限 0）；card_type 在跨日后是 2（复习），仍在同一调度日时沿用旧值。旧行是跨日
    /// 行、新时刻却回到了上次评分那天（时钟回拨）时，没法确定 card_type：这一项删掉，由调用方按
    /// 历史重算。返回重查的行数。
    pub fn scores_requery(&mut self, today: i64, now_ms: i64) -> Result<usize, RwkvError> {
        let mut ids = Vec::with_capacity(self.scores.len());
        let mut rows = Vec::with_capacity(self.scores.len());
        let mut drop = Vec::new();
        for (&id, entry) in &self.scores {
            match requery_row(&entry.query, entry.anchor_ms, today, now_ms) {
                Some(row) => {
                    ids.push(id);
                    rows.push(row);
                }
                None => drop.push(id),
            }
        }
        for id in drop {
            self.scores.remove(&id);
        }
        // 按卡 id 排序：ID 编码只在首次见到的实体上抽取，固定顺序让结果与表的内部顺序无关。
        let mut order: Vec<usize> = (0..ids.len()).collect();
        order.sort_unstable_by_key(|&i| ids[i]);
        let rows: Vec<ReviewInput> = order.iter().map(|&i| rows[i].clone()).collect();
        let values = self.query(&rows)?;
        for (row, score) in rows.into_iter().zip(values) {
            if let Some(entry) = self.scores.get_mut(&row.card_id) {
                entry.query = row;
                entry.score = score;
            }
        }
        Ok(order.len())
    }

    /// 从分数表删掉这些卡的项（卡被永久清除：它不会再成为候选，留着只占内存、整表刷新时白算）。
    /// 返回真删掉的项数。
    pub fn scores_remove(&mut self, card_ids: &[i64]) -> usize {
        card_ids
            .iter()
            .filter(|id| self.scores.remove(id).is_some())
            .count()
    }

    /// 分数表项数（测试 / 诊断）。
    pub fn scores_len(&self) -> usize {
        self.scores.len()
    }

    pub fn stats(&self) -> RwkvStats {
        self.inference.stats()
    }
}

/// [RwkvRuntime::scores_requery] 的行变换；`None` = 定不了 card_type（见该函数）。
fn requery_row(old: &ReviewInput, anchor_ms: i64, today: i64, now_ms: i64) -> Option<ReviewInput> {
    let mut row = old.clone();
    row.day_offset = Some(today);
    if anchor_ms < 0 {
        return Some(row);
    }
    let old_day = old.day_offset?;
    let last_day = old_day - old.current_elapsed_days?.max(0);
    row.current_elapsed_days = Some((today - last_day).clamp(0, 1 << 40));
    row.current_elapsed_seconds = Some(((now_ms - anchor_ms) / 1000).clamp(0, 1 << 50));
    let was_same_day = old_day == last_day;
    if today != last_day {
        row.card_type = Some(2);
    } else if !was_same_day {
        return None;
    }
    Some(row)
}

/// 一行所属笔记在状态里的键（没给 note_id 的行是每卡一条占位笔记，与小模型的 `stream_keys` 一致）。
fn note_key(input: &ReviewInput) -> i64 {
    input
        .note_id
        .unwrap_or(rwkv::ID_PLACEHOLDER_NOTE_BASE + input.card_id)
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
/// 这个模型不支持该操作（撤销日志只有小模型有）。
pub const FRWKV_ERR_UNSUPPORTED: i32 = -6;

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

/// precision 参数：f32 状态 / int8 / int4 紧凑 card+note 状态 / 按模型取推荐值
/// （[ModelKind::default_precision]：大模型 int8、小模型 int4）。
pub const FRWKV_PRECISION_F32: i32 = 0;
pub const FRWKV_PRECISION_INT8: i32 = 8;
pub const FRWKV_PRECISION_INT4: i32 = 4;
pub const FRWKV_PRECISION_DEFAULT: i32 = -1;

/// [frwkv_model_kind] 的返回值。
pub const FRWKV_MODEL_LARGE: i32 = 1;
pub const FRWKV_MODEL_SMALL: i32 = 2;

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

/// 不透明句柄：解析好的网络（大或小）。
pub struct FrwkvModel(Model);

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
        RwkvError::Unsupported(_) => FRWKV_ERR_UNSUPPORTED,
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

/// 查询行 → 输入。未知 present 位的行：给一个必然不合法的输入（无 day_offset）→ NaN。
fn query_input(row: &FrwkvReview) -> ReviewInput {
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

/// 从内存里的权重文件建模型（`ARWKVWEIGHTS1` 大 / 小模型，`ARWKVWEIGHTS8PC1` 小模型），
/// 按内容自动识别。失败返回空指针（见 [frwkv_last_error]）。
/// 返回的句柄用 [frwkv_model_free] 释放；runtime 持有自己的引用，释放 model 不影响已建的 runtime。
///
/// # Safety
/// `bytes` 必须指向 `len` 个可读字节。
#[no_mangle]
pub unsafe extern "C" fn frwkv_model_load(bytes: *const u8, len: usize) -> *mut FrwkvModel {
    let mut model = None;
    let code = guarded(|| {
        let bytes = slice_or_empty(bytes, len).ok_or_else(|| argument("null weights"))?;
        let parsed = Model::from_bytes(bytes)
            .map_err(|error| (FRWKV_ERR_DATA, format!("weights: {error}")))?;
        model = Some(Box::new(FrwkvModel(parsed)));
        Ok(())
    });
    match model {
        Some(model) if code == FRWKV_OK => Box::into_raw(model),
        _ => std::ptr::null_mut(),
    }
}

/// [FRWKV_MODEL_LARGE] / [FRWKV_MODEL_SMALL]；空指针返回 [FRWKV_ERR_ARGUMENT]。
///
/// # Safety
/// `model` 为空或是有效的 [FrwkvModel] 句柄。
#[no_mangle]
pub unsafe extern "C" fn frwkv_model_kind(model: *const FrwkvModel) -> i32 {
    match model.as_ref() {
        Some(model) => match model.0.kind() {
            ModelKind::Large => FRWKV_MODEL_LARGE,
            ModelKind::Small => FRWKV_MODEL_SMALL,
        },
        None => FRWKV_ERR_ARGUMENT,
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

/// 新建 runtime。`precision`：[FRWKV_PRECISION_F32] / [FRWKV_PRECISION_INT8] /
/// [FRWKV_PRECISION_INT4] / [FRWKV_PRECISION_DEFAULT]；
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
            FRWKV_PRECISION_INT4 => StatePrecision::Int4,
            FRWKV_PRECISION_DEFAULT => model.0.kind().default_precision(),
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
        let inputs: Vec<ReviewInput> = rows.iter().map(query_input).collect();
        let values = runtime.0.query(&inputs).map_err(rwkv_error)?;
        if count > 0 {
            std::slice::from_raw_parts_mut(out_retrievability, count).copy_from_slice(&values);
        }
        Ok(())
    })
}

/// 按时间顺序追加 `count` 条已答复习，每条记一条撤销日志（标签 `tags[i]`，例如这条日志 id 的
/// hash），见 [RwkvRuntime::append]。状态与 [frwkv_runtime_replay] 同一批行逐位相同。
/// 每行必须有评分；不合法 → [FRWKV_ERR_INPUT]（整批不应用）；大模型 → [FRWKV_ERR_UNSUPPORTED]。
///
/// # Safety
/// `runtime` 有效；`reviews` 指向 `count` 个 [FrwkvReview]；`tags` 指向 `count` 个 u64。
#[no_mangle]
pub unsafe extern "C" fn frwkv_runtime_append(
    runtime: *mut FrwkvRuntime,
    reviews: *const FrwkvReview,
    tags: *const u64,
    count: usize,
) -> i32 {
    guarded(|| {
        let runtime = runtime.as_mut().ok_or_else(|| argument("null runtime"))?;
        let rows = slice_or_empty(reviews, count).ok_or_else(|| argument("null reviews"))?;
        let tags = slice_or_empty(tags, count).ok_or_else(|| argument("null tags"))?;
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
        runtime.0.append(&inputs, tags).map_err(rwkv_error)
    })
}

/// 撤回最近一条 [frwkv_runtime_append]，仅当它的标签是 `tag`：返回 1；不是（或日志已被 replay /
/// restore / reset 清空、超出容量被丢弃）返回 0，状态不变——调用方全量重建。
///
/// # Safety
/// `runtime` 有效。
#[no_mangle]
pub unsafe extern "C" fn frwkv_runtime_unappend(runtime: *mut FrwkvRuntime, tag: u64) -> i32 {
    let mut rewound = false;
    let code = guarded(|| {
        let runtime = runtime.as_mut().ok_or_else(|| argument("null runtime"))?;
        rewound = runtime.0.unappend(tag).map_err(rwkv_error)?;
        Ok(())
    });
    if code == FRWKV_OK {
        i32::from(rewound)
    } else {
        code
    }
}

/// 清空常驻分数表（[RwkvRuntime::scores_clear]）。
///
/// # Safety
/// `runtime` 有效。
#[no_mangle]
pub unsafe extern "C" fn frwkv_runtime_scores_clear(runtime: *mut FrwkvRuntime) -> i32 {
    guarded(|| {
        let runtime = runtime.as_mut().ok_or_else(|| argument("null runtime"))?;
        runtime.0.scores_clear();
        Ok(())
    })
}

/// 在分数表里查 `count` 张卡（id 与版本）：命中的写 R 到 `out_scores[i]`、`out_found[i] = 1`；
/// 没有或版本不同的写 NaN / 0。返回命中数（≥ 0）。不改状态。
///
/// # Safety
/// `runtime` 有效；`card_ids` / `versions` 各指向 `count` 个元素；`out_scores` / `out_found`
/// 各可写 `count` 个元素。
#[no_mangle]
pub unsafe extern "C" fn frwkv_runtime_scores_lookup(
    runtime: *const FrwkvRuntime,
    card_ids: *const i64,
    versions: *const u64,
    count: usize,
    out_scores: *mut f32,
    out_found: *mut u8,
) -> i32 {
    let mut found = 0usize;
    let code = guarded(|| {
        let runtime = runtime.as_ref().ok_or_else(|| argument("null runtime"))?;
        let ids = slice_or_empty(card_ids, count).ok_or_else(|| argument("null card ids"))?;
        let versions = slice_or_empty(versions, count).ok_or_else(|| argument("null versions"))?;
        if count > 0 && (out_scores.is_null() || out_found.is_null()) {
            return Err(argument("null output"));
        }
        if count == 0 {
            return Ok(());
        }
        let scores = std::slice::from_raw_parts_mut(out_scores, count);
        let hits = std::slice::from_raw_parts_mut(out_found, count);
        for (index, value) in runtime.0.scores_lookup(ids, versions).into_iter().enumerate() {
            scores[index] = value.unwrap_or(f32::NAN);
            hits[index] = u8::from(value.is_some());
            found += usize::from(value.is_some());
        }
        Ok(())
    });
    if code == FRWKV_OK {
        i32::try_from(found).unwrap_or(i32::MAX)
    } else {
        code
    }
}

/// 按查询算 `count` 行的 R（与 [frwkv_runtime_query] 逐位相同，不合法行 NaN），写进分数表
/// （键 = 卡 id，版本 `versions[i]`，锚点 `anchors_ms[i]` = 这张卡最后一条保留评分的时刻、
/// 没有给 -1）并写到 `out_retrievability`。
///
/// # Safety
/// `runtime` 有效；`queries` 指向 `count` 个 [FrwkvReview]；`versions` / `anchors_ms` 各指向
/// `count` 个元素；`out_retrievability` 可写 `count` 个 f32。
#[no_mangle]
pub unsafe extern "C" fn frwkv_runtime_scores_update(
    runtime: *mut FrwkvRuntime,
    queries: *const FrwkvReview,
    versions: *const u64,
    anchors_ms: *const i64,
    count: usize,
    out_retrievability: *mut f32,
) -> i32 {
    guarded(|| {
        let runtime = runtime.as_mut().ok_or_else(|| argument("null runtime"))?;
        let rows = slice_or_empty(queries, count).ok_or_else(|| argument("null queries"))?;
        let versions = slice_or_empty(versions, count).ok_or_else(|| argument("null versions"))?;
        let anchors = slice_or_empty(anchors_ms, count).ok_or_else(|| argument("null anchors"))?;
        if count > 0 && out_retrievability.is_null() {
            return Err(argument("null output"));
        }
        let inputs: Vec<ReviewInput> = rows.iter().map(query_input).collect();
        let values = runtime
            .0
            .scores_update(&inputs, versions, anchors)
            .map_err(rwkv_error)?;
        if count > 0 {
            std::slice::from_raw_parts_mut(out_retrievability, count).copy_from_slice(&values);
        }
        Ok(())
    })
}

/// 从分数表删掉 `count` 张卡的项（[RwkvRuntime::scores_remove]）。返回删掉的项数（≥ 0）。
///
/// # Safety
/// `runtime` 有效；`card_ids` 指向 `count` 个元素。
#[no_mangle]
pub unsafe extern "C" fn frwkv_runtime_scores_remove(
    runtime: *mut FrwkvRuntime,
    card_ids: *const i64,
    count: usize,
) -> i32 {
    let mut removed = 0usize;
    let code = guarded(|| {
        let runtime = runtime.as_mut().ok_or_else(|| argument("null runtime"))?;
        let ids = slice_or_empty(card_ids, count).ok_or_else(|| argument("null card ids"))?;
        removed = runtime.0.scores_remove(ids);
        Ok(())
    });
    if code == FRWKV_OK {
        i32::try_from(removed).unwrap_or(i32::MAX)
    } else {
        code
    }
}

/// 全量刷新分数表（[RwkvRuntime::scores_requery]）：按第 `today` 个调度日、此刻 `now_ms` 重算
/// 每一项。返回重查的项数（≥ 0）。
///
/// # Safety
/// `runtime` 有效。
#[no_mangle]
pub unsafe extern "C" fn frwkv_runtime_scores_requery(
    runtime: *mut FrwkvRuntime,
    today: i64,
    now_ms: i64,
) -> i32 {
    let mut count = 0usize;
    let code = guarded(|| {
        let runtime = runtime.as_mut().ok_or_else(|| argument("null runtime"))?;
        count = runtime.0.scores_requery(today, now_ms).map_err(rwkv_error)?;
        Ok(())
    });
    if code == FRWKV_OK {
        i32::try_from(count).unwrap_or(i32::MAX)
    } else {
        code
    }
}

/// 作答时排程（[RwkvRuntime::next_intervals]）：`answer` 是这次作答的复习行（`ease` 被忽略，
/// 依次替换为 1..4；`duration` 通常未知、不置位），写 4 个天数到 `out_days`（Again / Hard /
/// Good / Easy；该评分作答后的遗忘曲线第一次 ≤ 目标的天数），`out_retrievability` 可空，非空时
/// 写 4 条曲线「在该日的 R」（到上限仍高于目标时是上限那天的 R）。什么都不保存。`answer` 不合法
/// → [FRWKV_ERR_INPUT]。
///
/// # Safety
/// `runtime`、`answer` 有效；`out_days` 可写 4 个 u32；`out_retrievability` 为空或可写 4 个 f32。
#[no_mangle]
pub unsafe extern "C" fn frwkv_runtime_next_intervals(
    runtime: *mut FrwkvRuntime,
    answer: *const FrwkvReview,
    target_retention: f32,
    max_interval_days: u32,
    out_days: *mut u32,
    out_retrievability: *mut f32,
) -> i32 {
    guarded(|| {
        let runtime = runtime.as_mut().ok_or_else(|| argument("null runtime"))?;
        let answer = answer.as_ref().ok_or_else(|| argument("null answer"))?;
        if out_days.is_null() {
            return Err(argument("null output"));
        }
        let mut row = *answer;
        row.ease = 1;
        let input = row.to_input(false).ok_or_else(|| {
            (
                FRWKV_ERR_INPUT,
                "invalid input: answer: unknown present bits".to_owned(),
            )
        })?;
        let (days, retrievability) = runtime
            .0
            .next_intervals(&input, target_retention, max_interval_days)
            .map_err(rwkv_error)?;
        std::slice::from_raw_parts_mut(out_days, 4).copy_from_slice(&days);
        if !out_retrievability.is_null() {
            std::slice::from_raw_parts_mut(out_retrievability, 4).copy_from_slice(&retrievability);
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

/// Writes a lossless snapshot to a UTF-8 path (no NUL terminator), flushes and
/// syncs it. The caller owns temporary-file promotion after success.
///
/// # Safety
/// `runtime` is valid; `path` points to `path_len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn frwkv_runtime_snapshot_to_file(
    runtime: *const FrwkvRuntime,
    path: *const u8,
    path_len: usize,
) -> i32 {
    guarded(|| {
        let runtime = runtime.as_ref().ok_or_else(|| argument("null runtime"))?;
        let path = slice_or_empty(path, path_len).ok_or_else(|| argument("null path"))?;
        let path = std::str::from_utf8(path).map_err(|_| argument("path must be UTF-8"))?;
        runtime.0.snapshot_to_file(std::path::Path::new(path)).map_err(rwkv_error)
    })
}

/// Restores a lossless snapshot from a UTF-8 path; errors preserve the runtime.
///
/// # Safety
/// `runtime` is valid; `path` points to `path_len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn frwkv_runtime_restore_from_file(
    runtime: *mut FrwkvRuntime,
    path: *const u8,
    path_len: usize,
) -> i32 {
    guarded(|| {
        let runtime = runtime.as_mut().ok_or_else(|| argument("null runtime"))?;
        let path = slice_or_empty(path, path_len).ok_or_else(|| argument("null path"))?;
        let path = std::str::from_utf8(path).map_err(|_| argument("path must be UTF-8"))?;
        runtime.0.restore_from_file(std::path::Path::new(path)).map_err(rwkv_error)
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
///
/// 错误存在调用线程的 thread-local 里：Dart isolate 回到事件循环（`await`）后可能换 OS 线程，
/// 所以必须在失败调用之后的同一段同步代码里（中间没有 `await`）取它。
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
