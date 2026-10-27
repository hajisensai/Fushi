## BUG-3801 · collection-longpress-haptic
- **报告**：2026-10-27（用户：「合集内长按震动反馈没有而且和外部书架不一致视频也是，另外轻触和长按都要有那个柔和光面效果」）
- **真实性**：✅ 真 bug，两条根因：
  1. 合集成员拖排网格（`media_collection_grid_detail_page.dart`，手动序无筛选时）与视频合集集卡网格（`media_collection_detail_page.dart` `_buildEpisodeGrid`）都走 `FushiReorderableGrid`，触摸长按是裸 `LongPressGestureRecognizer`（`fushi/lib/src/utils/components/fushi_reorderable_grid.dart` `_touchLongPressStart`），卡片整张包在 `IgnorePointer` 里。外面库页卡片走 `InkWell.onLongPress`，自带 `Feedback.forLongPress`（Android 震动 / iOS 重触感 + 点击音），网格这条路径一下都没有。轻点同理缺 `Feedback.forTap`。
  2. 封面柔光扫过 `ShelfCoverSheen`（`fushi/lib/src/utils/components/shelf_cover_material.dart`）只认 `FushiHoverLift` 的悬停态，触屏没有悬停，轻触 / 长按永远看不到；合集网格里卡片又被 `IgnorePointer` 挡住，连按压缩放都收不到。
- **[x] ① 已修复** — `FushiReorderableGrid` 长按识别时调 `Feedback.forLongPress`、轻点调 `Feedback.forTap`，并在单元外包 `FushiPressScale(behavior: opaque)` 代收按压；`FushiPressScale` 新增「按下确认」脉冲（按住满 `kPressTimeout` 或原地快速松手各发一次，滑走不发，与祖先脉冲相加透传），`ShelfCoverSheen` 看到脉冲变化就完整扫一遍光、扫完悄悄归位（叠层后几本 `pressGlint: false` 不闪）；非拖排成员格 `_MemberGridTile` 也包一层 `FushiPressScale` 代收。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/press_feedback_glint_test.dart`（网格长按震 / 轻点不震 / IgnorePointer 卡片收得到脉冲；脉冲轻触 / 长按 / 滑走 / 嵌套透传；扫光轻触扫过并归位、`glint: false` 不响应）。
- **备注**：脉冲作用于所有带 `FushiHoverLift` 的材质封面卡，外面库页的轻触 / 长按同样会扫光。
