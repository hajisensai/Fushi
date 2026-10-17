## BUG-3011 · 新增横向筛选与导航区未启用桌面鼠标拖动
- **报告**：2026-10-06（Codex 目录守卫复核）
- **真实性**：✅ 真 bug。Flutter 默认滚动行为不包含 mouse 拖动；新增的漫画设置页签、在线源筛选、放送日历工具条、字体筛选、设置跳转栏直接实例化横向滚动件，未接共享 `HorizontalDragScrollable`。根因调用分别位于 `manga_reader_settings_sheet.dart`、`installed_online_source_row.dart`、`airing_calendar_page.dart`、`custom_fonts_page.dart`、`settings_kit.dart` 的 `scrollDirection: Axis.horizontal`。
- **[x] ① 已修复** — `51724a29a64`：五个真实可滚区域接共享鼠标拖动包装。游戏与媒体服务器的 loading 骨架显式设置 `NeverScrollableScrollPhysics`，保持禁滚，不修改生产代码。
- **[x] ② 已增加自动化测试** — `horizontal_drag_scroll_guard_test.dart` 全树扫描钉住包装，新增静止骨架与嵌套 physics 正反自检：只有同一滚动件的直接禁滚参数能排除候选，子孙禁滚不影响父级检查。
- **备注**：未操作用户正在运行的 Fushi Dev，设备端鼠标交互复测待补；自动化执行结果见外部 `outputs/verify-1006-last.md`。

- **PR #1984 集成**：已在 pr/m3e-wave-1 复用对应修复；本 PR 的验证独立记于 outputs/pr-m3e-wave-1-review.md，不能继承 verify-1006 的通过结果。
