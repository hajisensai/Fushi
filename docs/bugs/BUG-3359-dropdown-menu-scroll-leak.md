## BUG-3359 · 下拉选择框（漫画源等）滚轮滚不动、页面顶栏反而跟着收起
- **报告**：2026-10-14（应用内反馈 uYumRL_Gwe「选择漫画源的时候滚动，无法向下滚动，并且顶部栏会向上滚动。可能同类选择框也有此类问题」）
- **真实性**：✅ 真 bug。漫画「发现」页的来源下拉是 `FushiDropdownMenu`（MD3 下即 `DropdownMenu`，`fushi/lib/src/utils/components/glass/fushi_glass_overlays.dart`）。它的面板是 `MenuAnchor` 的 OverlayPortal 浮层：渲染上画在 Overlay 里，**元素树上仍是锚点的后代**，面板 `SingleChildScrollView` 的滚动通知因此一路冒泡进页面。页面层的「滚动收起」监听（库页浮动顶栏 / `FushiPageScaffold` 页头）把它当正文滚动 → 顶栏收起；收起改了版式、下拉被重建，而 `DropdownMenu` 每次 build 都会在下一帧 `scrollToHighlight` 把列表滚回当前选中项 → 怎么拨都停在顶上。所有 `FushiDropdownMenu` / `FushiMenuAnchor` 选择框同病。
- **[x] ① 已修复** — 新增 `fushi/lib/src/utils/components/menu_overlay_scroll_boundary.dart`：在锚点这一层截住浮层冒出来的滚动通知（锚点自身子树里的滚动照常冒泡），被截下的滚动更新经 `SmoothWheelScrollScope.observeIsolatedScrollUpdate` 仍交给根部滚轮补间。`FushiDropdownMenu`（MD3 分支，`fushi_glass_overlays.dart:3481`）与 `FushiMenuAnchor`（`fushi_glass_overlays.dart:2959`，两套设计系统都经它）统一包上，`GamepadMenuDropdown` / `FushiDropdown` 等同类选择框随之受益。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/menu_overlay_scroll_boundary_test.dart`（下拉面板滚轮能滚、通知不冒泡进页面；`FushiMenuAnchor` 面板截下、锚点自身滚动照常冒泡）。
- **备注**：Apple 设计系统的 `FushiDropdownMenu` 走路由式 `showFushiMenu`，路由的通知本就不冒泡进页面，不受影响。
