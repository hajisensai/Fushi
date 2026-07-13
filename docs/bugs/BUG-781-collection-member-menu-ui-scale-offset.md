## BUG-781 · 合集详情页成员右键菜单未按界面缩放换算坐标错位
- **报告**：2026-07-13（用户：「合集内右键菜单没吃界面大小」，Windows 真机反馈）
- **真实性**：✅ 真 bug，BUG-129/261/381 同族缺陷的复发。根因链：
  - `hibiki/lib/src/pages/implementations/media_collection_grid_detail_page.dart` 的 `_showMemberMenu`（修复前 254-265 行）把网格右键 / 长按回调报的 `globalPosition`（真实视口坐标系）直接当 Overlay 本地坐标喂给 `showMenu` 的 `RelativeRect`；
  - 全局 `HibikiAppUiScale`（`hibiki/lib/src/utils/app_ui_scale.dart`，FittedBox 整体缩放）挂在 MaterialApp.builder，根 Navigator 的 Overlay 落在缩放画布坐标系内，两套坐标差 factor≈scale → 界面大小≠100% 时菜单偏离点击点约「点击坐标 ×(1−scale)」（scale=0.5 时约落在点击坐标的一半、数百像素）；
  - 标准修法早有先例：`hibiki/lib/src/pages/implementations/reader_hibiki/chrome.part.dart`（BUG-381，195-216 行）用 `overlay.globalToLocal(globalPosition)` 沿真实渲染变换链换算——阅读器内联图片右键菜单已如此修，合集详情页新写的成员菜单未沿用，踩回已知雷。
- **[x] ① 已修复** — `_showMemberMenu` 在拿到 Overlay 的 `RenderBox` 后加 `final Offset anchor = overlay.globalToLocal(globalPosition);`，`RelativeRect` 改用 `anchor`；FittedBox 缩放被 render transform 自动吸收，对任意 scale 自洽，scale=1 时为单位阵零行为变化（向后兼容）。顺手核查并修同族残留 `hibiki/lib/src/pages/implementations/illustrations_viewer_page.dart` 的 `_showImageContextMenu`（同样把 `globalPosition.dx/dy` 直当 Overlay 本地坐标，缺 `globalToLocal`）——同一修法修掉。提交 8f9334b06。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/media_collection_grid_detail_menu_scale_test.dart`：复刻生产拓扑（MaterialApp.builder 注入 `HibikiAppUiScale(scale: 0.5)`），真鼠标右键点成员卡中心，断言弹出菜单第一项渲染位置（真实屏幕坐标）与点击点距离 < 48 逻辑像素；修复前 scale=0.5 下会偏离约点击坐标的一半（数百像素），阈值明确区分修复前后。提交 8f9334b06。
- **备注**：菜单内容本身经缩放画布渲染，视觉尺寸随界面大小同比；本修只纠正锚点坐标系。同族已修点：BUG-381（阅读器内联图片右键，chrome.part.dart）、BUG-778（合集详情拖拽排序）。真机需复测缩放≠100% 下右键 / 触摸长按弹菜单贴手。
