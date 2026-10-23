# SRS 胖核心迁入 Rust（2026-10-23）

> 依据：根 `CLAUDE.md`「Rust 胖核心、Flutter 薄 UI（用户 2026-10-19 拍板）」。上游设计见
> [2026-10-14-fushi-srs-design.md](2026-10-14-fushi-srs-design.md)（事件模型、铁律 A–G、同步协议），
> 本文只讲「状态与计算从 Dart 搬到 Rust」的分期，不改事件模型与线格式。

## 1. 现状：状态与计算在哪

SRS 的事实来源是三类不可变事件（身份记录 `srs_entities`、字段修改记录 `srs_field_edits`、复习日志
`srs_review_logs`），派生态是两张缓存表（`srs_notes_cache` / `srs_cards_cache`）。今天：

| 部分 | 位置 | 跑在哪 |
|---|---|---|
| 事件落库、去重、支配判定 | `packages/fushi_engine/lib/srs/srs_db_store.dart` `_storeLocalBatch` | UI isolate（Drift 语句经后台 isolate 往返） |
| 事件 → 缓存行物化（笔记寄存器、卡片生成、卡片标志继承、复习日志 → 排程状态） | 同上 `_flushCaches` / `_planNote` / `_cardCacheRow`；规则在 `packages/fushi_srs`（`field_edit.dart` / `entities.dart` / `valid_logs.dart`） | UI isolate，块内连续计算不让出事件循环（`_refreshChunk` 的自注） |
| 计数、选卡、牌组树 | `srs_db_store.dart` `_countContext` / `nextCard` / `deckSummaries` | UI isolate |
| FSRS 公式、优化器、Anki 搜索求值、查重规范形 | `native/fushi_fsrs`（Rust） | 已是 Rust |
| RWKV-Instant 回放状态 | `native/fushi_rwkv`（Rust，后台 isolate 持有 runtime） | 已是 Rust |

除缓存表之外还有几份**Dart 侧镜像状态**，各自按请求或按戳重建：

1. AnkiConnect 整库笔记（`srs_ankiconnect_handler.dart` `_liveNotes`：按 `notesCacheStamp` 整库物化 `SrsNoteView`）；
2. AnkiConnect 查重规范形 `_dupeNorms`（noteId → 首字段 / 规范形，跨请求复用）；
3. AnkiConnect 查询身份 `_queryIdentities`（任务清单点名；本 PR 基线 `329a739431` 上还没有这个符号，属于并行的 AnkiConnect 整库快照改动）；
4. 搜索语料：AnkiConnect `findNotes` / `findCards` 每个请求按快照重建 `_CardSubject` 列表并新建
   `SrsSearchCorpus`（原生侧语料随请求释放）；浏览页、统计各建一份。

这些镜像与缓存表是同一份事实的不同投影，各自维护失效规则。胖核心的终局是：**事实与投影都归 Rust，
Dart 只发命令、渲染快照**。

### 1.1 实测热点（第一阶段选块依据）

`packages/fushi_engine/test/srs/srs_cache_rebuild_bench_test.dart`（临时文件库，`createInBackground`，
与 app 同一种连接）。3000 笔记 / 6000 卡 / 每卡 10 条日志，`rebuildCaches()` 分段计时（临时打点，未入库）：

| 段 | 耗时 | 占比 |
|---|---:|---:|
| 预读：日志与修改记录的服务器时刻（按 6.6 万个事件 ID 另查 `srs_event_local`） | ≈ 760 ms | 39 % |
| 预读：复习日志行（跨 isolate 搬运 Drift 行） | ≈ 270 ms | 14 % |
| 复习日志 JSON 解码（`jsonDecode` + `SrsReviewLog.fromJson`） | ≈ 310–370 ms | 17 % |
| 写缓存（一个 Drift batch） | ≈ 200 ms | 10 % |
| 笔记物化（寄存器 + 卡片生成） | ≈ 120 ms | 6 % |
| 有效日志选取 + 状态（`SrsCardHistory`） | ≈ 16–20 ms | 1 % |
| 合计 | 1.7–1.9 s | |

