## BUG-3203 · macOS 快捷键显示写死 Ctrl/Alt，引导键帽横向撑满
- **报告**：2026-10-08（仓库所有者，macOS：新手引导「全局查词」那步显示 Ctrl / Alt / D，不是 ⌘ / ⌥）
- **真实性**：✅ 真 bug（只是显示错，绑定本身正确）。
  - 显示：`InputBinding.displayLabel`（`fushi/lib/src/shortcuts/input_binding.dart`）直接拿持久化 token `ModifierKey.label`（`Ctrl` / `Alt` / `Meta`）拼字符串，全 app 的快捷键 chip、tooltip、菜单后缀、设置列表键帽、滚轮绑定名都经它或同样的 `m.label`，macOS 上没有任何平台分支。
  - 绑定：macOS 默认表 `ShortcutDefaults._macOS` 对其它动作做 Ctrl→Cmd，但**有意**保留全局查词为 Control+Option+D——⌘⌥D 是 macOS 系统级「隐藏/显示 Dock」，系统热键先于 `RegisterEventHotKey`，应用永远收不到；`GlobalLookupController` 注册的就是 `HotKeyModifier.control + alt`。所以实际按键是 ⌃⌥D，只修显示，不改成 Cmd。
  - 键帽撑满：`KeyCapWidget` 在 `width == null` 时侧壁、键面全是 `Positioned`，Stack 只能取父约束最大宽，Wrap 里每枚键帽占满一整行。
- **[x] ① 已修复** — `input_binding.dart` 新增显示统一入口：`ModifierKey.displayLabelOn` / `shortcutModifierDisplayLabels`（Apple 平台 ⌃ ⌥ ⇧ ⌘、按 HIG 顺序）/ `joinShortcutDisplayParts`（Apple 平台直接相连 `⌃⌥D`，其它平台 `+`）/ `InputBinding.displayParts`；`displayLabel`、`WheelBinding.displayLabel`、`WheelBindingLabel.label`、设置快捷键列表键帽（改用 `displayParts`，删掉按 `+` 拆字符串的 `_keyParts`）、键盘示意图的修饰键键帽、引导页键帽（抽成 `OnboardingHotkeyKeycaps`）全走它。持久化 token（`serialize` / `ModifierKey.label` / popup 线协议）不变。`KeyCapWidget` 无宽度时按内容收宽。
- **[x] ② 已加自动化测试** — `fushi/test/shortcuts/shortcut_display_platform_test.dart`（各平台分段 / 文本 / tooltip / 滚轮名，token 不随平台变）、`fushi/test/onboarding/onboarding_wizard_layout_test.dart`（macOS 下引导键帽为 ⌃ ⌥ D、同一行、按内容收宽，并钉住 macOS 默认绑定是 Control+Option+D）。
- **备注**：iPadOS 外接键盘同样用 Apple 符号（`shortcutUsesAppleSymbols` 含 iOS）。
