## BUG-2848 · AACS 蓝光原盘缺少解密读取链路
- **报告**：2026-10-01（用户：E 盘蓝光报 AACS 加密，要求补齐并同步其他系统。）
- **真实性**：✅ 功能缺口。真实 E 盘与本地目录副本均为密文，原加密判定正确；`fushi/lib/src/media/video/video_player_controller.dart` 的 `load()` 在判加密后直接抛错，播放器与 FFmpeg 均没有解密输入。实际匹配配置后，官方 libaacs 可解密同一张盘。另随包 FFmpeg 缺少该盘首音轨所需的 `pcm_bluray` 解码器。
- **[x] ① 已修复** — `AacsMediaSession`、纯 Dart CPS/AES 内容解码器与有界回环 Range 输入接入播放、FFmpeg/ASR/制卡；配置精确盘 ID 匹配，缓存/下载统一联网策略，所有系统共用；补随包 LPCM 解码。临时能力地址不持久化，换片/释放句柄关闭会话。AACS2/BD+与光驱认证不在本次范围。
- **[x] ② 已加自动化测试** — `aacs_content_decoder_test.dart`、`aacs_configuration_test.dart`、`aacs_stream_relay_test.dart`，真实盘 `aacs_native_media_test.dart`，实际应用 `aacs_real_disc_itest.dart`；三处真实盘数据与官方 libaacs 逐字节比对通过，真实帧/音频/MP4 输出通过。
- **备注**：密钥配置和真实盘采样不入库。设备测试单独记录，不能把共享纯 Dart 实现等同于五平台设备 E2E 已通过。
