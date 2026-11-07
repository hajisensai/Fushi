## BUG-4227 · iOS 后台拉起会话的 headless 标记被初始 inactive 覆盖，后台回收被判启动即闪退
- **报告**：2026-11-07（用户：应用内自动闪退报告 1jhwtJQIZq，iOS 3.3.0-debug.24438）
- **真实性**：✅ 真 bug。证据：`lastLifecycle=inactive@16:30:55.747 launch={applicationState=background scenes=1 foregroundScene=false}`，原生（`ios/Runner/AppDelegate.swift:812`）答 `hasUi=false`，标记初值本应是 `headless`，但 4ms 后被改成 `inactive`，判成「启动初始化未完成（停在前台时没了，疑似闪退）」。根因：
  - `fushi/lib/src/diagnostics/previous_exit_log.dart:1594`（修前）`foldIntoErrorLog` 挂观察者时补记 `WidgetsBinding.instance.lifecycleState`——iOS 后台拉起时引擎初始生命周期就是 `inactive`；
  - `previous_exit_log.dart:324`（修前）`SessionMarker.recordLifecycle` 无条件覆盖，`headless` 被任何生命周期（含 `inactive` / `hidden` / `paused`）覆盖；
  - `previous_exit_log.dart:226`（修前）`diedInForeground` 把 `inactive` 算前台。
- **[x] ① 已修复** — `recordLifecycle`：标记为 `headless` 时只有 `resumed`（界面真的上屏）才升级为普通状态，其余状态不改写（`detached` 照常标 clean）。不动 `diedInForeground` 对有界面会话 `inactive` 的语义。提交 22a6de2244。
- **[x] ② 已加自动化测试** — `fushi/test/diagnostics/previous_exit_log_test.dart`：「iOS 后台拉起：补记的初始 inactive / 后续 hidden、paused 不覆盖 headless」（走真实 `foldIntoErrorLog` + 观察者补记路径，binding 先置 inactive）、「headless 标记：只有 resumed 升级，detached 照常标 clean」。去掉修复两条都红。
- **备注**：Android 无界面引擎走方案 C（`headless_launch_gate.dart`）等界面接上才 start 标记，此改动对它无副作用。
