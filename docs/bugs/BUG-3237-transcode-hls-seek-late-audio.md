## BUG-3237 · 互联转码 HLS：音轨比画面晚起的片子一 seek 就黑屏 EOF
- **报告**：2026-10-10（修 BUG-3236 时真 mpv 端到端测试发现）
- **真实性**：✅ 真 bug（与蓝光无关的通用潜伏问题）。FFmpeg hls demuxer 把第 0 段**最先吐出**的包的 DTS 记作 `first_timestamp`，seek 门槛 = `first_timestamp` + 累计 EXTINF，只放行 DTS ≥ 门槛的视频关键帧；mpegts 里音频 PES 小、总比视频 PES 先完整吐出。`packages/fushi_engine/lib/media/video/live_transcode.dart` `buildTranscodeSegmentArgs` 每段只有段首一个 IDR（`-g 600`），第 0 段音频只要比画面晚起（实测 0.6 ms 就够），门槛就越过每一段的 IDR，任何 seek（含起播恢复进度）都丢光关键帧、0 帧 EOF。对照实验：普通转码（音 0 / 画 0.0213）seek 正常；同一命令把音频推后 → seek 0 帧；源本身音轨带延迟（`-itsoffset 0.1`）→ 同样坏。蓝光标题经输入改写后音频晚起 0.6 ms，所以首先暴露。
- **[x] ① 已修复** — `92e7965113`：分段命令加 `-af aresample=first_pts=0`（aresample 文档为「音频比视频晚起」准备的选项：开头补静音到段起点），音频永不晚于段首 IDR；随包 ffmpeg-min 已编入 aresample，`tool/ffmpeg-min/smoke-test.sh` 的分段同形命令同步加上（本地对随包 ffmpeg-min 实跑 PASS）。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/live_transcode_test.dart`「音频补齐到段起点」；opt-in 原生 `fushi/test/sync/fushi_sync_server_bluray_native_test.dart` 用真 mpv 对音轨晚起的普通视频与蓝光标题的转码 HLS 做 `--start=1.5` seek（去掉该参数即 0 帧，变异实测会红）。
- **备注**：opt-in 原生测试需 `FUSHI_TEST_FFMPEG`（完整 ffmpeg）、`FUSHI_TEST_MPV`、`FUSHI_FFPROBE`，CI 不跑。
