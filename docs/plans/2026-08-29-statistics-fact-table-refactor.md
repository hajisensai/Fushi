# 统计域根本性重构：事实表单一真相源 + 同步协议 v2

日期：2026-08-29 · 基线：origin/develop `13cc57a5ea`（schema v89 → 本次 v90） · 状态：用户已确认方案 3；PR A 实施中

用户拍板（2026-08-29）：① 阅读空闲门默认 10 分钟 + 切屏（失焦 / 进后台）自动暂停，**只对小说 / PDF / 漫画**，视频以播放态为准、切走仍在播照常计时；② 首页每日目标分子只算阅读域（book+manga），且所有页面必须从同一份事实面取数（守卫钉死）；③ 接受互联两端须同升。

## 0. 一句话

把「同一段学习时间写进 4 张 `+=` 表、按 title 认身份、同步靠 MAX/塌缩/差额三套补丁」
换成「一张按 uid 幂等 upsert 的事实表 `study_segments`，投影现算，同步按 uid 并集」。
游戏域（`galgame_sessions` + GROUP BY）已经是这个模式，本次把书/视频对齐过去，不发明新东西。

## 1. 现状病根（已坐实，file:line 见调查）

| # | 病根 | 位置 |
|---|---|---|
| A | 日汇总/小时桶纯 `+=`，无幂等键；任何路径 flush 两次即永久翻倍 | `database_statistics.part.dart:35/106/176/683` |
| B | 身份=title：`reading_statistics` 唯一键 `{title,dateKey}`；视频 wire 键 `{title,dateKey}` 无 bookUid | `tables.dart:174`、`aggregate_sync_service.dart:685-712` |
| C | 同步塌缩：对端按 title 求和上行 → 本地 `setVideoWatchStatistic` 删全部 per-uid 行写一条无 uid 行；分集 title 是裸 `S01E01` → 跨作品相加 | `database_statistics.part.dart:624-680` |
| D | `VideoWatchTracker.stop()` await 之后才清零 `_sessionWatchMs`，dispose 与进程退出并发各写一条 activity 行 | `video_watch_tracker.dart:165-176` |
| E | 计时=墙钟 60s tick + 120s 断档守卫；阅读器无空闲/输入判据（挂机全算） | `reading_time_tracker.dart:114` |
| F | 窗口 `>= now-7d` 含 8 天、`-30d` 含 31 天，环比分母 7 天；四处各写一遍 | `reading_statistics_page.dart:262`、`video_stat_aggregates.dart:87`、`game_stat_aggregates.dart:48`、`stat_activity.dart:41` |
| G | 四套同构聚合（阅读页/视频页/游戏页/dashboard）；dashboard 把书字+字幕字+hook 字相加当目标分子 | `home_dashboard_page.dart:675-715` |
| H | 字幕字数 dateKey 用墙钟非 cue 时刻；单行零 clamp | `video_watch_tracker.dart:318` |

## 2. 目标数据结构（schema v90）

### 2.1 `study_segments`（唯一事实表，新写入面只写它）

```
uid          TEXT PRIMARY KEY   -- 写入方生成（uuid v4），幂等键
device_id    TEXT NOT NULL      -- sync_repository.getOrCreateDeviceId()
media_kind   TEXT NOT NULL      -- 'book' | 'video' | 'game'（复用 ActivityMediaKind.dbValue）
media_key    TEXT NOT NULL      -- bookKey / bookUid / galgames.id（唯一身份，永不用 title）
format       TEXT NOT NULL DEFAULT ''  -- 'epub'|'pdf'|'manga'|''（写入面，取代 hourly.format）
title        TEXT NOT NULL      -- 展示快照，只用于 join 失败时回退显示
start_at     INT NOT NULL       -- ms
end_at       INT NOT NULL       -- ms；段不跨本地小时边界（写入方负责切）
date_key     TEXT NOT NULL      -- start_at 本地 y-m-d
hour         INT NOT NULL       -- start_at 本地小时
duration_ms  INT NOT NULL DEFAULT 0  -- 活跃时长（已过空闲/断档守卫）
chars        INT NOT NULL DEFAULT 0
pages        INT NOT NULL DEFAULT 0
updated_at   INT NOT NULL       -- 同步 LWW 水位
INDEX (media_kind, media_key), INDEX (date_key), INDEX (device_id, updated_at)
```

