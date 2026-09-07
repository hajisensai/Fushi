## BUG-2213 · 阅读空闲门分钟数在建时钟时快照，阅读中改设置不生效
- **报告**：2026-09-06（用户：）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/reader_fushi/navigation.part.dart:1581`（修复前）`_ensureStudyClock` 只在 `_studyClock ??= StudyClock(idleTimeout: appModel.readingIdleTimeout)` 建时钟那一次快照空闲门分钟数（PDF `reader_pdf_page.dart:170` 同形）；阅读中在面板改「阅读空闲超时」要退出重开书才生效。
- **[x] ① 已修复** — 提交：`003149107a`；`_ensureStudyClock()` 每次调用都 `clock.idleTimeout = appModel.readingIdleTimeout`（字段本就可变），并在 `_showAppearanceSheet` 面板关闭时再刷一次。PDF 侧建时钟仍一次快照（PDF 页无内置设置面板，改设置需回到设置页；未改）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/reader_study_clock_gate_guard_static_test.dart`「BUG-2213」组（`_ensureStudyClock` 每次刷 idleTimeout 且构造期不传；面板关闭刷一次）。
- **备注**：
