## BUG-5303 · 互联音乐库：host 网络来源曲目经 host 中继（design-imusic-q4）
- **报告**：2026-11-23（拍板台 design-imusic-q0..q12 实现分期，PR #4271 分支 `claude/imusic-impl`）
- **真实性**：✅ 真缺口（拍板「做」）。原先 `engine_music_library_host.dart` 把 SFTP / WebDAV / AList 来源的曲目标 `networkSource`，客户端不列出。
- **[x] ① 已修复** — 统一流票的解析器从「id → 文件」改成「请求 → 字节来源」（`packages/fushi_engine/lib/sync/library_media_streams.dart` 的 `LibraryMediaSource`：`LibraryMediaFile` / `LibraryMediaUpstream`）；`EngineMusicLibraryHost.trackSource` 对网络来源曲目调 app 注入的 `MusicHostNetworkSource`（与本机播放同一个 `SourceMusicRemoteMediaResolver`），`packages/fushi_engine/lib/sync/library_media_relay.dart` 用 host 的来源凭据代读上游、Range 原样透传，凭据不出 host。只有没装解析器的无头服务端仍标 `networkSource`。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/sync/music_library_host_module_test.dart`「网络来源：host 带自己的凭据代读，Range 透传，client 不见上游凭据」（真上游 HttpServer，206 字节逐一核对、上游收到 host 的 Authorization）。
- **备注**：设计与拍板见 `docs/specs/2026-11-23-interconnect-music-library-design.md` §9。
