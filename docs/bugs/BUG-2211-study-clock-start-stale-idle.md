## BUG-2211 · StudyClock.start 不重置空闲基准，回前台后首页阅读被空闲门拒绝
- **报告**：2026-09-06（用户：）
- **真实性**：✅ 真 bug。根因 `packages/fushi_audio/lib/src/audiobook/study_clock.dart:269`（修复前）`start()` 用 `_lastTouch ??= now`：只在首次起表时置空闲基准。挂机超过空闲门 → 切走 `stop()` → 回前台 `start()` 后 `_lastTouch` 仍是挂机前的旧值，首个 tick 被空闲门拒掉（直到下一次翻页才恢复），回前台后的第一页阅读整段丢失。
- **[x] ① 已修复** — 提交：`003149107a`；`start()` 无条件 `_lastTouch = now`——start 本身由用户回前台 / 手动继续 / 关面板触发，就是一次输入。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/study_clock_test.dart`「BUG-2211：挂机超时 → stop → start 后首个 tick 入账」+ 守卫 `reader_study_clock_gate_guard_static_test.dart`「start 无条件重锚空闲基准」。
- **备注**：
