## BUG-2250 · 阅读器主题卡遗漏日间跟随系统夜间选择器
- **报告**：2026-09-07（用户：阅读器内主题下面的日间夜间多段选择器不见了）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/audiobook/reader_quick_settings_sheet.dart:732` 的 `_buildThemeSelectorSection` 只装配 `buildThemeSelector`，而明暗切换是独立的 `buildBrightnessSelector`；全局外观设置仍装配两者，阅读器的普通/歌词布局页却遗漏后者。
- **[x] ① 已修复** — 在共享主题卡中接回原有明暗选择器，沿 `_themeSettingsContext` 同步偏好、正文样式和主题回调。提交见本文件 Git 历史。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/audiobook_play_bar_theme_chip_test.dart`：普通/歌词模式的320宽侧栏显示、点击三档、ThemeNotifier与Drift真值、reader live/style/theme回调；单文件10条通过。`fushi/integration_test/desktop_reader_chrome_shortcuts_itest.dart`：真实Windows窄窗口使用焦点方向键切light/dark/system，1条通过。
- **备注**：Windows 真实阅读器窄窗口焦点切换与截图已验证，图标完整显示在主题下方；Android/iOS 真机待补。
