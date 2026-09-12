## BUG-2483 · 已制卡候选与卡片查看器重复堆叠弹窗
- **报告**：2026-09-10（用户截图显示“卡片已在 Anki 中”候选框上又出现“已存在的卡片”查看器，要求来源回跳改卡复用该界面并消除重复弹窗）
- **真实性**：✅ 真 bug。`fushi/lib/src/anki/anki_mined_card_action_sheet.dart:147` 的 `_MinedCardActionDialogState._viewNote` 原先在候选对话框仍打开时调用 `showAnkiNoteViewer`，后者再次 `showDialog`，确定性叠加两层 DialogRoute；关闭查看器还会留下底层候选框。
- **[x] ① 已修复** — 候选到查看器改为同一路由内的状态切换，返回候选只替换内容，关闭查看器结束整次操作。提取共享字段组件和来源字段编辑／差异选择入口，展开显示完整内容、只返回明确选中的字段，保留已有宿主隐藏原生查词弹窗的机制。与卡片来源回跳功能在同一提交交付。
- **[x] ② 已加自动化测试** — `fushi/test/pages/anki_mined_card_action_sheet_widget_test.dart` 验证候选转查看器后（含 offstage）仅一个 AlertDialog、关闭后没有残留候选框；同时验证来源差异可展开完整长字段、只提交勾选字段、编辑器保留未改字段和 HTML。Flutter 3.44.0 实际执行该文件 9 条 widget 测试全部通过；`sentence_context_dialog_zorder_guard_test.dart` 对等适配多行格式后 3 条守卫通过。
- **运行证据**：Windows 真应用运行 `win-itest-20260910-090647-7240832e` 实际执行 1 个业务用例并退出 0，已捕获并检查 `card-source-single-note-dialog.png`，确认候选切换详情后（含 offstage）只有一个 AlertDialog，关闭动画结束后无残留。Android 同一业务用例也退出 0（PASS 1 / FAIL 0）。使用隔离 Anki 仓库夹具验证宿主界面，不修改用户的真实 Anki 集合；原生查词层隐藏机制另由既有 z-order 守卫覆盖。完整跨平台用例为 `fushi/integration_test/card_source_return_test.dart`。Android 截图在测试工具默认卸载清理中丢失，仅保留成功日志和用例断言证据。
