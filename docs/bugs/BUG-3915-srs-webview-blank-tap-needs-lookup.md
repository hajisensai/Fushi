## BUG-3915 · srs-webview-blank-tap-needs-lookup
- **报告**：2026-10-31（用户：#2675 改做完整手势系统时排查发现）
- **真实性**：✅ 真 bug。复习页 WebView 卡面（非 Fushi 卡片 / 释义区）上「点空白」只能经取词路径回到 Dart：页内指针脚本 `end()` 在取词点按关闭时直接 `return`（`fushi/lib/src/pages/implementations/srs/srs_card_lookup.dart:655`，基线 `0c39deaaa6`：`if (!g.tap || g.open) return;`），空白点按要靠 `fushiSelection.selectText` 命中不到字时回调 `onTapEmpty`。结果：关掉「点按查词」后 WebView 卡面点空白不再切换悬浮顶栏，而原生卡面（`SrsBlankTapRegion`）不看取词设置照常切换——两种卡面行为不一致。
- **[x] ① 已修复** — `62d3b819b8`：页内指针脚本重写为「取词 + 卡面手势」一条流水线，门控 `window.__fushiSrsGestures` 下发时先分归属（可点元素归页面、点在字上归取词、其余是空白），空白点按直接经 `onSrsGesture` 回报 `{t:'tap'}`，不再依赖取词开关；原生卡面同一套判据（`SrsCardGestureRegion`）。没下发门控的页面（网页浏览器标签页共用本脚本）走旧路径不变。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_card_gesture_script_test.dart`「取词关掉时点空白照报（与原生卡面一致）；弹窗开着时不报」（node 跑真脚本）；旧路径不变由同文件「没下发门控…旧路径原样」钉住。
- **备注**：同批顺手修了新脚本里的一个问题（未进 develop）：开了双击时第二下离第一下太远，第一下的单击被新挂起的点按顶掉、永不回报（`7a5b86b3fd`，同测试文件「双击」用例的「离得太远：各算单击」）。