结论：「复习日志 → 排程状态」这一段（取日志 + 取服务器时刻 + 解码 + 选取）占缓存物化的约 70 %，而其中
真正的规则计算只占 1 %——**只把选取搬进 Rust 而让 Dart 照旧解码，端到端不会更快**。第一阶段因此按
CLAUDE.md 的「先加粗边界」整段搬：日志原文直接交给 Rust，服务器时刻与日志在同一条语句里取出。

## 2. 终局形态

### 2.1 状态归属

| 状态 | 终局归属 | 说明 |
|---|---|---|
| 事件三表 + `srs_event_local` + 发件箱 / 留存批次 | Rust 核心（`native/fushi_srs_core`，自持 SQLite 连接） | 事务边界在 Rust；Drift 不再写 `srs_*` 表（守卫钉死） |
| 笔记 / 卡片缓存、计数、牌组树 | Rust 核心（内存索引 + 缓存表） | 增量维护，命令返回快照 |
| AnkiConnect 整库笔记 / `_dupeNorms` / 查询身份 / 搜索语料 | Rust 核心的常驻索引 | 随事件增量更新，不再按请求重建 |
| FSRS / 优化器 / 搜索求值 | 现 `native/fushi_fsrs`，并进核心或作为核心依赖 | 公式与搜索不变 |
| RWKV 回放状态 | 仍是 `native/fushi_rwkv` + 后台 isolate | 单独的库，见 §5.3 |
| 同步目录 IO、云盘 / 互联传输、媒体文件 | Dart | IO / 编排，不搬 |
| 卡面渲染（WebView）、模板 JS、i18n | Dart | 不搬 |

### 2.2 粗粒度命令

一次用户交互对应个位数次 FFI 调用；大块数据走指针 / `TypedData`；可能超过约 1 ms 的命令在后台
isolate（或核心自己的工作线程 + `SendPort` 回推）上跑，不阻塞 UI isolate。

| 命令 | 一次调用做什么 | 返回 |
|---|---|---|
| `open(profile, dbPath)` | 打开库、校验 / 升级缓存版本 | 牌组树快照 + 修订号 |
| `answer(cardId, rating, ctx)` | 读历史 → 排程 → 写日志 → 刷缓存 → 推进 HLC，一个事务 | 新日志 + 受影响计数 |
| `undo` / `reset` / `setDue` / `editFields` / `bulk(ops)` | 同上，各一个事务 | 事件 ID 列表 |
| `applyRemote(batchBytes, serverTime)` | 解批次、落库、刷缓存 | 受影响实体 + 下限变小的事件（转发用） |
| `importApkg(handle)` | 流式导入（与 apkg 流式会话对齐） | 进度事件 + 报告 |
| `nextCard(deck)` / `deckSummaries()` / `cardDetail(id)` | 读缓存 / 索引 | 小快照 |
| `browse(query, sort, page)` | 搜索 + 排序 + 分页 | 一页行（列式） |
| `ankiFindNotes(query)` / `ankiCanAdd(fields[])` / `ankiNotesInfo(ids)` | 常驻索引上求值 | 列式结果 |
| `exportPages(kind)` / `backupLines()` | 分页导出 canonical 行 | 字节页 |
| `rwkvRows(cursor)` | 给 RWKV 回放的日志行 | 与 `RwkvRows` 同布局 |

### 2.3 事件 / 快照 stream

核心维护单调修订号 `rev`；每个写命令结束时推一条变更事件 `{rev, notes[], cards[], decks[], kind}`
（ID 列表打包成 `TypedData`）。Dart 侧：

- 复习页 / 浏览页 / 首页计数按变更事件决定是否重新拉快照（替代今天的 `changeFingerprint` + `tableUpdates`）；
- AnkiConnect 不再自己按戳重建，直接调核心命令；
- 快照一律不可变、带 `rev`，Dart 不另存镜像。

## 3. 迁移阶段

