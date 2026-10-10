## BUG-3257 · 桌面CLI快捷键列表滚轮绑定在macOS输出显示格式
- **报告**：2026-10-10（PR #2044 审查遗留疑点）
- **真实性**：✅ 真 bug。`/api/admin/shortcuts` 的 `mouse` 列里按键绑定走 `MouseBinding.serialize()`、滚轮绑定走 `WheelBinding.displayLabel`（`fushi/lib/src/platform/desktop/ctl/ctl_settings_routes.dart:918`）。#2044 之前 `WheelBinding.displayLabel == serialize()`，输出恰好是序列化 token；#2044（BUG-3203）把 `displayLabel` 改成按平台的显示格式后，macOS 上同一列变成一半 token、一半 `⌥WheelDown` 符号，脚本无法稳定解析 / 回读。
- **[x] ① 已修复** — 三列抽成 `ctlShortcutBindingColumns`，滚轮绑定改回 `serialize()`（与同列鼠标键、`shortcut_bindings` 偏好同一套跨平台 token）；键盘列历来是显示标签（`Ctrl+F` 而非 `Ctrl+KeyF`，BUG-3040），不在本条范围。提交 fix(ctl): emit wheel bindings in serialized form from /api/admin/shortcuts
- **[x] ② 已加自动化测试** — `fushi/test/platform/desktop/ctl/ctl_settings_routes_test.dart`「快捷键列：滚轮绑定走序列化格式，macOS 上也不出 ⌥ 显示符号」（换回 displayLabel 时红：`['⌥WheelDown']`）。
- **备注**：键盘列在 macOS 上同样随 #2044 变成 `⌘F` 形态（显示列，非 wire 契约）；若 CLI 要求键盘列也跨平台恒定，需另定是否改为 `serialize()`。
