## BUG-2206 · 重排/宽变/模式切换恢复完成无条件清零令牌桶额度致漏计
- **报告**：2026-09-06（用户：）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/reader_fushi/navigation.part.dart:187-189`（修复前）`_onRestoreComplete` 每次都无条件 `_lastWatermarkAdvanceAt = now` + `_readChargeCreditMilliChars = 0`；而它在改字号 / 换主题 `_reloadWithCurrentSettings`、窗口宽变重排、分页↔连续切换、听书回读等**原位恢复**时都会跑。一次重排就把令牌桶攒下的额度砍光，紧随其后的正常翻页只分到几毫秒额度，整页被 `accumulateSessionCharsCapped` 漏计。
- **[x] ① 已修复** — 提交：`003149107a`；判据抽成纯函数 `restoreSeedResetsReadCharge(currentWatermark, seeded)`（`seeded > currentWatermark`）：只有 `computeCharWatermark` 播种值**大于**当前水位（真正前跳：首次进入 / 前进跨章 / 跳转）才重置时间基准与清零额度；播种值 ≤ 水位的原位恢复保留额度。`navigation.part.dart` 进度条跳转与 `chrome.part.dart` 搜索跳转保持无条件清零（那是真跳转）。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_study_clock_policy_test.dart`「restoreSeedResetsReadCharge」组 + 守卫 `reader_study_clock_gate_guard_static_test.dart`「BUG-2206：_onRestoreComplete 清零受门控」（4 空格缩进的无条件清零形态不得回归）。
- **备注**：
- **2026-09-06 追记**：令牌桶已整体删除（`ReadUnitLedger` 无额度概念，原位恢复走 `rebaseOnNextArrive()`），本条语境消失；`restoreSeedResetsReadCharge` 与其测试随之删除。见 `docs/plans/2026-09-06-read-unit-ledger.md`。