写法只有一种：`upsertStudySegment(row)` = `INSERT ... ON CONFLICT(uid) DO UPDATE SET` **绝对值**。
写入方持有自己当前打开段的内存累计器，每次 tick/flush 把绝对值写回同一 uid。
重复 flush = 同值覆盖 = no-op。`+=` 这一类 DAO 全部删除。

段的生命周期：`open`（首 tick）→ 每 60s upsert → 遇 stop / 小时边界 / 媒体切换 → 换新 uid。
一个 3 小时阅读 session ≈ 3~4 行；年级数据千行量级，GROUP BY 毫秒级。

### 2.2 `study_segment_tombstones`

```
media_kind, media_key, deleted_at   PRIMARY KEY (media_kind, media_key)
```
删某书/视频统计 = 删其 segments + 立碑；再读该媒体写出的 segment `updated_at > deleted_at` 自然复活。
取代 `statistics_tombstones` 的 `(title, sourceType)` 键。

### 2.3 旧表处置：**冻结为 legacy，不迁移、不改写、不删**

`reading_statistics` / `video_watch_statistics` / `reading_hourly_logs` / `video_hourly_logs` /
`activity_events`（read/watch 行）保持原样。本地写入面永不再写它们（守卫测试钉死）。
读取侧 `StatQuery` 把 legacy 行与 segments **并集**（legacy 只覆盖 v90 之前的日期，segments 只覆盖之后，
时间上天然不相交——不做任何合成转换，就没有双计的可能）。`galgame_sessions` 照旧（它已经是事实表）。

不迁移的理由：日汇总行没有 hour、小时行没有 title，两者是同一时间的两个不相交投影，
任何「合成 segment」都得二选一并丢另一维度或双计。冻结 + 并集读是唯一零损失做法。

## 3. 写入侧

### 3.1 `StudyClock`（取代 `ReadingTimeTracker` + `VideoWatchTracker` 的计时部分）

```dart
class StudyClock {
  StudyClock({
    required bool Function() isActive,      // 视频=isPlaying；阅读=最近输入在空闲窗内；游戏=前台
    required StudySegmentSink sink,          // 把当前段绝对值交给 DAO
    Duration tick = 60s, Duration maxGap = 120s,
  });
  void start(); void stop(); void touch();   // touch = 用户输入，喂空闲判据
  void addChars(int n); void addPages(int n); // 记到当前打开段
  Future<void> flushNow();                   // 不停表结算（原 sampleNow）
}
```
- 断档守卫沿用 `isContinuousReadingGap` 语义；小时边界切段沿用 `splitReadingTime`。
- **阅读空闲门**（新，只对阅读面）：`touch()` 由 EPUB `_refreshProgressFromScroll` / PDF `_onPageChanged` / 漫画 `_armPageDwellCount` 调用；`now - lastTouch > idleTimeout` 的 tick 丢弃并封段。
  `idleTimeout` 默认 `kDefaultReadingIdleTimeout` = 10 分钟；偏好键 `stats_reading_idle_timeout_minutes` 的设置 UI 在 PR C 加。视频面不设空闲门、`inactive` 不停表。
- **零长度窗口是 no-op**：同一时刻连续 flushNow / stop 不封段（否则紧随的正常窗口会开新 uid 把一次阅读切碎；实施时被测试抓出）。
- `stop()` 结构性幂等：取值-清零-换 uid 在任何 await 之前（消灭病根 D）。

### 3.2 各写入面改接

| 面 | 现在 | 改后 |
|---|---|---|
| EPUB `navigation.part.dart:1425/1434` | tracker(hourly) + `recordReadingSession`(activity+daily) | 一个 `StudyClock(format: epub)`；`_sessionCharsRead` 改 `clock.addChars` |
| PDF `reader_pdf_page.dart:175/252` | 同上 | 同上 |
| 漫画 `manga_fushi_page.dart:1157/1406/3455` | 同上 + pages | 同上 + `clock.addPages` |
| 视频 `video_fushi_page.dart:3361` | `VideoWatchTracker` → `recordWatchFlush` + activity | `VideoWatchTracker` 只留字幕停留门/完成判定，时长交 `StudyClock(isActive: isPlaying)`；字幕字数 `addChars`（段 dateKey=cue 时刻所在段） |
| 游戏时长 `gal_hook_session_controller.dart:3385` | `galgame_sessions` + activity(durationMs) | 只写 `galgame_sessions`（删 activity 行） |
| 游戏字数 `:3514` | activity(charsDelta) | `upsertStudySegment(kind: game, chars only)` |

