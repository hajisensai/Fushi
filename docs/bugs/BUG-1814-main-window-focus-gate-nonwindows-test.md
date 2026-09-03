## BUG-1814 · Windows 焦点闸门单测在非 Windows 误红
- **报告**：2026-08-24（Apple 全量回归门）
- **真实性**：✅ 真测试门 bug。生产 `mainWindowFocusGateApplies` 明确只有 `Platform.isWindows` 为 true，macOS 上 `MainWindowFocusGate.build` 直接返回 child；`fushi/test/focus/main_window_focus_gate_test.dart:36-89` 却在所有平台断言关门后请求焦点必须失败，导致 macOS 全量套件稳定两红。
- **[x] ① 已根因修复** — Apple QA 分支先用平台 skip 消除 macOS 假红（提交 `2b21b9513`）；合并 develop 的 `f6c7d8e15` 后采用更强方案：生产判据增加 `debugMainWindowFocusGateAppliesOverride`，测试 setUp 强制启用闸门，因此三条 Windows 语义在 macOS/Linux CI 也真实执行而非跳过；dispose 同时无条件退订，避免覆盖点变化时漏 listener。
- **[x] ② 已加自动化测试** — `main_window_focus_gate_test.dart` 现在跨宿主执行关门/开门/恢复三条行为测试，并新增“判据不适用时纯透传”反向用例。它既锁住 Windows 不抢前台不变量，也锁住 Android/iOS 不凭空多一层焦点闸门；合并后定向 4 条全绿。
- **备注**：最终方案优于最初平台 skip；它不改变默认生产判据（仍是 `Platform.isWindows`），只给测试提供显式覆盖点。
