## BUG-666 · 编辑排序模式：合集分组框看不见、减号删除后书籍消失、减号遮挡类型徽章
- **报告**：2026-07-09（用户复诉，前修 TODO-947/BUG-651 只做了框可见性、没命中「移出」与「遮挡」）
- **真实性**：✅ 真 bug（三处，均在书架「编辑排序」= `_openShelfSort` → `ShelfReorderPage` 内联展开系列成员这条路径）

三处根因（develop 8ed9b92da）：

- **① 合集分组框看不见**：`SeriesReorderFrame`（`hibiki/lib/src/pages/implementations/series_shelf_card.dart:334`）只靠成员卡自带 12px 内边距漏出一圈 alpha 0.32 的 matte + 3px 前景细线。用 RepaintBoundary 取像素实测：手机默认 `HibikiAppUiScale` FittedBox 缩放 s≈0.65 下，那圈只剩 ~6px、matte premultiply 后 ~82/255、边框只剩 ~2px 同色细线 —— 用户读作「没有框」。**非「框没画」而是「太淡看不清」**（前修 BUG-651 已让它可见但强度不够）。
- **② 点减号「移出系列」后书籍消失**：`_ShelfReorderPageState._onRemoveOutside`（`hibiki/lib/src/pages/implementations/shelf_reorder_page.dart`）移出成员后走 `setState(() => _items.removeAt(index))` 把整条丢弃。可移出的成员其实只是被移出系列、变回一本**散书**，本应就地留在编辑排序列表里；`removeAt` 让它凭空消失（用户报「书籍不会恢复到编辑排序里面」）。根因是「分组框被预先烘进 `ShelfReorderItem.card`」→ 移出时无法把成员降级成无框散书卡，只能整条删。
- **③ 减号图标遮挡书籍类型徽章**：网格 `_buildCell`（`hibiki/lib/src/utils/components/hibiki_reorderable_grid.dart:494`）把移出按钮固定放 `PositionedDirectional(top:0, end:0)`（右上角）；书卡的类型徽章 `coverBadge`（`hibiki/lib/src/pages/implementations/reader_history/card_widgets.part.dart:348`）也在封面右上角 → ~40px 按钮正压住 22px 类型徽章。

- **[x] ① 根因修复** — 三处：
  - ①：`SeriesReorderFrame` 把框做「厚」（`series_shelf_card.dart`）——额外内缩 `_kSeriesFrameInset=4` 让实心 matte 有保证宽度的可见色带、matte alpha 0.32→0.55、边框 3→4；RepaintBoundary 取像素复测 s=0.65 下边框实心 255、matte 色带 ~8px@140/255（改前 ~6px@82）。
  - ②：把「是否套框 + 框参数」从 `card` 里拆出成 `ShelfReorderItem.seriesFrame`（新 `SeriesFrameData`），框由 `ShelfReorderPage._buildItemCard` 据此叠加；`_onRemoveOutside` 改 `_items[index] = copyAsLoose()`（清 seriesId + seriesFrame）就地把成员降级为无框散书卡留在列表里。`_buildSortItems`（`reader_hibiki_history_page.dart`）随之只传 `seriesFrame` 参数、不再预烘框。
  - ③：网格 overlay 改 `Positioned.fill` 交调用方自定位；`_buildRemoveOverlay` 放封面**右下角**（`AlignmentDirectional.bottomEnd` + `overlayCornerBottomInset=kShelfTitleFooterHeight` 抬过标题 footer），避开右上角类型徽章 + 左上角系列名 header。
  - 提交：432ec5c33
- **[x] ② 加自动化测试** — `hibiki/test/pages/shelf_reorder_series_inline_test.dart`（widget 行为守卫）：
  - ②「点移出系列后成员降级为散书就地留在列表（不消失、脱框）」：移出首成员后 `SeriesReorderFrame` 2→1、移出按钮 2→1，三张卡（含被移出的）都还在。
  - ③「移出按钮落在封面右下角（不遮挡右上角类型徽章 / 左上角 header）」：断言按钮几何中心在格的下半 + 右半。
  - ①「分组框：实心 matte 背景 + ≥3px 同色边框都在」既有可视化守卫（matte alpha>0 + 边框≥3）随强度提升仍绿。
  - 全文件 7 用例绿 + `hibiki_reorderable_grid_test.dart` 15 用例绿 + 全量 `flutter analyze` 净。
- **备注**：只碰「编辑排序模式」相关代码，未动进度条显示（TODO-1346 并发）。视频库排序 `_openVideoSort` 不传 seriesFrame/onRemove → 无框无移出，零回归。
