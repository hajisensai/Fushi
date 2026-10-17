## BUG-3389 · 阅读器快捷设置改悬浮字幕字号会清空圆角与窗宽
- **报告**：2026-10-14（用户：反馈悬浮字幕自定义少、样式丑，改造时沿代码路径发现）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/reader_fushi/chrome.part.dart` 的 `onFloatingLyricFontSizeChanged` 手拼一次 `FloatingLyricChannel.updateStyle(...)`，只带字号与几种颜色，漏了 `cornerRadius` / `windowWidth`；Dart 侧这两个参数默认 0，原生 `StyleFromArgs` 照单全收，于是在快捷设置里改一次字号，圆角变直角、用户设的窗宽丢失。
- **[x] ① 已修复** — 改为 `appModel.audiobookSession.applyFloatingLyricStyle()`，与设置页同一条整份重推链路（悬浮字幕 M3E 改造同一提交）。
- **[x] ② 已加自动化测试** — `fushi/test/reader/floating_lyric_quick_font_size_style_guard_test.dart`。
- **备注**：—
