## BUG-3256 · 当前 tab 被非设置页途径关掉时外壳 tab 通知残留旧值
- **报告**：2026-10-10（PR #2052 审查遗留疑点）
- **真实性**：✅ 真 bug。存在非设置页途径：ctl `/api/admin/modules`（`ctl_settings_routes.dart` → `AppModel.setModuleEnabled`）、互联下载配置 / 备份恢复后的偏好刷新、新手引导写回，都能在用户停在该 tab 时把它关掉。`HomePage` 只在渲染层用 `_visibleTab` 兜底到落地 tab（`fushi/lib/src/pages/implementations/home_page.dart:1059`），`_currentTab` 与共享 `homeShellTabNotifier` 留着旧值——桌面自绘标题栏（main.dart `FushiDesktopTitleBar` 读 notifier）写「首页」，正文却是别的页；macOS 侧栏、ctl `current`、首页 `_isVisibleTab` 同样读到脏值。#2052 让首页可关后，这条从「库页被关」扩到最常停留的首页。另：外壳横滑 `HomeModuleSwipeDetector` 的 `GestureDetector` 没设 `excludeFromSemantics`（`fushi/lib/src/pages/implementations/home_module_swipe.dart:267`），整个正文多出 scrollLeft / scrollRight 无障碍动作，读屏横滚手势会误切模块。
- **[x] ① 已修复** — `HomePage` 监听 AppModel，当前 tab 不再可见时经统一入口 `_selectTab(homeLandingTab(tabs))` 把选中身份与 notifier 一起落到正在渲染的落地 tab（构建期的通知推到帧后）；横滑识别器 `excludeFromSemantics: true`。提交 fix(home): follow a hidden current tab to the landing tab and keep swipe out of semantics
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_module_home_optional_test.dart`「BUG-3256 停在首页时首页被关」（修复前 notifier 仍为 home，红）；`fushi/test/pages/home_module_swipe_test.dart`「外壳横滑不给正文加无障碍横滚动作」（修复前红）。
- **备注**：
