## BUG-151 · 悬浮字幕首次开启先显示默认底色
- **报告**：2026-06-09（用户：「字幕第一次开启有底色，再次关闭开启底色才会消失。这个貌似稳定触发。应该吃主题色啊」。）
- **真实性**：✅ 真 bug。`ReaderHibikiPage` 旧流程先调用 `FloatingLyricChannel.show()` 启动 Android service，service 在 `FloatingLyricService.onCreate()` / `createContentView()` 中用默认 `FloatingColors.LYRIC_BACKGROUND` 创建 view；Dart 随后才调用 `updateStyle()`，所以首次开启会先闪默认底色，第二次因 service/prefs 状态已热才不明显。
- **[x] ① 已修复** — `FloatingLyricChannel.show()` 支持携带字体、文字色、背景色、按钮色、高亮色、锁定和点击查词状态；`MainActivity` 在 `startService()` 前把这些参数写入 `floating_lyric_prefs`；`FloatingLyricService.onCreate()` 在 `super.onCreate()` 前读取初始状态，确保第一帧就使用 reader 主题色。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/floating_lyric_lock_icon_static_test.dart` 覆盖 native service 在 `super.onCreate()` 前 `readInitialState()`；`hibiki/test/media/audiobook/floating_lyric_channel_test.dart` 覆盖 show 参数完整下发。
- **备注**：已通过源码守卫和 Android 编译验证；首次开启 overlay 的真实视觉闪烁仍需 Android 设备肉眼复测。
