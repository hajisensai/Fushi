## BUG-1469 · 资源搜索对话框下拉框横向溢出
- **报告**：2026-08-09（用户：截图反馈）
- **真实性**：✅ 真 bug。`hibiki/lib/src/pages/implementations/video_discovery_acquisition_dialogs.dart:909` 与 `:935` 的两个 `DropdownButtonFormField` 默认 `isExpanded = false`，按最长菜单项的固有宽度布局；字幕“必需”文案超出半宽字段，导致 `RenderFlex` 向右溢出 61 px。
- **[x] ① 已修复** — 两个下拉框均启用 `isExpanded: true`，并将字幕选项限制为单行省略，使选中项在字段真实可用宽度内布局（`8514d78f7`）。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/video_discovery_acquisition_dialogs_test.dart:267` 在 700 px 窄宽中渲染真实资源对话框，同时覆盖来源/字幕两个下拉框，并断言无 Flutter 布局异常。
- **备注**：修复前新用例稳定复现 `A RenderFlex overflowed by 61 pixels on the right.`；修复后资源获取定向用例 5/5 通过，相关文件定向 analyze 无问题。仍需在 Windows 运行实例复测用户原始路径。
