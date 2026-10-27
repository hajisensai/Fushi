## BUG-3800 · 悬浮球切换配置按钮文案被换成配置名
- **报告**：2026-10-27（用户：PR #2565 合入后审查）
- **真实性**：✅ 真 bug。`fushi/lib/src/floating_ball/app_floating_ball_host.dart` 的 `FloatingBallGlobalAction.switchProfile` 分支（提交 fb48f2eeb9）把 `ReaderHeaderAction.label` 换成 `_switchProfileLabel`（当前配置名），而 PR 描述只说 tooltip 带配置名；标签胶囊（显示文字时）里只剩「Default」，看不出按钮是「切换」。
- **[x] ① 已修复** — `label` 恢复为 `t.floating_ball_action_switch_profile`，删掉 `_switchProfileLabel`；当前配置名只进 tooltip（`floating_ball_action_switch_profile_tooltip`，「切换配置（当前：xxx）」）。悬浮球没有另外的溢出菜单，按钮文字只来自 `label`。
- **[x] ② 已加自动化测试** — `fushi/test/floating_ball/app_floating_ball_host_test.dart`「切换配置按钮：文案仍是「切换配置」，当前配置名只进悬停提示」
- **备注**：
