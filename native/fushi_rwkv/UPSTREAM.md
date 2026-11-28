# fushi_rwkv 上游来源

## 基线

| | |
|---|---|
| 仓库 | https://github.com/Pedrubik2000/kuma3-anki-core （分支 `rwkv`） |
| 提交 | `c639bcec696f2317f9bb9a736d433b9d6c0d9c56`（2026-10-18，「kuma3 RWKV queue: cache last review times by card mtime and reps」） |
| 目录 | `rslib/src/rwkv/` |
| 许可 | GNU AGPL-3.0-or-later（文件头 `Copyright: Ankitects Pty Ltd and contributors`） |
| 上游的上游 | JSchoreels/anki 的 RWKV fork（`rslib/src/rwkv/mod.rs`，参照提交 `0dd75c5f8fa4ea3543f5a3559870e8aea047bf80`）。kuma3 在它之上加了 `StatePrecision`（int8 / int4 紧凑 card+note 状态）与 `bulk.rs` 的批量回放，所以选 kuma3 做基线 |

用户 2026-10-19 拍板：接受照搬上游 AGPL 代码。

## 权重（不入库）

| | |
|---|---|
| 文件 | `RWKV_trained_on_5000_10000.bin`（`ARWKVWEIGHTS1` 小端自定义格式，2,762,884 个 f32 参数） |
| 大小 | 11,082,637 字节 |
| SHA-256 | `749ad1ad18d5b6ef8c4185802fa0c1e4a14e67cd7874f3efeaae355fffb1b9ec` |
| 钉死 URL | https://raw.githubusercontent.com/Pedrubik2000/kuma3-anki-core/c639bcec696f2317f9bb9a736d433b9d6c0d9c56/qt/aqt/rwkv_inference/RWKV_trained_on_5000_10000.bin |
| 备用 URL | https://raw.githubusercontent.com/JSchoreels/anki/0dd75c5f8fa4ea3543f5a3559870e8aea047bf80/qt/aqt/rwkv_inference/RWKV_trained_on_5000_10000.bin |

2026-10-19 核对：kuma3-anki-core 的这份、JSchoreels/anki 的这份、kuma3-anki-app
（`Pedrubik2000/kuma3-anki-app` 分支 `rwkv` @ `8294162221978823ea5b76c1cb8686c8fe55abf8`
的 `AnkiDroid/src/main/assets/rwkv/model.bin`，git blob `af89daba…`）三者 **SHA-256 相同**。
`fetch_model.sh` / `fetch_model.ps1` 下载到 `model/`（已 gitignore）并校验 SHA-256。权重随上游仓库
以 AGPL-3.0-or-later 发布；小模型权重另见下文「小模型权重的许可」。

## 权重镜像（运行时首选来源）

| | |
|---|---|
| 位置 | GitHub release `hajisensai/Fushi` tag `rwkv-models`，资产 URL `https://github.com/hajisensai/Fushi/releases/download/rwkv-models/<名>` |
| 命名 | `<SHA-256 前 16 位十六进制>-<模型>-<原文件名>`，如 `87bce8dbb48a11dd-sm113-weights.int8.bin` |
| 约定 | **内容寻址、永不覆盖**：已发布的资产不删、不替换；换权重 = 新增一个新名字的资产，旧版本的 app 继续命中旧名字。上游作者曾原地替换 release zip（正式版因钉了可变 zip 而下载失败），所以运行时不钉上游 release，只钉上游**提交**的 raw URL 作备用 |
| 现有资产 | `87bce8dbb48a11dd-sm113-weights.int8.bin`（436,391 字节）、`24b39f61129bd9eb-sm130io-weights.int8.bin`（238,585 字节）（2026-11-27 起用）；`b2f335bd712b9d60-sm98-weights.int8.bin`、`77703dd2f2a21a1b-sm101-weights.int8.bin`、`ff626af2e974346e-sm72e25-weights.int8.bin`、`479b3e2bc6a1c900-sm56-weights.int8.bin`（旧版本 app 用） |
| 谁用 | `packages/fushi_engine/lib/srs/srs_rwkv_models.dart`（app 与无头服务端）、`fetch_model.*`（CI / 本地测试）：镜像在前、上游提交 raw URL 在后，**只认字节数 + SHA-256**，任一来源下错都换下一个，全失败时报出每个来源的原因 |
| 不在镜像里 | 测试用的 `weights.f32.bin`、`architecture.json`、`*-vectors.json.gz` 只从上游提交取 |

