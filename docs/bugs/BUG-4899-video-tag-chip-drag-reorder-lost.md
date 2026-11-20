## BUG-4899 · 视频库标签条拖动排序在桌面鼠标下失效
- **报告**：2026-11-15（用户：「我的标签拖动功能怎么没了」「这个没了不如删了」；拼贴改版评审设计稿 V3）
- **真实性**：✅ 真 bug（沿真实代码路径定位；未在真机复现，见备注）。
  - 先查是不是有提交删掉了拖动：`tag_filter_bar.dart` 的 `LongPressDraggable<BookTagRow>` + `DragTarget` 重排路径自 247fc429403（2026-09-09）起未改；视频页 `_buildTagFilterBar` 传 `onReorder: _reorderTags` 的接线自 497a2260900（2026-10-25）起只有缩进变化。**没有删除拖动的提交**，代码路径完整（本地是浅克隆，更早的历史经 GitHub API 逐提交核对 patch）。
  - 根因是手势竞技场：`fushi/lib/src/pages/implementations/tag_filter_bar.dart:289` 标签 chip 只有 `LongPressDraggable` 一条重排路径，它住在 `tag_filter_bar.dart:248` 的 `HorizontalDragScrollable` 横向 `ListView` 里（鼠标按住拖 = 横滚）。鼠标是精确指针，`computeHitSlop(mouse)` = `kPrecisePointerHitSlop` = 1 px：长按 500 ms 计时内手一抖超过 1 px，`DelayedMultiDragGestureRecognizer.checkForResolutionAfterMove` 自行 `rejected`，同一下位移让 Scrollable 的横向 drag recognizer（同为 1 px 门槛）胜出——桌面用户按住标签拖，看到的是标签条在滚、标签不动，表现为「拖动功能没了」。触屏 slop 是 18 px，不受影响。
- **[x] ① 已修复** — 「⋮⋮」拖动柄组件 `fushi/lib/src/media/tags/tag_drag_handle.dart`（`FushiTagDragHandle`，即时 `Draggable`：柄比滚动区深，指针路由先到它，越过 slop 的同一帧先认领，横滚抢不到）已接入 `fushi/lib/src/pages/implementations/tag_filter_bar.dart`（书架 / 视频 / 游戏库共用）：非多选时每枚 chip 左侧加柄，原 `DragTarget` 落点不变，`LongPressDraggable` 保留给触屏长按整枚 chip。
- **[x] ② 已加自动化测试** — `fushi/test/pages/tag_filter_bar_drag_handle_test.dart`（接入层：每枚标签有柄、多选隐藏；鼠标在柄上按下即拖、放到另一枚标签触发 `onReorder(0, 2)`）+ `fushi/test/media/tags/tag_drag_handle_test.dart`：复现根因（长按 chip + 鼠标 2 px 抖动 → 拖动认输、列表被横滚）+ 拖动柄鼠标 / 触屏按下即拖、放到另一枚标签触发重排、列表不滚。
- **备注**：仍需桌面真机（Windows，鼠标）复测视频库 / 书架标签条拖动重排（收尾集成时未跑真机与测试）。
