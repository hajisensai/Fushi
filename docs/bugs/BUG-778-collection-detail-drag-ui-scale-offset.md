## BUG-778 · 合集详情页拖拽排序不吃界面大小缩放拖动位置错位
- **报告**：2026-07-13（用户：「合集里面好像没吃界面大小缩放，导致拖动位置错误」，PR#41 真机测试反馈）
- **真实性**：✅ 真 bug，已知 SDK 缺陷的复发。根因链：
  - `hibiki/lib/src/pages/implementations/media_collection_detail_page.dart`（排序交互重设计 a16aec742 前身引入）用 SDK `ReorderableListView.builder` 做拖拽排集；
  - Flutter SDK 的拖拽代理（`reorderable_list.dart` `_DragItemProxy`）用「全局坐标 − overlay 原点」纯平移把浮层放进 Overlay 本地坐标系，**不认祖先缩放变换**；「界面大小」是 `HibikiAppUiScale` 的 `Transform.scale` 整体缩放 → 缩放≠100% 时拖动落点按 `(1−s)×(指针到 overlay 原点距离)` 漂移；
  - 仓库对该缺陷早有正解组件 `hibiki/lib/src/utils/components/hibiki_reorderable_column.dart`（`HibikiReorderableColumn`，类注释即为此缺陷而写：浮层渲染在列表自身 Stack、指针经 `globalToLocal` 消祖先缩放；词典排序/媒体源排序在用）——排序重设计时未沿用，踩回已知雷。
- **[x] ① 已修复** — 详情页换 `HibikiReorderableColumn`（`SingleChildScrollView` 承担滚动）：整行拖拽（鼠标按下即拖 / 触摸长按，组件内建设备区分），行尾拖柄图标保留为纯视觉提示；`_onReorder` 去掉 SDK「移除前下标」修正（组件回调即最终下标）。守卫加「SDK Reorderable 使用 token 不得回潮」禁令。提交 43c8d5046。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/media_collection_detail_sort_test.dart` 拖拽用例改长按整行手势（真写穿 `getCollectionItems` 的 sortIndex 断言不变）+ `unified_collections_architecture_guard_test.dart` 源码守卫（必须 HibikiReorderableColumn、禁 `ReorderableListView.builder(`/`ReorderableDragStartListener(` 等使用 token）。提交 43c8d5046。
- **备注**：widget 测试在 scale=1 下验语义与写穿；缩放≠100% 的坐标数学由 `HibikiReorderableColumn` 既有 `globalToLocal` 路径保证（与词典排序共用），实际拖动手感需真机复测。长列表拖拽时无 SDK 的边缘自动滚动（与词典排序同边界，真机确认是否需要）。