## 小模型权重的许可

上游 2026-11-25 起在 release 与 fork（`qt/aqt/rwkv_inference/WEIGHTS-NOTICE.md`）里写明：代码是 MIT，训练出的权重
（`weights.*.bin` 等）**不在 MIT 下**、作者不另授许可，按训练数据 anki-revlogs-10k 的条款对待——只允许记忆研究与
个人研究，**在应用里分发（商业与否）需要 Anki 的许可**；能否再分发在 srs-benchmark issue #353 未决。Fushi 镜像
（上面的 `rwkv-models` release）并在用户启用 RWKV 时下发这些权重，风险与取舍登记在拍板台
（`docs/agent/decision-board.md`「RWKV 小模型权重的分发许可」），等用户拍板。

## 搬了什么

| 上游文件（行数） | 本 crate（行数） | 处理 |
|---|---|---|
| `mod.rs`（12,748） | `src/rwkv/mod.rs`（≈4,800，其中 ≈200 行是标了 `Fushi` 的新增） | 推理核心逐字保留：权重加载（`WeightMap` / `Cursor`）、特征构造（`FeatureState`、`TorchIdRng` 与 ID 编码、全部 `scale_*` 与均值 / 方差常量、日期周期编码）、网络（`SrsModel` / `RwkvModule` / `RwkvLayer` / `TimeMixer` / `ChannelMixer` / `LoraSimple` / `Linear` / `Norm`、单步递推、AVX2+FMA / NEON / 标量 SIMD 辅助）、`ReviewInput`、`warm_up_reviews`（回放）、`warm_up_reviews_sequential`（逐条参考实现）、`predict_retrievability_many_from_warm_up`（批量 R 查询）、状态序列化 / 反序列化（`ARWKVMODSTATE1` f32 与紧凑格式）、特征簿记序列化（`ARWKVPROCSTATE2`） |
| `bulk.rs`（1,445） | `src/rwkv/bulk.rs`（1,367） | 批量回放逐字保留 |
| `precision.rs`（377） | `src/rwkv/precision.rs`（281） | int8 / int4 紧凑状态，删掉测试模块，其余未改 |
| `query_kernels.rs`（330） | —— | aarch64 NEON 查询内核：2026-11-26 删（见「改了什么 · 跨平台逐位一致」） |
| `matmul.rs`（145） | —— | macOS Accelerate `cblas_sgemm`：2026-11-26 删（同上） |

每个文件头保留上游版权与许可行，并加一行 `Adapted for Fushi from <repo>@<sha> <path>`。

## 删了什么

- **SQLite 状态缓存**（`StateCacheStoreWriter`、`write/restore/finish_warm_up_state_checkpoint`、
  delta chunk 读写、`ReviewStateMaps` 的 dirty 集与 checkpoint delta）——不再依赖 `rusqlite`。
- **resident-state stash / spill**（`StashedWarmUpState`、`WarmUpStateSpill`、`stash_*` /
  `restore_stashed_*` / `discard_*`、`drop_in_background`、`release_free_memory_to_os`）——不再依赖
  `anki_io` / `blake3` / `tracing`。
- **workload 模拟**（`simulate_workload*`、`RwkvWorkload*`、`SimulationStates`、`StreamIds`、
  `simulation_*`、`relative_overdueness` 引用）——不再依赖 `anki_proto`（`ReviewCardOrder`）。
- **按卡保存的曲线与它的接口**：`RwkvInference.curves`（≈1 KB/卡）、`current_curve_retrievability`、
  `answer_intervals` / `current_intervals`（带 S90 的双目标版本）、`S90_TARGET_RETENTION`、
  `ReviewInput::target_retentions` / `enforce_grade_order`；批量回放也不在每次调用结束时为每张卡算
  曲线。
  - **2026-10-20 搬回**（作答时排程改读曲线头，见 README「作答时排程」）：`predict_curve`、
    `linspace_exp` 逐字回到 `src/rwkv/mod.rs`；区间求解 `unrounded_intervals_for_answer_curves` /
    `crossings_on_grid` / `crossing_between` / `pava_non_decreasing` / `interval_search_days` /
    `clamped_interval_days` 逐字搬到 `src/curve.rs`（四个评分同一目标、`enforce_grade_order = true`）；
    `answer_heads` 的等价物是 `RwkvInference::answer_curves`（读 `SrsModel::review` 已经算出的
    `curve.weights`）。网络里的曲线头（`curve_head`）一直按上游计算，数值路径不动。
