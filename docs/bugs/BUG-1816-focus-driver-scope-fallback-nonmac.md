## BUG-1816 · FocusDriver Scope 兜底掩盖非 macOS Tab 回归
- **报告**：2026-08-24（Apple 全功能完成前独立代码审查）
- **真实性**：✅ 真测试门 bug。`fushi/integration_test/helpers/focus_driver.dart:95-124` 为 macOS EditableText/WKWebView 合成 Tab 的 runner 限制调用 `nextFocus()`；最初 Scope 分支没有平台门，iOS/Windows 真实 Tab 若卡在路由 FocusScope，也会被程序化推进并把“focus reachable”误报为通过。
- **[x] ① 已修复** — EditableText 与 route FocusScope 两个程序化 next-focus 兜底都显式要求 `defaultTargetPlatform == TargetPlatform.macOS`；iOS/Windows 不再降级，真实按键不动就让导航门红。提交 `a3e82e646`。
- **[x] ② 已加自动化测试** — `fushi/test/integration_helpers/focus_driver_test.dart:53-133` 分别覆写 macOS/iOS：同一被 Shortcuts 吞掉的 Tab 场景在 macOS 可用语义兜底到按钮，在 iOS 必须耗尽并返回 false。iOS 负测修复前实际 true，修复后 false；相邻 skipTraversal 守卫全绿。
- **备注**：`requestFocusInside`/`activateIntent` 仍只用于用例明确声明的平台 runner 激活兜底；零跳过导航门的主标签/设置目的地继续以 `focusWidget + Enter` 为第一路径，并通过上述 iOS 负测防止跨平台假绿。
