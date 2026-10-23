## BUG-3663 · 本场景按钮全取消时应用外球仍给（不画的）应用内球让位，Fushi 里一颗球都没有
- **报告**：2026-10-23（复核反馈 C-Bm1TZ388「悬浮球在应用内不显示：在应用外显示，应用内不显示」时发现的第二条路径；vivo V1901A / Android 9，2.10.0-debug。BUG-3602 修的是截屏 OCR 回调丢失导致应用内球一直藏着，这里是另一条与 OCR 无关、同样表现为「应用外有、应用内没有」的路径）
- **真实性**：✅ 真 bug（代码路径 + 宿主测试复现）。应用内球在当前场景勾选的按钮一颗都不剩时不画（`fushi/lib/src/floating_ball/app_floating_ball_host.dart` build 里「勾选的按钮一颗都不剩 = 用户不要这颗球」），但应用外球的让位判据只看「应用内显示」开关（`_systemBallYields` → `floatingBallSystemBallYieldsToInApp(inAppBallEnabled: prefs.floatingBallInApp)`，`fushi/lib/src/floating_ball/floating_ball_config.dart`）。用户把「其它页面」（或某一场景）的按钮全取消、只想用应用外球时：Fushi 在前台 → 应用外球让位隐藏，应用内球因为没按钮不画 → 一颗球都没有；切到别的应用 → 应用外球照常出现。日志里没有能区分是这条还是 BUG-3602 的证据（原生日志不进反馈），两条都修。
- **[x] ① 已修复** — 宿主在 build 里先算本场景的按钮，再判临时隐藏；按钮为空记进 `_inAppBallHasButtons`，让位判据改为「开关开着且本场景有按钮」（与关掉「应用内显示」同义），变化时等这一帧结束后重新下发让位值。临时不画（场景隐藏 / 本页关闭 / 截屏中 / 反馈截图）不影响，照样让位。
- **[x] ② 已加自动化测试** — `fushi/test/floating_ball/app_floating_ball_host_test.dart`「BUG-3663 本场景按钮全取消……」（按钮全取消后让位值从 true 变 false、应用内不画球、开关不动；勾回按钮后恢复让位）。
- **备注**：未上真机。