- 其余 `RwkvInference` 接口：`review`（逐条带状态字节的老接口）、`predict_many`、
  `predict_retrievability_many`、`predict_retrievability_many_after_review(s)*`、
  `warm_up_snapshot` / `restore_warm_up_snapshot` / `warm_up_state` / `restore_warm_up_state`、
  `state_for_card` / `restore_state`（撤销用）、`state_snapshot` / `read_warm_up_states`
  （kuma3 的 f16 离线状态文件，有损）。
- 所有测试 / 探针：`#[cfg(test)]` 的 profile 计时、scan capture、状态压缩实验、
  `collection_benchmark.rs`、`history_ablation_bench.rs`、`query_math_bench.rs`、
  `precision_tests.rs` 与 `mod.rs` 末尾 4,000 行测试模块。

上游共 16,056 行（9 个文件），保留 6,917 行（5 个文件，含 Fushi 新增）。

## 改了什么（全部标 `Fushi:`；除下面「量化比例因子」「跨平台逐位一致」两条外均不涉及数值）

- 权重从字节切片加载（`WeightMap::from_bytes` / `SrsModel::from_weight_bytes`，原来读文件路径）；
  公开 `RwkvModel`（可在多个 runtime 间共享），`RwkvInference::new(&model, precision)` 取代
  `load_with_precision(path, target_retention, max_interval_days, precision)`；为此给网络结构体
  加了 `#[derive(Clone)]`（非 f32 精度时复制一份网络，因为上游把精度存在 card / note 模块上）。
- `bulk.rs`：去掉曲线计算与 dirty 标记后，state-only 分支的返回值改为 `drop(..)`。
- **跨平台逐位一致**（2026-11-26，`src/rwkv/det.rs`，README「跨平台逐位一致」）：上游的点积 / axpy 在
  x86 AVX2+FMA、aarch64 NEON、标量回退各有一套求和顺序（尾部还有的融合有的不融合），R 查询在 macOS /
  aarch64 走批量 GEMM（Accelerate `cblas_sgemm`、NEON 查询内核、改写过的衰减公式 `exp(-e^-0.5 sigmoid(x))`
  与 Accelerate 的向量超越函数），x86 走逐行；超越函数用各平台的 libm。同一历史在不同平台上 R 差最后几位，
  阈值边上的卡到期判定不同。改为：点积 32 条交错 lane + 固定归约树、axpy 每个元素都 FMA（无 FMA 的 CPU 用
  软件 FMA），`exp` / `ln` / `ln_1p` / `tanh` / `sin` / `cos` / `powf` / `sigmoid` 自写（f64 计算、一次舍入），
  R 查询所有平台都走逐行路径（删 `matmul.rs`、`query_kernels.rs`、`review_retrievability_query_refs_batched`
  及其批量 scratch / `apply_batch` / `Norm::apply_batch`，`bulk.rs` 的 `apply_block_approx_into` 与
  `approximate_projections` 参数一并删）。与上游夹具的差：f32 ≤ 3.6e-7、int8 ≤ 6.5e-4（量化台阶），
  容差不变；快照魔数升为 `FRWKVSNAP2\0` / `FRWKVSMALL2\0`，旧快照拒收、全量重放。
- `ARWKVPROCSTATE2` 特征簿记照写，曲线表恒为 0 条；读取时跳过曲线（复用上游
  `read_runtime_feature_state`）。
- 新增：`snapshot` / `restore_snapshot`（无损快照，见 README）、`reset`、`last_day_offset`、
  `stats`、`precision`；`warm_up_reviews_sequential` 改为 `pub` 供对拍测试调用。
