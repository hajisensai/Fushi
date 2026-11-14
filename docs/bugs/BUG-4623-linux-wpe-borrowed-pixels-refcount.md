## BUG-4623 · Linux 漫画阅读器释放 WPE 借用像素缓冲区后崩溃
- **报告**：2026-10-26（用户：）
- **真实性**：✅ 真 bug。打开真实漫画后，WPE 像素回退调用 `wpe_buffer_import_to_pixels()`，该 API 返回由 `WPEBuffer` 持有的借用 `GBytes`，随后代码错误地 `g_bytes_unref(pixels)`。复现日志出现 GLib refcount critical，之后进程 SIGSEGV；根因位于 `packages/flutter_inappwebview_linux/linux/in_app_webview/in_app_webview.cc:1428-1460`。
- **[x] ① 已修复** — 移除对借用 `GBytes` 的 unref；立即复制像素后由 WPEBuffer 管理其生命周期。提交：`2409ba9b82`。
- **[x] ② 已加自动化测试** — `fushi/test/build/linux_wpe_borrowed_pixels_ownership_guard_test.dart` 检查该数据被复制且不再 unref。
- **备注**：定向 Flutter 测试与 Linux release 构建通过；仍待用户在同一真实漫画上肉眼复测。
