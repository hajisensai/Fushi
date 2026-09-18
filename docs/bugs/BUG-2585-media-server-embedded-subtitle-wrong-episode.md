## BUG-2585 · 媒体服务器内嵌字幕轨：连播切集后下载错集且失败静默
- **报告**：2026-09-18（用户截图：Emby 剧集《要我和你交往也不是不行》S01E02，字幕轨列表「Embedded 2: jpn / subrip（….jpn.srt）」选了不生效；问「写着 srt 又有 subrip」）
- **真实性**：✅ 真 bug（沿真实代码路径定位两处；用户现场未复测）
  - 「srt / subrip」不是矛盾：`subrip` 是服务器报的流编码名（`MediaStreams[].Codec`），`.srt` 是本仓按编码映射的下载扩展名（`JellyfinApi._subtitleExt`），标签把两者都显示了而已。
  - 根因 1：`fushi/lib/src/pages/implementations/video_fushi/subtitle.part.dart` `_applyRemoteEmbeddedSubtitle` 用 `widget.remoteInfo` / `widget.remoteClient`（**打开播放页时那一集**），合集连播切到第 2 集后再选内嵌轨，下载的是第 1 集的同号轨 → 字幕与画面对不上（副字幕的 `_applyRemoteEmbeddedSecondarySubtitle` 早已改成 `_effectiveRemoteInfo`，主字幕漏改）；也没传 `episodeIndex`。
  - 根因 2：轨行 `onTap` 是 `unawaited(_applyRemoteEmbeddedSubtitle(...))`，下载抛错（服务器 404 / 500、兼容层不支持字幕端点、断网）直接逃逸：无 OSD、无日志，用户只看到「点了没反应」。
- **[x] ① 已修复** — `4de6d78bdc0`：两处内嵌轨下载都改按当前集（`_effectiveRemoteInfo` / `_effectiveRemoteClient` + `episodeIndex`），下载失败落 `ErrorLogService` 并 OSD `video_subtitle_load_failed`。另：Emby / Jellyfin 的 PlaybackInfo DeviceProfile 明确声明文本字幕 `External`（BUG-2583），服务器不会把文本轨烧进转码流。
- **[x] ② 已加自动化测试** — 源码守卫 `fushi/test/pages/video_remote_embedded_subtitle_current_episode_guard_test.dart`：两处方法体不含 `widget.remoteInfo` / `widget.remoteClient`、必含 `_effectiveRemoteInfo` / `_effectiveRemoteClient` / `episodeIndex: ep`，且下载失败有 `ErrorLogService` + `video_subtitle_load_failed` 归宿。
- **备注**：用户若是直接打开 E02（非切集），根因 1 不触发；那时「不生效」多半是下载失败被静默（根因 2）——修后会弹 OSD 并落日志，「调试日志」页可见服务器返回码。
