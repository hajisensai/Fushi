## BUG-1953 · Torrent 详情缺少实时数据时空态布局失衡
- **报告**：2026-08-26（用户：Torrent 详情 Tracker 页显示问题截图）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/torrent_detail_dialog.dart` 的 `_buildEmptyNote` 仅在占满剩余高度的 `TabBarView` 中居中绘制裸文本，导致缺少实时数据时出现大面积无层级空白。
- **[x] ① 已修复** — `_buildEmptyNote` 改用统一 `FushiPlaceholderMessage`，补齐图标、分组底色与 480px 最大内容宽度；提交哈希在本提交落地后回填。
- **[x] ② 已加自动化测试** — `fushi/test/pages/torrent_detail_dialog_test.dart` 验证缺失实时数据分支渲染统一空态卡、信息图标且宽度不超过 480px。
- **备注**：代码与 widget 测试通过后仍需在 Windows 对原截图路径肉眼复测。
