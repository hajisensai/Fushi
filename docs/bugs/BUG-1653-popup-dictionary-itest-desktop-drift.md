## BUG-1653 · popup_dictionary 应用级测试在桌面端因平台与导航假设失效
- **报告**：2026-08-14（用户：要求修复后手动测试全部功能并修复发现项）
- **真实性**：✅ 真 bug。`integration_test/popup_dictionary_test.dart` 只按 Android 编写：
  无条件调用 `getExternalStorageDirectory()`；复跑时同名词典已存在却只认
  `onImportSuccess`；并假定词典永远是导航第 2 项。macOS 真 app 巡检分别在这三处失败，
  无法抵达弹窗功能验证。
- **[x] ① 已修复** — 桌面端每轮生成确定性词典、重复导入改验真实已安装状态；外部存储
  只在 Android 查询；导航按 `HomeTab.dictionaries` 的生产身份定位。测试同时扩展为真
  WebView 浮层验收：DOM 按钮存在、高度自适应、收藏/取消收藏写穿 SQLite、关闭浮层。
- **[x] ② 已加自动化测试** — 修复即落在现有 `popup_dictionary` 应用级目标中；macOS
  `flutter test integration_test/popup_dictionary_test.dart -d macos --no-pub` 已全绿。
- **备注**：macOS runner 无可抓取 CGWindow，且离屏 WKWebView 的 `window.innerHeight`
  为 0；BUG-1651 同步增加 Flutter RenderBox 高度回退，实测单词条外壳从最大 360 收到
  296。
