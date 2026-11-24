## BUG-5245 · 暂停时切换「模糊 NSFW 封面」，锁屏 / 媒体卡不更新，仍显示原图
- **报告**：2026-11-22（2026-11-22 项目审查 HBK-AUDIT-217，PR #4140）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/music/music_session.dart:615`（修前）只在发布媒体卡时同步读一次 `blurNsfwCovers()`，开关变化没有任何路径触发重发；播放时靠进度 tick 顺带刷新，暂停时没有 tick，打开开关后锁屏 / 通知继续挂着之前发布的 NSFW 专辑原图（关掉开关也补不回图）。
- **[x] ① 已修复** — `MusicSession.blurNsfwCovers` 改为 `ValueListenable<bool>`，构造时订阅、值变化即 `_publishMediaSession`，`dispose` 退订；`AppModel` 传 `DerivedValueListenable<bool>(this, …)`：从 AppModel 自身派生（它转发当前偏好仓库的变化，换档案换仓库也跟得上），只在开关值真的变了时通知。设置页、设置同步、控制通道改这个偏好都走同一条路。
- **[x] ② 已加自动化测试** — `fushi/test/media/music/music_session_nsfw_blur_test.dart`（真 `MusicSession` + `FushiAudioHandler`：暂停后打开开关，断言 `artUri` 立即变 null，关掉后补回）。
- **备注**：锁屏卡实际显示需真机复测（Android 通知 / iOS 锁屏），本轮未做设备复测。