- `cargo fmt` 只动了删除后留下的空行与新增代码。
- **量化比例因子**（2026-10-20，`precision.rs` `encode_matrix`，**改数值**）：码字照旧按
  `max/limit` 取整，比例因子改为对码字的最小二乘拟合 `(x·c)/(c·c)`。上游的 `max/limit` 每次作答都往
  card / note 状态注入能量，int4 下状态指数增长到 f32 溢出（上游 350 万条历史的笔记、Fushi 实测的
  小模型 card，见 README「状态精度」）。int8 夹具仍在 1e-3 容差内（`every_fixture_matches_upstream_in_f32_and_int8`）。
  大模型 int4 card 状态即使这样也发散，`lib.rs` 拒绝该组合。
- **card / note 状态存储**（`SharedStateMap`）：紧凑状态改存定长槽位池（`slots.rs`），f32 状态照旧
  `Arc`；对外行为（`state` / `put` / `take`）不变，修的是回放导致的堆碎片（README「内存」）。
- 新增：`answer_curves`（作答时排程：每个评分一行假设作答的曲线头，见 README）、`forecast`（假设
  作答后在若干天查询即时 R，测试与诊断用，不参与排程）、`FeatureState::with_hypothetical_review`
  （假设回放一条再撤销）、`forecast_query`、`stream_peak`（长历史测试诊断）。

`src/lib.rs`（输入校验、线程池、作答时排程的天数搜索、C ABI）与 `src/rwkv/small/`、`src/rwkv/slots.rs`
是 Fushi 新写的。小模型的来源：JSchoreels/anki-rwkv release `small-model-sm40-2026-10-19`
（包 `sm40v2-package.zip`，SHA-256 `9bc1e3e4040ce9693f230e905abb5c925b1102f787424b9059543ae900f1e2a2`），按包内
INTEGRATION.md 与 `reference/small_model_recurrent.py` 实现；不含发布包的代码。2026-10-27 起用的权重换成
同架构重训的 release `small-model-sm56-2026-10-24`（包 `sm56-package.zip`，当时 5,581,795 字节、SHA-256
`7b1790f49fdabf1279510247cc9bc3bf3ac461b67cf0135ab8e51589b5efe71a`；`architecture.json` 与参考代码
与 sm40v2 逐字节相同，代码无需改动）。2026-11-07 起换成无泄漏的 sm72e25：JSchoreels/anki 提交
`986963d23e7ec9f22771c38998ef9042214c2b98` 的 `qt/aqt/rwkv_inference/sm72e25/weights.{int8,f32}.bin`、
`architecture.json`（与 SM56 逐字节相同）与 `rslib/src/rwkv/testdata/sm72e25-vectors.json.gz`，哈希见
`src/lib.rs` 的 `SMALL_MODEL_*_SHA256`（与该提交的 `manifest.json` 一致）；随之加入无泄漏输入规则（输入
13–15 恒为 0，README「sm72e25」）。2026-11-15 起换成 **Instant-Only 的 sm98**：上游 release
`JSchoreels/anki-rwkv` tag `rwkv-family-2026-11-13` 的 Small Instant-Only，钉 JSchoreels/anki 提交
`001440b03395f24ffc1714b18ad3d9d4d89d2067`（release 说明写明 fork 里的文件与 release「byte for byte」相同）的
`qt/aqt/rwkv_inference/sm98/weights.{int8,f32}.bin`、`architecture.json`（与 sm72e25 逐字节相同，SHA-256
`9bd41f11…`）与 `rslib/src/rwkv/testdata/sm98-vectors.json.gz`，哈希见 `src/lib.rs`（与该提交的 `manifest.json`
一致）；随之加入回放预测的 show-time 查询行（INTEGRATION.md §6.10，README「sm98」），并让 RWKV-Curve 拒绝
Instant-Only 小模型。同一提交的 Tiny Instant-Only **sm101**（`qt/aqt/rwkv_inference/sm101/` 与
`rslib/src/rwkv/testdata/sm101-vectors.json.gz`，哈希见 `src/lib.rs` 的 `TINY_MODEL_*_SHA256`）作设置里可选的
省内存档，同一套代码加载、测试两套都对拍。2026-11-27 起换成 release `rwkv-family-2026-11-28`（fork main
`6cb164606`）的两个 Instant-Only 模型，钉提交 `6cb164606984c14432ef5e9befdedd6cc070f539`：Small **sm113**
（`qt/aqt/rwkv_inference/sm113/`，`architecture.json` 与 sm98 逐字节相同）与**默认**的六层 Tiny **sm130io**
（`qt/aqt/rwkv_inference/sm130io/`，"w64-c1-d2p1u1"），测试向量 `rslib/src/rwkv/testdata/{sm113,sm130io}-vectors.json.gz`；
权重与 `architecture.json` 与 release zip（按其 `SHA256SUMS` 校验）逐字节相同。层结构按 fork
`engine.rs::layer_plan_for` 的做法只认已知层数组合（README「sm113 / sm130io」）。上游 kuma3 / JSchoreels 的回放预测（`warm_up_reviews_sequential` 的 `query_input`）仍用作答
间隔；Fushi 按 §6.10 改，只影响小模型。权重与测试向量不入库，Fushi 只在用户启用时按钉死 URL 下载（运行时首选上面
的镜像）。

