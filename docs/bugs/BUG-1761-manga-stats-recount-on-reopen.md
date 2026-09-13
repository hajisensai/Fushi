## BUG-1761 · 漫画统计重开书重复计页170页卷记成400页
- **报告**：2026-08-21（用户：Discord moonbeam「fushi currently thinks i've read 400
  pages of a 170 page volume」）
- **真实性**：✅ 真 bug，两个根因叠加（`fushi/lib/src/media/manga/reader/manga_fushi_page.dart`）：
  ① 去重集合 `_sessionCountedPages` 是页面 State 字段，每次重开这卷都是空集——跨会话
  零去重，恢复位置附近与回翻经过的页全部重算，DB 侧 `addReadingStatistic` 按
  (title, dateKey) 纯累加无上限；② 「到达即计」——页面一成为当前页立刻入账，快速
  翻过/扫过的页全部记成已读，来回翻一圈就是整卷虚增。同函数还藏着反向 bug：flush 用
  整段墙钟 `now - _sessionStartTime` 过 `isContinuousReadingGap`（120s），而漫画只在
  退出/失焦才 flush → 任何 >120s 的正常会话时长被整段丢弃（虚高与丢失并存）。
- **[x] ① 已修复** — 三件套：**停留门**（`_armPageDwellCount`：当前页停留 ≥1.5s 才
  经 `_countVisiblePages` 入账，换页重计时、同页滚动不重置；「到达即计」被挡在门外，
  产品决策：快速翻过≠读过，书籍/视频同规则另案修）；**续读预置**
  （`_seedCountedPagesFromRestore`：恢复存档时把 0..恢复页 预置为已计，与 EPUB
  `sessionWatermarkAfterRestore` 同款语义；在线 initialPage 显式跳页不预置）；
  **时长逐 tick 记账**（BUG-1052 同款对齐 PDF：`ReadingTimeTracker` 的 `onDelta` 累计
  `_sessionReadingMs`，flush 前 `sampleNow()`，gap 守卫只在 tracker 内逐 tick 生效；
  最后一段哪怕 <1s，已入账页数/字数也落库不丢）。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_stats_dwell_guard_test.dart`：
  停留门唯一入账口 + 三入口全走停留门 + 同页不重置计时 + 两条恢复路径都预置 +
  onDelta/sampleNow 接线 + 整段墙钟形态不得回潮 + 最后一段不丢内容账 七条。
- **备注**：历史数据不自愈（`reading_statistics.pages_read` 是累加标量，无明细可回溯）；
  `pagesRead` 不进 sync wire（纯本机维度），改计数不影响跨端契约。EPUB/视频的同型
  「到达即计」另案：EPUB 见 BUG-1762、视频见 BUG-1763。
- **2026-09-06 被 ReadUnitLedger 取代**：漫画「读过」判据改为翻走即计 + 会话覆盖并集，无停留门（1.5s 到达停留裁定推翻）、无会话 Set、无存档预置，见 docs/plans/2026-09-06-read-unit-ledger.md；守卫 `manga_stats_dwell_guard_test.dart` 同步改为账本接线守卫。
