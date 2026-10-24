## BUG-3703 · srs-optimizer-prefix-json-quadratic
- **报告**：2026-10-23（审查记录 HBK-AUDIT-017：FSRS 优化器每条复习复制一份历史前缀、整份 JSON 过 FFI）
- **真实性**：✅ 真问题（性能 / 内存）。根因两处，都是「训练条目 = 一张卡到某次评分为止的历史前缀」被按条目物化：
  - `packages/fushi_engine/lib/srs/srs_optimizer.dart:131-149`（修前）：每条复习 `input.reviews.sublist(0, i + 1)` 复制一份前缀，
    一张 n 次评分的卡产出 Σ_{k=2..n} k 个 `SrsFsrsReview` 引用，整组 O(Σ L²)，还要整份带进后台 isolate（深拷贝）。
  - `packages/fushi_srs/lib/src/ffi/ffi_fsrs_engine.dart:209-237、343-348`（修前）：`computeParameters` / `evaluate` /
    `evaluateTimeSeries` 每次都把全部前缀 `toJson → jsonEncode → toNativeUtf8`，Rust 侧再 `serde_json` 解析成 `Value` 树
    再转 `Vec<FSRSItem>`。一轮优化至少 5 次调用（compute + 2×evaluate + 2×evaluate_tss），每次重编一遍。
  - 实测（1500 卡、每卡 20–120 次评分、10.5 万条目、Σ 前缀 444 万条评分）：单次请求 142.7 MB JSON，进程峰值 RSS 8125 MB，
    端到端 76.6 s（其中绝大部分是 JSON 编解码与 `Value` 树，不是 fsrs-rs 的计算）。
- **[x] ① 已修复**（9999afa554）— 训练集改成打包 TypedData `SrsFsrsTrainingSet`（`packages/fushi_srs/lib/src/fsrs_engine.dart`）：每张卡只存一份
  完整历史（`ratings` / `deltaDays` / `cardOffsets` / `cardIds`），条目只记按评分时刻排好序的 `(卡序号, 前缀长度)`；原生侧新 C ABI
  `ffsrs_fit`（`native/fushi_fsrs/src/lib.rs`，替换 `ffsrs_compute_parameters` 与 JSON op `evaluate` / `evaluate_tss`，ABI 1→2）
  在 Rust 里展开前缀再交给 fsrs-rs。不留 JSON 回退。
  - **口径不变**：条目顺序（= fsrs-rs 按序给的近期训练权重与时间序列切分）由 Dart 侧同一个比较器排序决定；card ID 按条目对齐
    展开后只给参数优化（与旧实现一致，两种评估不带 ID）；小数天以 f32 传，与旧路径 JSON→f32 的舍入相同，输入逐位一致。
  - **复杂度实际变成什么**：Dart 侧构建、isolate 拷贝、FFI 传输都从 O(Σ L²) 降到 O(N)（N = 总评分数，约 13 字节 / 条评分）。
    Rust 侧仍逐条展开前缀：每次调用临时占 O(Σ L²) × 8 字节（`FSRSReview`），调用结束即释放。fsrs-rs 内部 FSRS-6 训练、
    训练集内评估、时间序列切分评估仍逐条前缀计算，**计算量仍是 O(Σ L²)**（只是常数从「JSON + Value 树」降到「8 字节 memcpy +
    模型前向」）；FSRS-7 参数优化带 card ID 时 fsrs-rs 按扩展窗口训练，计算量本来就接近线性。要彻底线性需要 fsrs-rs 提供「整段历史 +
    前缀长度」的 API，属上游改动，不在本修复范围。
  - **修前 / 修后实测**（Windows x64 release DLL，同一合成数据，同一调用序列 compute6 + 2×evaluate + tss6 + tss7 + compute7）：

    | 场景 | 指标 | 修前 | 修后 |
    |---|---|---|---|
    | 3000 卡 × 2–30 次（4.5 万条目，Σ前缀 51 万） | 单次传输 | 15.6 MB JSON | 0.64 MB |
    | | 峰值 RSS（基线 ≈200 MB） | 1147 MB | 272 MB |
    | | 端到端 | 7.67 s | 1.19 s |
    | 1500 卡 × 20–120 次（10.5 万条目，Σ前缀 444 万） | 单次传输 | 142.7 MB JSON | 1.39 MB |
    | | 峰值 RSS（基线 ≈205 MB） | 8125 MB | 420 MB |
    | | 端到端 | 76.6 s | 8.7 s |

    修后长历史场景的耗时大头是两次 `evaluate_tss`（各 ≈3.7 s，fsrs-rs 每折重训），即上面说的 fsrs-rs 内部 O(Σ L²) 计算。
- **[x] ② 已加自动化测试** — `packages/fushi_srs/test/fsrs_training_set_regression_test.dart` + 夹具
  `packages/fushi_srs/test/fixtures/fsrs_training_regression_vectors.json`：旧实现（develop 329a739431）在固定合成输入（300 卡、
  2137 条交错排序条目）上的输出，新路径对 FSRS-6 / FSRS-7 各比参数（带 / 不带 card ID）、两种 evaluate、时间序列切分评估，容差 1e-5；
  变异实测（改两个期望值）对应两条变红。Rust 单测 `training_set_expands_prefixes_in_item_order` /
  `fit_rejects_malformed_training_sets`（`native/fushi_fsrs/src/lib.rs`）。
- **备注**：基准脚本未入库（旧实现的 API 已删）；向量生成器与基准脚本放在本 PR 描述里。
