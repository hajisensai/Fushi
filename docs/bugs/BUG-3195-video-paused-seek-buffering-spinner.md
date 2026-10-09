## BUG-3195 · 暂停状态下拖进度条后加载圈和 0 B/s 一直挂着
- **报告**：2026-10-08 18:05（用户：哈吉千歳）
- **真实性**：✅ 真 bug。播放器中途缓冲圈由 media_kit 的 `player.state.buffering` 驱动（`fushi/lib/src/pages/implementations/video_fushi/controls_theme.part.dart` 的 `bufferingIndicatorBuilder`）。media_kit 1.2.6（`lib/src/player/native/player/real.dart` 的 `core-idle` 分支）把 mpv `core-idle` 直接当缓冲：暂停时 `core-idle` 恒为真，只有 `pause()` 调用那一下临时屏蔽。暂停状态下 seek 让 `core-idle` 落下再升起，升起时被记成「缓冲中」，暂停期间不会再落下，于是加载圈和网络读取速度行（「0 B/s」）一直挂到按播放。
- **[x] ① 已修复** — 本 PR：`VideoPlayerController.bufferingIndicatorVisible`（订阅 `buffering` 与 `playing` 两路流）只在「正在播放且缓冲中」时为真；`VideoBufferingIndicator` 按它显隐，两套控制条主题都接上。暂停时画面不需要数据，seek 帧出完就是静止画面；继续播放后真缺数据，`core-idle` / `paused-for-cache` 照常点亮。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_paused_seek_buffering_indicator_test.dart`（判据纯函数、组件按判据显隐、两套主题接线）。
- **备注**：media_kit 无法离屏跑真 libmpv，真机暂停 → 拖进度条复测待补。没有改 vendored media_kit（core 不在 third_party）。
