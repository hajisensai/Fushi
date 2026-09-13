## BUG-2217 · 跨小时瞬间 addChars 产出 0 时长字数段
- **报告**：2026-09-06（用户：）
- **真实性**：✅ 真 bug。根因 `packages/fushi_audio/lib/src/audiobook/study_clock.dart:303`（修复前）`addChars` 直接 `_ensureOpen(now)`：跨小时瞬间（打开段是 12 点段、now 已 13 点）先封旧段、按 13 点开新段只装字数；随后 `_accrue`（`:371-386`）按待定窗口 `[12:59:55, 13:00:10]` 拆桶时发现打开段小时不符 → `_seal()` 把它封成 **0 时长纯字数段**再另开一个 12 点段——同一小时两段 + 一段 0 时长字数段。
- **[x] ① 已修复** — 提交：`003149107a`；墙钟模式下 `addChars` / `addPages` 在 `_ensureOpen` 之前先 `_accrue(_now())` 结算待定窗口（新 helper `_settleBeforeContentAccount`，显式记账模式不走），旧小时的时长先落旧段，新段同时承接新小时的时长与字数。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/study_clock_test.dart`「BUG-2217：跨小时瞬间 addChars 先结算待定窗口，不产出 0 时长字数段」（断言无 `durationMs=0` 段、恰两段、字数落 13 点段）。
- **备注**：
