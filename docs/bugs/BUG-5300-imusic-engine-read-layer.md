## BUG-5300 · 互联音乐库第 1 期余项：歌词本地层与封面选取搬进引擎
- **报告**：2026-11-23（拍板台 design-imusic-q0..q12 实现分期，PR 分支 `claude/imusic-impl`）
- **真实性**：✅ 真缺口（分期待办，`docs/specs/2026-11-23-interconnect-music-library-design.md` §8 第 1 期）。已做：`fushi_music` 进引擎依赖；`music_lyrics_sources.dart`（含 `preferredMusicLyricRow`、`kMusicLyricsNoneFormat`）与 `themeSongFilesOf` 搬进引擎，app 改调引擎；host 侧歌词 / 封面 / MV 解析在 `packages/fushi_engine/lib/media/music/host/engine_music_library_host.dart`。未做：app 的 `fushi/lib/src/media/music/lyrics/music_lyrics_service.dart` 仍自带 sidecar / 内嵌读取（`_readSidecars` / `_bestEmbedded`），与引擎 host 的 sidecar 读取是两份；封面选取（`cover_path` / `cover_track_uid`）app 侧还有一份。
- **[ ] ① 未修复** — 把「本地歌词层」（sidecar 选取 + 内嵌 + 生成字幕判定）抽成引擎里一个无 Flutter 依赖的类，app 的 `MusicLyricsService` 与引擎 host 共用；封面选取同理，删 app 版。
- **[ ] ② 未加自动化测试** — 歌词解析单测从 app 挪到引擎照样绿；引擎纯度守卫绿。
- **备注**：设计与拍板见 `docs/specs/2026-11-23-interconnect-music-library-design.md` §8 / §9。
