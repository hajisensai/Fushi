# 学习统计域规则（v92，2026-08-29 起）

统计域在 v92 做过一次根本性重构（计划：[docs/plans/2026-08-29-statistics-fact-table-refactor.md](../plans/2026-08-29-statistics-fact-table-refactor.md)；BUG-1947 / BUG-1948）。这里只列**改代码时必须遵守的规则**，全部有守卫测试（`fushi/test/tools/statistics_write_convergence_guard_test.dart`）钉死。

## 数据结构（一句话）

学习时长 / 字数 / 页数只有**一张事实表** `study_segments`（`packages/fushi_core/lib/src/database/tables.dart`），一段一行、按稳定媒体身份 `media_key`（bookKey / bookUid / galgames.id，**永不用 title**）键控、按 `uid` **绝对值 upsert**。旧四张投影表 `reading_statistics` / `video_watch_statistics` / `reading_hourly_logs` / `video_hourly_logs` 与 `activity_events` 的 read/watch/game 行是 **legacy：冻结、只读、不迁移**。

## 写入面

- 只有一个时钟 `StudyClock`（`packages/fushi_audio/lib/src/audiobook/study_clock.dart`）：断档（120s）/ 活跃态（视频 = isPlaying）/ 空闲门（阅读面，默认 10 分钟，设置项 `reading.stats_idle_timeout_minutes`）三道守卫，段不跨小时边界，`stop()` 结构性幂等（清引用在首个 await 之前）。
- 页面**不许**持有 `_sessionReadingMs` / `_sessionCharsRead` 之类会话累计器；字数 / 页数经 `clock.addChars` / `addPages` 记到当前段（停表期间两者直接丢弃、不开段，BUG-2210）；用户输入经 `clock.touch()` 喂空闲门（EPUB `_refreshProgressFromScroll` / 听书播放态每次 cue 推进 `_onCueChanged`（BUG-2212，歌词模式唯一的输入源）/ PDF `_onPageChanged` / 漫画 `_noteVisiblePages`）。**查词不喂门**（走词典弹窗，不经 `touch()`）。`start()` 本身重锚空闲基准（BUG-2211）。
- 阅读面切屏（`paused` / `inactive`）必须停表、`resumed` 续表；EPUB 面所有 start / stop 决策只经统一判据 `studyClockMayRun`（手动暂停 / 生命周期停表 / 面板·弹层·全页路由压住正文的 `modalDepth`，BUG-2208 / BUG-2209）+ `_syncStudyClockRunState()`，弹层入口用 `_withStudyClockPaused` 包（查词浮窗与 Anki 制卡对话框除外——那是阅读的一部分）；`idleTimeout` 每次 `_ensureStudyClock` / 面板关闭都从设置刷新（BUG-2213）。视频面 `inactive` **不**停（用户拍板：切走仍在播照常计时）。
- **阅读三域（EPUB / 漫画 / PDF）「读过」口径 = 入账额 = 会话翻过的单元并集 ∩ [0, 当前位置)（用户 2026-09-06 两次裁定：翻走即计 + 并集去重；回翻撤回、再前进按并集恢复、从未翻过的不计；决策与全口径对照见 `docs/plans/2026-09-06-read-unit-ledger.md`）**：唯一判据实现是 `ReadUnitLedger`（`fushi/lib/src/stats/read_unit_ledger.dart`，纯 Dart），单元 = 半开区间（EPUB 全书绝对字符偏移 `[页首字, 页尾字+1)`、漫画 / PDF 页号），离开单元那一刻并入并集（`IntervalCoverage`，`stats/interval_coverage.dart`，原视频 `WatchCoverage` 抽通用），每次落定按上式重算应入账集合并把差分经 `onCredit` / `onRetract` → `StudyClock.addChars/addPages` / `retractChars/retractPages`（撤回从最新段往前扣、会话级夹 0，对齐 Hoshi；停表期间与入账对称丢弃）。**没有停留门、没有速率封顶、没有任何播种 / 预置 API**：跳转、换章、恢复都不需要告诉账本「跳过了」，只计翻走的单元；**离开当前单元只在离开那一刻 `leave()`**：`_beginNavigation`（所有导航必经点，loadUrl 之前）+ 三个同章跳转入口（进度条 `restoreProgress` / 收藏句 `restoreToCharOffset` / 脚注 `jumpToFragment`）+ 显式跳句 + 关书三条路；`_onRestoreComplete` 不碰账本（BUG-2225 / 2189：旧「原位恢复判据 → `rebaseOnNextArrive`」把同章跳转恒判原位、跳走前那页不结算，导航失败 `discard` 丢真读过的上一页）。同页换坐标（重排 / 宽变 / 分页↔连续）提前结算同页，并集去重后总额不变（EPUB 不再用 `rebaseOnNextArrive`，漫画仍用）；坐标系整体变更（章字数后台补算）用 `reset()`，导航失败 `discard()` 只兜新页短暂 arrive 的空状态。B-3 窗（`readerScrollWithinReanchorSettle`）内丢弃的 scroll 回传与听书 reveal 共用一个 `_scheduleReanchorSettleProgressRefresh` 单 Timer 在窗关后补刷（BUG-2227：否则落点页只能等 10s 轮询，关书结算旧页）；退出探针有意不 arrive。并集只活在一个阅读器 State 里（关书重开再读照常计）。页面**不许**再持有任何标量水位 / 令牌桶 / 已计页 Set（旧形态：`_sessionMaxAbsoluteChars` / `accumulateSessionCharsCapped` / `_sessionCountedPages` / `pdfPagesNewlyReached`，守卫钉死不得回潮）。进度 UI / 落库位置仍按视口首字算，是另一本账，不经账本。
- **视频面口径 = 只计首次覆盖（BUG-2108，用户拍板「重听不要记录在内」）**：视频面时钟走 `StudyAccrual.explicit`（tick 不按墙钟计，只裁决段生命周期），时长由 `VideoWatchTracker` 推入——每秒 + 每次播放源通知采样位置，连续播放推进（`isContinuousPlaybackAdvance`）才把片内区间并入该视频的 `IntervalCoverage`（`fushi/lib/src/stats/interval_coverage.dart`，已看过的区间并集；原 `WatchCoverage`），只有**新增**部分按比例折成墙钟时间经 `clock.addActiveMs` 记账；回放上一句 / 拖回 / 向前 seek 跳过 / 次日重看一律不计，单部视频累计 ≤ 片长。并集按 `video_watch_coverage_<bookUid>` 偏好持久化（`videoWatchCoveragePrefKey`），删该视频统计 / 清空全部视频统计时连带清（= 当没看过）。本次会话前已整段看过的 cue 字幕字数同律不计。不要再给视频面传 `isActive`（构造期断言）。
- `upsertStudySegment` 只有两个写入方：`StudyClock` 与 galgame hook 的 chars-only 段（`gal_hook_session_controller.dart`）。游玩时长只写 `galgame_sessions`。
- legacy 表的 `set*` OVERWRITE 写入口只许 `lib/src/sync/**` 调（旧端 wire 家族落地）。`add*` 累加 DAO 已删，不得复活。

