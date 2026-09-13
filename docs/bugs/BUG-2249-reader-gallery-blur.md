## BUG-2249 · 插图画廊未同步正文图片模糊设置
- **报告**：2026-09-07（用户截图反馈）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/reader_fushi/chrome.part.dart:966`：独立画廊未接收正文的 blurImages 及已揭开图片集合，大图和缩略图均直接显示原图。
- **[x] ① 已修复** — 画廊接入模糊和揭开状态，首次点击或 Enter 揭开，同步当前正文及 Drift 持久化。提交见本文件 Git 历史。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_gallery_page_test.dart`：大图和缩略图遮罩、已有揭开状态、首次揭开及再次查看均有 widget 测试。定向测试通过。
- **备注**：共享 Flutter 组件覆盖各平台；尚未完成用户原书和手机设备复测。