每一阶段都按 CLAUDE.md 的搬迁规则：整段搬、删 Dart 版、不留回退；原生库是硬依赖（加载失败明确报错，
测试找不到库要失败）；删除前用旧实现生成固定输入 → 输出向量；PR 写端到端耗时（含 FFI 与拷贝）。

| 阶段 | 范围 | 删除的 Dart | 回归向量 | 端到端验收 |
|---|---|---|---|---|
| **P1（本 PR）卡片历史内核** | 复习日志 → 排序 / 撤销 / 等价导入 / 排程归属 / 当前状态；缓存刷新把日志原文直接交给 Rust；预读里服务器时刻改为 JOIN | `SrsCardHistory._computeEffective` / `lastEffective` / `scheduler` 的 Dart 实现；按事件 ID 另查服务器时刻 | 1500 份随机历史 × 两条入口（§4.2） | `rebuildCaches` / `histories(全部)` / 单卡交互（§6） |
| P2 寄存器物化 | 字段修改记录 → 寄存器（因果上下文合并、`srsResolveRegister`、删除并发）→ `SrsNoteView` / `SrsCardFlags` / `SrsNoteTypeView`；排序键 `srsSortKey`；导入器的等价判重并进内核 | `field_edit.dart` 的寄存器合并、`ordering.dart`、`entities.dart` 的 materialize、`srsImportEquivalent` | 随机修改记录集（含并发 / 支配 / 删除并发 / 前身链）→ 物化视图 JSON | 打开 1 万笔记库的笔记物化、批量改标签 |
| P3 缓存刷新整段 | 笔记缓存行 + 卡片生成（`isAnkiCardEmpty` / cloze 序号）+ 卡片缓存行一次算完；Dart 只做预读与写 batch | `_planNote` / `_applyNotePlan` / `_cardCacheRow` | 用 P1+P2 之后的 Dart 刷新路径生成「事件集 → 缓存行」向量 | 导入 1 万笔记、`rebuildCaches`、单卡作答 |
| P4 事件库归 Rust | Rust 自持 SQLite 连接，事务边界与写入全在 Rust；计数 / 选卡 / 牌组树改为核心命令；Drift 对 `srs_*` 只读或不碰 | `SrsDbStore` 的写路径与 `_countContext` | 同步模拟器（`simulator_test`）整套改为驱动核心；现有往返次数守卫改为「命令次数」守卫 | 作答、打开复习页、应用一批对端事件 |
| P5 AnkiConnect 镜像收编 | 整库笔记、`_dupeNorms`、查询身份、搜索语料改为核心常驻索引，随变更事件增量更新 | handler 里的四份镜像与按请求重建 | AnkiConnect 现有契约测试 + 用镜像版生成的 `findNotes` / `canAddNotes` 向量 | Yomitan 连续 `findNotes` / `canAddNotes` 一千次 |
| P6 统计 / 优化器 / RWKV 取数 | 统计投影、优化器训练集、`RwkvRows` 由核心按页产出 | `srs_stats_loader.dart` 的取数与 `SrsCardHistory` 循环、`srs_rwkv_history.dart` 的取数 | 用旧取数生成的统计结果 / 训练集 / RWKV 行指纹 | 打开统计页、一次优化、RWKV 全量重建 |

P2 与 P3 可以在同一 PR 里做（它们共享预读形状）；P4 是分水岭，之前每个阶段都保持「Drift 是唯一连接、
Rust 是纯函数内核」，事务语义不变；P4 之后 Rust 持有连接。P5 依赖 P4（常驻索引要与事务同步），
在那之前 AnkiConnect 整库快照会话的接口按 §5.4 对齐。

## 4. 第一阶段（本 PR）

### 4.1 实现

