## BUG-1534 · 下载任务详情长路径溢出
- **报告**：2026-08-11（用户：）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/torrent_detail_dialog.dart` 的统计行只让标签列扩展，右侧值使用不可收缩的普通 `Text`；Windows 长路径会反向压缩标签并从对话框右侧溢出。
- **[x] ① 已修复** — 标签和值改为 1:2 的弹性列，值允许换行并右对齐，长保存路径和内容路径保持在对话框内。
- **[x] ② 已加自动化测试** — `fushi/test/pages/torrent_detail_dialog_test.dart` 使用超长 Windows 路径覆盖离线详情布局且断言无渲染异常。
- **备注**：按用户要求跳过自动化测试，使用 Windows Debug 构建直接实测。
