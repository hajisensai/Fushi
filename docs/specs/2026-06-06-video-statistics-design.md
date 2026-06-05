# 视频统计（Video Statistics）设计文档

- 日期：2026-06-06
- 分支：`worktree-video-statistics`
- 状态：已批准设计，待实现

## 1. 背景与目标

书架（书籍）侧已有「阅读统计」（`ReadingStatisticsPage`，入口在书架页顶栏 `Icons.bar_chart_outlined`），展示「字数 + 阅读时长」，数据来自 `ReadingStatistics` / `ReadingHourlyLogs` 两表，阅读器通过 `ReadingTimeTracker` + 字符增量实时采集。

视频侧（底栏 video tab，`HomeVideoPage` / `VideoHibikiPage` / `VideoBooks` 表）**目前完全没有任何观看时长 / 统计采集**——`VideoBooks` 只持久化 `lastPositionMs`（断点续播）。

目标：在视频区域提供一套与书籍统计**位置对等、形态一致**的统计功能，入口放在视频页（与书架统计的入口在书架页对称）。

## 2. 核心原则

- **数据完全隔离**：视频统计使用独立的 Drift 表，绝不复用 / 污染 `ReadingStatistics`。`ReadingStatisticsPage._computeAggregates` 遍历全表聚合，若混入视频数据会污染阅读统计。
- **历史无法补采**：从本功能上线起开始记录，既往观看不回填。
- **UI / 图表 / 入口与书籍统计对等**：复用相同图表绘制与汇总卡片形态。

## 3. 统计指标（用户确认：三者全要）

| 指标 | 含义 | 类比阅读统计 |
|---|---|---|
| 观看时长 | 仅播放中累加的时长 | 阅读时长 `readingTimeMs` |
| 字幕字数 | 单调前进经过的字幕 cue 文本字符数 | 阅读字数 `charactersRead` |
| 完成视频数 | 进度首次 ≥ 90% 的视频数（按时间戳去重） | 无对应（新增维度） |

## 4. 数据采集

采集发生在视频播放页 `video_hibiki_page.dart` + 新建 `VideoWatchTracker`（仿 `packages/hibiki_audio/.../reading_time_tracker.dart`）。

### 4.1 观看时长
- `VideoWatchTracker` 持有周期定时器（60s，对齐 `ReadingTimeTracker`）。
- 每次 flush 计算 elapsed，**仅当 `VideoPlayerController.isPlaying` 为真时累加**（暂停不计时——这是与阅读统计的关键差异，阅读默认页面可见即算）。
- 按「当前视频书 `title` + 今日 dateKey」累加写 `VideoWatchStatistics.watchTimeMs`；同时写 `VideoHourlyLogs`。
- 处理跨小时 / 跨天边界（照搬 `ReadingTimeTracker._flush` 的拆分逻辑）。

### 4.2 字幕字数
- 监听 `VideoPlayerController`（`ChangeNotifier`，cue 变化时 `notifyListeners`）。
- 维护「已计数的最大 cue index」，仅当 `currentCueIndex` **单调前进到新最大值**时累加该 cue 文本字符数。
- 来回 seek / 重看同一句不重复计数（类比阅读 `_lastAbsoluteCount` 单调推进）。代价是来回看少计，是可接受的近似（看过的句子不重复计学习量）。
- 按「当前视频书 `title` + 今日 dateKey」累加写 `VideoWatchStatistics.subtitleChars`。

### 4.3 完成视频数
- `VideoPlayerController` 新增 `int? get durationMs => _player?.state.duration.inMilliseconds`。
- 当 `positionMs / durationMs ≥ 0.9` 且该视频 `VideoBooks.completedAt` 为 null 时，首次写入完成时间戳。
- 时间戳天然去重（只记首次完成，重看不重复计）。

## 5. 数据存储（`packages/hibiki_core`，schema v21 → v22）

### 5.1 新表 `VideoWatchStatistics`（对照 `ReadingStatistics`）
| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | int PK autoIncrement | |
| `title` | text | 视频书标题维度 |
| `dateKey` | text | `yyyy-MM-dd` |
| `subtitleChars` | int | 累加 |
| `watchTimeMs` | int | 累加 |
| `lastModified` | int | 同步预留 |

唯一键 `{title, dateKey}`（每视频每天一行，累加 upsert）。

### 5.2 新表 `VideoHourlyLogs`（对照 `ReadingHourlyLogs`）
| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | int PK autoIncrement | |
| `dateKey` | text | |
| `hour` | int | 0-23 |
| `watchTimeMs` | int | 累加 |

唯一键 `{dateKey, hour}`（今日小时图用）。

### 5.3 `VideoBooks` 加列
- `completedAt`（`DateTime?`，默认 null）：首次进度 ≥ 90% 的时间戳。

