## BUG-2209 · 后台听书跟随经 _ensureStudyClock 重启已停表时钟
- **报告**：2026-09-06（用户：）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/reader_fushi/navigation.part.dart:1586`（修复前）`_ensureStudyClock` 只看 `_studyClockManualPause` 就 `clock.start()`；而它被 `_onRestoreComplete`（`:165`）、content-ready 兜底（`:68`）、`_refreshProgress` 记字数（`:1154`）反复调用。`reader_fushi_page.dart:2924` 切后台 `stop()` 后，开启后台听书的用户 cue 跨章 → `_navigateToChapter` → 恢复完成 → `_ensureStudyClock` 把时钟重新起表，后台挂机时长照计（BUG-892 的形状换了个入口回来）。
- **[x] ① 已修复** — 提交：`003149107a`；页面加统一判据：顶层纯函数 `studyClockMayRun(manualPause, lifecycleStopped, modalDepth)`（`reader_fushi_page.dart`）+ getter `_studyClockMayRun` + `_syncStudyClockRunState()`（可跑→`start()`，不可跑→`stop()`）。`didChangeAppLifecycleState` paused/inactive 置 `_studyClockLifecycleStopped=true` 后 sync，resumed 清旗后 sync；`_ensureStudyClock` 与 `_toggleStudyClockManualPause` 都改走判据，页面里不再有裸 `_studyClock?.start()/stop()`。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_study_clock_policy_test.dart`（判据真值表）+ `fushi/test/pages/reader_study_clock_gate_guard_static_test.dart`「BUG-2209」组（`_ensureStudyClock` 不含手动暂停旗、生命周期两分支都经 sync、开关不直接 start/stop）。
- **备注**：