删除：`addReadingStatistic` / `addHourlyReadingTime` / `addUnattributedHourlyReadingTime` /
`addVideoWatchStatistic` / `addVideoHourlyWatchTime` / `recordReadingSession` / `recordWatchFlush` /
`addActivityEvent`（read/watch/game 用法；`added` 事件保留，它不是统计）。
`set*` OVERWRITE 版保留给 legacy 同步（§5.2）。

## 4. 读取侧：一份 `StatQuery`

`fushi/lib/src/stats/stat_query.dart`（纯 Dart，输入 legacy 行 + segments + galgame_sessions，可单测）：

- `StatWindow.days(n, now)` = `[now-(n-1)d, now]` 含端共 n 天；环比 = 前一个同长窗口（消灭病根 F，四处只留一处）。
- `dailyTotals(kind, window) → Map<dateKey, StatDay{ms, chars, pages}>`
- `perMediaTotals(kind, window) → Map<mediaKey, ...>`（title 由 join 得，无 join 用快照）
- `hourly(dateKey, kind, format?)`
- 活动流唯一数据源 `StatFacts.activityRows` = legacy `activity_events` ∪ `segmentsAsActivityRows(segments)` ∪ `galgameSessionsAsActivityRows`（游玩会话不再写 activity 行，读取时合成）→ 既有 `aggregateActivityEvents` 按 30 分钟 gap 归并 session
- 实施形态：没有单独的 `StatQuery` 类——`loadStatFacts` 产出统一事实面 `StatFact`（日面 / 小时面分列，legacy 行与段同形），既有纯聚合函数（`aggregateStatSourceDaily` / `computeVideoStats` / `computeGameStats`）改吃事实 + `StatWindow`，UI 组件层零改动
- 单行 clamp：`duration_ms ≤ 1h`（段本身 ≤ 1 小时，超出=脏数据，读侧截断并计数上报 ErrorLog）

消费方改接：`reading_statistics_page` / `video_statistics_page` / `game_statistics_page` /
`home_dashboard_page` / `activity_feed` / `dashboard_remote_merge` / `stat_delete_confirm_dialog`。
`_computeAggregates` / `computeVideoStats` / `computeGameStats` / dashboard 内联累加 → 删，全走 `StatQuery`。

**口径统一（假设，可改）**：dashboard 每日目标分子 = 与阅读统计页同口径（book+manga 字数）；
视频字幕字/游戏 hook 字在 dashboard 分行展示不并入目标。`sumTimeWindowsByDateKey` / `DashboardTimeStats` 零调用方 → 删。

## 5. 同步协议 v2

### 5.1 wire

`AggregateSnapshot.currentVersion` 保持 1（旧字段=legacy 冻结值，MAX-union 幂等且不再变化），
**新增 additive 字段**（走既有「旧端忽略未知 key」不变量，不 bump 版本、不让旧端整包降级为空）：
- `studySegments: List<StudySegmentRecord>`（全字段）
- `studySegmentTombstones: List<{mediaKind, mediaKey, deletedAt}>`

合并 = 按 uid 并集，同 uid 取 `updated_at` 大者；墓碑 `deleted_at > segment.updated_at` → 删除胜。
`AggregateMergeService` 加 `mergeSegments` / `mergeSegmentTombstones` 两个纯函数；
`mergeStatBuckets` / `deficit-lift` / `setVideoWatchStatistic` 塌缩逻辑**只对 legacy 字段生效**，不再触碰任何新数据。

三条传输零改接口：云端 per-device JSON asset、互联 `GET/PUT /api/library/aggregate`、
`app_model_library_host_service.foldIntoLocal` 都只是多两个 key。
增量：云端快照体积随 segments 线性增长（估算 3h/天 × 365 ≈ 1.5k 行 ≈ 200KB/年），一年内不需要分片；
分片（按月 asset）列为后续 TODO，不在本次范围。

### 5.2 旧端兼容（明确的取舍）

