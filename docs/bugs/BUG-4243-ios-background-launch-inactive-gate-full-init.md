## BUG-4243 · iOS 后台拉起时 inactive 被精简入口当成有界面，完整初始化在后台照跑并被判闪退
- **报告**：2026-11-09（用户：应用内反馈 wlUi86UBfd，iOS 27.2，3.3.0-debug.24438/24454/24476 共三条）
- **真实性**：✅ 真 bug。证据：三条报告的 launch 都是 `applicationState=background scenes=1 foregroundScene=false`、frames=0，原生（`fushi/ios/Runner/AppDelegate.swift:812`）答 `hasUi=false`；进程启动后 7–16ms 生命周期变成 `inactive`，`AppInit.hangRecovered` 停在 rebuild-dict-paths / open-database（后台被挂起），却被报成「停在前台时没了，疑似闪退」。根因：
  - `fushi/lib/src/startup/headless_launch_gate.dart:54`（修前）`lifecycleHasUi` 把 `inactive` 一律当「界面已接上」。这在 Android 成立（`inactive` 只在 Activity 接管引擎后的 onPause / 失焦才发），在 iOS 不成立：后台拉起时 scene 已连接但不在前台，引擎照样报 `inactive`。于是 `chooseLaunchEntry`（:70）返回 `full`、或 `waitForUiLifecycle`（:92）被 `inactive` 放行，BUG-4072 方案 C 的精简入口在 iOS 上形同虚设，完整初始化（会话标记、数据库、词典）在后台照跑；
  - 之后会话标记的 headless 初值被补记的 `inactive` 覆盖、被判 unexpected——这一段由 #3055（BUG-4242，`SessionMarker.recordLifecycle` 只在 resumed 升级 headless）修，本条不重复改。
- **[x] ① 已修复** — `lifecycleHasUi` / `chooseLaunchEntry` / `waitForUiLifecycle` 显式带 `inactiveMeansUi`（`platformInactiveMeansUi`：只有 iOS 为 false），`holdHeadlessLaunchUntilUi` 可注入、缺省按平台。iOS 上原生说没界面时只认 `resumed` 放行；Android 行为不变。
- **[x] ② 已加自动化测试** — `fushi/test/startup/headless_launch_gate_test.dart`：「iOS：原生说没界面、生命周期是 inactive → 仍走精简入口」「iOS 后台拉起：已是 inactive 也停在精简入口，再来 inactive 不放行，resumed 才放行」。把 `inactiveMeansUi &&` 去掉（恢复修前语义）两条都红。
- **备注**：iOS 真机后台拉起（后台刷新 / 推送 / 音频）复测未做；用户从后台拉起的进程点开 app 时一定到 `resumed`，此时才跑完整初始化。
