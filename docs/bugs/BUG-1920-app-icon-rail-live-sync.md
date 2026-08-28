## BUG-1907 · 应用图标切换未同步到主侧栏
- **报告**：2026-08-28（用户：）
- **真实性**：✅ 真 bug。设置页成功路径只更新原生窗口图标、偏好和本页 `_currentIcon`（`fushi/lib/src/pages/implementations/miscellaneous_settings_page.dart:106`），侧栏却固定渲染 `AppModel.appIcon` 的 `assets/meta/icon.png`；启动恢复也只重应用原生窗口图标，未向 Flutter UI 发布当前选择。
- **[x] ① 已修复** — 本提交在 `fushi/lib/src/utils/misc/app_icon_preferences.dart:37` 建立归一化、可监听的 `AppIconSelection` 真值；启动前恢复、预设/自定义成功路径统一发布，rail 改由 `CurrentAppIcon` 监听。Android 冷启动以真实 launcher alias 覆盖旧版缺失/漂移的 Dart 偏好；原生切换已成功但偏好写入失败时也同步本次运行态。Windows 自定义图标按 256px 上限解码，并在固定路径覆盖后逐出裸 `FileImage` 与 `ResizeImage` 两级缓存、递增 revision，避免第二张仍显示第一张且杜绝 8K 原图挤爆 ImageCache。
- **[x] 视觉收尾** — 根据实机复测移除 rail 品牌位额外的卡片底色、描边和内边距；64px 图片仅保留圆角裁切，直接展示所选应用图标。
- **[x] ② 已加自动化测试** — `fushi/test/utils/app_icon_preferences_test.dart` 覆盖归一化、provider、启动发布、同路径 revision；`fushi/test/widgets/current_app_icon_test.dart` 覆盖运行时发布后同一品牌位立即重绘；`fushi/test/tools/app_icon_guard_test.dart` 钉住启动、设置和 rail 接线及 cache eviction。
- **备注**：`flutter analyze --no-pub` 通过；按用户明确要求未运行任何测试。Windows 增量构建与真实设置页切换复测在合入后执行。
