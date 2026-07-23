## BUG-1026 · 查词弹窗滚轮滚动慢，缺可配置速度项
- **报告**：2026-07-23（用户：）
- **真实性**：✅ 真 bug/功能 — 根因 `hibiki/assets/popup/popup.js:3602` 硬编码 `POPUP_WHEEL_PIXEL_FACTOR = 0.24`（粗鼠标滚轮降速系数，BUG-260 从 0.35 收窄），在 `:3739-3744` 参与 `deltaPx * factor` 计算，用户无法调节。popup.js 三份镜像同源（`hibiki/assets/popup/`、`hibiki/assets/browser_extension/vendor/`、`tools/browser-extension/vendor/`）。
- **[x] ① 已修复** — 新增偏好 `popup_wheel_speed`（double 倍率，默认 1.0，clamp 0.5–5.0）：`preferences_repository.dart` getter/setter + `app_model.dart` 委托 + 设置页滑杆 + i18n。in-app 三种弹窗经 `popup_settings_injection.dart` 注入 `window.__hoshiPopupWheelSpeed`；浏览器扩展弹窗经查词响应 `theme` 通道下发 `--hibiki-wheel-speed`（`app_model.browserExtensionThemeColors`）→ `content.js` `hibikiRender` 读它设同名全局（content/popup 同隔离世界共享 window）。popup.js 三份把 `factor` 乘以 `window.__hoshiPopupWheelSpeed`（缺省 1.0）。一个 app 设置驱动全部弹窗。提交：<待填>
- **[x] ② 已加自动化测试** — `hibiki/test/reader/popup_wheel_speed_asset_test.dart`：三份 popup.js 均含读取 `__hoshiPopupWheelSpeed` 且乘入 factor 的源码守卫；`popup_settings_injection` 测试断言注入该全局；`browser_extension_theme_colors` 测试断言 theme map 含 `--hibiki-wheel-speed`。提交：<待填>
- **备注**：默认 1.0 倍率与改前行为逐帧一致（粗鼠标 0.24、触控板 1.0）；倍率同乘两类设备，作为统一「滚轮速度」旋钮。
