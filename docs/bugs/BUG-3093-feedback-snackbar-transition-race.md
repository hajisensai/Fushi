## BUG-3093 · 反馈提交测试在提交页退场动画中断言提示条数，CI 慢时数到两条
- **报告**：2026-10-09（develop CI `Build Release APK` run 37899073377 tests (2)：`feedback_pages_test.dart:330` `find.text(t.feedback_submitted)` 期望 1 个，实际 2 个；同一测试在后续 develop 提交上通过）
- **真实性**：✅ 真问题，在测试同步上，不是产品缺陷。`feedback_center_page.dart` `_compose()` 在 `Navigator.push` 的 future 完成时（提交页 pop 刚开始）`showSnackBar`；ScaffoldMessenger 在路由过渡期间把同一条 SnackBar 同时挂在退场中的提交页与中心页两个 Scaffold 上（Flutter 有意的过渡设计，退场结束后只剩一条）。测试只等「列表出现新 ticket」就断言 `findsOneWidget`，CI 慢时断言落在退场窗口内。本地探针复现：提交后首帧 `snackbars=2 composeOnTree=true`。
- **[x] ① 已修复** — `fushi/test/feedback/feedback_pages_test.dart`：按条件同步等提交页（`feedback-submit`）离开路由树、并显式断言 `findsNothing` 后再数提示条，不加固定延时。
- **[x] ② 已加自动化测试** — 即上述测试本身（本地连跑多次全绿；探针确认退场窗口内确为 2 条）。
- **备注**：flaky 不是根因；同类「在路由过渡中数 SnackBar」的断言都应先等前一路由离树。
