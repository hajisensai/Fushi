## BUG-4715 · 库页排序菜单不从排序按钮下方弹出而是弹在页头动作组右下角
- **报告**：2026-11-16（维护者应用内反馈 n-0lIy8dtQ：「排序菜单弹出位置与按钮位置不符，同类处一并根因修」）
- **真实性**：✅ 真 bug。库页（视频库 / 书架历史 / 游戏库）的「排序」菜单不挂在排序按钮上，而是挂在
  `FushiPageHeader.menuAnchor` 的零尺寸锚点上：`fushi/lib/src/utils/components/fushi_material_components.dart:5037`
  （`fushiHeaderActionsWithMenuAnchor` 把锚点 `PositionedDirectional(end: 0, bottom: 0)` 叠在动作组右下角），锚点本身是
  `SizedBox.shrink()`（`fushi/lib/src/pages/implementations/tag_filter_bar.dart:466`、`games_library_page.dart:1129`），
  按钮 onTap 只调 `MenuController.open()`、不告诉锚点是谁触发的（`tag_filter_bar.dart:789`、`games_library_page.dart:1053`）。
  于是只要排序按钮不在动作组最右端（游戏库：排序后面还有筛选 / 管理标签 / 布局切换），菜单就弹在动作组右下角。
  零尺寸锚点是 658cad6e06 为「按钮可能被收进 ⋯、菜单不能挂在会被卸载的按钮上」引入的，常驻是对的，错在弹出位置也跟着常驻盒子。
- **[x] ① 已修复** — 新增 `FushiHeaderMenuController` + `FushiHeaderMenuAnchor`（`fushi/lib/src/utils/components/fushi_header_menu_anchor.dart`）：
  锚点仍常驻（铺满动作组），打开时控制器把触发控件（`FushiActionOrigin.current`：按钮自己，被收纳时是 ⋯）交给锚点，
  锚点把锚框挪到触发控件的矩形上，菜单与其他 `FushiMenuAnchor` 一样从按钮下沿弹出；三处库页全部改用它，零尺寸锚点删除。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_page_header_menu_anchor_test.dart`（排序按钮不在最右端时菜单左沿对齐按钮 /
  外壳浮动工具栏胶囊里同样对齐 / 收进 ⋯ 后从 ⋯ 下方弹出 / 菜单项可点；修复前同款断言实测红：菜单左沿 719.6、按钮左沿 666.9）；
  `fushi/test/widgets/zero_size_menu_anchor_guard_test.dart`（源码守卫：`lib/` 禁止 `child: SizedBox.shrink()` 的 MenuAnchor）。
- **备注**：真机 / 桌面肉眼复测未做。
