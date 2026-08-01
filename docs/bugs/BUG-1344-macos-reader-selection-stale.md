## BUG-1344 · macOS查词关闭后原文选区高亮残留
- **报告**：2026-08-01（用户：Mac 端查词结束后原词仍高亮，必须切屏或点击其它软件才消失）
- **真实性**：✅ 真 bug。整条查词弹窗栈关闭时，旧代码 `unawaited(_clearSelectionJs())` 派发异步 WKWebView 清选区，随即同步 `requestFocus()`；焦点切换先绘出失焦灰选区，迟到的 JS 虽删除 DOM/CSS selection，却没有下一次平台 surface 重绘，直到切应用才消失。根因见 `hibiki/lib/src/pages/implementations/reader_hibiki/lookup.part.dart:72-93` 与收尾顺序 `reader_hibiki_page.dart:3119-3147`。
- **[x] ① 已修复** — `df3b89200`：整栈关闭改走异步收尾，先 `await _clearSelectionJs()` 真正清除原生 Range、CSS Highlight 与内部 selection，再归还 reader 焦点；await 后复查 `mounted` 和 `isDictionaryShown`，旧会话不会抢新查词弹窗的焦点。查词弹窗仍打开时保留原文锚点，未改变连续查词、收藏或制卡语义。
- **[x] ② 已加自动化测试** — `hibiki/test/reader/reader_lookup_eval_guard_test.dart` 锁定“await clear → 生命周期/新会话复核 → focus reclaim”严格顺序；`reader_native_selection_lookup_guard_test.dart` 的原生选区 Copy 清理守卫继续通过。
- **备注**：代码、静态时序守卫和相关 reader 测试已通过；WKWebView 合成层残帧只能用真机截图最终确认，按用户要求本次不等待编译/设备验收。
