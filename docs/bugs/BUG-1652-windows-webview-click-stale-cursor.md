## BUG-1652 · Windows WebView 点击使用旧光标坐标导致词条操作无响应
- **报告**：2026-08-14（用户：右上角“+”与“收藏”点击无反应）
- **真实性**：✅ 真 bug。Windows `custom_platform_view.dart` 的 hover/move 会调用
  `setCursorPos`，但 mouse down/up 只调用按钮状态同步；native WebView2 的
  `setPointerButtonState` 使用缓存的 `lastCursorPos_`，弹窗出现在静止光标下或跨平台视图
  边界时，down/up 会落到旧 DOM 坐标，按钮业务 handler 根本收不到 click。
- **[x] ① 已修复** — 所有非触摸事件统一规划为“先同步本次 localPosition，再按位同步
  按钮状态”，down/up/cancel/hover/move 都走同一有序路径。
- **[x] ② 已加自动化测试** — `mouse_button_mask_diff_test.dart` 新增 down/up 命令顺序
  回归，断言坐标命令严格排在 primary button 翻转之前；原多键与 sticky-state 用例保持
  全绿。
- **备注**：业务层 `mineEntry` / `favoriteEntry` 的 JS→Dart 回调原本完整，两个按钮一起
  失效发生在它们共同的 Windows 指针输入前置链路。
