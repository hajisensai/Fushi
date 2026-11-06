## BUG-3915 · lyrics-plugin-cache-key-collision
- **报告**：2026-10-31（用户：合并第三方 PR #2674 前的审查发现）
- **真实性**：✅ 真 bug。PR #2674 的歌词插件来源（⑤）把搜到的结果落在 `MusicLyricsSource.plugin(id)`
  （`fushi/lib/src/media/music/lyrics/music_lyrics_service.dart:575`，PR 版本），与平台曲目自带歌词（③'，同文件 `:410`）
  同一个键 `provider:plugin:<id>`。同一插件同时声明 `lyrics` 与 `lyricsSearch`/`lyricsFetch` 时：③' 没歌词写的负缓存
  被 ⑤ 的模糊结果覆盖，之后 ③' 把这份模糊结果当平台自带歌词直接命中、永不再问平台；反过来 ⑤ 的负缓存会在一天内
  挡住 ③'。spec §3 当时断言「不冲突」是错的。
- **[x] ① 已修复** — 歌词插件来源改用独立键 `provider:lyrics:<id>`（`MusicLyricsSource.lyricsPlugin` /
  `isLyricsPlugin` / `lyricsPluginIdOf`，`music_lyrics_sources.dart`）；选来源面板两份候选都列，标题用
  `musicLyricsCandidateTitle` 标出是「歌词」还是「歌词来源」（`music_plugin_settings.dart`）；spec §3 改正。
  提交：`fix(music-lyrics): separate lyrics-plugin cache key and store raw plugin tracks`（feat/batch3-lyrics-plugins）。
- **[x] ② 已加自动化测试** — `fushi/test/media/music/lyrics/music_lyrics_service_plugins_test.dart`
  「同一插件既给平台曲目自带歌词、又做歌词来源」组（两条路径各记各的缓存 / 选来源面板两份候选）；
  `fushi/test/pages/music/music_lyrics_providers_test.dart`「选来源候选标题区分平台自带歌词与歌词插件」。
- **备注**：PR 未发布过，`provider:plugin:<id>` 下不存在 ⑤ 写的旧行，无需迁移。
