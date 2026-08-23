## BUG-1814 · Windows 焦点闸门单测在非 Windows 误红
- **报告**：2026-08-24（Apple 全量回归门）
- **真实性**：✅ 真测试门 bug。生产 `mainWindowFocusGateApplies` 明确只有 `Platform.isWindows` 为 true，macOS 上 `MainWindowFocusGate.build` 直接返回 child；`fushi/test/focus/main_window_focus_gate_test.dart:36-89` 却在所有平台断言关门后请求焦点必须失败，导致 macOS 全量套件稳定两红。
- **[x] ① 已根因修复** — 三条 Windows 语义用例统一以 `!mainWindowFocusGateApplies` 作为 skip 条件；macOS/Linux 不再断言不存在的 Win32 `SetFocus` 闸门，Windows runner 仍完整执行原三条行为断言。提交 `2b21b9513`。
- **[x] ② 已加自动化测试** — 直接运行 `flutter test --no-pub test/focus/main_window_focus_gate_test.dart`：修复前 macOS 两红（`probe.hasFocus` 实际 true），修复后 3 条明确标记平台 skip、套件退出码 0；Windows 上 skip 条件为 false，原有红绿行为测试仍是自动化门。
- **备注**：这是平台测试路由修复，不改变生产焦点逻辑。
