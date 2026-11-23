## BUG-5305 · 互联音乐库：客户端设码率上限时 host 转码（design-imusic-q6）
- **报告**：2026-11-23（拍板台 design-imusic-q0..q12 实现分期，PR 分支 `claude/imusic-impl`）
- **真实性**：✅ 真缺口（拍板「做」，未实现）。host 原样直出（`InterconnectMusicBrowser.streamFor` 恒 `transcoded: false`），客户端的「服务器码率上限」设置对互联 host 不生效。
- **[ ] ① 未修复** — `streamurl` 的 `musicTrack` 签发带可选码率档（照视频流票 `_VideoStreamOptions`），host 复用视频转码管线出音频 profile（opus / aac）；客户端把 `musicServerMaxBitrate` 传进签票；信号路径面板按 `transcoded` 显示。
- **[ ] ② 未加自动化测试** — 引擎测试：带码率档签票走转码；客户端测试：码率上限透传。
- **备注**：设计与拍板见 `docs/specs/2026-11-23-interconnect-music-library-design.md` §8 / §9。
