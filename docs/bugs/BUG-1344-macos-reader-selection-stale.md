## BUG-1344 · macOS查词关闭后原文选区高亮残留
- **报告**：2026-08-01（用户：Mac 端查词结束后原词仍高亮，必须切屏或点击其它软件才消失）
- **真实性**：✅ 真 bug。整条查词弹窗栈关闭时，旧代码 `unawaited(_clearSelectionJs())` 派发异步 WKWebView 清选区，随即同步 `requestFocus()`；焦点切换先绘出失焦灰选区，迟到的 JS 虽删除 DOM/CSS selection，却没有下一次平台 surface 重绘，直到切应用才消失。根因见 `hibiki/lib/src/pages/implementations/reader_hibiki/lookup.part.dart:72-93` 与收尾顺序 `reader_hibiki_page.dart:3119-3147`。
- **[x] ① 已修复** — `df3b89200`, `3cf848329`：整栈关闭先 `await _clearSelectionJs()` 再归还 reader 焦点；await 后复查 `mounted`、弹窗可见性及 `activeLookupGeneration`，连“新查词已开始但弹窗尚未显示”的窗口也不会被旧会话抢焦点。原生右键/系统菜单查词则先采完句子与夹图状态、在打开弹窗前立即清原生 selection，避免失焦灰块从一开始就出现。
- **[x] ② 已加自动化测试** — `reader_lookup_eval_guard_test.dart` 锁定“await clear → 生命周期/lookup generation/可见性复核 → focus reclaim”严格顺序；`reader_native_selection_lookup_guard_test.dart` 分别锁定 Windows Flutter 右键与非 Windows 原生菜单“采状态 → 清选区 → 搜索”的顺序。
- **备注**：代码、静态时序守卫和相关 reader 测试已通过；WKWebView 合成层残帧只能用真机截图最终确认，按用户要求本次不等待编译/设备验收。
