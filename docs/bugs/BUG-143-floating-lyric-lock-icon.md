## BUG-143 · 浮动歌词锁定态显示开锁图标
- **报告**：2026-06-08（用户截图：浮动歌词条的锁按钮显示开锁图标，但实际处于锁定状态，首次使用时容易反直觉。）
- **真实性**：✅ 真 bug。Android 浮动歌词原生浮层由 `hibiki/android/app/src/main/java/app/hibiki/reader/FloatingLyricService.java:103` 初始化锁按钮，并由 `:371` 的 `applyLockButton()` 根据 `isLocked` 切换图标；旧代码在未锁定初始态显示闭锁图标，并在 `isLocked == true` 时显示 `ic_floating_lock_open`，视觉图标表达的是点击后的动作而不是当前锁定状态。
- **[x] ① 已修复** — `FloatingLyricService` 改为未锁定显示 `ic_floating_lock_open`、锁定显示 `ic_floating_lock`；`contentDescription` 继续保留为点击动作（锁定态为“解锁”），锁定态高亮颜色不变。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/floating_lyric_lock_icon_static_test.dart` 增加源码守卫，锁住初始图标、锁定/未锁定映射、无障碍动作标签和锁定高亮。
- **备注**：这是 Android 原生 overlay 的视觉语义修复；已做源码守卫和 Android debug 编译验证，未在真机 overlay 上做肉眼复测。
