## BUG-1920 · 应用图标切换未同步到主侧栏
- **报告**：2026-08-28（用户：）
- **真实性**：✅ 真 bug。设置页成功路径只更新原生窗口图标、偏好和本页 `_currentIcon`（`fushi/lib/src/pages/implementations/miscellaneous_settings_page.dart:106`），侧栏却固定渲染 `AppModel.appIcon` 的 `assets/meta/icon.png`；启动恢复也只重应用原生窗口图标，未向 Flutter UI 发布当前选择。
- **[x] ① 已修复** — 本提交在 `fushi/lib/src/utils/misc/app_icon_preferences.dart:37` 建立归一化、可监听的 `AppIconSelection` 真值；启动前恢复、预设/自定义成功路径统一发布，rail 改由 `CurrentAppIcon` 监听。Android 冷启动以真实 launcher alias 覆盖旧版缺失/漂移的 Dart 偏好；原生切换已成功但偏好写入失败时也同步本次运行态。Windows 自定义图标按 256px 上限解码，并在固定路径覆盖后逐出裸 `FileImage` 与 `ResizeImage` 两级缓存、递增 revision，避免第二张仍显示第一张且杜绝 8K 原图挤爆 ImageCache。
- **[x] 视觉收尾** — 根据实机复测移除 rail 品牌位额外的卡片底色、描边和内边距；64px 图片仅保留圆角裁切，直接展示所选应用图标。
- **[x] ② 已加自动化测试** — `fushi/test/utils/app_icon_preferences_test.dart` 覆盖归一化、provider、启动发布、同路径 revision；`fushi/test/widgets/current_app_icon_test.dart` 覆盖运行时发布后同一品牌位立即重绘；`fushi/test/tools/app_icon_guard_test.dart` 钉住启动、设置和 rail 接线及 cache eviction。
- **合并时复核补修（PR #1039 合入 develop 当轮）**——PR 自述「按用户明确要求未运行任何测试」，故合并前逐条静态复核并补了三处：
  1. **逐出漏在兜底路径**（真缺陷）。逐出原本只写在 `saveAppIconSelection` 里，而「原生图标已切换、偏好落盘失败」那条兜底直接调 `publishAppIconSelection`，绕过逐出。自定义图始终落在**固定**路径，`FileImage` 的 key 不变，`imageCache.putIfAbsent` 会把上一张的解码原样还回来——新 revision 只让组件重新 resolve，拦不住缓存命中。修法不是在兜底里补一句，而是把逐出收进**唯一发布点** `publishAppIconSelection`（随之改 async，四个调用点跟进），任何调用方都不可能再漏。新增行为测试 `app_icon_preferences_test.dart` 的「发布新选择时逐出同路径的旧图片缓存」；变异实测：把逐出从发布点拿掉 → `Expected: false / Actual: <true>` 变红，sha256 校验回滚。
  2. **rail 品牌位零余量**（窄平台风险）。`Padding(all(gap=8))` + `SizedBox.square(64)` = 80，正好等于 `kAdaptiveNavRailWidth`；rail 外是 `SafeArea(right: false)`，left inset 一旦 > 0（带刘海的平板/折叠屏横屏）可用宽度不足 80，写死的 64 会溢出。改为 `FittedBox(fit: BoxFit.scaleDown)` 兜住：有地方仍是 64，挤了等比缩小。桌面三端 inset 恒 0，观感不变，故 TMDB「不得更显眼」论证里的 64dp 上限依旧成立。
  3. **设置页仍留着第二份真值**。`_currentIcon` 字段与 `currentAppIconSelection` 各写各的——正是本 bug 要消灭的形状，只是暂时只有一个写者所以看不出来。改成 `String get _currentIcon => currentAppIconSelection.value.presetKey;`，删掉四处赋值（保留 `setState` 触发重建）。
- **一处被驳回的疑似回归**：审查提出「Windows 上 `loadAppIconSelection()` 抛异常时，新代码会把窗口图标主动刷成 default，旧代码是不动」。复核结论是**不成立**——Windows exe 的静态图标本来就是 default，develop 上加载失败等于不调 `setWindowIcon`、窗口显示的同样是 default，两条路径肉眼结果一致，未做改动。
- **合并当轮验证**：`flutter analyze --no-pub` No issues found；定向 `app_icon_preferences` + `current_app_icon` + `app_icon_guard` + `md3_design_system_static` + `tmdb_attribution` + `home_page_tabs` → **118 tests PASSED**。
- **备注**：`flutter analyze --no-pub` 与 Windows Debug 增量构建通过；用户已在真实设置页确认自定义图标会即时同步。按用户明确要求未运行任何测试。
