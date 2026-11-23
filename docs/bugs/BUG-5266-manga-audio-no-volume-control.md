## BUG-5266 · manga-audio-no-volume-control
- **报告**：2026-11-22（应用内反馈 SDfRadAtkL，Windows，3.4.0-debug.31261：「缺少调整音量」）
- **真实性**：✅ 真 bug（根因 `fushi/lib/src/media/manga/audio/manga_audio_playback_driver.dart` `MangaAudioPlayerPort` 只暴露 play / pause / seek / speed，`manga_audio_session.dart` `_ControllerPort` 没转接 `AudiobookPlayerController.volume/setVolume`；`fushi/lib/src/media/manga/reader/manga_read_aloud_bar.dart` 成品条只有上一句 / 播放 / 下一句 / 跟随翻页 / 倍速 / 停止）
- **[x] ① 已修复** — 端口 + 会话适配 + 驱动转接音量；成品音频播放条加音量按钮，弹出与有声书快捷设置同一口径的音量条
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/reader/manga_read_aloud_bar_test.dart`「成品音频播放条的音量按钮弹出有声书同口径音量条」（MD3 / Apple 各一遍）；`fushi/test/media/manga/audio/manga_audio_playback_test.dart`「音量：驱动转接播放器音量并通知播放条」
- **备注**：现场合成朗读（`MangaReadAloudBar`，走 `DesktopAudioPlayback.playFileToEnd`）没有音量口径与偏好，未加音量按钮；要加需新立全局朗读音量偏好，属范围扩大，未做。

### 根因

漫画有声成品与有声书共用 `AudiobookSession` / `AudiobookPlayerController`，控制器早有
`setVolume`（0–2 clamp）且会话已把 `onVolumePersist` 接到 `repo.updateVolume`、起播时读
`repo.readVolume` 恢复按书音量；但漫画这边的播放器端口没有音量，播放条也无入口，用户
无处可调。

### 修复

- `MangaAudioPlayerPort` 增 `volume` / `setVolume`，`_ControllerPort` 转接
  `AudiobookPlayerController.volume` / `setVolume`（沿用其 clamp 与按书持久化）；驱动暴露
  `volume` / `setVolume` 并通知。
- 音量条口径（0–200%、拖动 1% 一档、按键 5%、读数格式）抽成
  `fushi/lib/src/media/audiobook/audiobook_volume_slider.dart` 的 `AudiobookVolumeSlider`，
  有声书快捷设置的 `AudiobookVolumeRow` 的常量与读数改引用它，两处同一口径。
- 播放条：倍速弹层抽成通用 `_PopoverButton`（加淡入 + 轻微放大的出现动效，走
  `fushiMotionDuration` / `FushiMotion`），成品条在倍速与停止之间加音量按钮（静音时
  画静音图标，tooltip / Semantics 带「音量 xx%」），弹层里是图标 + `AudiobookVolumeSlider`
  + 百分比读数，画在 `MangaChromeSurface` 上（MD3 / Apple 两套材质）。
