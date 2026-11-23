## BUG-5302 · 互联音乐库：客户端歌词页 / 卡拉 OK 页放 host 的 MV（依赖 #4249）
- **报告**：2026-11-23（拍板台 design-imusic-q0..q12 实现分期，PR 分支 `claude/imusic-impl`）
- **真实性**：✅ 真缺口（分期待办）。host 侧已下发 MV 绑定（`GET /api/library/music/tracks/<uid>/videos`，含 YouTube 绑定的 `youtubeRef`，design-imusic-q7「做」）并能签 `musicVideo` 流票；客户端 `fushi/lib/src/media/music/server/interconnect_music_client.dart` 已实现 `MusicServerVideoSource`（`videosFor` / `openVideo` / `setVideoOffset` 写回）。但歌词页 MV 背景控制器 `MusicMvBackdropController` 与自动匹配都在**未合并**的 PR #4249，develop 上没有消费端，所以客户端还看不到 host 的 MV。
- **[ ] ① 未修复** — #4249 合入后：MV 解析器重构成「本机解析器 + 远端解析器（`MusicServerVideoSource`）」两实现；远端曲目的歌词页 / 卡拉 OK 页背景走 `openVideo` 租约（用完 release）；YouTube 绑定交客户端自己的 YouTube 音源（受 `onlineMusicSource` 门）；曲目本身是 MV 视频时接受两条连接（design-imusic-q8 我定 a：与本机实现一致，不改播放器结构）；MV ±100ms 微调调 `setVideoOffset` 写回 host。
- **[ ] ② 未加自动化测试** — 客户端假 host 测试 + 两台真机：远端曲目歌词页 MV 背景对齐（蓝光 m2ts 一例）。
- **备注**：设计与拍板见 `docs/specs/2026-11-23-interconnect-music-library-design.md` §8 / §9。