## 读取面

- 统计展示只经 `loadStatFacts`（`fushi/lib/src/stats/stat_facts.dart`）→ 统一事实面 `StatFact`（日面 / 小时面分列，legacy 行与段同形，**不许**把两面并进同一列表求和）。不许直读 legacy 表 / `activity_events` 做统计（豁免：`stat_facts.dart`、`lib/src/sync/**`、`home_video_page.dart` 的最近观看时刻）。
- 窗口阈值只在 `StatWindow`（`stat_window.dart`）：近 7 天恰 7 天、近 30 天恰 30 天、上周窗口同长不重叠。页面不许自己 `now - 7d`。守卫 ④ 是本域唯一按**命名清单** `kStatPages` 扫描的（其余全树枚举），所以新增统计页漏登记时目录枚举守卫和定向测试都挑不到——④a 自校验兜底：**用了 `StatWindow` 就必须在 `kStatPages` 里**，漏登记直接红。
- **「今日」边界 = `FushiDatabase.statDayResetHour` 整点（设置项 `reading.stats_day_reset_hour`，偏好键 `stats_day_reset_hour`，0..23，默认 0 = 本地午夜）**，写入时定 dateKey：`statDateKeyOf(t)` 把 `t` 前移该小时数再取日历日（重置 = 4 时凌晨 2 点的段记到「昨日」，与 Hoshi Android `statisticsResetMinutes` 同语义、但只到整点）。它是 dateKey 派生的**唯一**输入，`AppModel._applyStatDayResetHour` 在偏好加载后与改设置时镜像过去；历史段**不重分桶**（改设置只影响之后写入），同步携带写入端的 dateKey。读取面一律做 **key 算术**（`statDateKeyPlusDays` / `statDateKeyToDay` / `statCalendarDayKeyOf` / `statTodayDay`）：`StatWindow`、streak、热力图**不得**用 `DateTime(now.year, now.month, now.day)` 合成午夜当「今日」（会把重置前的凌晨错切到日历今日）；热力图格子是日历日、key 走 `statCalendarDayKeyOf` 不过 `statDateKeyOf`。页面跨日重聚合 Timer 用 `StatWindow.untilNextStatDayBoundary`（原 `untilNextLocalMidnight`）。
- 活动流唯一数据源 `StatFacts.activityRows` = legacy 活动行 ∪ `segmentsAsActivityRows` ∪ `galgameSessionsAsActivityRows`；首页、游戏首页、互联 host 的远端活动端点都吃它。
- 首页每日目标分子与阅读统计页目标卡共用 `studyGoalCharsForDay`（BUG-1993）：函数只按 `dateKey` 求和，**域由调用方传的行集决定**。目标是「每日学习目标」——两处都传完整日面（`StatFacts.daily`，阅读 + 视频字幕 + 游戏 hook），与热力图「全部」档同覆盖面；只算某一域时传对应切片（如 `dailyBooks`，统计页概览「今日字数」与 CPH 仍是阅读域）。v92 曾把分子硬编码 `isBook`，纯视频/游戏日目标恒 0、与同一张卡上方的热力图对不上。偏好键 `readingGoalDailyChars` / `readingGoalWeeklyChars` 冻结不动，语义已是学习目标。守卫 ⑧ 同时钉函数名与这两处实参。
- 统计上屏入口收敛到首页 dashboard 的统计中心（`statistics_center_page.dart`，总览 + 阅读/视频/游戏三 tab）。三个统计页保留独立页形态，另经 `embedded: true` 走 `buildEmbeddedStatTab`（`stat_shared.dart`）嵌进 tab——**页头动作必须同时喂给两条渲染路径**，只改独立页会让 tab 里的入口静默丢失。书架/视频/游戏页头不再各挂统计入口。
- 时段明细统一走 `showStatPeriodDetailSheet`（`stat_period_detail_sheet.dart`），它只吃调用方传进来的 `StatFact`、不碰 DB。**只许传日面切片**（`facts.daily` 系）：日面与小时面共享同一批 `StatFact` 实例，`hour` 不能当判别位，sheet 自己无法拒绝小时面，传错即双计。

