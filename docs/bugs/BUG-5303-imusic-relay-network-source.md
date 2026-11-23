## BUG-5303 · 互联音乐库：host 网络来源曲目经 host 中继（design-imusic-q4）
- **报告**：2026-11-23（拍板台 design-imusic-q0..q12 实现分期，PR 分支 `claude/imusic-impl`）
- **真实性**：✅ 真缺口（拍板「做」，未实现）。`engine_music_library_host.dart` 的 `musicHostUnplayableReason` 把 SFTP / WebDAV / AList 来源的曲目标 `networkSource`，客户端 `InterconnectMusicBrowser._tracks` 过滤不列出。
- **[ ] ① 未修复** — host 签 `musicTrack` 票时对网络来源曲目走 SFTP 回环中继那套（host 持凭据代读、Range 透传），`trackFile` 之外加一个流式 resolver；客户端去掉过滤。
- **[ ] ② 未加自动化测试** — 引擎路由测试：网络来源曲目 Range 中继；客户端列出并可播。
- **备注**：设计与拍板见 `docs/specs/2026-11-23-interconnect-music-library-design.md` §8 / §9。
