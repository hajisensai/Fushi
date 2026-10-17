## BUG-3257 · 桌面CLI快捷键列表滚轮绑定在macOS输出显示格式
- **报告**：2026-10-10（PR #2044 审查遗留疑点）
- **真实性**：✅ 真 bug。`/api/admin/shortcuts` 的 `mouse` 列里按键绑定走 `MouseBinding.serialize()`、滚轮绑定走 `WheelBinding.displayLabel`（`fushi/lib/src/platform/desktop/ctl/ctl_settings_routes.dart:918`）。#2044 之前 `WheelBinding.displayLabel == serialize()`，输出恰好是序列化 token；#2044（BUG-3203）把 `displayLabel` 改成按平台的显示格式后，macOS 上同一列变成一半 token、一半 `⌥WheelDown` 符号，脚本无法稳定解析 / 回读。
- **[x] ① 已修复** — 三列抽成 `ctlShortcutBindingColumns`，滚轮绑定改回 `serialize()`（与同列鼠标键、`shortcut_bindings` 偏好同一套跨平台 token）；键盘列历来是显示标签（`Ctrl+F` 而非 `Ctrl+KeyF`，BUG-3040），不在本条范围。提交 fix(ctl): emit wheel bindings in serialized form from /api/admin/shortcuts
- **[x] ② 已加自动化测试** — `fushi/test/platform/desktop/ctl/ctl_settings_routes_test.dart`「快捷键列：滚轮绑定走序列化格式，macOS 上也不出 ⌥ 显示符号」（换回 displayLabel 时红：`['⌥WheelDown']`）。
- **备注**：2026-10-10 用户拍板「根据 mac 的来」：这个列表是给人看的（`fushi_cli keys ls` 直接渲染），按平台显示约定出——键盘与滚轮都走 `displayLabel`，macOS 上是 `⌘F` / `⌥WheelDown`，与 app 内快捷键设置页同形。上面「改回 `serialize()`」的修法因此撤回：滚轮列改为 `displayLabel`，同列鼠标键无修饰键、无平台差异，两者不再矛盾。测试改为钉 macOS 上键盘列含 `⌘`、滚轮列含 `⌥`。
