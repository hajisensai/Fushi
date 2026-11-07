## BUG-4219 · shelf-columns-shrink-regression
- **报告**：2026-11-07（用户：群反馈「更新完页面显示 80% 但书没有缩小」——v3.3.0 起安卓手机 80% 界面缩放下书架从 3 列掉成 2 列，70% 才回到 3 列但字太小）
- **真实性**：✅ 真 bug。`81d0317f468`（10-30，「continue hero aligns to the third cover」）给书架网格加左右各 `spacing.gap`(8) 的内缩，`_shelfCardLayout` 同时把列数改按内缩后的宽算：`reader_fushi_history_page.dart` `_shelfCardLayout` 里 `availableWidth: constraints.maxWidth - gridInset * 2`。列数 = 宽 ÷ 150 向下取整，360dp 手机 80% 缩放逻辑宽 450 → 旧 450/150 = 3 列，新 434/150 = 2.89 → 2 列；要 3 列得 ≥ 373dp。
- **[x] ① 已修复** — 新增 `collection_shelf_row.dart` `shelfGridCardLayout`：自动列数按整个内容宽算，内缩只从格宽里扣（内缩本是视觉对齐，不该改列数）。同一 PR 加库页「每行数量」选项（书架 / 漫画 / 视频 / 游戏，按库 × 尺寸档设备本地记，`library_grid_columns.dart`），窄屏排序按钮改开「排序与显示」底部抽屉（`library_view_options.dart`），书架格宽 < 130dp 时格子内边距减半（`shelfGridCellInsetFor`）。
  - 同 PR 修材质溢出（用户试用 3 / 4 列时截图，2 列也偶发）：书架网格格子用固定比例 `kShelfBookCardAspectRatio`（180/320），封面区 = 格高 − 固定高的文字块，格宽一偏离设计值封面区就不是书封比例，封面按高度适配后两侧露出材质衬底（窄格）或被裁（宽格）。改为 `shelf_card_widgets.dart` `shelfBookCellAspectRatio` 按格宽现算（封面区恒 1:1.42，格高 = 内边距 + 封面高 + 文字块），书架主网格 / 排序网格 / 合集详情页书卡同用。
- **[x] ② 已加自动化测试** — `test/pages/library_grid_columns_test.dart`：450 逻辑宽自动 3 列 / 360 仍 2 列 / 固定列数 / 偏好表分格与坏值 / 设备本地 / 抽屉点选不关且重画。
- **备注**：未上真机复测（本机无该型号；改动是纯几何计算，单测钉住了失败路径的数值）。
