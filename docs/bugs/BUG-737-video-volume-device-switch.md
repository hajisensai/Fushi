## BUG-737 · 反复切换音频输出设备后视频音量逐步变小甚至静音
- **报告**：2026-07-11（用户：反复切换音频设备后 hibiki 视频音量会变小，有时直接没声；仅视频音量，查词音频正常）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/media/video/video_player_controller.dart:781`（`volume` getter 直接信任 libmpv `state.volume`）+ 全仓库缺音频设备切换监听（app 从不在设备切换后回补音量目标）。
- **[x] ① 已修复** — `video_player_controller.dart`：首次建 `Player` 时订阅 media_kit `stream.audioDevice`，设备切换后重新下发音量目标 `_muted ? 0.0 : _lastVolume`；`dispose` 取消订阅。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_volume_device_switch_guard_test.dart`（源码扫描：订阅存在 + 回补 `_lastVolume`/尊重静音 + dispose 取消 + 根因注释 + 查词对照）。
- **备注**：

  **现象**：反复切换系统音频输出设备后，视频播放器的音量逐步变小，多次切换后甚至完全静音。查词弹窗读音的音量正常（明显比视频大，用户正是由此察觉）。

  **根因**（沿真实代码路径确证，非臆测）：
  - 视频走 media_kit **裸 `Player()`**（`audio-device=auto`），不经 just_audio。音量只在两处下发给 libmpv：`video_player_controller.dart:1436-1439`（`load()`，取自 prefs）和用户手动调音量（`setVolume`/`adjustVolume`/`toggleMute`）。
  - 之后 `volume` getter（`:781` `_player?.state.volume ?? _lastVolume`）**直接把 libmpv 的 `state.volume` 当真值**，app 从不回补目标音量。
  - 全仓库 grep `setAudioDevice`/`audioDevice`/`onDeviceChanged` **零命中**——切换输出设备完全由 libmpv 内部处理：它重建 ao，软件 `volume` 属性被重置/衰减，media_kit（`media_kit-1.2.6/.../real.dart:1619-1624` 被动观察 `volume` 属性）把降低值镜像进 `state.volume`。**反复切换即逐步衰减直至归零**。
  - 已排除 app 层累积衰减：`_lastVolume` 只在 load（prefs）/用户操作时写，无 `stream.volume` 回写反馈环，reload 也从 prefs 取值不读回衰减值。故衰减纯在 libmpv 层，app 的缺陷是**从不回补**。

  **为何查词音频免疫**：`hibiki/lib/src/utils/misc/desktop_audio_playback.dart:123` 每个 clip 播放前都 `setVolume(volume.clamp(...))` 重设**绝对**音量，天然把 libmpv 漂移抹平 → 永远正常。

  **修复**：`VideoPlayerController` 首次建 `Player` 时订阅 `player.stream.audioDevice`（media_kit 内部 `distinct` 去重），设备变化时把音量目标 `_muted ? 0.0 : _lastVolume` 重新 `setVolume` 给 libmpv——恢复「libmpv 音量 == app 目标」不变量，与查词路径每次重设绝对音量同构。订阅随 `Player` 生命周期挂一次（换集复用不重挂，避免叠加）、`dispose` 取消。这是根因修复（补上缺失的平台边界回补契约），非延迟/重试/吞异常绕过。

  **待真机**：需在桌面真机（Windows/macOS）播放视频时反复切换系统音频输出设备，复测音量保持不衰减、且不误解除用户静音。自动化测试只能守住「订阅存在且回补目标音量」的静态不变量；真实 libmpv ao 重建时序与音量表现需人工目测确认。
