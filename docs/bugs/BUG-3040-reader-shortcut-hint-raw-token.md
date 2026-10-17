## BUG-3040 · 阅读器工具栏/溢出菜单快捷键提示显示原始键名 Ctrl+KeyF，触屏也显示
- **报告**：2026-10-05（协作者 shishamo：Android 平板歌词模式「⋯」菜单里「导航 · Ctrl+KeyF」「有声书 · KeyB」）
- **真实性**：✅ 真 bug。① `fushi/lib/src/shortcuts/input_binding.dart` `_keyLabel` 对已知键直接返回持久化 token，字母 / 数字键的 token 是 DOM code（`KeyF` / `Digit1`），`displayLabel` 于是显示 `Ctrl+KeyF`（快捷键设置页的键位 chip 同源）。② `reader_fushi/chrome.part.dart` `_labelWithShortcut` 不分平台给动作文案挂快捷键后缀，触屏平板菜单里也是一串键名。
- **[x] ① 已修复** — ① `_keyLabel` 把 `Key?` / `Digit?` token 显示成裸字符（`input_binding.dart:349`；持久化 `serialize()` 不变）；② 后缀统一走 `labelWithShortcutHint`（`shortcut_labels.dart:216`），只在 `isDesktopPlatform`（键盘是常规输入的平台）挂。仓库里没有「是否接了物理键盘」的既有判据，按平台类别判：桌面挂，Android / iOS（含接了外接键盘的平板）不挂；外接键盘平板若也要显示，需另加键盘检测。
- **[x] ② 已加自动化测试** — `fushi/test/shortcuts/input_binding_test.dart`（`Ctrl+F` / `B` / `1`，serialize 仍是 `Ctrl+KeyF`）；`fushi/test/shortcuts/shortcut_hint_label_test.dart`（桌面挂人类可读键名、触屏不挂、未绑定不挂）。
- **备注**：
