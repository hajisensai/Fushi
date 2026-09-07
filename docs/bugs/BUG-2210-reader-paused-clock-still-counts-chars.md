## BUG-2210 · 手动暂停计时期间翻页仍 addChars 产出 0 时长字数段
- **报告**：2026-09-06（用户：）
- **真实性**：✅ 真 bug。根因 `packages/fushi_audio/lib/src/audiobook/study_clock.dart:300-314`（修复前）`addChars` / `addPages` 不看 `isRunning`：手动暂停（`chrome.part.dart:2247`）或切屏 `stop()` 后翻页，`_refreshProgress` 仍 `_ensureStudyClock().addChars` → `_ensureOpen` 以 0 时长开段装字数 → 落库成「0 时长有字数」的段，字/时被推向无穷；漫画页停留定时器到期 `addPages`（`manga_fushi_page.dart:953-965`）是同形变体。
- **[x] ① 已修复** — 提交：`003149107a`；在 `StudyClock` 层修：`addChars` / `addPages` 在 `!isRunning` 时直接 return（停表 = 不在学习，字数页数一并不计；水位照常由页面推进，这些字之后也不会补计——有意）。漫画页同形变体由此一并解决，不改漫画页。原「无段时以 0 时长开段」用例改成 start 后测。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/study_clock_test.dart`「BUG-2210：停表期间 addChars / addPages 不入账、不开段」+ `fushi/test/pages/reader_study_clock_gate_guard_static_test.dart`「addChars / addPages 停表即丢」。
- **备注**：
- **2026-09-06 追记**：新模型下停表期间翻走的单元同样进覆盖并集但 `addChars` 丢弃、之后不补计——契约不变，由 `StudyClock` 保持，账本不管。
