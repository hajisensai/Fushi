# fushi_rwkv

Fushi 的 **RWKV-Instant** 原生推理库：把 Anki 社区 RWKV 调度
（[kuma3-anki-core](https://github.com/Pedrubik2000/kuma3-anki-core) 的 `rslib/src/rwkv`，
AGPL-3.0-or-later）的推理核心原样搬过来，外面包一层输入校验 + C ABI。来源、搬了什么 /
删了什么、许可见 [UPSTREAM.md](UPSTREAM.md)。

> **许可：本 crate 是 AGPL-3.0-or-later。** 它特意不并进 `native/fushi_fsrs`（GPL-3.0-only），
> 链接它的产物整体受 AGPL 约束；无头服务端若对外提供 RWKV 调度，须向用户提供源码。

现状（2026-10-19）：只有库 + 对拍测试 + CI 门。**还没有** Dart 绑定、各平台构建脚本与随包、
排程接入（等排程策略迁到 Rust 后再接）。

## 它算什么

RWKV-Instant 不给间隔，只给 **R（回忆概率）**：

1. 把用户全部复习历史**按时间顺序**回放（`frwkv_runtime_replay`）进一个 2,762,884 参数的
   RWKV 网络（通用预训练权重，不按用户训练），维护 card / note / deck / preset / global
   五层循环状态，以及特征构造器的簿记（每卡累计间隔、当天计数、ID 随机编码）。
2. 排队时对候选卡做一次只算 R 的批量查询（`frwkv_runtime_query`）。
3. 上游的到期判据：**R ≤ 目标保留率**即可排入（`rslib/src/scheduler/rwkv.rs:944`，
   `score > target` 判 Blocked；另有同日 / 最少间隔复习数等间距规则，`:964`）。这一步属于
   排程层，不在本库。

新答一题 = 追加回放这一条（增量，无需重放全史）。改写历史（删 revlog、Forget、改卡组归属
等）则要 `reset` 后全量重放——上游 kuma3 用历史指纹判断能否只追加（`offline.rs:433`
`history_plan`），本库不管这件事。

## C ABI

| 符号 | 作用 |
|---|---|
| `int32_t frwkv_abi_version(void)` | ABI 版本（当前 1）；Dart 侧不一致即判不可用 |
| `size_t frwkv_review_struct_size(void)` | `sizeof(FrwkvReview)`（80），核对结构体布局 |
| `FrwkvModel* frwkv_model_load(const uint8_t* bytes, size_t len)` | 从内存里的权重文件建模型；失败 NULL |
| `void frwkv_model_free(FrwkvModel*)` | 释放模型；已建的 runtime 各持一份引用，不受影响 |
| `FrwkvRuntime* frwkv_runtime_new(const FrwkvModel*, int32_t precision, uint32_t threads)` | `precision`：0 = f32、8 = int8；`threads`：0 = 全部核心，n = 专用 n 线程池（墨水屏 / 省电传 1）。失败 NULL |
| `void frwkv_runtime_free(FrwkvRuntime*)` | |
| `int32_t frwkv_runtime_replay(FrwkvRuntime*, const FrwkvReview* reviews, size_t count, float* out_predictions)` | 按时间顺序追加一批已答复习。`out_predictions` 可空；非空则写 `count` 个 f32：每条有评分行**作答前**的 R，无评分行写 NaN。任一行不合法 → `-2`，整批不应用 |
| `int32_t frwkv_runtime_query(FrwkvRuntime*, const FrwkvReview* queries, size_t count, float* out)` | 批量查询当前 R，写 `count` 个 f32；不合法的行写 **NaN**（见下） |
| `int32_t frwkv_runtime_snapshot(const FrwkvRuntime*, uint8_t** out_bytes, size_t* out_len)` | 导出无损快照（用 `frwkv_free_bytes` 释放） |
| `int32_t frwkv_runtime_restore(FrwkvRuntime*, const uint8_t* bytes, size_t len)` | 用快照替换状态；precision 必须一致；失败时状态不变 |
| `int32_t frwkv_runtime_reset(FrwkvRuntime*)` | 清空到新建状态 |
| `int32_t frwkv_runtime_stats(const FrwkvRuntime*, FrwkvStats* out)` | 已回放复习数、卡 / 笔记 / 牌组 / 预设数、各层状态字节数 |
| `char* frwkv_last_error(void)` | 本线程最近一次失败的可读错误（UTF-8，新分配）；无则 NULL |
| `void frwkv_free_string(char*)` / `void frwkv_free_bytes(uint8_t*, size_t)` | 释放上面两种返回值 |

返回码：`0` 成功；`-1` 调用错误（空指针、未知 precision）；`-2` 输入行不合法；`-3` 权重 /
快照字节损坏或不匹配；`-4` 内部 panic（已接住，不越过 FFI）；`-5` runtime 在之前的 panic 后
不可信（只接受 reset / restore / free）。一个 runtime 不是线程安全的，调用方串行化；model 可共享。
线程数不影响数值（上游的并行全是逐行 map，没有跨线程浮点归约；测试核对 0/1/3 线程逐位相同）。

### `FrwkvReview`（80 字节，`#[repr(C)]`，8 字节对齐）

```c
typedef struct {
  int64_t card_id, note_id, deck_id, preset_id;
  int64_t duration_millis, card_type, day_offset, elapsed_days, elapsed_seconds;
  uint32_t present;   // 下表的位：对应字段有值；没置位 = 上游的 None
  uint8_t  ease;      // 0 = 无评分（回放时跳过、查询时忽略），1..4 = Again/Hard/Good/Easy
  uint8_t  reserved[3];
} FrwkvReview;
```

`present` 位：`1` note_id、`2` deck_id、`4` preset_id、`8` duration_millis、`16` card_type、
`32` day_offset、`64` elapsed_days、`128` elapsed_seconds；其余位必须为 0（回放：整批 `-2`；查询：该行 NaN）。

## 字段语义（Fushi 复习日志 → ReviewInput 的依据）

下面的 `file:line` 都指上游 kuma3-anki-core @ `c639bcec`（见 UPSTREAM.md）。上游把 Anki
revlog 转成 `ReviewInput` 的链路是：`storage/revlog/mod.rs:720`
`rwkv_historical_review_rows_with_cutoffs`（选行）→ `scheduler/rwkv.rs:181` `walk`（算 day /
elapsed / preset）→ `scheduler/rwkv/history.rs:67` `historical_review`（card_type 编码）→
`scheduler/rwkv/offline.rs:479` `answered_input`。查询行由 `scheduler/rwkv.rs:536`
`rwkv_review_input_rows_from_cards` + `:629` `rwkv_review_input_state` 取数，`offline.rs:564`
`query_input` 组装。特征怎么用这些字段在上游 `rslib/src/rwkv/mod.rs:2804` `features_for`
（本 crate `src/rwkv/mod.rs` 同名函数）。

### 回放哪些复习（上游的排除规则）

- 按 revlog id（= 作答时刻毫秒）**升序**，全 collection 一条时间线（不是按卡分组）。
- 只要 `ease ∈ 1..=4` 且 `type ∈ 0..=5`；排除 `type = 3 (Filtered) 且 factor = 0` 的行
  ——即过滤牌组里「不改排程」的预习 / cram（`storage/revlog/mod.rs:800-806`）。
  `ease = 0` 的手动行（重排、Set Due Date、Forget）不是复习，不进回放。
- **Forget / 重置**：某卡最近一条 `type = 4 且 ease = 0 且 factor = 0`（Forget 写的标记行）
  之前（含）的该卡复习全部丢弃（`:772-778`、`:810-815`）。
- **只保留最近一次学习序列**：某卡出现「非学习行之后又一条 Learning（type 0）行」时，
  只保留最后一次这样的起点及之后的行（`:958` `retain_rwkv_rows_from_latest_learning_start`）。
  该起点行就是 `is_learning_start`。
- 卡已删除（cards 表里找不到）的 revlog 跳过（`:807`）。
- 本库的回放额外要求：有评分行的 `day_offset` 单调不减（跨批次也查），否则整批 `-2`。
  `ease == 0` 的行与上游一样被直接跳过（`bulk.rs:110`），不参与校验，也不影响特征。

### 逐字段

| 字段 | 回放（已答）| 查询 |
|---|---|---|
| `card_id` | revlog 的 cid。**也是时间戳**：首次复习的「自创建起 elapsed」用 `review_id - card_id` 算（见 elapsed）。 | 卡 id |
| `note_id` | 卡的 nid（`storage/revlog/mod.rs:766`）。缺失 → 用 `ID_PLACEHOLDER + card_id`（每卡一个独立占位，`mod.rs:2877`）并置「无 note」标志位 | 同 |
| `deck_id` | 卡**当前的家牌组**：在过滤牌组里时取 `odid`，否则 `did`（`:766`）。注意是读历史时卡的当前牌组，不是作答当时的牌组 | `card.original_deck_id.or(card.deck_id)`（`scheduler/rwkv.rs:561`） |
| `preset_id` | 稳定的预设 id：家牌组的 deck config id（`scheduler/rwkv.rs:255-283`、`:1074`）；有 add-on 预设覆盖规则时按规则路由 | 同，取不到（非数字 add-on 预设）→ 缺省 |
| `ease` | 1..4（Again/Hard/Good/Easy）| 忽略（查询总是 None） |
| `duration_millis` | revlog 的 `time`（毫秒，上游不截断；特征是 `ln(10 + ms)` 标准化，`mod.rs:3207`）| 忽略 |
| `card_type` | **不是卡类型**，是上游的「RwkvReviewState」：`0` = 学习序列起点（`is_learning_start`），否则 `revlog type + 1` —— `1` Learning、`2` Review、`3` Relearning、`4` Filtered、`5` Manual/Rescheduled（`history.rs:80-86`）。特征里是 `card_type - 2`。另：kuma3 在同一调度日再次复习 review 卡时改写那条 revlog 的 type——上一条是 Review+Again 或 Relearning+Again/Hard 记 Relearning（→ 3），否则记 Filtered（→ 4）（`offline.rs:949-999`，与桌面版一致）| 对特征**无影响**（查询行的 state 特征恒为 0）。上游填的是当前状态 0 new / 1 learning / 2 review / 3 relearning / 4 filtered（`offline.rs:566`），可照填或不填 |
| `day_offset` | **调度日**：`days_elapsed − ⌊(next_day_at − 1 − review_secs) / 86400⌋`，下限 0（`scheduler/rwkv.rs:1106`）。即按用户的「次日开始时间」（rollover）切日，以 collection 创建日为 0；时区 / UTC 偏移已含在 `next_day_at` 里。特征只用差值与 `(day − 首条复习日) mod 7 / mod 周期`，所以基准日可以任取，但**必须与切日规则一致**，同一调度日的复习必须同值 | 今天的调度日 `timing.days_elapsed`（`:607`）。必须 ≥ 最后一条已回放复习的 day，否则本库给 NaN |
| `current_elapsed_days` | 距**本卡上一条保留的复习**的调度日差，`max(0)`（`scheduler/rwkv.rs:228-251`）。本卡首条：若是学习起点且牌组配置开了「首次复习从创建算起」（默认有 deck config 即为真，`:1088`），`= ⌊(review_id − card_id)/1000/86400⌋`；否则 `-1` | review / relearning 卡：`next_day_at` 与上次复习时刻的日差；learning 卡：**缺省**（上游只给秒，特征里用 `秒 / 86400` 补）；新卡：开了上述配置时 `= 自创建秒数 / 86400`，否则缺省（`scheduler/rwkv.rs:629-711`）|
| `current_elapsed_seconds` | 距本卡上一条保留复习的秒数 `(review_id − prev_id)/1000`，`max(0)`；首条同上（`(review_id − card_id)/1000` 或 `-1`）| 距上次复习（`card.last_review_time`）到现在的秒数；新卡同上 |

补充规则：

- **首条学习复习不读 elapsed**：已答行 `ease ≠ None` 且 `card_type == 0` 时，上游把它的
  elapsed 一律当 `-1`（`mod.rs:3203` `creation_elapsed_is_query_only`）——「自创建起的时间」
  只给作答前那一刻的**查询**看。所以回放时首条照填上面的值也没关系，填 `-1` 亦可。
- 一个 elapsed 缺省时由另一个推出：`seconds = days × 86400`，`days = seconds / 86400`，
  都缺省则为 `-1`（`mod.rs:3176-3200`）。`-1` 的语义是「没有上一条」，不要用别的负数。
- **同日复习**照常回放：elapsed_days = 0、elapsed_seconds = 真实秒差；特征里另有
  「当天第几张新卡 / 第几条复习」计数（按 day_offset 切换）。
- **过滤牌组**：改排程的过滤牌组复习（type 3，factor ≠ 0）照常回放（card_type 4）；
  不改排程的（factor = 0）整条排除（见上）。deck_id 始终取家牌组。
- **查询不是纯函数**：第一次出现的 card / note / deck / preset id 会从上游复刻的
  PyTorch ID 编码随机流（`TorchIdRng`）里取一段 12 / 8 维编码并记住。所以同样的历史，
  查询的先后顺序会影响之后的特征（与上游行为一致；快照会保存这条随机流的位置）。
- 回放时可以要「作答前预测」（`out_predictions`）：对每条已答行先按查询算 R 再作答，
  与逐条「先查再答」一致（上游测试的黄金值就是这么来的）。上游 kuma3 平时回放不要预测
  （`offline.rs:337`，块大小 65,536）。
- kuma3 在 Android 端默认 int8 状态（`offline.rs:100-104`）。

### 查询给 NaN 的情况

缺 `day_offset`；`day_offset` 早于最后一条已回放复习；`elapsed_*` < -1；未知 `present` 位；
模型输出非有限或不在 [0, 1]。上游排程层对这类值同样当作「不可评分」（`offline.rs:507`
`valid_probability`）。

## 快照

`FRWKVSNAP1\0` + precision 字节（0 / 8 / 4）+ 上游 `append_warm_up_snapshot_binary` 的布局：
card、note、deck、preset 四张表（u32 个数，按 id 升序：i64 id + u32 长度 + 状态字节），
global（标志 + 长度 + 状态），特征簿记（标志 + 长度 + `ARWKVPROCSTATE2`，曲线表恒为空）。
**无损**：任意时刻导出 → 新 runtime 恢复 → 继续回放，结果与不中断逐位相同（有测试）。
kuma3 自己的离线状态文件把 deck / preset / global 存成 f16（有损），本库不用那种格式。

## 实测（2026-10-19，AMD Ryzen 7 9800X3D，16 逻辑核，Windows x64，release）

`cargo run --release --example bench -- <model> 5000 730 <threads>`：模拟 5,000 张卡 /
2,500 笔记 / 20 牌组 / 5 预设，730 天，56,511 条复习；按 65,536 条一块回放。

| | f32 | int8 |
|---|---|---|
| 回放，16 线程 | 1.90–1.97 s（≈29k 条/s） | 2.82–2.98 s（≈19–20k 条/s） |
| 回放，1 线程 | 11.4–12.0 s（≈4.7–5.0k 条/s） | 16.1 s（≈3.5k 条/s） |
| 查询 5,000 张卡，16 线程 | 157–163 ms（≈32 µs/卡） | 166–191 ms |
| 查询 5,000 张卡，1 线程 | 1.1–1.4 s（≈225–272 µs/卡） | 1.5 s |
| 单张查询 / 追加一条作答 | ≈0.25 ms / ≈0.45 ms | ≈0.3 ms / ≈0.5 ms |
| card 状态 | **52,278 B/卡**（3 层 × 4,352 个 f32） | **15,415 B/卡** |
| note 状态 | 34,858 B/笔记 | 10,283 B/笔记 |
| 特征簿记 | ≈180 B/卡 | 同 |
| deck / preset / global | 4 层 69,698 B/牌组、3 层 52,278 B/预设、4 层 69,698 B，恒为 f32 | 同 |
| 本例总状态 / 快照 | 350 MB / 351 MB | 104.5 MB / 105.5 MB |

估算：每卡 ≈ card 状态 + note 状态 / 每笔记卡数 + 180 B，即 f32 ≈ 70 KB/卡、int8 ≈ 21 KB/卡
（两卡一笔记）。2 万张卡：f32 ≈ 1.4 GB、int8 ≈ 0.42 GB 常驻。上游在 13,965 张卡的真实收藏上
报 f32 1,247 MB / int8 395 MB（`docs/rwkv-state-precision-2026-10-10.MD`），与此一致。
**手机上应默认 int8**（上游测得 int8 与 f32 的整体 log loss 差 −0.00005%、单条最大差 0.68 个百分点）。

x86 的查询走逐条标量路径；aarch64（Android / iOS）与 macOS 走上游的批量 GEMM / NEON /
Accelerate 路径，本表不代表移动端速度。冷启动第一次回放会多花数秒在缺页上（本机首轮 f32 9.8 s）。

## 测试

```sh
bash native/fushi_rwkv/fetch_model.sh          # 或 powershell -File native/fushi_rwkv/fetch_model.ps1
cargo test --release --manifest-path native/fushi_rwkv/Cargo.toml
```

权重缺失 / SHA-256 不符时测试**失败**并提示跑 fetch_model（不跳过）；`FUSHI_RWKV_MODEL`
可指向别处的权重文件。

- `tests/parity.rs`：与上游对拍（夹具由 `tools/oracle` 把上游 `rslib/src/rwkv` 原样编译后产出，
  f32 / int8 各一份），上游自己测试里写死的两个数，批量回放 vs 逐条回放的状态逐位相同，
  快照中断续跑，损坏快照拒收，线程数无关，reset。
- `tests/c_abi.rs`：只走 `extern "C"` 的往返与错误路径。
- 容差：f32 `1e-5`；int8 `1e-3`（来源见 `tests/common/mod.rs`：生成平台上实测 0 差；把 x86
  的 AVX2+FMA 内核强制换成标量内核模拟别的平台，int8 最大差 3.78e-4、f32 2.98e-7）。

## 构建

只有 cargo；`target/`、`prebuilt/`、`model/` 不入库。各平台构建脚本 / 随包是后续任务。
release 用 `opt-level = 3`（理由与实测见 `Cargo.toml`）。CI：`.github/workflows/native-rwkv-gate.yml`。
