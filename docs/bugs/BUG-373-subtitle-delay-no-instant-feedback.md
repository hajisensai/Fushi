## BUG-373 · 字幕调整（音画延迟）没有即时反馈
- **报告**：2026-06-21（用户：字幕调整应该及时反馈）
- **真实性**：✅ 真 bug。两环都缺（对文本字幕）：
  - **不即时应用**：`VideoPlayerController.setDelayMs`（`hibiki/lib/src/media/video/video_player_controller.dart:598`）改 `_delayMs` 后既不重算当前 cue 也不 `notifyListeners`。文本字幕偏移在 Dart 侧靠 `effectiveSubtitlePositionMs(pos, delay)` 扣减，当前 cue 只在 125ms 周期 tick 的 `_syncCueForPosition` 里按新 delay 重算 → 暂停定格微调时连 tick 都不推进位置，「调了没反馈」。
  - **无可见反馈**：`_setDelayMs`（`video_hibiki_page.dart:4334`）只 setState 面板，无任何 OSD/toast（对比调速/切字幕都走左上角 `_showOsd`）。
- **[x] ① 已修复** — ① `setDelayMs` 文本字幕分支立即跑 `_resyncTextSubtitleAfterDelayChange(positionMs)`（=`_syncCueForPosition(pos, persistPosition:false)`），当前 cue 同帧按新偏移重算 + notify；图形字幕（libmpv `sub-delay`）即时渲染故跳过。② `_setDelayMs` 加 `_showOsd(t.video_subtitle_delay_osd(ms: signed), icon: Icons.sync_outlined)`，左上角 mpv 式数值反馈（带正负号，与面板内 +N ms 一致）。新增 i18n key `video_subtitle_delay_osd`（17 语言）。提交：<PENDING>
- **[x] ② 已加自动化测试** — 行为测试 `hibiki/test/media/video/video_subtitle_delay_instant_resync_test.dart`（经 `debugSetDelayMsForTesting(delay, positionMs:)` 走同一重算路径，断言定格调延迟当前 cue 立即按新偏移变化 / 落 gap 立即清空）+ 源码守卫 `hibiki/test/pages/video_subtitle_delay_osd_guard_test.dart`（断言 `_setDelayMs` 经 `_showOsd` + 用 `video_subtitle_delay_osd` key + `Icons.sync_outlined`）。
- **备注**：反馈形式（左上角 OSD 数值）沿用项目调速范式；若 PM 想要不同形式（如面板内 toast / 进度条上数值）可调整。需**真机复测**：暂停定格调延迟字幕同帧位移 + 看到 OSD。
