## BUG-2222 · PDF 阅读器从不 addPages，页数统计恒 0
- **报告**：2026-09-06（用户：）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/reader_pdf_page.dart:188-201`（修复前）`_onPageChanged` 只 `_studyClock?.touch()` 喂空闲门，从不 `addPages`；PDF 的 `study_segments.pages` 恒 0，统计页 / 热力图页数面对 PDF 完全空白。
- **[x] ① 已修复** — 提交：`003149107a`；维护会话最高页 `_sessionMaxPageIndex`（有存档预置到存档页，无存档 -1），纯函数 `pdfPagesNewlyReached(pageIndex, sessionMaxPageIndex)` 只计首次越过最高页的部分，`_onPageChanged` 据此 `addPages(newPages)`（往回翻 / 回到已读页不计；跳目录前跳 N 页计 N 页，PDF 无停留门）。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_study_clock_policy_test.dart`「pdfPagesNewlyReached」组 + 守卫 `reader_study_clock_gate_guard_static_test.dart`「BUG-2222：_onPageChanged 经 pdfPagesNewlyReached 只计首次越过的页」。
- **备注**：
- **2026-09-06 被 ReadUnitLedger 取代**：PDF「读过」判据改为翻走即计 + 会话覆盖并集，`pdfPagesNewlyReached` / `_sessionMaxPageIndex` 标量水位删除（跳 N 页只计跳走前那页、无存档预置），见 docs/plans/2026-09-06-read-unit-ledger.md；行为用例 `test/reader/reader_pdf_read_ledger_test.dart`，守卫组改钉 `_readLedger.arrive(` / `addPages(readUnitsLength(`。
