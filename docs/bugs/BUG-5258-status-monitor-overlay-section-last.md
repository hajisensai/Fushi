## BUG-5258 · status-monitor-overlay-section-last
- **报告**：2026-11-23（应用内反馈 guvfO-g0aI：「悬浮小窗要放在最顶上」）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/status_monitor_page.dart:78-82` 分区顺序是 实时 → 线程 → 卡顿 → 明细 → 悬浮小窗，开关排在页底，要滚过整页读数才找到。悬浮层本身在全局 Stack 最上层（`main.dart` 的 `StatusMonitorOverlayHost`），z 序没问题；按拍板理解为页面排序。页面没有 tab / 锚点（`SettingsSectionSpy` 未用），只需改分区顺序。
- **[x] ① 已修复** — `_OverlaySection` 移到分区列表第一个。
- **[x] ② 已加自动化测试** — `fushi/test/diagnostics/status_monitor_test.dart`「状态页：悬浮小窗分区排第一…」：默认 800×600 窗口首屏能找到开关且在 CPU 读数之上（修复前整节懒构建不出来）。
- **备注**：