## 同步（wire v2）

- `AggregateSnapshot` 版本仍是 1，`studySegments` / `studySegmentTombstones` 是 additive 字段（旧端忽略、缺失当空；bump 版本会让旧端整包降级为空）。
- 段按 uid 并集、同 uid 取 `updatedAt` 大者（`AggregateMergeService.mergeStudySegments`）。
- **墓碑语义（BUG-2214 / BUG-2220，2026-09-06 起）= 「压制 `startAt < deletedAt` 的段」，墓碑永不退场。** 一个段是不是「删除之前的学习」在它开始那一刻就定了，不随 tick 漂移；删除后新开的段 `startAt >= deletedAt` 天然存活，所以立碑不会毒化身份、也不需要清碑。同身份只保留 `deletedAt` 最大的一块碑（`mergeStudyTombstones`），碑戳只增不减（`upsertStudySegmentTombstone` 只在更大时覆盖）。旧口径「段 `updatedAt > deletedAt` 则碑出局」已废：删除时仍在跑的时钟下一 tick 就把整块碑判死、对端全部历史回灌，且两端墙钟直比让碑来回消失。
- 落地顺序**先碑后段**（`_applyStudySegments`）：`applyStudySegmentTombstone` 删本地 `startAt < deletedAt` 的段，`upsertStudySegmentsIfNewer` / `upsertStudySegment` 都过墓碑门（被压制的行静默丢弃——删该媒体统计时该媒体的开放段不会写回）。备份 ATTACH 合并 `_mergeStudySegments` 同语义。
- 「清空全部阅读 / 视频统计」对该种类**每个身份逐一立碑**再删行（`clearStudySegments`，BUG-2215）；此前不立碑，多端下一轮同步整批复活。legacy 家族仍不立 title 碑（旧口径）。
- 游戏段 / 碑（`kActivityMediaGame`，galgame hook 字数段）**不出本机**（BUG-2221，`AggregateMergeService.isStudyKindSyncable`）：聚合导出、并集仲裁、落地、备份 ATTACH 四处同一判据，与 `galgame_sessions` 不跨端同律；旧端混进来的落地时再丢一次。
- legacy 家族仍走 MAX-union / `setVideoWatchStatistic` 塌缩 / deficit-lift——那是旧数据的旧口径，**不要**把段接进去，也不要从段折叠回 legacy 字段（会双计）。
- 已知取舍：新端 v92 之后的统计旧端看不到，互联两端须同升；墓碑语义变更同样要求两端同升（旧端仍按 `updatedAt` 仲裁，会让新端已删的段在旧端存活并回传，新端落地时按新语义再压制）。

## 改统计相关代码前

1. 跑 `flutter test test/tools/statistics_write_convergence_guard_test.dart test/media/audiobook/study_clock_test.dart test/database/study_segments_test.dart test/sync/aggregate_study_segments_sync_test.dart test/stats/read_unit_ledger_test.dart test/stats/interval_coverage_test.dart --no-pub`。
2. 新写入面 = 新的 `StudyClock` 实例，不是新表；新展示 = 从 `StatFacts` 派生，不是新查询。
