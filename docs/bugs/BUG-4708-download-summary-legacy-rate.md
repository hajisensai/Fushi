## BUG-4708 · 下载中心合计速度不计入磁力 / 外部来源（legacy 番剧下载计划）行的实时速率
- **报告**：2026-11-16（用户：应用内反馈 D8YKoitTvM，Windows 3.3.0-debug.27417）下载中心顶部合计速度恒 0 B/s，而磁力 / 外部来源（legacy 番剧下载计划）行自己显示 ↓1.5 MB/s。
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/anime_download_dialog.dart:176` `animeDownloadTaskEntry` 收了 `DownloadTaskStats`，只用来算状态，没把 `downRateBps` / `upRateBps` / 做种位投影进 `DownloadTaskEntry`；`fushi/lib/src/media/downloads/download_task_browser.dart:1241` `DownloadSummaryHero` 按 `task.downRateBps ?? 0` 合计，legacy 行恒按 0 计（同理「做种」筛选也筛不到 legacy 行）。视频任务路径 `video_download_jobs_panel.dart:962-967` 是填了的。
- **[x] ① 已修复** — `animeDownloadTaskEntry` 与视频任务同口径把 `seeding` / `downRateBps` / `upRateBps` 从 stats 投影进 Entry；`DownloadSummaryHero` 注释改为按「来源报得出实时速率」计入。
- **[x] ② 已加自动化测试** — `fushi/test/pages/anime_download_task_entry_test.dart`：`observed stats project live rates and seeding into the entry`（Entry 字段）、`download summary hero totals legacy plan rates`（hero widget 显示非 0 合计）；修复前两条均红。
- **备注**：