## 黄金值（tests/fixtures/）

由 `tools/oracle` 生成：它把上游 `rslib/src/rwkv` **原样**编译（`#[path]` 指向上游检出），
只给它 import 的三个外部名字加了空壳（`anki_io`、`anki_proto::…::ReviewCardOrder`、
`crate::card::CardType` / `relative_overdueness`，都只在 SQLite / spill / workload 路径上用到，
生成时不执行），然后对同一组输入跑上游的 `RwkvInference::warm_up_reviews` 与
`predict_retrievability_many_from_warm_up`，f32 与 int8 各存一份。输入：

- `upstream_golden_history`：上游自己的 35 条黄金历史（`qt/tests/test_rwkv_inference_process.py`），
  一次回放 + 末 9 条查询；该测试写死的 `_RWKV_GOLDEN_ROW0_IMMEDIATE` / `_ROW34_IMMEDIATE` 另行断言。
- `upstream_golden_history_incremental`：同一历史逐条回放。
- `edge_cases`：手写边界（兄弟卡、缺 note / deck / preset、缺时长、无评分行、同日重学、长间隔、
  从没复习过的卡、只给 elapsed 天或秒）。
- `simulated_collection`：确定性模拟收藏（640 卡 / 320 笔记 / 5 牌组 / 3 预设，≈400 调度日，
  7,528 条回放，单次调用超过上游批量块 2,048 行，查询批超过上游 512 行的状态块）。

生成平台 x86_64-windows。重新生成并核对（2026-10-19 实测与入库夹具逐字节相同）：

```sh
cd native/fushi_rwkv/tools/oracle
git clone --branch rwkv https://github.com/Pedrubik2000/kuma3-anki-core upstream
git -C upstream checkout c639bcec696f2317f9bb9a736d433b9d6c0d9c56
RWKV_UPSTREAM_SHA=c639bcec696f2317f9bb9a736d433b9d6c0d9c56 \
  cargo run --release --bin golden -- ../../model/RWKV_trained_on_5000_10000.bin py_golden.json ../../tests/fixtures
```

`py_golden.json` 由 `extract_py_golden.py` 从上游那份 Python 测试里抽出。

## 许可说明

- 本 crate 整体 **AGPL-3.0-or-later**（`Cargo.toml` 的 `license`）。Fushi app 本体是 GPL-3.0；
  GPLv3 §13 允许与 AGPLv3 作品组合，组合后 AGPL 部分的条款（含 §13 网络交互）继续适用。
- 所以本 crate **不并进** `native/fushi_fsrs`（GPL-3.0-only，避免把它拖成 AGPL）；
  随包时同理要注意 iOS 的伞形静态库 `native/fushi_ios_umbrella`：把本 crate 加进去会让整个伞形库
  受 AGPL 约束（后续随包任务需决定是否另出一个伞形库）。
- **无头服务端（`packages/fushi_server`）若对外提供 RWKV 调度**，按 AGPL §13 必须向通过网络
  与之交互的用户提供对应源码（含本 crate 与任何修改）。
- 上游重新同步时：在 kuma3-anki-core 新提交上重复「删了什么 / 改了什么」，重新生成黄金值并核对，
  更新本文件与 `src/lib.rs` 的 `UPSTREAM_SHA`。
