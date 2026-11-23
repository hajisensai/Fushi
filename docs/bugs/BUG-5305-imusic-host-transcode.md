## BUG-5305 · 互联音乐库：客户端设码率上限时 host 转码（design-imusic-q6）
- **报告**：2026-11-23（拍板台 design-imusic-q0..q12 实现分期，PR #4271 分支 `claude/imusic-impl`）
- **真实性**：✅ 真缺口（拍板「做」）。原先 host 恒原样直出，客户端「服务器码率上限」对互联 host 不生效。
- **[x] ① 已修复** — `streamurl` 的 `options.maxBitrateKbps`（`kMusicStreamOptionMaxBitrate`）记在票上；host 在源码率高于上限时用 `MusicStreamMaterializer` 转成 AAC（`.m4a` faststart，可 seek，CUE 段一并截好），签票回 `transcoded` / `codec` / `bitrateKbps`。客户端 `InterconnectMusicHosts` 读与服务器曲库同一个 `musicServerMaxBitrate` 设置。没有沿用视频的 HLS 分段转码（docs/specs/2026-09-21-interconnect-video-transcode.md）：音乐整首转码只要几秒，转成整文件后可 Range seek、可缓存，比分段 playlist 简单可靠，且移动端 host 的进程内 ffmpeg-kit 也能跑（分段要接管 stdout 管道，移动端不行）。
- **[x] ② 已加自动化测试** — `music_library_host_module_test.dart`「码率上限：高于上限的转 AAC；网络来源也经 ffmpeg 读上游（带头部）」；`fushi/test/media/music/server/interconnect_music_client_test.dart`「码率上限随签票带给 host」。
- **备注**：设计与拍板见 `docs/specs/2026-11-23-interconnect-music-library-design.md` §9。
