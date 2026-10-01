## BUG-2834 · 全 app 鼠标滚轮一格一跳：除正文阅读器外的列表 / 查词弹窗都不是无极滚动
- **报告**：2026-10-01（用户：「不只小说，查词框，统计，观看历史等所有滚轮都改成无极滚轮」，接 BUG-2830 正文滚动模式无极滚轮之后）
- **真实性**：✅ 真 bug，三处各自的根因：
  1. **Flutter 列表（统计 / 观看历史 / 设置 / 书架 …）**：Flutter 的 `ScrollPositionWithSingleContext.pointerScroll` 把一格 delta 单帧 `forcePixels` 过去。仓里旧方案 `FushiScrollController`（`fushi/lib/src/utils/misc/platform_utils.dart:95`，BUG-1959/1960）改写 `pointerScroll` 补间，但它只在**显式接了这个控制器**的滚动区生效——全仓约 300 个滚动视图只有 3 个接了；没写控制器的 ListView 走 `Scrollable` 内部写死的 `ScrollController()`，根本接不进去，所以统计页、观看历史等全部一格一跳。
  2. **查词弹窗（app 内弹窗 WebView + 浏览器扩展）**：`fushi/assets/popup/popup.js` 的 wheel 监听为了统一步长 `preventDefault` 接管滚动，再 `scrollBy({behavior:'auto'})` 一步落地——浏览器原生的平滑滚动被它自己关掉了，粗滚轮一格瞬跳 48px。
  3. **漫画放大平移**：`fushi/lib/src/media/manga/manga_overlay_html.dart` 跨页模式 ZOOM>1 的滚轮走 `_panBy(-wdx, -wdy)` 一步写完 PAN，同样瞬跳。
- **[x] ① 已修复** —
  - Flutter：新增根部 `SmoothWheelScrollScope`（`fushi/lib/src/utils/misc/smooth_wheel_scroll.dart:41`），挂在主 app（`fushi/lib/main.dart:2433`）与弹窗词典入口（`fushi/lib/popup_main.dart:248`）的 MaterialApp builder 上。根 `Listener` 在 `PointerSignalResolver` 裁决前收到滚轮事件，裁决时胜出的 Scrollable 同步发 `ScrollUpdateNotification` 报出「哪个 position、从哪到哪」，同一任务的 microtask 里拉回起点再 `animateTo` 补间（不出帧不闪）；连拨同向从未到达的目标累加、反拨从视觉位置起步、只认指针下的滚动区、吸附式（PageView）与关闭动画时保持原生。距离 1:1 不变（BUG-2009），细指针手势按手势锁定走同步。删除 `FushiScrollController`，三处接线改回普通 `ScrollController`——全仓只剩这一套滚轮处理。
  - 查词弹窗：`popup.js` 粗滚轮一格改为 `popupWheelEaseBy`（`popup.js:6166`，rAF 指数缓动 0.18 / 0.5px 收尾，与正文 `kContinuousWheelScrollJs` 同手感），连拨累加、外部滚动让位、贴边停；触控板 / 高精度滚轮仍 1:1 同步，墨水屏瞬时模式不缓动。三份 popup.js（app 内 / app 内扩展 vendor / `tools/browser-extension/vendor`）逐字节同步。
  - 漫画：`_wheelPanEase`（`manga_overlay_html.dart:1934`）——落点仍由 `_panBy` 一步算出（钳制只住在 `_panBy`），同一任务内撤回，再逐帧经 `_panBy` 推过去；拖动 / 方向键 / 缩放 / 贴边翻页改了 PAN 就让位；贴边后的翻页累计（BUG-1760）不变，飞向边缘途中不翻页。
- **[x] ② 已加自动化测试** —
  - `fushi/test/utils/misc/smooth_wheel_scroll_scope_test.dart`（原 `desktop_wheel_scroll_controller_test.dart` 改写）：分帧到达、无控制器 ListView 也补间、无本层的对照组单帧跳、连拨累加、反拨、细 delta 手势同步、小尾帧不掐断、静默重分类、惯性取消不丢距离、钳边、PageView 不插手、跟随者不被误动，外加主 app / 弹窗入口接线守卫与「不得复活按控制器接线的平行实现」守卫。变异实测：`_ease` 直接返回 → 4 红；去掉吸附判据 → PageView 用例红。
  - `fushi/test/reader/popup_wheel_scroll_behavior_test.js`：rAF 改为排队逐帧推进，新增 5 例（一格不瞬跳且多帧到 48px、连拨 3 格 = 144、反拨、外部滚动让位、触控板不缓动）；变异实测（去掉缓动分支）2 红。`tools/browser-extension/popup-wheel-lazy.test.js` 桩改为真实移动 `scrollTop` + rAF 排队。
  - `fushi/test/media/manga/manga_wheel_pan_ease_js_test.dart`：node 执行生成文档里真实的 `_clampPan` / `_panBy` / 滚轮监听，5 例（分帧到位、连拨累加 + 钳边、贴边翻页语义不变、外部改 PAN 让位、反拨）；变异实测（缓动直接返回）3 红。
- **备注**：未在 Mac 真机 / Windows 真机手测，只有 widget 测试与 node 行为测试。残留：Flutter 层的补间是「同任务内先跳到落点再拉回」，滚动监听在同一任务里会看到一对多余的 update 通知（不出帧，画面上看不见）。滚动揭示 / 视差 / 滚动进度 / 平滑滚动到 等动效属于另一类需求，不在本条。
