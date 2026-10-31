# fushi_rwkv

Fushi 的 **RWKV 排程**原生推理库，两个网络：

- **大模型**（2,762,884 参数）：Anki 社区 RWKV 调度（[kuma3-anki-core](https://github.com/Pedrubik2000/kuma3-anki-core)
  的 `rslib/src/rwkv`，AGPL-3.0-or-later）的推理核心原样搬过来；来源、搬了什么 / 删了什么见
  [UPSTREAM.md](UPSTREAM.md)。
- **小模型 SM56**（331,511 参数，d_model 64）：JSchoreels/anki-rwkv release
  `small-model-sm56-2026-10-24`（包 sm56）。Fushi 按 SM40（`small-model-sm40-2026-10-19`，包 sm40v2）
  的 INTEGRATION.md 与 NumPy 参考实现**新写**（`src/rwkv/small/`）；SM56 是同一架构重训
  （`architecture.json` 与参考代码逐字节相同，只换权重与测试向量），与发布包黄金向量对拍；
  特征构造器与大模型共用。

外面包一层输入校验 + 作答时排程 + C ABI。权重都不入库（`fetch_model.*` 下载，见「测试」）。

> **许可：本 crate 是 AGPL-3.0-or-later。** 它特意不并进 `native/fushi_fsrs`（GPL-3.0-only），
> 链接它的产物整体受 AGPL 约束；无头服务端若对外提供 RWKV 调度，须向用户提供源码。

现状（2026-10-20）：五端随包（硬依赖，构建脚本 `build_*.{ps1,sh}`、`verify_abi.sh`）；Dart 绑定
`packages/fushi_rwkv`（FFI + 常驻 worker isolate）；排程接入 `SrsAlgorithm.rwkv`，**RWKV-Instant、
新建牌组的默认算法**（排队时用 `frwkv_runtime_query` 查此刻的 R，见[排队](#排队rwkv-instantfushi-用的)；
记忆状态与存下的到期日仍由 FSRS-7 维护；`packages/fushi_engine/lib/srs/srs_rwkv_*.dart`、
`SrsDbStore._instantReviews`）。权重由服务自动下载（`srs_rwkv_models.dart`，钉 URL + SHA-256）。

## 它算什么

模型有两个输出头：**即时头**给「此刻作答答对的概率」R，**曲线头**给「这次作答之后的遗忘曲线」R(t)：

1. 把用户全部复习历史**按时间顺序**回放（`frwkv_runtime_replay`）进 RWKV 网络（通用预训练
   权重，不按用户训练），维护 card / note / deck / preset / global 五层循环状态，以及特征构造器的
   簿记（每卡累计间隔、当天计数、ID 随机编码）。
2. 排队时对候选卡做一次只算 R 的批量查询（`frwkv_runtime_query`）。
3. 作答时用**曲线头**排出四个评分的间隔（见「作答时排程」），卡片按间隔到期。上游 kuma3 的
   RWKV-Instant 是另一种判据——每天对候选卡查即时 R，**R ≤ 目标保留率**即排入
   （`rslib/src/scheduler/rwkv.rs:944`）；Fushi 不用它，原因同「作答时排程」里即时头不能外推。

新答一题 = 追加回放这一条（增量，无需重放全史）。改写历史（删 revlog、Forget、改卡组归属
等）则要 `reset` 后全量重放——上游 kuma3 用历史指纹判断能否只追加（`offline.rs:433`
`history_plan`），本库不管这件事。

## C ABI

| 符号 | 作用 |
|---|---|
| `int32_t frwkv_abi_version(void)` | ABI 版本（当前 4）；Dart 侧不一致即判不可用 |
| `size_t frwkv_review_struct_size(void)` | `sizeof(FrwkvReview)`（80），核对结构体布局 |
| `FrwkvModel* frwkv_model_load(const uint8_t* bytes, size_t len)` | 从内存里的权重文件建模型，按内容识别大 / 小模型（`ARWKVWEIGHTS1` f32 两者皆可，`ARWKVWEIGHTS8PC1` int8 逐行仅小模型）；失败 NULL |
| `int32_t frwkv_model_kind(const FrwkvModel*)` | 1 = 大模型，2 = 小模型；空指针 `-1` |
| `void frwkv_model_free(FrwkvModel*)` | 释放模型；已建的 runtime 各持一份引用，不受影响 |
| `FrwkvRuntime* frwkv_runtime_new(const FrwkvModel*, int32_t precision, uint32_t threads)` | `precision`：0 = f32、8 = int8、4 = int4（**仅小模型**，见「状态精度」）、-1 = 推荐值（大模型 int8、小模型 int4）；`threads`：0 = 全部核心，n = 专用 n 线程池（墨水屏 / 省电传 1）。失败 NULL |
| `void frwkv_runtime_free(FrwkvRuntime*)` | |
| `int32_t frwkv_runtime_replay(FrwkvRuntime*, const FrwkvReview* reviews, size_t count, float* out_predictions)` | 按时间顺序追加一批已答复习。`out_predictions` 可空；非空则写 `count` 个 f32：每条有评分行**作答前**的 R，无评分行写 NaN。任一行不合法 → `-2`，整批不应用 |
| `int32_t frwkv_runtime_query(FrwkvRuntime*, const FrwkvReview* queries, size_t count, float* out)` | 批量查询当前 R，写 `count` 个 f32；不合法的行写 **NaN**（见下） |
| `int32_t frwkv_runtime_append(FrwkvRuntime*, const FrwkvReview* reviews, const uint64_t* tags, const int64_t* ats, size_t count)` | 同 replay 追加（状态逐位相同），每行记一条撤销日志（标签 `tags[i]`，Fushi 用日志 id 的 hash；评分时刻 `ats[i]` 毫秒，不得早于日志里最后一条）；每行必须有评分；**仅小模型**（大模型 `-6`）。日志上限 32 MB（约 600 条），超出丢最早的 |
| `int32_t frwkv_runtime_unappend(FrwkvRuntime*, uint64_t tag)` | 撤回最近一条 append，仅当标签是 `tag`：返回 1，状态与没回放过它逐位相同（之后没有新抽 ID 编码时连编码一并收回）；不是它 / 日志被 replay·restore·reset 清空过返回 0、什么都不改 |
| `int32_t frwkv_runtime_rewind_from(FrwkvRuntime*, int64_t at_ms, int64_t floor_ms, uint64_t* out_count)` | 退到 `at_ms` 之前：撤掉日志里时刻 ≥ `at_ms` 的全部条目，返回 1 并写撤了几条；状态与「只回放过时刻 < `at_ms` 的行」逐位相同，之后按时间顺序 append 从 `at_ms` 起的行 = 全量回放（Fushi 的「退回重放」）。`floor_ms` = 调用方保证最近一次 replay·restore·reset 之后不经日志进来的行的最晚时刻（reset 后 `INT64_MIN`，不知道 `INT64_MAX`）；它或超出容量丢掉的条目不早于 `at_ms` 时返回 0、什么都不改（调用方从检查点或全量回放重来） |
| `int32_t frwkv_runtime_scores_clear(FrwkvRuntime*)` | 清空常驻分数表 |
| `int32_t frwkv_runtime_scores_lookup(const FrwkvRuntime*, const int64_t* card_ids, const uint64_t* versions, size_t count, float* out_scores, uint8_t* out_found)` | 按（卡、版本）查分数表；命中写 R 与 1，否则 NaN 与 0；返回命中数 |
| `int32_t frwkv_runtime_scores_update(FrwkvRuntime*, const FrwkvReview* queries, const uint64_t* versions, const int64_t* anchors_ms, size_t count, float* out)` | 同 query 算 R（逐位相同，每行不取决于同批别的行）并记进表（版本、锚点 = 最后一条保留评分的毫秒时刻，无则 -1） |
| `int32_t frwkv_runtime_scores_requery(FrwkvRuntime*, int64_t today, int64_t now_ms)` | 全量刷新：把每一项的查询行改写成第 `today` 个调度日、此刻 `now_ms`（规则同 Dart `srsRwkvAddNowRow`）再整批重查；返回项数 |

分数表：append / unappend / replay 作废同卡、同笔记的项（它们的卡 / 笔记状态变了），牌组 / 预设 / 全局
状态被别的卡带动的变化由调用方定时 `scores_requery` 收敛；reset / restore 清空日志与表。契约测试
`tests/journal.rs`（含「rewind_from + 按时间顺序 append == 全量回放」的逐字节对拍）。
| `int32_t frwkv_runtime_next_intervals(FrwkvRuntime*, const FrwkvReview* answer, float target_retention, uint32_t max_interval_days, uint32_t* out_days, float* out_r)` | 作答时排程（见下）：写 4 个天数（Again / Hard / Good / Easy），`out_r` 可空；什么都不保存 |
| `int32_t frwkv_runtime_snapshot(const FrwkvRuntime*, uint8_t** out_bytes, size_t* out_len)` | 导出无损快照（用 `frwkv_free_bytes` 释放） |
| `int32_t frwkv_runtime_restore(FrwkvRuntime*, const uint8_t* bytes, size_t len)` | 用快照替换状态；precision 必须一致；失败时状态不变 |
| `int32_t frwkv_runtime_snapshot_to_file(const FrwkvRuntime*, const uint8_t* path, size_t path_len)` | 将无损快照直接写文件并 flush / sync_all；路径为无 NUL 结尾的 UTF-8 字节；调用者负责临时文件成功后提升 |
| `int32_t frwkv_runtime_restore_from_file(FrwkvRuntime*, const uint8_t* path, size_t path_len)` | 直接从文件有界读取；校验全部成功后替换状态并清空撤销日志与分数；失败时状态、poison 标记、日志与分数均不变 |
| `int32_t frwkv_runtime_reset(FrwkvRuntime*)` | 清空到新建状态 |
| `int32_t frwkv_runtime_stats(const FrwkvRuntime*, FrwkvStats* out)` | 已回放复习数、卡 / 笔记 / 牌组 / 预设数、各层状态字节数 |
| `char* frwkv_last_error(void)` | 本线程最近一次失败的可读错误（UTF-8，新分配）；无则 NULL |
| `void frwkv_free_string(char*)` / `void frwkv_free_bytes(uint8_t*, size_t)` | 释放上面两种返回值 |

返回码：`0` 成功；`-1` 调用错误（空指针、未知 precision）；`-2` 输入行不合法；`-3` 权重 /
快照字节损坏或不匹配；`-4` 内部 panic（已接住，不越过 FFI）；`-5` runtime 在之前的 panic 后
不可信（只接受 reset / restore / free）。`-6` 该模型不支持（撤销日志只有小模型）。一个 runtime 不是线程安全的，调用方串行化；model 可共享。
线程数不影响数值（大模型：上游的并行全是逐行 map，没有跨线程浮点归约，测试核对 0/1/3 线程逐位
相同；小模型：每个实体 × 头是一条顺序任务，块边界与线程数都不改结果，测试核对块大小 1 / 7 / 333 /
整批逐位相同）。

### 排队（RWKV-Instant，Fushi 用的）

上游 kuma3 / JSchoreels 的 RWKV-Instant（`rslib/src/scheduler/rwkv.rs`、`queue/builder/gathering.rs`）：
RWKV 牌组的复习卡**不看到期日**，每次排队以当前状态查每张复习卡此刻的即时 R（`frwkv_runtime_query`，
一批一次），**R ≤ 牌组目标保留率**的才出，按 R 升序，每日复习上限照常；今天答过的卡还要满足间隔守卫
（距上次作答 ≥ 30 秒且之后别的卡答过 ≥ 5 次，上游默认）。学习 / 重学 / 新卡照旧。每答一题后重查
（上游默认刷新间隔 1）。别的卡的作答改变牌组 / 预设 / 全局状态，所以一张卡什么时候回来会随整体表现
自动变化。上游的「每天最少复习数」默认 0，这里不做：R 都高于目标时队列为空，即模型认为都还记得。

存下的到期日（作答时由 FSRS-7 写）只在 RWKV 不可用时排队、导出给 Anki 时用；同步不需要它——
RWKV 状态由同步来的复习日志在每台设备上回放出来（同一权重、确定性）。统计页的未来到期 / 逾期 /
负担不计按 R 排队的卡，可提取度用 RWKV 的；浏览器的 `is:due` 与出卡同口径；日志的 `alg` 记 `rwkv`。

**为什么用即时头而不是曲线头**（`examples/curve_calibration.rs`，小模型 int4，20 个封存用户约 136 万对
相邻复习，按真实间隔分桶的预测均值 vs 实际通过率）：

| 分组 / 真实间隔 | 曲线头 | 即时头 | 实际 |
|---|---|---|---|
| 全体，90–365 天 | 0.841 | 0.810 | 0.812 |
| 全体，1–3 年 | 0.846 | 0.831 | 0.834 |
| 通过率 ≥ 95% 的用户，90–365 天 | 0.948 | 0.860 | 0.854 |
| 通过率 ≥ 95% 的用户，1–3 年 | 0.933 | 0.786 | 0.691 |

即时头在每个间隔段都基本校准，曲线头对长间隔过度乐观（高通过率用户里曲线头预测在 0.75–0.85 之间的
那些 90–365 天复习，实际只答对 44%）。即时头不能沿天数外推成间隔（见下一节），所以用它的方式就是
上游 Instant 的「每次排队重查」。

### 作答时排程（RWKV-Curve，库里保留，app 不用）

`frwkv_runtime_next_intervals` 读**曲线头**：对每个评分假设这张卡**现在**以该评分作答（一行不提交的
更新行，什么都不保存），得到这次作答之后的遗忘曲线 R(t)（小模型：3 条幂曲线的混合
`Σ w_i (1 + t/S_i)^(-d_i)`；大模型：128 条固定指数曲线的混合，上游 `predict_curve`），两者按构造
随 t 不增；间隔 = R(t) 第一次 ≤ 目标保留率的天数，向上取整、限制在 [1, 上限]，到上限仍高于目标给
上限；评分顺序用 PAVA 修正为不减。区间求解（网格 + 割线细化 + PAVA）与上游 RWKV-Curve 逐字相同
（`src/curve.rs`）。这正是小模型 INTEGRATION.md §9.2 规定的用法（`p_curve(t)` is the quantity to
schedule on）。

**为什么不用即时头外推（2026-10-20 修正）**：之前的实现把即时头的 R 当遗忘曲线，查「作答后第 d 天」
的 R 找越线点。即时头是「到期这一刻答对的概率」：训练数据里间隔越长的卡本来就越熟，它几乎不随假设
的间隔下降，也不单调（Again 之后的曲线会回升），约等于该用户的整体通过率。在 20 个封存用户上实测
（保留率 0.8，每人 300 张卡）：通过率高的用户 Good 间隔中位数顶到 36,500 天上限、连 Again 都排出
上百年；通过率低的用户一半以上的 Good 只给 1 天。改读曲线头后间隔连续分布（`examples/interval_dist.rs`）。

**仍然要知道的模型行为**：曲线头也是从该用户的历史学来的。几乎从不忘的用户（封存集里 Again 率
1%–2% 的那些）曲线非常平，保留率 0.8 下 Good 的中位间隔可到几千天，Again（重学毕业后）也可能是
几百天；通过率很低的用户则常是 1 天。大模型（上游实际发布的 RWKV-Curve）在同样输入上是同一量级，
不是 Fushi 的实现问题。牌组的最大间隔照常生效。

`frwkv_last_error` 存在**调用线程**的 thread-local 里。Dart isolate 只在一段同步执行内固定在
同一个 OS 线程上，回到事件循环（`await`）后可能换线程：返回码 < 0 时必须在**同一段同步代码里、
不经任何 `await`** 紧接着取 `frwkv_last_error`，否则可能拿到别的线程的旧错误或 NULL。

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

## 两个模型与状态精度

| | 大模型 | 小模型（SM56） |
|---|---|---|
| 参数 | 2,762,884 | 331,511 |
| 权重 | `RWKV_trained_on_5000_10000.bin`（11 MB，AGPL） | 发布包里的 `weights.int8.bin`（436 KB，加载时反量化）或 `weights.f32.bin`；许可作者尚未声明 |
| 状态精度 | f32 / **int8**（推荐） | f32 / int8 / **int4**（推荐） |
| card + note 状态 / 卡（一卡一笔记） | int8 25,698 B | int4 2,944 B（int8 4,480 B） |
| 回放速度（下表） | ≈16k 条/s | ≈50k 条/s |

card / note 状态按精度紧凑存储（每行 16 个值一个 f32 比例 + 8 / 4 位码字，shift 存 f16）；deck /
preset / user 状态恒为 f32。

**int4 数值稳定性（Fushi 的修复，2026-10-20）。** 上游的量化每行按 `max/limit` 定标再四舍五入：
落在半个台阶到一个台阶之间的分量会被抬到一个台阶（最多 ×2），每次作答都往状态里注入能量。
card 状态第一层的递推不阻尼这种误差：在一份 121 万条复习的真实历史上，小模型 int4 有 101 张高频卡
的状态每次复习 ×1.06（0.25 → 7,962，往 f32 溢出走）；上游大模型的 int4 笔记状态在 350 万条历史上
同样溢出（它因此把笔记退回 int8）。现在两种模型的量化都改为**最小二乘比例因子**
（`scale = (x·c)/(c·c)`，存下的行是原行在码字方向上的正交投影，范数不增；同样码字下 L2 误差最小），
存储格式不变。效果：

- 小模型 int4：上面那份历史与合成的每卡 1 万次复习历史上，card / note 峰值都与 f32 同量级；
  LogLoss 与旧量化相差 ≤ 0.0002。
- 大模型 int4：card 状态**仍然发散**（每卡 1 万次复习时峰值 1.3e16，f32 为 3.7），所以
  `frwkv_runtime_new` 拒绝大模型 + int4（`ModelKind::supports`）。大模型 int8 稳定。
- 钉住它的测试：`tests/long_history.rs`（换回旧量化器即失败，已做变异实测）、
  `small/model.rs` 的 `quantization_never_lengthens_a_row`。

**准确率（部署路径）**：`examples/replay_eval.rs` 在 anki-revlogs-10k 的 295 个封存用户（两个模型都
没训练过）上，用本库的特征构造与回放算每条非首次复习作答前的 R（2026-10-20，共 19,462,638 条；
**小模型为 SM40**，换 SM56 后未在这 295 人上重跑，见下方「SM56」）：

| | LogLoss（按条加权） | 更好的用户数 | 非有限值 | 状态峰值（card / note） | 回放耗时（16 线程，总计） |
|---|---|---|---|---|---|
| 小模型 int4 | **0.26998** | 159 / 295 | 0 | 1.22 / 0.44 | 2,265 s |
| 大模型 int8 | 0.28247 | 136 / 295 | 0 | — | 4,152 s |

小模型 int4 比大模型 int8 低 4.42%，与 JSchoreels 训练打分器下「大模型好 0.92%」的结论相反：
打分器用的是训练管线自己的特征，这里是 Fushi 实际部署的特征构造。大模型在少数用户上明显变差
（如 3306：0.613 对 0.517，f32 一样差，不是量化造成的）。所以默认小模型 int4，大模型只作为可选项，
不称「质量优先」。

**SM56（2026-10-27 换上）。** 作者的打分器下（723 个留出用户，int8 权重 + int8 状态）SM56 比大模型
高 0.34% / 0.47%（曲线 / 即时），SM40 是约 +1%；与上一版 SM55 的成对差在 0 以下。作者**没有**在
SM56 上测 int4 状态，所以换之前在部署路径上补测（本机没有 295 人的数据集，只能用下面两份）：

| 历史 | 配置 | SM40 LogLoss | SM56 LogLoss | 状态峰值 card / note（SM40 → SM56） | 非有限值 |
|---|---|---|---|---|---|
| 发布包测试向量用户 4676（3,716 条，2,838 条计分） | int4 | 0.064858 | 0.063046 | 0.45 / 0.26 → 0.44 / 0.64 | 0 |
| 同上用户 1745（4,144 条，3,705 条计分） | int4 | 0.402668 | 0.404410 | 0.61 / 0.25 → 0.61 / 0.63 | 0 |
| 两人合计（按条加权；大模型 int8 0.25455） | int4 | 0.25614 | 0.25634 | | |
| `long_history.rs` 的合成历史，6 卡 × 1 万天 | f32 | 0.414853 | 0.417993 | 0.96 / 0.25 → 1.73 / 3.43 | 0 |
| 同上 | int4 | 0.415103 | 0.417222 | 0.49 / 0.12 → 0.77 / 1.00 | 0 |

结论：两位真实用户上与 SM40 持平（+0.08%，样本太小，分不出好坏）；SM56 的 int4 与自己的 f32
相差 ≤ 0.0003，长历史下状态有界（`LONG_DAYS=10000` 的 `long_history.rs` 通过）。SM56 的 note
状态量级本身比 SM40 大（f32 下也是），int4 的最小二乘量化反而把它压得比 f32 小，没有发散迹象。
测试向量用户的 .bin 由包里 `testvectors/user_*.npz` 的更新行（`raw_*` 列，`card_type` 取
`raw_state`）转换；部署路径在这两人上与参考实现的即时头 LogLoss 相差 < 1%（ID 编码随机不同）。
换模型后旧快照按权重指纹被拒，首次启动全量重放一次。

## 快照

大模型：`FRWKVSNAP1\0` + precision 字节（0 / 8 / 4）+ 上游 `append_warm_up_snapshot_binary` 的布局：
card、note、deck、preset 四张表（u32 个数，按 id 升序：i64 id + u32 长度 + 状态字节），
global（标志 + 长度 + 状态），特征簿记（标志 + 长度 + `ARWKVPROCSTATE2`，曲线表恒为空）。
**无损**：任意时刻导出 → 新 runtime 恢复 → 继续回放，结果与不中断逐位相同（有测试）。
kuma3 自己的离线状态文件把 deck / preset / global 存成 f16（有损），本库不用那种格式。

小模型：`FRWKVSMALL1\0` + precision 字节 + 权重指纹（u64，FNV-1a，别的权重文件的快照被拒）+ 五个流
（card、deck、note、preset、user）各自：槽长 u32、个数 u32、按 id 升序的（i64 id + 槽字节）；最后
u32 长度 + `ARWKVPROCSTATE2` 特征簿记。同样无损。

**内存**：card / note 的紧凑状态存在定长槽位池（`src/rwkv/slots.rs`，按 1 MB 分块、原地覆盖）。上游
每份状态一个 `Vec`，回放时与每块的 f32 解码临时数据交错分配释放，长期块钉住空洞：2026-10-20 实测
1.5 万张卡（大模型 int8）存活分配 401 MB、工作集 760 MB，`HeapCompact` 一点也还不回去。改后同一场景
工作集 / 状态从 1.87–2.0 倍降到约 1.5 倍；余下部分是上游批量回放的瞬时峰值（每块把涉及的卡各 3 层
解码成 f32，回放中存活峰值 647 MB）被堆留住。小模型引擎每步只在栈 / 小块暂存里解码当前层，约 1.4 倍。

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

## 小模型实测（同一台机器，同一模拟收藏：14,715 卡 / 7,358 笔记，167,061 条复习）

| | 小模型 int4 | 小模型 int8 | 大模型 int8 |
|---|---|---|---|
| 回放，16 线程 | 3.3 s（≈51k 条/s） | 4.4 s | 10–12 s（≈14–16k 条/s） |
| 查询 14,715 张卡 | 215 ms（15 µs/卡） | 357 ms | 640–750 ms |
| card / note 状态 | 1,920 B/卡、1,024 B/笔记 | 2,944 / 1,536 | 15,415 / 10,283 |
| 总状态 / 进程工作集增量 | 36 MB / 54 MB | 55 MB / 76 MB | 304 MB / 461–573 MB |

真实历史（含逐条作答前预测）：121 万条复习的用户，小模型 int4 回放 28 s、大模型 int8 约 4 分钟。

不做 GPU：小模型在桌面上一次全量回放是秒级到几十秒（之后增量追加、快照缓存），移动端的瓶颈是内存
而不是算力；递推的 user 流是一条贯穿全部复习的顺序依赖，GPU 也只能按层并行，换来的是每个平台一套
着色器后端与驱动差异。

## 测试

```sh
bash native/fushi_rwkv/fetch_model.sh          # 或 powershell -File native/fushi_rwkv/fetch_model.ps1
cargo test --release --manifest-path native/fushi_rwkv/Cargo.toml
```

权重缺失 / SHA-256 不符时测试**失败**并提示跑 fetch_model（不跳过）；`FUSHI_RWKV_MODEL`
可指向别处的大模型权重，`FUSHI_RWKV_SMALL_PACKAGE` 指向别处的小模型发布包（zip，测试直接从包里读
权重与 `testvectors/*.npz`）。

- `tests/parity.rs`：与上游对拍（夹具由 `tools/oracle` 把上游 `rslib/src/rwkv` 原样编译后产出，
  f32 / int8 各一份），上游自己测试里写死的两个数，批量回放 vs 逐条回放的状态逐位相同，
  快照中断续跑，损坏快照拒收，线程数无关，reset。
- `tests/c_abi.rs`：只走 `extern "C"` 的往返与错误路径。
- `tests/small_model.rs`：小模型与发布包 NumPy 参考实现的黄金向量（两位用户、14,403 行，f32 / int8
  权重）逐行对拍 p_imm、p_rating、标签时刻与 6 个扫描时刻的 p_curve，容差 1e-5（实测最大 3.4e-6）；
  块边界不改结果（三种精度逐位相同）；`layer_steps` 与 `architecture.json` 一致。
- `tests/forecast.rs`：假设作答不改状态、与真的作答一致；排程读的遗忘曲线随时间不增、次日 Again
  低于 Easy，天数是曲线上「当天 R ≤ 目标、前一天 > 目标」的那天；`src/curve.rs` 的单元测试用已知
  形状的曲线钉住求解器（越线点向上取整、评分顺序、上限 / 下限）。
- `examples/interval_dist.rs`：真实历史上排出的间隔分布（各保留率下 Good / Hard / Again 的分位数）。
- `tests/long_history.rs`：长历史下紧凑状态有界（见「状态精度」），`LONG_DAYS=10000` 加长。
- `examples/replay_eval.rs`、`examples/state_drift.rs`、`examples/bench.rs`：真实历史评测、状态峰值
  追踪、速度与内存。
- 容差：f32 `1e-5`；int8 `1e-3`（来源见 `tests/common/mod.rs`：生成平台上实测 0 差；把 x86
  的 AVX2+FMA 内核强制换成标量内核模拟别的平台，int8 最大差 3.78e-4、f32 2.98e-7）。

## 构建

`build_windows_dll.ps1` / `build_android_so.{ps1,sh}` / `build_linux_so.sh` / `build_macos_dylib.sh`
产出到 `prebuilt/<平台>/`，iOS 并进 `native/fushi_ios_umbrella`；`verify_abi.sh` 核对导出表与 Dart
绑定。app 构建缺库即失败（硬依赖）。`target/`、`prebuilt/`、`model/` 不入库。
release 用 `opt-level = 3`（理由与实测见 `Cargo.toml`）。CI：`.github/workflows/native-rwkv-gate.yml`。
