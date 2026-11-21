## BUG-4947 · 音频源对话框连点删除崩溃（RangeError @ List.removeAt）
- **报告**：2026-11-21（应用内反馈 BTnqi9Py0e，v3.3.0 安卓 iReader Ocean 5 Pro 电子墨水屏：180ms 内连点两次删除，两条 UncaughtZone `RangeError (length): Valid value range is empty: 0 @ List.removeAt ← _AudioSourcesDialogState._buildSourceRowContent`）
- **真实性**：✅ 真 bug。
  - 根因：`fushi/lib/src/pages/implementations/dictionary_settings_dialog_page.dart:377-416`（修前）开关 / 上移 / 下移 / 删除四个按钮的闭包捕获的是**构建时的 `index`**，点击时直接 `_sources.removeAt(index)` / `_sources[index] = ...`。两次点击之间不保证有一次重建（慢帧设备、主线程忙），第二次点击命中上一帧构建的旧按钮：只剩一行时越界抛 `RangeError`；多行时旧下标指向别的行，静默**误删 / 误移另一行**（比崩溃更隐蔽）。
- **[x] ① 已修复** — 四个行内按钮统一走 `_updateRow(row, change)`：用闭包捕获的行实例按 `identical` 现场查真实位置再改表；每次改动都会让该行换新实例（`copyWith`）或移出列表，查不到就说明点的是已不存在的旧行，这次点击没有作用对象。上移 / 下移在当前位置已到边界时不动。提交见本文件 Git 历史。
- **[x] ② 已增加自动化测试** — `fushi/test/pages/audio_sources_dialog_page_test.dart` 的 `row buttons tapped twice before a rebuild (BUG-4947)` 组：两次 tap 之间不 pump，覆盖「唯一一行连点删除不抛错」「首行连点删除不误删第二行」「首行连点下移不把别的行换回来」。修前代码上同组测试红（RangeError / 误删），修后绿。
- **备注**：同一反馈里的后台 ANR（10:14:43，正文截断无栈）与 dvZrfpJRn8 同机同期，证据不足以定位，不在本条范围。