- `native/fushi_fsrs/src/history.rs`：选取规则唯一实现。两个批量入口：
  - `ffsrs_history_states`：落库形态（canonical JSON 原文 + 服务器时刻，按历史分组）→ 每份历史的当前
    状态（`SrsScheduleResult` 全字段 + lastLogId + 排程归属），二进制定长记录 + 串表；
  - `ffsrs_history_select`：列模式（Dart 内存里的 `SrsReviewLog` 打包成 7 列 i64 + 串表）→ 去重后排序与
    每条日志的选取标记。
  规则细节（UTF-16 码元序比较字符串、同 ID 留最后一条、`res` 不是对象当没结果、必填键缺失 / 类型不对
  判坏数据、浮点按精确舍入解析）都按旧 Dart 实现逐条对齐，向量钉死。
- `packages/fushi_srs/lib/src/history_kernel.dart`：打包 / 解包；原生库缺失抛
  `SrsHistoryKernelUnavailableError`，没有 Dart 回退。
- `SrsCardHistory`（`valid_logs.dart`）改为选取结果的视图：构造即一次 FFI；`SrsCardHistory.many` 一批一次。
- `SrsDbStore`：缓存刷新（`_flushChunk` / `_refreshCardChunk`）改为 `_prefetchLogBlobs`
  （`CAST(json AS BLOB)` + `LEFT JOIN srs_event_local`）→ `_cardMaterials` 整块一次 `ffsrs_history_states`；
  `_prefetchEdits` / `_prefetchLogs` 的服务器时刻改为 JOIN 取，删掉按事件 ID 另查的 `_prefetchServerTimes`；
  `histories()` 整块一次 `SrsCardHistory.many`。
- 未动：`srs_ankiconnect_handler.dart`（整库快照会话在改）；`srs_stats_loader.dart` 仍逐卡构造
  `SrsCardHistory`（每卡一次 FFI，统计投影会话在改那段取数，P6 收编）。

### 4.2 回归向量

`packages/fushi_srs/test/history/fixtures/history_vectors.json.gz`，由**删除前的 Dart 实现**在
`329a739431` 上生成（脚本留档 `gen_history_vectors.dart.txt`）：1500 份历史、约 1 万条日志，覆盖撤销 /
撤销不存在的目标 / 等价导入的 ±1 秒边界 / handOff / 不认识的 kind / 同 ID 重复 / 服务器时刻钳位 /
代理对 writerId（UTF-16 序与码点序相反）。`history_vectors_test.dart` 要求列模式（逐份与整批）与落库形态
两条入口与旧实现逐条一致；另有坏数据用例：Rust 与 `SrsReviewLog.fromJson` 同样判错。

### 4.3 端到端耗时

见 §6（PR 里同表）。

## 5. 边界

### 5.1 同步

事件不可变、线格式不变（`SrsReviewLog.toJson` / canonical JSON），核心读的正是落库原文。P1–P3 期间
`SrsSyncReplica` 仍由 `SrsDbStore` 实现；P4 起由核心实现同一接口（批次冻结、留存、转发、S(e) 合并都在
核心事务里），`fushi_srs` 的同步引擎（目录进度、文件 IO、多目录转发）留在 Dart——它是 IO 编排，
只经 `SrsSyncReplica` 的粗粒度方法与核心交互。排序键钳位规则（S(e) + 10 分钟）P1 起在 Rust 选取里已有
一份、在 Dart 寄存器排序里还有一份，P2 收编后只剩 Rust。

### 5.2 备份

备份 zip 的格式与按时间点恢复（`srs_backup_store.dart` / `restore_plan.dart`）不变。恢复规划
（`srsPlanStateRestore`）依赖 `SrsCardHistory`，P1 起选取已走 Rust；恢复写出的日志仍经事件落库路径。
P4 起 `exportCanonicalLines` / `exportAll` 改为核心分页导出，备份 IO 与 zip 打包留在 Dart。

### 5.3 RWKV

`native/fushi_rwkv` 保持独立的库与后台 isolate（AGPL-3.0-or-later，许可证边界不能并进 GPL 核心）。
核心只负责产出回放用的日志行（P6 的 `rwkvRows`，布局沿用 `packages/fushi_rwkv` 的 `RwkvRows`），
不链接、不调用 RWKV；排队时的回忆率仍由 `SrsRwkvService` 经 RWKV worker 给出。P1 不碰 RWKV 路径。

