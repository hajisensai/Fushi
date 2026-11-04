## BUG-4121 · 每次开网络流 mpv 报 "Failed to create file cache"
- **报告**：2026-11-04（Steam Deck mpv 日志排查视频卡顿时发现）
- **真实性**：✅ 真 bug（无害但每次都错）。media_kit `native/player/real.dart` 初始化设 `cache-on-disk=yes`，却以 `config=no` 启动 libmpv、没有 `cache-dir`；mpv 开网络流启用缓存时建磁盘缓存失败、报错后退回内存缓存。Fushi `fushi/lib/src/media/video/video_mpv_config.dart` `buildNetworkCacheProperties` 的字节上限本就按内存缓存定，但没覆盖这一项。
- **[x] ① 已修复** — `buildNetworkCacheProperties` 下发 `cache-on-disk=no`（open 前注入，全平台），与实际生效的内存缓存一致。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_mpv_config_test.dart` 桌面 / 移动两档都断言 `cache-on-disk=no`。
- **备注**：
