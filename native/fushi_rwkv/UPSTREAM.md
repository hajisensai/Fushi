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
以 AGPL-3.0-or-later 发布（上游未单列权重许可）。

## 搬了什么

| 上游文件（行数） | 本 crate（行数） | 处理 |
|---|---|---|
| `mod.rs`（12,748） | `src/rwkv/mod.rs`（≈4,800，其中 ≈200 行是标了 `Fushi` 的新增） | 推理核心逐字保留：权重加载（`WeightMap` / `Cursor`）、特征构造（`FeatureState`、`TorchIdRng` 与 ID 编码、全部 `scale_*` 与均值 / 方差常量、日期周期编码）、网络（`SrsModel` / `RwkvModule` / `RwkvLayer` / `TimeMixer` / `ChannelMixer` / `LoraSimple` / `Linear` / `Norm`、单步递推、AVX2+FMA / NEON / 标量 SIMD 辅助）、`ReviewInput`、`warm_up_reviews`（回放）、`warm_up_reviews_sequential`（逐条参考实现）、`predict_retrievability_many_from_warm_up`（批量 R 查询）、状态序列化 / 反序列化（`ARWKVMODSTATE1` f32 与紧凑格式）、特征簿记序列化（`ARWKVPROCSTATE2`） |
| `bulk.rs`（1,445） | `src/rwkv/bulk.rs`（1,367） | 批量回放逐字保留 |
| `precision.rs`（377） | `src/rwkv/precision.rs`（281） | int8 / int4 紧凑状态，删掉测试模块，其余未改 |
| `query_kernels.rs`（330） | `src/rwkv/query_kernels.rs` | aarch64 NEON 查询内核，未改 |
| `matmul.rs`（145） | `src/rwkv/matmul.rs` | macOS Accelerate `cblas_sgemm`，未改 |

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

## 改了什么（全部标 `Fushi:`；除下面「量化比例因子」一条外均不涉及数值）

- 权重从字节切片加载（`WeightMap::from_bytes` / `SrsModel::from_weight_bytes`，原来读文件路径）；
  公开 `RwkvModel`（可在多个 runtime 间共享），`RwkvInference::new(&model, precision)` 取代
  `load_with_precision(path, target_retention, max_interval_days, precision)`；为此给网络结构体
  加了 `#[derive(Clone)]`（非 f32 精度时复制一份网络，因为上游把精度存在 card / note 模块上）。
- `bulk.rs`：去掉曲线计算与 dirty 标记后，state-only 分支的返回值改为 `drop(..)`。
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
同架构重训的 release `small-model-sm56-2026-10-24`（包 `sm56-package.zip`，SHA-256
`7b1790f49fdabf1279510247cc9bc3bf3ac461b67cf0135ab8e51589b5efe71a`；`architecture.json` 与参考代码
与 sm40v2 逐字节相同，代码无需改动）。权重与测试向量不入库，
许可作者尚未声明（2026-10-20 核对：仓库 license 为空），Fushi 只在用户启用时从作者的 release 下载。

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
