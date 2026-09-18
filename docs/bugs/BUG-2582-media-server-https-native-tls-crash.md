## BUG-2582 · macOS / iOS 播放 https 媒体流闪退：随包 libmpv 的 Mbed TLS 握手段错误
- **报告**：2026-09-18（用户：「ios 播放直接闪退」「macos 也是播放闪退」，播的是 Emby 媒体服务器条目）
- **真实性**：✅ 真 bug（Mac 真机复现 + 崩溃报告，非推断）
  - 现场：Mac `~/Library/Logs/DiagnosticReports/fushi-2026-09-18-210129.ips`（用户侧）与本轮基线复现 `fushi-2026-09-18-212831.ips`，两份**同栈**：`EXC_BAD_ACCESS / SIGSEGV, KERN_INVALID_ADDRESS at 0x20`，崩溃线程 mpv `*/opener`：
    `open_demux_thread → demux_open_url → stream_create → Avformat(tls_mbedtls) → mbedtls_ssl_handshake → … → ssl_parse_server_hello → mbedtls_ssl_read_record → ssl_get_next_record`。
  - 根因：macOS / iOS 随包 libmpv 是本仓自建的 `hajisensai/libmpv-darwin-build @ hibiki/ffmpeg-6.1.6`（`third_party/media_kit_libs_macos_video/macos/Makefile:3-27`、ios 同款），FFmpeg 6.1.6 的 `tls_mbedtls` 配 Mbed TLS 在 ServerHello 解析阶段空指针解引用——**任何 https 媒体流一到 native 侧握手就死**。本仓交给 native 的 URL 走 `fushi/lib/src/media/video/video_player_controller.dart` 的 `nativePlaybackUri`（`fushi/lib/src/utils/net/app_native_proxy.dart`），此前只把**钉扎（互联自签）原点**降成明文经中继升 https，普通 https（Emby / Jellyfin 远程访问、公网直链）原样交给 native → mpv 经中继 CONNECT 隧道自己做 TLS → Apple 端段错误。Windows 随包 libmpv 走 libcurl 所以只卡不崩；Android 的 ffmpeg tls 则从不校验证书。
  - 复现测试：`fushi/integration_test/video_https_stream_native_tls_itest.dart`（公网 https mp4 经 `UrlStreamVideoClient` → `VideoFushiPage` 真播放）。基线 `3049b534f6f` 在 Mac 上 1 秒内进程消失（runner `RUN_END exit=79`，新 ips 同栈）。
- **[x] ① 已修复** — `23fad6468d4`：`nativePlaybackUri` 把**所有** https 降成明文显式端口 http 并登记 `(host, port)` 为「中继终结 TLS」原点；`AppNativeProxy._forward` 对登记原点用系统信任根的 `createAppHttpClient` 升回 https（钉扎原点仍按指纹）；上游 3xx 的 https `Location` 同样改写并登记，native 跟过去仍经中继；明文 http 经过时撤销同原点登记。TLS 信任从此只在 Dart 一处裁决，与 API / 字幕 / 封面通道同判据（登录能过的证书，视频就一定能过）。修后同一条测试 macOS（`RUN_END exit=0`，`playedMs=1633`，无新 ips）与 iOS 模拟器（`playedMs=1733`，无新 ips）都真实起播，`[video-load]` 打印的 native URI 已是 `http://test-videos.co.uk:443/...` 降级形式。
- **[x] ② 已加自动化测试** — `fushi/test/utils/net/app_native_proxy_tls_origin_test.dart`（真自签 https 原点 + 注入信任测试证书的上游客户端：登记原点 200 / 206 Range 透传、未登记必 502、Location 改写并登记、同原点一串请求复用一个上游客户端）；`app_native_proxy_pinned_origin_test.dart` 的 `nativePlaybackUri` 契约更新（未钉扎 https 也降级 + http 撤销登记）；真机门 `integration_test/video_https_stream_native_tls_itest.dart`。
- **备注**：
  - 已知缺口：HLS 播放列表**正文里**的绝对 `https://` 分片 URL 仍由 mpv 自己取（中继不改写 m3u8 正文），Apple 端会继续撞同一崩溃；Emby / Jellyfin 转码 HLS 用相对 URL、不受影响。要彻底封死得让中继改写 m3u8 正文或换掉 Apple 端 libmpv 的 TLS 后端（重编 `libmpv-darwin-build`，给 `tls_mbedtls.c` 补 `psa_crypto_init` / 锁 TLS 1.2）。
  - iOS 模拟器强制软件渲染（`TextureSW`），验证的是 TLS / 中继路径，不是真机的 `TextureHW`。
  - 自签证书的 Emby https：中继用系统信任根，会 502；但登录阶段 Dart 客户端同样不信它——两处一致，属预期。
