## BUG-753 · 页头标签药丸按本地宽降级失败·挤压书架标题重叠
- **报告**：2026-07-12（用户：）截图书架页头大标题「书架」被挤到贴按钮、折成两行（书/架），带文字的动作药丸（导入书/管理来源/收藏夹/阅读统计）没有降级成纯图标（用户：「已经重叠了还没降级成无字」）。
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/utils/components/hibiki_icon_button.dart:157` 的 `_labelExpanded` 只按**整窗**宽（`MediaQuery.sizeOf`）判定是否展开 label 药丸，与页头实际可用宽脱钩。桌面带导航栏 / 分栏时整窗 ≥600（甚至 ≥840）但页头本地宽更窄，窗宽判定仍把 4 个动作展开成药丸，`HibikiPageHeader`（`hibiki_material_components.dart` `_HibikiPageHeaderRow`）里 `Expanded` 的标题被压到 0 附近、贴着按钮并折成两行。
- **[x] ① 已修复** — 展开判定改由 `_HibikiPageHeaderRow` 的 `LayoutBuilder` 用**本地可用宽**（`constraints.maxWidth`，经 `windowSizeClassReal` 乘回 UI 缩放还原真实宽）判定，仅 `WindowSizeClass.expanded`（真实 ≥840）才展开，结果经新增的 `HibikiHeaderLabelScope` InheritedWidget 下发给后代 `HibikiIconButton`；域外独立使用的带 label 按钮回退整窗判定（`!= compact`），行为零变化。提交见分支 `worktree-header-pill-collapse`。
  - `hibiki/lib/src/utils/components/hibiki_icon_button.dart`：新增 `HibikiHeaderLabelScope`；`_labelExpanded` 优先读作用域、域外回退整窗。
  - `hibiki/lib/src/utils/components/hibiki_material_components.dart`：`_HibikiPageHeaderRow` 按本地宽算 `expandLabels` 并包裹 actions。
- **[x] ② 已加自动化测试** — `hibiki/test/widgets/hibiki_material_components_test.dart` 新增两条：整窗 1200(expanded) + 页头本地宽 720(medium) 时带 label 动作回落纯图标（无文字、标题「书架」不被挤）；本地宽 1000(expanded) 时展开成图标+文字药丸。`flutter test test/widgets test/pages` 2153 通过，`flutter analyze` 全库 No issues。
- **备注**：号段可能与并发 agent（PR#56 提到的 BUG-753 词头迷你滚动条）撞号，集成合并时由 integration owner 决定改号一个 + reindex。真机 / 离屏目视复测桌面带导航栏窄页头的降级观感待补（本次已用 widget test 在失败几何上确定性验证机制）。