### 5.4 `database.dart` 新增 CRUD
- `addVideoWatchStatistic({title, dateKey, subtitleChars, watchTimeMs})`：累加语义事务内 upsert（对照 `addReadingStatistic`）。
- `getAllVideoWatchStatistics()`。
- `addVideoHourlyWatchTime({dateKey, hour, deltaMs})`：对照 `addHourlyReadingTime`。
- `getVideoHourlyLogsForDate(dateKey)`。
- `markVideoCompleted(bookUid, completedAt)`：仅当当前 `completedAt` 为 null 时写入（幂等首次）。
- 完成数不新增 count 方法：统计页用现有 `VideoBookRepository.listAll()` 读各行 `completedAt`，在页面侧按时间戳落入今日 / 周 / 月 / 全部区间计数（天然去重）。

### 5.5 迁移 v21 → v22（基底当前 schema 已是 v21）
- `schemaVersion` 21 → 22；新增 `if (from < 22) { ... }` 步骤。
- 建 `VideoWatchStatistics`、`VideoHourlyLogs` 两表（`m.createTable`，带 `_tableExists` 守卫避免 fresh DB 重建）。
- `VideoBooks` `addColumn(completedAt)`（带 `_columnExists` 守卫，无损，既有行为 null）。

## 6. 统计页面 `VideoStatisticsPage`

结构对等 `ReadingStatisticsPage`（`CustomScrollView` + slivers）：

1. **汇总卡片** 2×2（今日 / 本周 / 本月 / 全部）。每格显示：字幕字数（大号粗体）+ 观看时长（小字）+ 完成数（小字）。
2. **今日按小时图**（观看时长，对齐阅读 hourly）。
3. **最近 30 天图**（字幕字数，对齐阅读 daily）。
4. **按视频排行**（每视频：标题 + 进度条占比 + 「字幕字数 · 时长」）。
5. 空数据态 `HibikiPlaceholderMessage(Icons.bar_chart_outlined, video_stat_no_data)`；顶部刷新按钮。

### DRY：共享图表
将 `reading_statistics_page.dart` 内的 `_HourlyChartPainter` / `_BarChartPainter`（两处当前完全相同）提取到共享文件 `lib/src/pages/implementations/stat_charts.dart`，阅读统计页与视频统计页共用。聚合用的内部数据类（`_DayData` / `_BookData` 等）各页保留自己的等价物，或一并提取为公共 `StatDayData`。

完成视频数的「今日 / 本周 / 本月 / 全部」按 `VideoBooks.completedAt` 时间戳落入对应区间计数（天然去重）。

## 7. 入口

`home_video_page.dart` 顶栏 `actions` 加一个统计 `IconButton(Icons.bar_chart_outlined)`，紧跟现有导入按钮，`Navigator.push`（`adaptivePageRoute`）到 `VideoStatisticsPage`。

> 注意：基底已含 `feat(video): long-press menu + shared tag system`（7dc730935），实现前需重新核对 `home_video_page.dart` 当前顶栏结构。

## 8. i18n

- 复用通用 key：`stat_today` / `stat_this_week` / `stat_this_month` / `stat_all_time` / `stat_format_minutes` / `stat_format_hours_minutes` / `stat_format_chars` / `stat_format_chars_wan` / `stat_refresh`。
- 新增（经 `hibiki/tool/i18n_sync.dart`，17 语言）：
  - `video_statistics`（标题 / tooltip）
  - `video_stat_by_video`
  - `video_stat_subtitle_chars`
  - `video_stat_completed`
  - `video_stat_watch_time`
  - `video_stat_no_data`
- 改完跑 `dart run slang` + `dart format strings.g.dart`。

## 9. 测试（TDD，最强可落地层）

- **DB**：`VideoWatchStatistics` / `VideoHourlyLogs` CRUD（累加 upsert）、`markVideoCompleted` 幂等、v22 迁移（含 `completedAt` addColumn 无损、既有 `VideoBooks` 行保留）。
- **`VideoWatchTracker` 纯逻辑**：暂停不计时、跨小时 / 跨天拆分、cue 字数单调前进（来回不重复）、完成阈值 0.9 边界。
- **统计页聚合纯函数**：今日 / 周 / 月 / 全部累加、按视频排行排序、完成数按时间戳分桶。
- **入口 widget**：视频页统计按钮存在且导航到 `VideoStatisticsPage`。
- **i18n 完整性**：17 语言 key 齐全。

## 10. 已定默认（用户已确认）

- 完成阈值 **90% 进度**（不强求看到片尾）。
- 观看时长 / 字幕字数按**视频书整本**统计（播放列表不细分到集）。
- 30 天图用字幕字数、小时图用观看时长（与阅读统计对齐）。

## 11. 影响范围与风险

- 影响文件：`packages/hibiki_core`（tables / database / migration）、`hibiki/lib/src/media/video/`（tracker + controller getter）、`video_hibiki_page.dart`（接采集）、`home_video_page.dart`（入口）、新页 `video_statistics_page.dart`、共享 `stat_charts.dart`（含重构 `reading_statistics_page.dart`）、i18n 17 文件 + 生成文件。
- 最大回归点：① schema 迁移必须无损（既有视频书 / 阅读统计不受影响）；② 提取共享图表后阅读统计页行为不变（重构等价性）。
- 向后兼容：仅新增表 / 列 + 新页 + 新入口，不改既有持久化 key、不动阅读统计数据。