- 旧端 → 新端：旧端仍上传 legacy 字段（它们在旧端还在增长），新端照旧 MAX 进 legacy 表。**新端读侧并集 legacy+segments 时，legacy 表里来自旧端的新日期行会与本机 segments 同日并存**——这是两台设备各自的量，不重叠，求和正确。
- 新端 → 旧端：新端的 legacy 字段冻结，旧端看不到新端 v90 之后的统计。**这是协议升级的必然代价**；互联两端应同时升级（用户拍板「根本性修复」，接受）。
- 备份 ATTACH 合并（`backup_merge_engine.dart`）：`study_segments` 按 uid `NOT EXISTS` 插入 + `updated_at` 大者更新；墓碑同规则；legacy 表合并逻辑不动。

## 6. 分 PR 落地（三条，按序合入）

### PR A · 数据层 + 写入 + 读取（必须一起，否则新数据无处显示）
1. `tables.dart` 加两表，`database.dart` v90 迁移（建表 + 索引，不动旧表）。
2. `database_statistics.part.dart`：`upsertStudySegment` / `deleteStudySegmentsFor(mediaKind, mediaKey)` / `getStudySegments(window)` / 墓碑 DAO；删 §3.2 列出的 `add*`/`record*`。
3. `StudyClock`（`packages/fushi_audio` 现有 tracker 位置，`ReadingTimeTracker` 改名为它，保留纯函数 `splitReadingTime`/`isContinuousReadingGap`）。
4. 五个写入面改接（§3.2）。
5. `StatQuery` + 七个消费方改接（§4）。
6. 测试：
   - DB：upsert 幂等（同 uid 两次 = 一行同值）、跨小时切段、墓碑复活规则；
   - `StudyClock`：空闲门、断档、stop 幂等（两条并发 stop 只产生一个终值）、小时边界；
   - `StatQuery`：窗口恰 n 天、环比分母、legacy+segments 并集无双计、clamp；
   - 守卫：`statistics_write_convergence_guard_test` 改为「lib/ 内除 legacy 同步路径外零调用 `add*`/`recordReadingSession`/`recordWatchFlush`」+ 「legacy 表零本地写入」；每条守卫做变异实测。
7. `docs/bugs/`：`dart run tool/bug.dart new` 两条——同步 title 塌缩（病根 C）、`VideoWatchTracker.stop` 双写（病根 D），根因 file:line 写进去，① 修复 ② 测试勾选。
8. 验证：`flutter analyze` 全量；定向 `flutter test test/database test/pages test/sync test/tools`；合入前 `dart run tool/flutter_test_failures.dart --no-pub` 认 VERDICT 行；真机：Windows 读一本 EPUB 5 分钟 + 看一段视频 3 分钟 + 挂机 15 分钟，对账 segments 表（挂机段不入账）。

### PR B · 同步 v2
1. `aggregate_snapshot.dart` 加两个 additive 字段 + round-trip 测试。
2. `AggregateMergeService.mergeSegments` / `mergeSegmentTombstones`。
3. `aggregate_sync_service.materializeLocalSnapshot` / `mergeSnapshots` / `applySnapshotToLocal` / `filterTombstoned` 接入。
4. `backup_merge_engine` 加 `_mergeStudySegments`。
5. 测试：两端各写、并集幂等（同快照应用两次 = 一次）、墓碑跨端、旧端 v1 payload 混入不污染 segments、`fushi_library_host_service_aggregate_test` 补两 key。
6. 验证：本机双实例互联（host + client 各一份 DB）跑一轮 sync，对账两边 segments 行数与 uid 集合相等。

### PR C · 清理与 UI
1. 设置页加「阅读空闲判定（分钟）」（i18n 走 `i18n_sync --add`，登记 `kCoveredElsewhere`）。
2. dashboard 口径与统计页对齐；删死代码。
3. `docs/agent/` 补一段统计域规则（「只写 study_segments；legacy 冻结」）。

## 7. 风险与不做的事

- **schema 号撞车**：PR#1051 与 #1053 都写 v89；本计划取 v90，开 PR 前 `git fetch` 复核最新 `schemaVersion`。
- **互联跨版本**：新端 → 旧端的新统计不可见（§5.2），文档写明、发布说明写明。
- **快照体积**：一年内无需分片；超过再做按月 asset。
- **口径变化**：dashboard 目标分子改为 book+manga（假设）；阅读空闲门默认 10 分钟（假设）。两者用户可否决。
- **不做**：不迁移/重算历史数据；不改 `galgame_sessions`；不动 `mining_statistics` / `lookup_mining_counters` / 收藏（它们不是时长/字数域，且已是 MAX 计数语义）。
- **不做**：不重写统计页 UI 组件（`stat_*.dart` 展示层不动，只换数据入口）。
