## BUG-565 · iOS 有声书播放没声音
- **报告**：2026-07-06（用户：wight）
- **真实性**：✅ 真 bug。根因：`packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart:905` 的有声书 `_configureAudioSession()` 只设置了 Android audio attributes，未给 iOS 设置 `AVAudioSessionCategory.playback`；`audio_session` 在 iOS category 为空时 native fallback 到 `AVAudioSessionCategorySoloAmbient`（`audio_session-0.1.25/ios/.../DarwinAudioSession.m:118`），会受系统静音开关影响，表现为播放器状态正常但无声。
- **[x] ① 已修复** — `packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart:909` 显式设置 iOS `AVAudioSessionCategory.playback` + `AVAudioSessionMode.spokenAudio`，保留 Android media 配置。
- **[x] ② 已加自动化测试** — `hibiki/test/media/audiobook/audiobook_ios_audio_session_guard_test.dart:6` 源码守卫有声书主播放器必须配置 iOS playback category / spokenAudio mode。
- **备注**：已构建并安装到 iOS 27 真机，安装后设备 CoreDevice 状态变为 unavailable，控制台连接断开；需用户解锁/恢复连接后补做肉耳复测确认。
