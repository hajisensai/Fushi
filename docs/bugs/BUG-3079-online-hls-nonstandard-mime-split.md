## BUG-3079 · 在线视频源进度条被切成三四秒一段（HLS 播放列表被当普通列表逐分片播放）
- **报告**：2026-10-07（QQ 群用户：Aniyomi 扩展源视频能播放，但进度条每三四秒成为一段，多个源都有此现象）。
- **真实性**：✅ 真 bug。`fushi/lib/src/utils/net/app_native_proxy.dart:517` 在正文识别为 HLS 后改写播放列表 URI，却仍透传上游 Content-Type。非 `.m3u8` 路径与 `text/plain` 等非标准 MIME 组合使 native 无法正确识别 HLS，可能退为普通播放列表、逐个播放仅三四秒的分片。真实调用链为 `fushi/lib/src/media/video/video_player_controller.dart:2257` 的 `nativePlaybackUri` 与 `:2485` 的本机代理装配，随后进入 `_relayBody` / `_relayWholeBody`。
- **[x] ① 已修复** — `ccd07448a3`（`pr/online-video-segmented-bar`）：在完整正文确认是 HLS、URI 改写成功后，将响应 MIME 规范为 `application/vnd.apple.mpegurl`（`app_native_proxy.dart:531`）。保留原有 gzip 解码、长度重算与完整 Range 转 200；部分 Range、普通视频及真实图片继续透传。
- **[x] ② 已加自动化测试** — `fushi/test/utils/net/app_native_proxy_hls_test.dart:270`：真实本机 HTTP 上游 + AppNativeProxy，验证非 `.m3u8` 路径、`text/plain`、`Range: bytes=0-` 的响应 MIME 与完整 URI 改写；另验 gzip 播放列表原有 MIME 归一化。原有测试继续覆盖真实图片、伪装分片及部分范围请求。
- **备注**：交接记录确认新增测试在旧实现上失败；本轮重跑 HLS 文件 8/8、相邻 normalizer / 代理 / TLS / 指纹钉扎 / 诊断 48/48 通过（退出码均 0），Flutter 3.47.6 全量 analyze 退出码 0、零问题。没有用户原始扩展/剧集/流地址，因此未做用户原始失败路径的设备肉眼复测，不能据此宣称所有扩展均已恢复；该项留待发布后用户复核。本次无 UI 改动，无界面截图。
- **native 合成流验证**：本机真实 mpv 经 AppNativeProxy 播放 `master.txt` + `text/plain` 的 12 秒 HLS（3 × 4 秒分片），断言 `playlist-count=1`、`duration=12.000000`、`current-demuxer=lavf`、`file-format=hls`，1/1 通过、退出码 0。临时探针与日志只保留在 `.codex-test/online-video-segmented-bar/`，不入库；这不替代用户原始源的设备复测。