### 5.4 与 AnkiConnect 整库快照会话的接口约定

P5 之前，整库快照会话（`srs_ankiconnect_handler.dart`）按 `SrsDbStore.notesCacheStamp()` 失效。约定：

- 快照的失效键继续是「缓存修订」这一个值；P4 起它就是核心的 `rev`，快照代码只换取值来源；
- 快照里的每卡状态一律读缓存表 / 核心快照，不自己从日志重算（P1 起日志 → 状态只有 Rust 一份）；
- 查重规范形继续走 `srsDupeNormBatch`（已是 Rust），P5 改为核心常驻索引的命令，入参出参形状保持。

## 6. 第一阶段实测

本机 Windows x64，`FUSHI_SRS_CACHE_BENCH=<笔记数> dart test test/srs/srs_cache_rebuild_bench_test.dart`
（`packages/fushi_engine`），每卡 10 条日志，三轮。计的是调用方看到的整段耗时（读库 + 跨 isolate 搬运 +
打包 + FFI + 写缓存）。改前 = `0073dddcdf`（向量提交，仍是 Dart 实现），改后 = 本 PR。

| 规模 | 操作 | 改前 | 改后 |
|---|---|---:|---:|
| 3000 笔记 / 6000 卡 | `rebuildCaches()` | 1694–1865 ms | 1254–1401 ms |
| | `histories(全部 6000 卡)` | 1157–1177 ms | 1034–1105 ms |
| | `setFlag`（单卡事件 + 单卡缓存刷新） | 9–51 ms | 9–18 ms |
| 10000 笔记 / 20000 卡 | `rebuildCaches()` | 7209–9453 ms | 3958–5445 ms |
| | `histories(全部 20000 卡)` | 4990–5755 ms | 3445–3972 ms |
| | `setFlag` | 10–22 ms | 9–11 ms |

改后 3000 笔记 `rebuildCaches()` 的分段（临时打点，未入库）：

| 段 | 耗时 |
|---|---:|
| 预读日志原文 + 服务器时刻（一条 JOIN，6 万行跨 isolate） | ≈ 524 ms |
| 写缓存 | ≈ 224 ms |
| 预读修改记录 + 服务器时刻（JOIN） | ≈ 220 ms |
| 卡片历史内核（打包 + 一次 FFI + 完整 JSON 解析 + 选取 + 解包） | ≈ 103 ms |
| 笔记物化 | ≈ 84 ms |

- 省下的来自两处：服务器时刻不再按几万个事件 ID 另查（约 −700 ms / 3000 笔记），日志解码从 Dart 的
  310–370 ms 换成内核里约 100 ms（含打包与解包）。
- 剩下的最大头是「6 万条日志原文跨 isolate 搬运」——只要 Drift 还是唯一连接就省不掉，这是 P4（Rust
  自持连接）的直接收益。
- **列模式（内存里已有 `SrsReviewLog` 的调用方）单看选取不比 Dart 快**：6000 份 × 10 条，旧 Dart 逐份构造
  15–16 ms，Rust 逐份 21–25 ms、整批 18–20 ms（打包串表 + FFI 的固定成本，约 1 µs / 份）。仍然搬，是因为
  选取规则只能有一份（缓存刷新的状态与 `history().state` 必须同源，两份实现迟早漂移）；这些调用方的
  端到端耗时由取数主导（`histories()` 见上表，因 JOIN 变快）。统计页仍逐卡构造（每卡一次 FFI），P6 收编取数时改整批。

### 6.1 顺带修掉的竞态

`SrsRwkvService._refreshOnce` 用两条语句分别查「日志指纹」与「已回放之后的新行数」，作答（不等对齐）
落在两条之间时新行数比指纹多一条，被当成「历史被改写」去全量重建，连续答题时 RWKV 反复退回「还没准备好」。
本 PR 让作答少了两次往返、时序变了，`srs_rwkv_service_test`「同日重复的间隔守卫」稳定复现。修法：两个值
同一条语句取（`_fingerprintSince`），同一个快照。
