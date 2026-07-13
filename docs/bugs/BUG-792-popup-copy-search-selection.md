## BUG-792 · 查词弹窗选中后复制/搜索无效

- **报告**：2026-07-14（用户：）
- **真实性**：✅ 真 bug。根因两层：
  - **① 桌面 fork 未实现 `getSelectedText`**：`packages/flutter_inappwebview_windows/windows/in_app_webview/webview_channel_delegate.cpp:285` 的 method 分发里**没有 `getSelectedText` 分支**，落到默认 `result->NotImplemented()` → Dart 侧 `_controller.getSelectedText()` 返回 null。
  - **② 选区在同源子 iframe 内**：查词弹窗把每张词条卡渲染成独立**同源** iframe（`hibiki/assets/popup/global_lookup_host.js:8`「Why iframes」），用户拖选的原生文本落在 CHILD iframe 的 `window.getSelection()` 里；即便 `getSelectedText` 可用，它也只读顶层文档，取不到 iframe 内选区。
  - 两条右键菜单路径都靠它取选区：非 Windows 的 `menuItems` 查词项（`dictionary_popup_webview.dart:975`）+ Windows 的 `_showWindowsContextMenu` 复制/搜索（同文件旧 `final String text = (await _controller?.getSelectedText()) ?? ''`）。拿到空串 → `if (text.isEmpty) return` 早退 → 复制/搜索表现为无效。
- **[x] ① 已修复** — 新增穿透同源 iframe 的选区读取：`_selectedTextAcrossFramesJs`（递归遍历 `iframe.contentWindow` 的 `window.getSelection()`，`JSON.stringify` 收口回传）+ `_selectedTextAcrossFrames()` helper，替换全部 3 处 `getSelectedText()` 调用（menuItems 查词项 + Windows 菜单复制/搜索）。用已实现的 `evaluateJavascript` 下发，桌面+移动一处修复通吃。文件 `hibiki/lib/src/pages/implementations/dictionary_popup_webview.dart`。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/popup_selection_copy_search_iframe_guard_test.dart`：① 剥注释后弹窗源码不得再出现 `getSelectedText`；② 必须存在遍历 iframe 的选区 JS（含 `iframe`/`contentWindow`/`getSelection` 递归）。并更新既有守卫 `test/pages/dictionary_popup_webview_test.dart:629` 把旧的「复制走 getSelectedText」断言改为「走 _selectedTextAcrossFrames」。
- **备注**：源码扫描守卫已挡回归；跨 iframe 真实选区行为需真机复测（Windows 桌面弹窗拖选→右键复制/搜索；Android 弹窗拖选→原生菜单查词）作为最终验收门。
