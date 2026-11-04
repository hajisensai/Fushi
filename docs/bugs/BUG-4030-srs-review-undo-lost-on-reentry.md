## BUG-4030 · SRS 退出再进复习页后无法撤销上一次评分
- **报告**：2026-11-02（应用内反馈 `Feedback: gvyN7EzzDD`：「SRS 重新进入复习页后无法撤销上一次评分」，Anki 可以）
- **真实性**：✅ 真。撤销栈是复习页 State 的字段（`fushi/lib/src/pages/implementations/srs/srs_review_page.dart:297` `final List<_UndoStep> _undo`，修复前），离开复习页 State dispose 后整栈丢失；再进复习页是新 State、空栈，撤销键不出现。Anki 的撤销挂在 collection 上，与 reviewer 窗口无关。
- **[x] ① 已修复** — 撤销栈改挂在库实例上：`fushi/lib/src/srs/srs_review_undo.dart` `SrsReviewUndoStack.of(SrsDbStore)`（`Expando`，与 store 同生命周期，上限 `kSrsReviewUndoLimit = 50`）；复习页 `_pushUndo` / `_undoLast` 只经它读写，不再自持状态。提交 `d693ba1bd2c55272363526ef3d3da48bb5f43ff7`。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_review_undo_reentry_test.dart`（真 SrsDbStore：评分 → 卸载复习页 → 同一 store 重挂，撤销键在、撤销后历史回退且卡片回到队首；栈按 store 隔离且有上限）。
- **备注**：换 profile / 重开库是新 store，撤销栈随之清空（与 Anki 换 collection 一致）。
