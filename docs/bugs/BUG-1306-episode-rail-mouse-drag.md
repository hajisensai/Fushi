## BUG-1306 · 选集横排无法鼠标拖动滚动（漏包共享横滚件）
- **曾用号**：本条一度取到 BUG-1303，因并发 PR #624 抢注而改为 1306。
- **报告**：2026-08-01（用户：「这里的集，没办法鼠标拖动欸」）
- **真实性**：✅ 真 bug — 根因 `hibiki/lib/src/media/video/video_episode_rail.dart:99`
  （修复前）：`ListView.separated` 直接裸用，没有任何 `ScrollConfiguration` 包裹。

  Flutter 桌面的默认 `MaterialScrollBehavior.dragDevices` **不含**
  `PointerDeviceKind.mouse` —— 横向滚动区用鼠标左键按住左右拖**毫无反应**。

  仓库对这件事早有定论并已收口成两个共享件（`platform_utils.dart`）：
  - `HorizontalDragScrollable` —— 放开 mouse/trackpad/stylus 拖动；
  - `WheelToHorizontalScroll` —— 物理滚轮发的是 `(0, dy)`，而 `Scrollable` 按自身
    轴取分量（横向只取 `dx`），裸滚轮对横向区同样没反应（BUG-1214）。

  合集横排行（`collection_shelf_row.dart`）、标签筛选栏、首页横排都已包了这两件，
  **唯独这条剧集轨漏包** —— 于是同一种横排在库页拖得动、进了合集详情页就拖不动。

- **[x] ① 已修复** — `video_episode_rail.dart` 的 `ListView.separated` 包上
  `WheelToHorizontalScroll(controller: _controller)` + `HorizontalDragScrollable`，
  并补 `physics: desktopAwareScrollPhysics()`（与合集横排行完全同构）。
  是接上仓库既有的共享方案，不新造机制。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_episode_rail_drag_test.dart`
  （3 例）：**鼠标**拖动后 `ScrollController.offset` 真的变大（断言真滚动行为，
  不是「包了某个 widget」的结构断言 —— 后者在共享件换实现时会假绿）；触屏拖动
  照旧可用（放开鼠标不得破坏原有输入）；内容不足一屏时不越界。

  用例的关键在 `kind: PointerDeviceKind.mouse` —— `tester.drag` 不指定 kind 时默认
  发 touch 事件，而 touch 本就在默认 `dragDevices` 里，**测不出这个 bug**。

- **备注**：同一批用户反馈里的其余两项见
  [BUG-1298](BUG-1298-collection-hero-portrait-cover.md)（hero 竖版海报被裁）与
  [BUG-1305](BUG-1305-collection-scrape-metadata.md)（合集刮削资料无宿主 / 名字不回写）。
