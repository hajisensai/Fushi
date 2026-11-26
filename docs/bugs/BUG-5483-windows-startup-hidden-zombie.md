## BUG-5483 · Windows 升级 3.4 后进程常驻后台、主窗永远不显示，再点图标无反应
- **报告**：2026-11-26（Discord 用户 GrimsChild，Surface Pro 7+；附 `error_log.txt` 与进程 dump）
- **真实性**：✅ 真 bug。触发卡死的那一步见 BUG-5484（根因待取证）；本条是**卡住之后**的三处结构缺陷，它们把「启动某一步不返回」放大成「进程隐形、重启无效、零证据」：
  1. **隐藏建窗没有期限**：普通启动主窗隐藏建窗（`fushi/windows/runner/win32_window.cpp:213`），只在 Dart 首页 / 错误页第一帧光栅化后由 `_releaseStartupFrame` 显窗（`fushi/lib/main.dart:2672` 先 `await binding.waitUntilFirstFrameRasterized`）。中间任何一步 await 不返回，进程就永远隐形。用户 dump：32 个线程全部空闲等待、主线程在 `GetMessage` 正常泵消息，运行 42 分钟。
  2. **二次启动判据错**：`fushi/windows/runner/main.cpp` 把「主窗不可见」一律当「首实例正在退出」，可启动中的首实例同样不可见 → 第二个进程白等 `kPreviousInstanceWaitMs`（20 s）再把请求转给隐藏窗口后退出 = 「点了没反应」，用户只能重启电脑（用户原话：重启几次都没用）。
  3. **卡住时零证据**：停泵看门狗只在主线程不泵消息时抓 dump；Dart 失联检测要等第一次心跳且 Dart 照常跳；BUG-772 present 看门狗在 `runApp` 后才挂；`StartupTimeline` 只在显窗后落盘。用户找遍只有一份无关的 `session_end.log`（关机时写的）。
- **[x] ① 已修复** —
  - 原生启动期限 `fushi/windows/runner/startup_reveal_policy.h` + `hang_watchdog.cpp` `CheckStartupReveal`：主窗建好 45 s 仍从没显示 → 抓全线程栈 `hang-*.dmp`、`hang_watchdog.log` 记一行、`ShowWindowAsync` 强制显窗（投递式，主线程真卡住也不连累看门狗线程）；主窗第一次可见时挂 `FushiMainWindowShown` 窗口属性。
  - 二次启动 `main.cpp` 改用 `ClassifyExistingInstance`：显示过又不可见才是退出中（等互斥量）；从没显示过是启动中（立即转交，不白等）。
  - Dart 启动期限 `fushi/lib/src/startup/startup_stall_deadline.dart`：`main()` 起跑 40 s 仍未显窗 → 把 `StartupTimeline` 已走到的阶段（最后一个阶段之后那一步即卡住的 await）写进同一份 `hang_watchdog.log`，下次启动由 `HangWatchdogLog.foldIntoErrorLog` 折进错误日志。
- **[x] ② 已加自动化测试** — `fushi/windows/runner/tests/startup_reveal_policy_test.cpp`（随每次 Windows runner 构建执行：分类四态 + 期限一次性）、`fushi/test/startup/startup_stall_deadline_test.dart`（到点写行 / 已显窗不写 / 非 Windows 不挂 / 期限早于原生 / 原生接线源码守卫）。
- **备注**：强制显窗不是掩盖症状：dump 与卡住阶段先落盘，触发卡死的根因单独登记在 BUG-5484 待新证据定位。未在真实 Surface 设备上复测（手头无该设备），由用户装下一个 debug 包验证：45 s 后应能看到窗口，`%LOCALAPPDATA%\Fushi\crashdumps\hang_watchdog.log` 里应有 `startup:` 两行与一份 `hang-*.dmp`。
