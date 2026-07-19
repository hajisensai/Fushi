## BUG-927 · 阅读器原生选区残留卡住查词 + 右键闪退

- **报告**：2026-07-19（用户：长按左键拖动复制后无法查词；点「复制」出现系统蓝色选区后也查不了词，再按右键闪退）
- **真实性**：✅ 真 bug。桌面/细指针（鼠标）路径三连锁：
  - 根因① 查词被吞：`hibiki/lib/src/pages/implementations/reader_hibiki/webview.part.dart:1051-1065` 的 `pointerup` `_hoshiReaderMouseNativeTextStart` 分支，早退条件是 `if (nativeMoved || hasNativeSelection)`。只要上一轮残留的原生选区（`!isCollapsed`）还在，纯 tap（未移动）也提前 `return`，跳过 `_gestureEnd -> selectText -> clearSelection` 整条链 → 之后每次点击都被吞、查词永远打不开。桌面鼠标拖选/右键复制刻意保留原生选区（供 Ctrl+C），最易触发这个死循环。
  - 根因② 复制不清选区：桌面右键 `copy`（`chrome.part.dart` `_showReaderTextContextMenu` 的 `'copy'` 分支）与移动端原生 ContextMenu `copy`（`webview.part.dart` `ContextMenuItem id:3`）只 `Clipboard.setData`，从不 `removeAllRanges()`；只有移动端拖选菜单 `'copy'` 调 `_clearReaderAppSelection()`。复制后原生蓝/灰选区残留 → 喂给根因①。
  - 根因③ 右键闪退：`chrome.part.dart:250 _showReaderTextContextMenu` 从 `onSecondaryTapDown`（`webview.part.dart` `GestureDetector.onSecondaryTapDown`）fire-and-forget 调用，首个 `evaluateJavascript`（`nativeSelectionTextInvocation`）**未 try/catch**。WebView 半销毁/插件通道异常时抛 `PlatformException/MissingPluginException`，逃出 zone 被 `main.dart` `runZonedGuarded` 记为 fatal（进程终止）。孪生 `_fillLookupStateFromNativeSelection` / `_copyNativeSelectionToClipboard` 都已 try/catch，唯独此处漏。
- **[x] ① 已修复** —
  - `webview.part.dart` pointerup：早退条件 `nativeMoved || hasNativeSelection` → 仅 `nativeMoved`。纯 tap 落到 `_gestureEnd`，`selectText` 会先 `clearSelection(removeAllRanges)` 再查词，既清残留选区又正常弹词典。删掉不再使用的 `nativeSelection`/`hasNativeSelection` 死变量。
  - 桌面右键 `copy` 分支 + 移动端原生 ContextMenu `copy` action：复制后补 `await _clearReaderAppSelection()`（内部 `clearSelection` 走 `window.getSelection()?.removeAllRanges()`），与拖选菜单 `'copy'` 对齐。
  - `_showReaderTextContextMenu` 首个 `evaluateJavascript` 包 try/catch，异常记 `ErrorLogService` 后 `return`，不再逃 zone。
  - 提交：（见 PR）
- **[x] ② 已加自动化测试** — `hibiki/test/reader/reader_native_selection_lookup_guard_test.dart`：源码守卫钉死①pointerup 早退不得再含 `hasNativeSelection`；②两处 `copy` 分支复制后必须 `_clearReaderAppSelection()`；③`_showReaderTextContextMenu` 的 eval 必须在 try/catch 内。防回归。
- **备注**：均为桌面/细指针（鼠标）现象；触屏 `@media(pointer:coarse)` 强制 `user-select:none` 本就不建原生选区，但外接鼠标会让设备报告 `pointer:fine` 从而暴露同一路径。真机验证走 Windows。
