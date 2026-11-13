## BUG-4480 · Linux 漫画页面出现条纹，调整窗口大小时阅读器崩溃
- **报告**：2026-10-26（用户：）
- **真实性**：✅ 真 bug。`wpe_buffer_import_to_pixels()` 返回长度为 `height * mapStride` 的 borrowed 像素数据；阅读器按 `width * 4` 跨行读取，造成条纹。窗口缩放时 WPE 会更换 buffer pool，而 reader 仍保留旧的 borrowed `current_buffer_`；下一帧对失效指针执行 `WPE_IS_BUFFER`，在 `OnWpePlatformBufferRendered` 崩溃。根因位于 `packages/flutter_inappwebview_linux/linux/in_app_webview/in_app_webview.cc:1344-1578`。
- **[x] ① 已修复** — 使用实际 stride 解码到紧密 RGBA 输出；CPU 复制完成即归还 WPE buffer，并在 `buffers-changed` 池替换时清理 EGL 与旧 buffer。提交：`ab7e94c512`。
- **[x] ② 已加自动化测试** — `packages/flutter_inappwebview_linux/linux/test/flutter_inappwebview_linux_plugin_test.cc` 覆盖带行 padding 的 ARGB 转换；`fushi/test/build/linux_wpe_borrowed_pixels_ownership_guard_test.dart` 锁定 stride 和 resize 生命周期契约。
- **备注**：定向 Dart 守卫、原生 stride 测试和 Linux release 构建通过。待用户在同一漫画页面上肉眼复测条纹与窗口缩放。
