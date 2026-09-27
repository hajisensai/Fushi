## BUG-2731 · 移动端横滑跳转后被自适应画质重开流抹回原位
- **报告**：2026-09-27（用户：哈吉千歳，录屏「滑动进度怪怪的，滑动一下会变成没滑动」）
- **真实性**：✅ 真 bug，平板（SM-X716B，2.8.0-debug.15728）adb 复现：互联远端视频（host 局域网原画直传 `…/stream`）上横滑往回 seek，落点 716072ms 已生效；约 2 秒后日志出现 `[video-load] … /hls.m3u8`，整条流被重开成 host 转码，重开恢复到 715427ms（seek 之前的旧位置），画面回到原处。
  - 根因一（误降档）：`fushi/lib/src/pages/implementations/video_fushi/quality.part.dart` `_tickAdaptiveQuality` 把 `controller.isBuffering` 一律当网况喂给 `AdaptiveQualityController.tick`（`fushi/lib/src/sync/interconnect_adaptive_quality.dart`），远端流一次 seek 要断旧连接重发 Range，缓冲 3～4 秒，正好越过 `kAdaptiveStallTicksToDrop = 3`，局域网原画被判「撑不住」降到 1080p 转码。
  - 根因二（抹回旧位置）：换档 / 换音轨等「按当前位置重开流」读的是 `controller.positionMs`（mpv 原始位置），seek 未落地时仍是旧值；横滑与双击快进/快退在 fork（`third_party/media_kit_video/.../material.dart` `onHorizontalDragEnd` / 双击 `onSubmitted`）里直接 `player.seek`，不像进度条那样回调 `onSeekEnd`，controller 根本不知道 seek 目标。
- **[x] ① 已修复** — fork 横滑 / 双击落点回调 `onSeekEnd(target)`（→ `notifyExternalSeek`）；`VideoPlayerController` 新增不限拍数的 seek 在途目标（双向 ±1.5s 窗口判落地）、`seekGeneration`、`resumePositionMs`；`quality.part.dart` 五处重开点改读 `resumePositionMs`；自适应决策器 `noteSeek()`：seek 后至多 10 拍缓冲不计卡顿、起播即结束宽限。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_adaptive_quality_test.dart`（group「seek 引起的缓冲不算网况」）、`fushi/test/media/video/video_player_controller_test.dart`（group「resumePositionMs」）、`fushi/test/third_party/media_kit_video_seekbar_guard_test.dart`（group「BUG-2731」源码守卫）。
- **备注**：修复后的真机复测待 CI 签名包——平板装的是 CI 密钥签名版，本机只有 debug 密钥，覆盖安装需先卸载（会清数据），未做。哈吉千歳录屏里的 HUD 偏移一直显示 ±0:00 而画面一路往回跳，是同一机制：每次重开都回到旧存档位置，用户只能反复小幅滑动。
