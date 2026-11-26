## BUG-5514 · book-fan-covers-clipped-in-tall-block
- **报告**：2026-11-19（来源：应用内反馈 ONOhm9EOY3，开发者自提）
- **真实性**：✅ 真 bug。截图是书封扇形摆法（`FushiCoverBlockArt.book`，不是反馈 AI 总结推测的 portrait 叠封）。`fushi/lib/src/utils/components/fushi_cover_block.dart` `_BlockGeometry.of` 的 book 分支让书封高 = 块高 − 上下边距、绕底边中点斜放（静止 6 / −2 / −9°，悬停到 −18°），却没约束旋转后的外接框：转角让封面的角探出槽外，探出量与书封高成正比——首页「最近添加」这种高格子里最左那本的左上角与下角被色块（`ShellClip` + `Clip.hardEdge` 圆角）裁掉。
- **[x] ① 已修复** — 新增 `_poseBounds` / `_slotsBounds`（与 `_posed` 的 Transform 同一算式算四角外接框）；book 分支按静止与悬停两个姿态的总外接框约束：放不下就按比例缩书封高（书封宽随高按比例走，仍与封面同比例），再整体平移进色块，离边 `_kPosterEdgeMargin`（同背景图 + 海报摆法）。
- **[x] ② 已加自动化测试** — `fushi/test/utils/components/fushi_cover_block_book_fan_bounds_test.dart`（420×440 高格子 1 / 2 / 3 本、470×280 规整块 3 本：静止与悬停每一本的绘制外接框都在色块内）。
- **备注**：portrait 叠封的右 / 下出血是设计稿「略出血」，未改。
