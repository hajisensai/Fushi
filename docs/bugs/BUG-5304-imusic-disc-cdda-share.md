## BUG-5304 · 互联音乐库：光盘标题与 CDDA 曲目共享（design-imusic-q5）
- **报告**：2026-11-23（拍板台 design-imusic-q0..q12 实现分期，PR #4271 分支 `claude/imusic-impl`）
- **真实性**：✅ 真缺口（拍板「做」）。原先光盘标题 / CDDA 曲目标 `discTitle` / `cdda`，客户端不列出。
- **[x] ① 已修复** — 新增 `packages/fushi_engine/lib/media/music/host/music_stream_materializer.dart`：光盘标题按章节起止经原盘适配器（DVD `dvdvideo` title 输入、BD `.mpls`）截成 FLAC；CDDA 在 Windows 上按盘时间轴读扇区（`audio_cd_ripper.dart` 新增 `extractAudioCdRange`）成 WAV 再编码 FLAC；同一输入并发只截一次、缓存按总量淘汰。签票回 `segmentApplied`，client 不再拼 EDL 段。只剩非 Windows host 的 CDDA 标 `cdda`（macOS 的 CD 挂成 AIFF 文件，入库即本机文件；Linux 无按扇区读盘实现）。
- **[x] ② 已加自动化测试** — `music_library_host_module_test.dart`「光盘标题：按章节起止截成 FLAC」「CDDA：Windows 光驱按盘时间轴读一段，再编码」（替身 ffmpeg / 读盘，核对参数与缓存命中）；`packages/fushi_engine/test/media/music/music_stream_materializer_test.dart`（并发去重、失败不留 .part、按总量淘汰）。
- **备注**：设计与拍板见 `docs/specs/2026-11-23-interconnect-music-library-design.md` §9。
