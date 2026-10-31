## BUG-3893 · 发现页「今日放送」冷启动等整周放送表拉完才显示
- **报告**：2026-10-29（用户：群反馈 L1rmA0Ayuh，fushi-bot 代提交；海外弱网用户「really slow」）
- **真实性**：✅ 真 bug（读代码确认，实际耗时未实测）。「今日放送」小模块只显示今天，但请求（`fushi/lib/src/pages/implementations/discovery/airing_today_shelf.dart:71`）与完整日历页一样取整周；缓存空时 `fushi/lib/src/media/video/airing_calendar_loader.dart:159-174` 逐页串行拉整周（perPage 50、最多 12 页、页间 700ms），全部拉完才返回，今天的数据被整周阻塞，弱网下长时间骨架屏。
- **[x] ① 已修复** — `AiringCalendarRequest` 加 `day`：小模块只请求今天这一本地日的窗口（通常一两页）。取数先查**整周**缓存，命中就截取当天、零请求；未命中再查单日缓存（签名 `day:<当日 00:00>|all`，与整周签名不相撞），最后只拉当天窗口。整周仍在进完整日历页时按需拉，分页仍串行 + 页间 700ms（AniList 限流约 90 req/min），没有改成并发；总请求数只减不增。提交见 PR。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/airing_calendar_loader_test.dart`（MockClient 断言请求窗口 = 当天、单日结果不冒充整周缓存、整周缓存命中时零请求截取当天、整周请求窗口不变）；`fushi/test/pages/video_discovery_page_test.dart` 断言小模块请求带今天的 `day`。
- **备注**：未在真实弱网环境测耗时。
