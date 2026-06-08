## BUG-144 · 悬浮字幕锁定位置误锁播放控制
- **报告**：2026-06-09（用户：「把字幕的移动锁定和点击查词的开关分开吗，适配不想不小心移动字幕但是想保持能查词/调进度的场景」。）
- **真实性**：✅ 真 bug。Android 悬浮字幕的锁定态由 `FloatingLyricService.isDragLocked()` 暴露给 `BaseFloatingService.setupDragListener()`，旧实现一进触摸回调就 `if (isDragLocked()) return true;`，会把整块 overlay 的点击事件吃掉；同时 `FloatingLyricService.onControlClick()` 在锁定时拦截除锁按钮外的播放控制，导致“锁位置”实际变成“锁全部交互”。
- **[x] ① 已修复** — `BaseFloatingService` 只在移动阶段禁止更新/保存位置，普通 tap 仍进入 `onOverlayTapped()`；`FloatingLyricService` 去掉锁定态对上一句/播放/下一句/关闭按钮的拦截，并新增独立 `clickLookupEnabled` 开关。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/floating_lyric_lock_icon_static_test.dart` 覆盖“位置锁只禁用拖动，不禁用 tap 查词和控制按钮”；`hibiki/test/media/audiobook/floating_lyric_channel_test.dart` 覆盖 Dart channel 下发点击查词开关；`hibiki/test/models/preferences_repository_test.dart` 覆盖偏好持久化。
- **备注**：已通过源码守卫和 Android 编译验证；真实悬浮窗手势仍需 Android 设备肉眼复测。
