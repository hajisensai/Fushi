## BUG-1237 · 查词弹窗触屏复制经已结束 ActionMode 失效
- **报告**：2026-07-29（用户：Android 查词弹窗触屏复制无效）
- **真实性**：✅ 真 bug。`third_party/flutter_inappwebview_android/.../InAppWebView.java:1564-1607` 在传入 ContextMenu 时走 `rebuildActionMode`，先 `actionMenu.clear()` / `actionMode.finish()`，再把菜单点击转发给已结束的 ActionMode；hybrid composition 又绕过了 `:1584-1587` 的旧补救。
- **[x] ① 已修复** — commit `e6c5e5e98`：`dictionary_popup_webview.dart:1253-1336` 仅在 Android 隐藏失效的系统默认项，复制改由 Dart `Clipboard.setData`；分享与网页搜索复用 `SelectionExternalActions`，动作后穿透同源 iframe 清选区。iOS 不扩范围，Windows 右键路径不变。
- **[x] ② 已加自动化测试** — commit `e6c5e5e98`：`popup_touch_copy_actionmode_guard_test.dart` 锁 ActionMode 绕行、iframe payload 与桌面反向守卫；`selection_external_actions_test.dart` 锁 CJK/空格/换行原样 payload；`android_selection_action_channel_guard_test.dart` 锁 `ACTION_WEB_SEARCH` + `SearchManager.QUERY`、无 URL/Google/Bing fallback。mutation 把 `SearchManager.QUERY` 改成普通 `"query"` 后守卫按预期转红，恢复后 3/3。
- **备注**：无 Android 物理机，触屏选区、系统分享面板、系统默认搜索 handler 与“无 handler”可见 toast 尚待非施工 reviewer 真运行复测，当前标 `implemented_unverified`。
