## BUG-1020 · Windows剪贴板监听页内翻转开关后永久失效

- **报告**：2026-07-23（用户）——"不知如何触发。但就是会触发。貌似无法监听粘贴板的问题。。重启应用恢复"（平台：Windows 桌面）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/home_dictionary_page.dart:254-256`（页级 dispose 的 stop 门控读**可变** pref `desktopClipboardEnabled`，与 initState 的 start 门控读的是同一可变量但时刻不同）。
- **根因**：`DesktopLookupService` 是 app 级单例，剪贴板监听生命周期用共享引用计数 `_startRefCount`（`desktop_lookup_service.dart:85,179-229`），有两个 owner：
  - **app 级**：`AppModel.applyDesktopClipboardLifecycle`（`app_model.dart:4203-4212`，启动一次 + 每次开关切换）——开=`start()`、关=`stop()`。
  - **页级**：`HomeDictionaryPage`——initState 按 pref `start()`（`home_dictionary_page.dart:168`）、dispose 按 pref `stop()`（`:254-255`）。

  页级 start/stop 都**现读可变 pref `desktopClipboardEnabled`**，且在 initState 与 dispose 两个不同时刻读。当用户在这两点之间翻转开关，两次读到不同值 → start/stop 失配。永久失效复现序列：① 关状态进词典页（initState 门控为假、不 start）→ ② 页内打开开关（app 级 `start()`，count 0→1，OS watcher 挂上）→ ③ 离开词典页（dispose 读 pref 现在=真 → `stop()`，count 1→0 → `clipboardWatcher.stop()` + `removeListener` 真正拆掉 OS 监听）。净结果：页面 dispose 吞掉了 app 级 hold 的那 +1，count=0、watcher 死，而 pref 仍显示"已开启"、app 级 owner 以为自己还持有着不会再 start → **剪贴板监听永久哑火，直到重启 app（main 重跑 applyLifecycle 重新 start）或手动关再开**。反向（页内关开关再离开）则 dispose 门控为假不 stop → 计数泄漏在 1，长期加剧错配。病根注释 `app_model.dart:4202`"service.start 对已运行是 no-op"是 bool 时代的陈旧假设，BUG-700 改成 refcount 后 start 每次都 +1，该假设失效。
- **[x] ① 已修复** — `home_dictionary_page.dart`：页级加实例 bool `_desktopLookupStarted`，`_startDesktopLookupIfEnabled` 真正 `start()` 前同步置 true（与 `start()` 内部首个 await 前同步完成的 `_startRefCount++` 天然配对），dispose **仅据此 bool** 决定是否 `stop()`，与可变 pref 彻底解耦。页级 owner 恒为严格配对的 +1/-1，pref 怎么翻都不吞别人的计数；不改动 `DesktopLookupService` refcount 语义，故 BUG-700 断点不变式（`home_dictionary_clipboard_watcher_breakpoint_test.dart`）仍成立。提交 `e2f67aa8a`。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/home_dictionary_clipboard_pref_flip_desync_test.dart`（widget 行为守卫，两例）：① 关状态进页 → app 级 `start()` → 页内翻 enabled=true → 卸载页，断言 `svc.isRunning` 仍为真且 OS watcher 未被 `stop`（复现即本 bug）；② 开状态进页真 start → 页内翻 enabled=false → 卸载页，断言严格配对 `stop`（1→0）无泄漏。已核实两例在旧（pref 门控）代码下均变红（test1 isRunning=false、test2 未 stop），修复后转绿。提交 `e2f67aa8a`。
- **备注**：移动端（Android/iOS）无此路径——剪贴板自动查词是桌面独有功能，`DesktopLookupService.start()` 首行 `if (!isDesktop) return`。与已修复的 BUG-700（600px 断点重建把 watcher 拆死）是同一 refcount 生命周期的相邻缺陷，但触发条件不同（本 bug=pref 在页生命周期内翻转，BUG-700=窗口跨断点重建）。
