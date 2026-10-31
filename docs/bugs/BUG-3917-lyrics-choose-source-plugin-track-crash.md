## BUG-3917 · lyrics-choose-source-plugin-track-crash
- **报告**：2026-10-31（合并 PR #2674 后新加测试暴露，develop 既有问题）
- **真实性**：✅ 真 bug。在线音源插件曲目上点「选来源」：`MusicLyricsService.localCandidates` 只按 `isCueTrack`
  决定是否探本地 sidecar / 内嵌（`fushi/lib/src/media/music/lyrics/music_lyrics_service.dart` 的 `localCandidates`，
  修前 `if (!track.isCueTrack)`），而 `resolve` 对插件曲目另外判了 `plugin == null`。插件曲目的 `path` 是
  `fushi-plugin` URI，`_ultraStarByHeader` 里 `File(path).uri` 抛 `Invalid argument(s): Illegal character in path`，
  整个选来源面板失败。
- **[x] ① 已修复** — `MusicLyricsTrackRef.readsLocalLyrics`（CUE 虚拟曲目与插件曲目都不认本地 sidecar / 内嵌）作为唯一判据，
  `resolve` 的 ②③ 与 `localCandidates` 共用。提交：`fix(music-lyrics): choose-source on plugin tracks skips local file probing`
  （feat/batch3-lyrics-plugins）。
- **[x] ② 已加自动化测试** — `fushi/test/media/music/lyrics/music_lyrics_service_plugins_test.dart`
  「同一插件既给平台曲目自带歌词、又做歌词来源 / 选来源面板两份候选都列出，按来源区分」（在插件曲目上调 `localCandidates`，修前即抛上述异常）。
- **备注**：
