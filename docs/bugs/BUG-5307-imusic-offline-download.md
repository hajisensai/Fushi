## BUG-5307 · 互联音乐库：把 host 曲目下载到本机离线听（design-imusic-q12）
- **报告**：2026-11-23（拍板台 design-imusic-q0..q12 实现分期，PR 分支 `claude/imusic-impl`）
- **真实性**：✅ 真缺口（拍板「做」，未实现）。客户端只能串流 host 曲目。
- **[ ] ① 未修复** — 下载用 `musicTrack` 流票拉整文件到本机某个音乐来源；下载后的本机曲目 uid 按新路径会变（`native/fushi_music/src/uid.rs` 哈希含路径），用 `music_track_uid_aliases` 把新 uid 映射到 host uid（design-imusic-q1 选 a 的同键），歌词 / MV 绑定随之复制。
- **[ ] ② 未加自动化测试** — 下载 + 别名映射单测；离线播放与歌词跟随。
- **备注**：设计与拍板见 `docs/specs/2026-11-23-interconnect-music-library-design.md` §8 / §9。
