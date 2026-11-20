## BUG-4906 · 调试版流水线面板在 iOS（TestFlight）/ 安卓调试包上不显示
- **报告**：2026-11-20（用户：更新 › 应用新版 的「调试版流水线」移动端 / iOS 看不到）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/updates_center_open.dart:61`（修前）只按更新通道**设置**挂面板：`appUpdateChannelOf(appModel) != UpdateChannel.debug` 就不挂。TestFlight 每次 develop push 推的都是调试包（`FUSHI_BUILD_VERSION=x.y.z-debug.N`），iOS 用户却从不改通道设置（默认 stable）；安卓直接装调试 APK 的人同理。桌面上用户手动选过 debug 通道所以能看到。
- **[x] ① 已修复** — 抽出纯函数 `showsDebugPulsePanel`：选了 debug 通道 **或** 本机运行版本属于 debug 通道（`channelForUpdateVersion`）即挂面板；正式 / 预发布包且没选 debug 时仍不挂（原设计意图）。
- **[x] ② 已加自动化测试** — `fushi/test/updates/debug_pulse_panel_gate_test.dart`
- **备注**：未在 iOS 真机复测（需要等这条修复进 TestFlight 包）。
