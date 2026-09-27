## BUG-2729 · 串流弱网：码率下限卡死拥塞控制、默认值被固化
- **报告**：2026-09-27（所有者审 #1687：「弱网也要优化」「默认值直接改新，不用考虑老用户」）
- **真实性**：✅ 真 bug，#1687 修好 `set_encodings` 写回之后才暴露的三处。
  1. `fushi/lib/src/sync/game_stream_host.dart` 的 `gameStreamBitrateWindow`：固定码率把 `min=start=max=目标`，自适应的下限是 `min(1 Mbps, 目标)`。libwebrtc 把编码的 `minBitrate` 当成拥塞控制（GCC）的下限：带宽估计不会报到它以下、pacer 至少按它发。#1687 之前这些值被 flutter_webrtc 静默丢掉，所以没事；写回生效后，链路低于下限时（固定 20 Mbps 走弱 Wi-Fi、或自适应下链路 < 1 Mbps）码率降不下来，丢失的带宽变成排队延迟（画面滞后数秒）再变成丢包。
  2. 同一条路径上，默认降级策略 maintain-resolution 下 libwebrtc 只让帧率退让、永不降分辨率，链路弱到连降帧都撑不住时只剩幻灯片，没有「何时让分辨率、何时恢复」的机制。
  3. `fushi/lib/src/models/preferences_repository.dart` 的 `setGameStreamVideoSettings` 存整张 `toJson()`：只改过一项的用户也把当时所有默认值（旧默认 `balanced`）固化进库，#1687 改的新默认对他们不生效。
- **[x] ① 已修复** — `62c416ce696`（PR 分支 `pr/game-stream-weak-network`）：
  - 下限：两种模式共用 `kGameStreamCongestionFloorBps`（150 kbps），固定码率 = 从目标起步、上限为目标，不再把下限钉在目标；自适应从一半起步。
  - 分辨率阶梯 `GameStreamResolutionLadder`：只在 maintain-resolution 下生效，按拥塞控制的估计（`availableOutgoingBitrate`，不是编码输出码率——那正是 BUG-2727 balanced 误降的原因）判断：持续 4 s 低于当前高度的最低可用码率（`gameStreamMinimumUsableKbps`）降一档；持续 10 s 达到上一档最低值的 2 倍才升一档（阈值 2 倍 + 时间不对称，不来回抖）。主机每 2 s 采一次 `getStats`（原来只在开 trace 时采）。
  - 设置只存与默认不同的字段（`GameStreamVideoSettings.toOverridesJson`），偏好键改为 `game_stream_video_overrides`，旧键整表不再读（所有者：没有老用户，不做迁移）。
  - 顺手：`application_loopback_capturer.cc` 删掉 `timeBeginPeriod(1)` / `timeEndPeriod(1)` / `<timeapi.h>`（高精度 waitable timer 不依赖进程定时器精度，粗定时器回退时 `AudioFeedClock` 仍按流逝时间追平）；`FUSHI_PATCH.md` 补记两份整文件覆盖。
- **[x] ② 已加自动化测试** — `62c416ce696`：`fushi/test/sync/game_stream_android_features_test.dart`（码率窗口两种模式的下限、阶梯：满足时不降 / 持续不足才降 / 短暂抖动不降 / 逐档恢复 / 升档要 2 倍余量不抖 / 缺估计重置计时 / 非标准高度作顶档）；`packages/fushi_engine/test/game_stream_launch_settings_test.dart`（持久化只留改过的字段、缺省字段回填为当前默认）。
- **备注**：真机弱网（限速 / 丢包）未测；阈值表是按经验取的起点，需用 `FUSHI_GAME_STREAM_CAPTURE_TRACE` 的 `[fushi_sender]` / `[fushi_ladder]` 行在真实弱网下校准。原生改动本机无 MSVC，靠 CI 的 Windows 构建验证编译。
- **审查后续**（同分支追加提交）：阶梯下发被编码器拒绝时不再断流——只记 `engineLog` / trace，并把阶梯回滚到编码器实际生效的高度（与 `game_stream_service.dart` 改设置失败的契约一致）；带宽估计取 transport 报告 `selectedCandidatePairId` 指向的 candidate-pair，没有再退到带 `availableOutgoingBitrate` 的那一对（多网卡 / IPv4+IPv6 时不再静默取成 null）；阶梯改用单调时钟，两次估计间隔 > 3 s 或 ICE 离开 Connected 时重启计时；`_setVideoParameters` 用 Future 链串行化；`getStats` 5 s 超时、`_stop` 复位采样标记；`fromJson` 回退值全部取默认构造；「自适应码率」提示文案改为说明两种模式的实际差别（17 个文件定点改值）。测试：`game_stream_host_test.dart` 用假 native 驱动真实接线（下发 scale 1.5、拒绝后不断流且阶梯回滚、stop 后不再采样）、`game_stream_sender_stats_test.dart`（选中 pair 优先 / 回退）、阶梯的间隔与 hold 用例。
