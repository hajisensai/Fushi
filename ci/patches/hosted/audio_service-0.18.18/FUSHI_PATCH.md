# Fushi：系统媒体按键 PLAY / PAUSE 保留方向（BUG-3777）

audio_service 0.18.18 的 Android 原生层 `AudioService.java` 里，`MediaSessionCallback.onMediaButtonEvent`
把真实的 `KEYCODE_MEDIA_PLAY` / `KEYCODE_MEDIA_PAUSE` 与 `KEYCODE_MEDIA_PLAY_PAUSE` / `KEYCODE_HEADSETHOOK`
一起交给 `listener.onClick(eventToButton(event))`；`eventToButton` 对 PLAY / PAUSE 落 `default` 返回
`MediaButton.media`。方向在原生层就丢了，Dart 侧只收到一次「单击」，`FushiAudioHandler.click` 只能按切换处理：

- 蓝牙耳机 / 车机重连时补发的 PLAY（AVRCP passthrough），在**播放中**到达就把声音暂停；
- 暂停中收到 PAUSE 反而开始播放。

改法：`KEYCODE_MEDIA_PLAY` → `onPlay()`、`KEYCODE_MEDIA_PAUSE` → `onPause()`（与通知栏按钮走的
`KEYCODE_BYPASS_PLAY` / `KEYCODE_BYPASS_PAUSE` 同一条路，最终到 Dart 的 `AudioHandler.play()` / `pause()`，
即 `MediaPlayIntent.play` / `.pause`，会话只在状态不一致时才切换）。只有 PLAY_PAUSE / HEADSETHOOK
仍是单击（切换）；BYPASS 键码、STOP / FF / REWIND / NEXT / PREVIOUS 不变。

整份 `AudioService.java` 覆盖进 pub cache（`ci/apply-patches.sh`），基于 0.18.18 原件只改了
`onMediaButtonEvent` 的 switch。守卫：`fushi/test/build/audio_service_media_button_patch_guard_test.dart`
（目录版本必须等于根 `pubspec.lock` 里解析到的版本，否则补丁被 apply-patches 静默跳过）。

**已知交互**：PLAY / PAUSE 有了方向后，正确性依赖媒体会话里的播放态。关掉「显示媒体通知」时 Fushi
不向 audio_service 推播放态（见 BUG-3777 的 A，待所有者拍板），只按 AVRCP 播放态决定发 PLAY 还是 PAUSE
的耳机会一直发 PLAY——这种组合下耳机暂停不再生效（修复前是切换）。

**删除条件**：上游 audio_service 把 PLAY / PAUSE 键码映射到 `onPlay` / `onPause`，或本仓升级 audio_service
版本时——升级必须把本补丁移植到新版本目录（守卫会因版本不符变红）。
