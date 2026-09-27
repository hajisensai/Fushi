## BUG-2731 · 移动端横滑跳转后被自适应画质重开流抹回原位
- **报告**：2026-09-27（用户：哈吉千歳，录屏「滑动进度怪怪的，滑动一下会变成没滑动」）
- **真实性**：✅ 真 bug，平板（SM-X716B，2.8.0-debug.15728）adb 复现：互联远端视频（host 局域网原画直传 `…/stream`）上横滑往回 seek，落点 716072ms 已生效；约 2 秒后日志出现 `[video-load] … /hls.m3u8`，整条流被重开成 host 转码，重开恢复到 715427ms（seek 之前的旧位置），画面回到原处。
  - 根因一（误降档）：`fushi/lib/src/pages/implementations/video_fushi/quality.part.dart` `_tickAdaptiveQuality` 把 `controller.isBuffering` 一律当网况喂给 `AdaptiveQualityController.tick`（`fushi/lib/src/sync/interconnect_adaptive_quality.dart`），远端流一次 seek 要断旧连接重发 Range，缓冲 3～4 秒，正好越过 `kAdaptiveStallTicksToDrop = 3`，局域网原画被判「撑不住」降到 1080p 转码。
  - 根因二（抹回旧位置）：换档 / 换音轨等「按当前位置重开流」读的是 `controller.positionMs`（mpv 原始位置），seek 未落地时仍是旧值；横滑与双击快进/快退在 fork（`third_party/media_kit_video/.../material.dart` `onHorizontalDragEnd` / 双击 `onSubmitted`）里直接 `player.seek`，不像进度条那样回调 `onSeekEnd`，controller 根本不知道 seek 目标。
- **[x] ① 已修复**（`bdb87a91547`）— fork 横滑 / 双击落点回调 `onSeekEnd(target)`（→ `notifyExternalSeek`）；`VideoPlayerController` 新增不限拍数的 seek 在途目标（双向 ±1.5s 窗口判落地）、`seekGeneration`、`resumePositionMs`；`quality.part.dart` 五处重开点改读 `resumePositionMs`；自适应决策器 `noteSeek()`：seek 后至多 10 拍缓冲不计卡顿、起播即结束宽限。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_adaptive_quality_test.dart`（group「seek 引起的缓冲不算网况」）、`fushi/test/media/video/video_player_controller_test.dart`（group「resumePositionMs」）、`fushi/test/third_party/media_kit_video_seekbar_guard_test.dart`（group「BUG-2731」源码守卫）。
- **备注**：修复后的真机复测待 CI 签名包——平板装的是 CI 密钥签名版，本机只有 debug 密钥，覆盖安装需先卸载（会清数据），未做。哈吉千歳录屏里的 HUD 偏移一直显示 ±0:00 而画面一路往回跳，是同一机制：每次重开都回到旧存档位置，用户只能反复小幅滑动。

### 跟进（PR #1696 审查留下的同根问题）
- **根因三（连续 seek 互相抹掉，录屏「HUD 一直 ±0:00、只能反复小幅滑动」的直接形态）**：相对 seek 全按滞后的原始位置算——fork `material.dart` 横滑 `onHorizontalDragEnd`（`player.state.position + swipeDuration`）、双击快进/快退 `onSubmitted`（`state.position ± value`）、`horizontalSeekResolver` 的 `position:` 参数，以及 `VideoPlayerController.seekRelative`（`positionMs`）。第一次 seek 还在缓冲时再滑一次，第二次目标是「旧位置 + delta2」，第一次位移丢失。
- **根因四（从未落地的在途目标永久残留）**：`_checkSeekLanded` 只认「位置落进目标 ±1.5s」。seek 被忽略 / 失败 / 被吸附到窗口外后正常播放几分钟，手动换档仍跳回过期目标，`_reportRemotePlaybackStopped` 也上报旧位置。
- **根因五（重开流期间在途目标为空）**：`load` 开头把在途目标置 null，重开的恢复 seek 不登记；重开还在打开 / 缓冲时再换档，`resumePositionMs` 读到复用 Player 的残留位置或新流起播前的 0。
- **[x] ① 已修复**（跟进 PR，提交哈希见 PR）—
  - fork 新增主题字段 `MaterialVideoControlsThemeData.relativeSeekBasePosition`（`third_party/media_kit_video/lib/media_kit_video_controls/src/controls/material.dart:375`）与 `_relativeSeekBase`（:898），横滑 resolver 参数 / 回退公式 / 落点（:916 / :928 / :948）与双击两处（:1668 / :1726）一律以它为基准；页面接到 `controller.resumePositionMs`（`fushi/lib/src/pages/implementations/video_fushi/controls_theme.part.dart:262`），横滑 HUD 目标时间同一基准（:434）；`seekRelative` 改用 `resumePositionMs`（`fushi/lib/src/media/video/video_player_controller.dart:3922`）。
  - 「seek 已收场」判据（`video_player_controller.dart:350` / `_checkSeekLanded` :823）：落进 ±1.5s 窗口，**或**连续 8 拍（125ms/拍）「在播、不缓冲、位置逐拍正常推进（0 < 步长 ≤ 1000ms）」即清在途目标；缓冲 / 暂停 / 位置不动时计数不涨，不是超时。没用 mpv `seeking` 属性：media_kit 1.2.6 无 seek 完成事件，只能异步 FFI 轮询，读在 mpv 处理 seek 命令之前会读到 `no` 把刚登记的目标误清。所有置位 / 清除统一走 `_setPendingSeekLanding`（:814），连同推进计数一起复位。
  - `load` 开头把在途目标置为按 intent 算出的起播点 `preloadStartMs`（:2063），open 后按真实 duration 复核出 `resolvedStartMs` 再覆盖（:2460），不计 `seekGeneration`。
  - `AdaptiveQualityController`（`fushi/lib/src/sync/interconnect_adaptive_quality.dart:80`）注释写明两处未修盲区：1Hz 采样落在「短暂起播又卡」空档时宽限被拉到上限 / 取决于采样相位；循环重播每几秒 seek 使宽限不断续命、差网永不降档。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_player_controller_test.dart`（group「resumePositionMs」新增三条：连续 `seekRelative` 位移累加；未落地但正常推进后目标清除；缓冲 / 暂停 / 不动 / 推进被打断都不清）；`fushi/test/third_party/media_kit_video_seekbar_guard_test.dart`（group「BUG-2731 follow-up」源码守卫：fork 相对 seek 不再读原始 position、页面接线、`seekRelative` 与 `load` 两处登记顺序）。`load` 需要真 libmpv，无法纯单测，故「重开后在途目标 = resolvedStartMs」只有源码守卫。
- **备注**：跟进同样**未真机复测**（理由同上：平板是 CI 签名包，覆盖安装会清数据）。
