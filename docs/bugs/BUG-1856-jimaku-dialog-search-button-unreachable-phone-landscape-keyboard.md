## BUG-1856 · Jimaku 获取字幕对话框在手机横屏弹键盘时只看得见「取消」，搜索按钮藏在可滚区不可达
- **报告**：2026-08-25（用户：iPhone 横屏截图，点「集数（可选）」弹出数字键盘后整个对话框只剩标题、半个输入框和「取消」）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/jimaku_subtitle_dialog.dart:1023-1030`（改前 `_buildFilterPane`）把唯一主操作「搜索」`FilledButton` 放在 `SingleChildScrollView` 筛选面板里，底部固定栏只有「取消」。横屏 390dp 高的屏弹出 ~200dp 键盘后对话框只剩百来 dp，面板 `Flexible` 被压到只露一个输入框，按钮滚出视野；且 iOS 数字键盘（`TextInputType.number`）没有回车键，`onSubmitted` 也触发不了——主操作在该视口下结构上不可达。
- **[x] ① 已修复** — 搜索按钮移到底部固定操作栏与「取消」并排（`Row` 右对齐：取消 · 搜索），面板只留输入与筛选。提交见 PR。
- **[x] ② 已加自动化测试** — `fushi/test/pages/jimaku_two_pane_layout_test.dart`：①「搜索与取消同一行、在取消右侧、不在 SingleChildScrollView 内」；② 回归用例复刻 844×390 横屏 + `viewInsets.bottom=200` 键盘，断言搜索按钮完整落在键盘上方、`onPressed` 非空、`hitTestOnBinding` 真能命中。变异实测：把按钮挪回面板，两条都红。
- **备注**：旧测试「search button lives in filter pane」是上一轮按手绘稿定的排版（KEY→TITLE→SEARCH 同栏），本轮以「主操作必须在非滚动槽位」取代它。未做 iOS 真机复测。
