## BUG-2247 · 有声书切换设置标签沿用章节滚动位置
- **报告**：2026-09-07（用户截图反馈）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/reader/reader_audiobook_panel.dart:164`：切换标签仅更换滚动内容子树，SingleChildScrollView 状态复用，章节滚动偏移被带入设置。
- **[x] ① 已修复** — 滚动容器按标签 key 重建，primary=false 防止借用外层滚动控制器。提交见本文件 Git 历史。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_audiobook_panel_test.dart`：切换前滚动章节，切换后断言设置 ScrollPosition 为 0 且首项可见。定向测试通过。
- **备注**：共享 Flutter 组件覆盖各平台；尚未完成用户原书和手机设备复测。
