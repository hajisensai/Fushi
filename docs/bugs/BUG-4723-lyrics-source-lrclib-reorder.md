## BUG-4723 · 歌词来源列表 LRCLIB 固定排第一，不能和插件一起排序
- **报告**：2026-11-16（维护者待办，应用内反馈 h7d6Pa_g-7：音乐「来源 › 歌词」里 LRCLIB 带锁图标、副标「内置，始终第一」）
- **真实性**：✅ 维护者明确要求（原设计 `docs/specs/2026-10-30-lyrics-plugins.md` 定的「LRCLIB 固定第一」，现改判为可排序）。
  固定第一在结构里：偏好 `music_lyrics_providers` 只存插件（`fushi/lib/src/media/music/lyrics/lyrics_provider_list.dart:3`、`:97`），
  解析链先单独查 LRCLIB 再查插件、兜底也是 LRCLIB 优先（`fushi/lib/src/media/music/lyrics/music_lyrics_service.dart:639-673`），
  设置页单独画一行带锁的 LRCLIB（`fushi/lib/src/pages/implementations/music/music_lyrics_providers.dart:105-114`）。
- **[x] ① 已修复**（0b47cc01eb）— LRCLIB 以 id `provider:lrclib` 作为普通一项进入同一份有序来源列表（`mergeLyricsSourceList`：旧偏好没有它时补在最前并启用，存量顺序不变）；
  `MusicLyricsService.resolve` 按这份列表逐个问（插件解析拆成单个来源的 `_resolvePluginProvider`），书写系统兜底也按列表顺序；设置页 LRCLIB 与插件同一可排序、可启停列表。
- **[x] ② 已加自动化测试** — `fushi/test/media/music/lyrics/music_lyrics_service_plugins_test.dart`（插件排在 LRCLIB 前先问插件、停用 LRCLIB 不问）、
  `music_lyrics_script_selection_test.dart`（兜底按来源顺序）、`lyrics_provider_list_test.dart`（旧偏好补 LRCLIB 最前）、`fushi/test/pages/music/music_lyrics_providers_test.dart`（LRCLIB 下移 / 停用写偏好）。
- **备注**：曲库全文搜索选行的纯判据 `preferredMusicLyricRow`（`MusicLyricsSource.automaticRank`）不读偏好，LRCLIB 与歌词插件缓存行之间仍按默认顺序（LRCLIB 在前）近似，
  与改动前插件之间不按用户顺序的近似同性质；用户把插件排到 LRCLIB 前且两边都有缓存时，搜索索引可能收录 LRCLIB 那份。未在本条修。
