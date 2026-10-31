## BUG-3892 · 「从所有设备删除」不勾时副标题写「其他设备保留」，读成自相矛盾
- **报告**：2026-10-31（反馈 TXKXSgDhP6：「从所有设备上删除这个名字不对吧，从所有设备删除，其他设备保留，这不是自相矛盾吗」）
- **真实性**：✅ 真 bug。删除确认框的勾选行标题恒为 `delete_scope_sync_everywhere`「从所有设备删除」，副标题却随勾选翻面：不勾时换成 `delete_scope_keep_local_desc`「其他设备保留」。两行并排读成「从所有设备删除 / 其他设备保留」。两份独立实现都这样写：书架 `fushi/lib/src/pages/implementations/reader_history/dialogs.part.dart:138-141`（`ReaderHistoryDeleteDialog`）与通用 `fushi/lib/src/sync/deletion_prompt.dart:189-192`（`showDeleteScopeConfirm`）。
- **[x] ① 已修复** — 副标题改成不随勾选翻面的条件句：`delete_scope_sync_everywhere_desc` =「勾选后，其他设备下次同步时会确认删除；不勾选则其他设备保留」（en「If checked, other devices confirm the deletion on their next sync; if not, they keep their copy」）。两处实现同改；不再使用的 `delete_scope_keep_local_desc` 经 `i18n_sync --remove` 删掉。其余 14 种语言把各自已有的两句译文（「同步时确认删除」+「其他设备保留」）合成同一条件句，没有回落成英文。
- **[x] ② 已加自动化测试** — `fushi/test/sync/delete_scope_no_channel_widget_test.dart` 新组「副标题是条件句（TXKXSgDhP6）」：书架删除框与通用弹窗各一条，来回切勾选，副标题始终是同一条件句。
- **备注**：标题「从所有设备删除」保留——它是勾选框，勾与不勾已经由控件状态表达。
