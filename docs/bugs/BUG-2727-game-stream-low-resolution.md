## BUG-2727 · 串流码率卡在 2.5 Mbps、分辨率被压到 720p 以下
- **报告**：2026-09-26（用户：「很卡……帧率跑不满」）
- **真实性**：✅ 真 bug，两段根因，均用串流 trace（`FUSHI_GAME_STREAM_CAPTURE_TRACE`）在真机取证。
  1. flutter_webrtc Windows 的 `FlutterPeerConnection::updateRtpParameters`（`common/cpp/src/flutter_peerconnection.cc`）改的是 `parameters->encodings()` 返回的包装副本，从不 `set_encodings()` 写回，主机设的 maxBitrate/minBitrate/maxFramerate/scaleResolutionDownBy 全部被静默丢弃：编码器停在 libwebrtc 按分辨率的默认上限（>960x540 为 2.5 Mbps），`qualityLimitationReason=bandwidth`，而带宽估计是 75 Mbps。补上写回后又因为 getter 把未设置字段报成 0 / ""、Dart 整张表回传，空 `scalabilityMode` 让整个 `setParameters` 被拒（主机报「Video encoding limits were rejected」，串流起不来）。
  2. 默认降级策略 `balanced` 下，libwebrtc 对 QP 不可信的编码器（主机的 OpenH264）按**实际输出码率**缩放分辨率；VN 画面编码只有几百 kbps，于是 4K/1080p 捕获从第一帧起就被压到 1280x720 / 960x540。对照：同一会话 VP8+balanced 升到满尺寸 1920x1080，H.264+maintain-resolution 第一帧起就是 1920x1080、`limit=none`。
- **[x] ① 已修复** — `665cf267c42` 写回编码参数、`c41129f45fb` 只应用已设置的值（正数、缩放 ≥1、非空模式，int32/int64/double 通吃）；`568cdcdac2a` 串流默认降级改为 maintain-resolution（已保存的显式选择不变）。真机：`setParameters` 成功，编码 target 跟随带宽估计（5→20+ Mbps），H.264 保持满分辨率。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/game_stream_launch_settings_test.dart`（未知值回退到 maintain-resolution）、`fushi/test/sync/game_stream_sender_stats_test.dart`（trace 发送端统计行：分辨率/帧率/编码耗时/受限原因/码率/音频包率）。原生补丁本机只能靠真机 trace 验证（插件编进 app，没有独立测试目标）。
- **备注**：「帧率跑不满」的另一部分不是串流造成的——本机显示器 144 Hz，SGRE 开垂直同步时每 3 个刷新周期出一帧，WGC 实测到达 42～49 fps（≈144/3），捕获每帧仅约 4 ms（读回 2.3 + 转换 1.6）、到达即送出。想要 60 fps 需把游戏或显示器刷新率设成 60/120 Hz。
