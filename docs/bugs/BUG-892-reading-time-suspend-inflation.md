## BUG-892 · 阅读时长记账把后台/挂起/睡眠时长计为阅读（34h 的书 / 单小时 >1h / 凌晨幻影 / 纵轴 "2h 2h"）
- **报告**：2026-07-18（用户：mamit）。反馈原文：某本书阅读时长显示 34h（有声书仅 ~10h）；日阅读 10-13h 不可能；「Today by hour」在凌晨 3/5 点（睡觉时）显示在读；单小时高达 2.5h（每小时不可能 >1h）；纵轴刻度错乱 "0 45m 1h 2h 2h"（重复 2h）。用户猜测「app 在后台/拔耳机暂停后仍计时」。
- **真实性**：✅ 真 bug（沿真实代码路径定位）。根因链见下。
- **[x] ① 已修复** — 见「修复」。
- **[x] ② 已加自动化测试** — `hibiki/test/media/audiobook/reading_time_tracker_gap_test.dart`（纯函数守卫 + 生命周期源码守卫）、`hibiki/test/pages/stat_activity_test.dart`（纵轴标签塌陷回归）。
- **备注**：真机复测原始失败路径（挂后台一夜、拔耳机暂停后台、查统计页）待做。

### 根因
两条**独立**的阅读时长记账链路都按墙钟差累加、且都缺「后台/挂起窗口丢弃」守卫；视频侧
早已有此守卫（`hibiki/lib/src/media/video/video_watch_tracker.dart` 的 `kMaxWatchGap` /
`isContinuousWatchGap`，注释直言「对照 ReadingTimeTracker._flush」），阅读侧是那个未修的旧实现。

1. **每小时桶**（"Today by hour"）：`packages/hibiki_audio/lib/src/audiobook/reading_time_tracker.dart`
   `ReadingTimeTracker._flush`（旧行 32-54）。60s `Timer.periodic`，每 tick 把 `now - _tickStart`
   墙钟差记入小时日志。移动端进后台时定时器被系统冻结；恢复时补发一次，`elapsed` = 整段后台
   时长（可能整夜数小时）。`_flush` 的跨边界拆桶只假设跨**一个**小时边界，于是把 `secondMs`
   （例如 2.5h）整块塞进 `now.hour` 一个桶 → **单小时 >1h**；`start.hour`/`now.hour` 落在挂起
   /恢复时刻的小时 → **凌晨幻影在读**。且**只要 reader 页面开着就一直累加**，从不看是否播放/
   前台（`start()` 在章节恢复处调，只 dispose 才 stop）。
2. **每书/每日时长**（KPI、按书、速度、34h 那本书）：`hibiki/lib/src/pages/implementations/
   reader_hibiki/navigation.part.dart` `_flushReadingStats`（旧行 1165-1184）。`elapsedMs =
   now - _sessionStartTime`，同样墙钟差、无守卫。`didChangeAppLifecycleState` 在 `paused` 会
   flush（记到暂停点），但**恢复时不重置 `_sessionStartTime`**，下次翻页/退出 flush 时把整段
   后台时长算进去（只要该段 `_sessionCharsRead>0`）→ **某本书 34h**。
3. **纵轴 "2h 2h"**：`hibiki/lib/src/pages/implementations/stat_charts.dart` `formatStatDurationAxis`
   （旧行 51-56）用 `ms ~/ 3600000` 向下取整，maxMs>1h（因根因 1）时相邻刻度（2.0h / 2.5h）
   都塌成 "2h" → 纵轴重复标签。两层叠加：根因 1 让 maxMs 本不该 >1h + 格式器塌陷。
4. DB 层（`database.dart` `addHourlyReadingTime` / `addReadingStatistic`）纯累加、无单桶 1h 上限，
   不会拦住被灌爆的桶（守卫应在采集端，与视频侧一致）。

### 修复
- **移植视频侧守卫到阅读采集端**（`reading_time_tracker.dart`）：新增纯函数
  `kMaxReadingGap`(120s) / `isContinuousReadingGap(start, now)` / `splitReadingTime(start, now)`
  （对照 `video_watch_tracker.dart`）。`_flush` 先 `isContinuousReadingGap` 门控——间隔
  >120s（后台挂起/熄屏/睡眠/长 GC 致定时器冻结后补发）**整窗丢弃只重锚 `_tickStart`**，正常
  ≤120s 窗口才 `splitReadingTime` 拆桶累加。保证拆桶输入恒 ≤120s（单次至多跨一个边界，其
  单边界假设成立），单桶单次 ≤120s → 一小时桶封顶 ≤3600000ms，消除 >1h/凌晨幻影。
- **生命周期停/启 + 会话计时重锚**（`reader_hibiki_page.dart` `didChangeAppLifecycleState`）：
  `paused`/`inactive` 分支在 flush 后 `_readingTimeTracker?.stop()`（先 flush 退出瞬间部分窗口
  再 cancel，不留后台 tick）；`resumed` 分支 `_sessionStartTime = DateTime.now()`（丢弃后台段，
  修每书时长）+ `_readingTimeTracker?.start()`（重锚重启小时计时）。
- **纵轴格式器**（`stat_charts.dart` `formatStatDurationAxis`）：小时量级非整点保留一位小数
  （`2.8h`），整点仍显整数（`2h`），消除向下取整塌陷；根因 1 修好后 maxMs 回落 ≤1h，此为
  存量脏数据的防御。
- 提交：见下方 commit。

### 未做（本轮范围外，另立跟进）
- **阅读速度忽略过短翻页 + 设置项**（用户反馈问题 6）：需在字数计入处加最短停留门槛 +
  `settings_schema_reading.dart` 开关，属新功能，另行处理。
- **Daily avg 与 Today/字符图口径对不上**（问题 7）：`_buildKpiStrip` 的 dailyAvg = 总字数 ÷
  历史活跃天数（终身均值），与近期指标口径不同导致「偏低」，属产品语义决策，未擅改。
