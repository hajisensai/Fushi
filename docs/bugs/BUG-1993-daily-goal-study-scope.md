## BUG-1993 · 首页每日目标只算阅读域纯视频游戏日显示零
- **报告**：2026-09-01（用户：每日目标不显示进度——当日看视频字幕 7152 字 / 53.8 分钟，热力图「全部」有数，下方目标却 0 / 3000）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/stats/stat_facts.dart:349`（改前）：v92 统计重构把目标分子函数 `readingGoalCharsForDay` 硬编码 `f.isBook` 过滤，只算书 + 漫画；首页目标行 `home_dashboard_page.dart:1915` 传的又是书面切片 `_readingRows`。热力图「全部」档统计阅读 + 观看 + 游戏三来源，同一张卡上下两个数口径不一致——纯视频/游戏日目标恒 0。
- **[x] ① 已修复** — 目标概念重设计为「每日学习目标」：`studyGoalCharsForDay` 只按 dateKey 求和、域由调用方传入的行集决定（消除 `isBook` 特殊分支）。首页目标行/近 7 日日均传完整日面（阅读+观看+游戏，派生 getter `_dailyRows`）；阅读统计页目标卡与「今天」目标环新增学习域分子 `_todayStudyChars` / `_weekStudyChars`（每周目标同口径一起改），概览「今日字数」与 CPH 保留阅读域。热力图来源筛选只影响热力图，结构上不进目标分子。偏好键 `readingGoalDailyChars` 冻结不动，已设的 3000 保留。
- **[x] ② 已加自动化测试** — `fushi/test/pages/stat_source_totals_test.dart`（`studyGoalCharsForDay` 组：混合日/字幕日/纯游戏日/跨日边界/域切片）+ `fushi/test/tools/statistics_write_convergence_guard_test.dart` ⑧（两页目标分子必须走同一 `studyGoalCharsForDay`）。
- **备注**：v92 收窄口径本意是让首页与阅读统计页对得上（旧首页三种字相加、统计页只算阅读域），但收窄方向选错了——用户语境里视频字幕/游戏 hook 也是学习量，正确方向是两页一起放宽到学习域。
