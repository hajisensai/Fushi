## BUG-3654 · Linux 漫画阅读器 OCR 文字无法点击查词
- **报告**：2026-10-26（用户：）
- **真实性**：✅ 真 bug。用户能悬停到 OCR 文字并看到文本光标，但点击 OCR 字与页面空白区都无响应；说明 WPE 指针移动路径工作、点击序列未被 WebKit识别。`SetPointerButton` 的 `WPE_EVENT_POINTER_UP` 在构造事件时仍把已释放按钮的 modifier 位留在 `button_state_` 中，和旧 FDO 分支的状态时序相反。根因：`packages/flutter_inappwebview_linux/linux/in_app_webview/in_app_webview.cc:3326-3378`。
- **[x] ① 已修复** — 在创建 WPE pointer-up event 前清除释放按钮的状态位，使 `modifiers` 表示松开后的状态。提交：`0ee8db3a1b`。
- **[x] ② 已加自动化测试** — `fushi/test/build/linux_wpe_borrowed_pixels_ownership_guard_test.dart` 锁定按钮位必须在 WPE pointer-up event 创建前清除、事件创建后不得再清。
- **备注**：定向测试与 Linux release build 通过；待用户用鼠标复测 OCR 点击 / 空白点击。
