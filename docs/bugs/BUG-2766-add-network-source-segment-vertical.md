## BUG-2766 · 移动端添加网络来源的协议分段控制器文字竖排
- **报告**：2026-09-29（用户：移动端「添加来源」的分段控制器显示有问题，字都变成竖排）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/media_sources_view.dart` 的 `_NetworkSourceFormDialogState.build` 用了裸 `SegmentedButton`（SFTP / FTP / WebDAV / AList）。手机上 AlertDialog 内容区只有约 230dp，Material 把每段宽度钳到「可用宽 / 段数」，标签放不下就逐字断行；360dp 下实测「SFTP」文本框 4×80（竖排）。BUG-1184 已为此提供共享的 `FushiSegmentedStrip`，这个对话框漏用。
- **[x] ① 已修复** — 改用 `FushiSegmentedStrip`（段宽不小于最宽标签，装不下横向滚动）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/media_source_network_transport_strip_test.dart`：360dp 手机宽度下经 `addSource()` → Network 打开表单，断言 4 个协议标签宽大于高；旧代码下实测红（width 4 < height 80）。
- **备注**：
