## BUG-4006 · 首页复习面板缺少今日复习统计
- **报告**：2026-11-04（用户：应用内反馈 4mY-bG0T96「首页复习面板应该显示统计」）
- **真实性**：✅ 需求成立（功能缺口）。首页复习条 `HomeSrsPanel`（修前 `fushi/lib/src/pages/implementations/home_srs_panel.dart:95`）只读牌组列表的新 / 学习 / 到期计数，没有今天已复习数 / 用时 / 正确率；引擎也没有只算「今天」的轻量查询（统计页 `loadSrsStats` 要整份统计）。
- **[x] ① 已实现** — 引擎 `SrsDbStore.todayReviewSummary()`（`packages/fushi_engine/lib/srs/srs_db_store.dart`，对 `srs_stat_reviews` 按 `(profile_uid, occurred_at)` 索引取今天 `[dayStart, nextDayStart)` 的有效复习计数 / 用时和 / Again 数，口径与统计页 `todayStats()` 相同）+ 远程复习库 op `todayReviewSummary` 与 wire 编解码；首页条下加一行「今日 N 张 · 用时 · 正确率」（`homeSrsTodayLine`，`srsTodayReviewSummaryProvider` 随 `srsRevisionProvider` 重读，固定行高骨架 + AnimatedSwitcher）。i18n `home_srs_panel_today` 经 i18n_sync 加。提交：见下方提交记录。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/srs_today_review_summary_test.dart`（昨天 / 今天 / 撤销的复习，结果等于 `loadSrsStats(...).todayStats()`；远程 wire 往返）、`fushi/test/pages/home_srs_panel_test.dart`（真实 store 答两张卡后首页行与 `homeSrsTodayLine` 一致、含 50%）。
- **备注**：未做真机 / 桌面肉眼复测首页行的视觉。
