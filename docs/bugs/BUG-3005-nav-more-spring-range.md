## BUG-3005 · 导航底栏更多菜单弹簧过冲导致打开时断言
- **报告**：2026-10-06（M3E wave 1 PR 代码审查）
- **真实性**：✅ 真 bug（代码路径确认，运行验证待补）。紧凑底栏放不下全部模块时，打开「更多」触发 `fushi/lib/src/utils/adaptive/adaptive_navigation.dart:1840` 的原生 `showMenu`。原曲线 `FushiMotion.release` 是阻尼比 0.6 的 spatial 弹簧，会超过 1；material_ui 1.5.0 的 `popup_menu.dart:992` 将它应用到 `route.animation`，随后 `:723`、`:766` 的 `Interval` 对超范围输入断言。
- **[x] ① 已修复** — 将原生菜单路由曲线改用保持 0..1 的 `FushiMotion.enter`（effects 弹簧）；保留导航指示器本身的 spatial 动画。提交哈希待主代理统一提交后记录。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/adaptive_nav_compact_labels_test.dart` 的「360dp 宽 8 个入口」行为测试中，打开菜单后以 16ms 间隔检查 24 帧异常，再验证菜单项选择结果。执行结果由主代理统一验证后补记。
- **验证补记（2026-10-06）**：根因修复提交 `e32c4b9748f`。修正隐藏导航分支的测试定位后，Flutter 3.47.6 定向测试 7 项全部通过（包含上述逐帧菜单断言），全量 analyze 0 issue。证据见交接输出 `pr-m3e-wave-1-reverify.log`；前述待验证状态由本条更新。
- **备注**：需回补 `claude/shishamo-1005` 集成分支。尚未做真实设备 UI 复测，不宣称设备验证通过。
