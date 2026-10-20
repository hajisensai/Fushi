## BUG-3647 · srs-deck-delete-no-delete-cards-option
- **报告**：2026-10-21（用户：「这个删除牌组哪有强制把卡片留下的」，附删除牌组对话框截图）
- **真实性**：✅ 真 bug。`SrsDbStore.deleteDeck`（`packages/fushi_engine/lib/srs/srs_db_store.dart`）只有「卡片移到上级牌组」一条路，删除牌组对话框（`fushi/lib/src/pages/implementations/srs/srs_deck_list_page.dart` `_delete`）也只给一个确认键；Anki 的删除牌组是连卡片一起删，用户无法删掉牌组里的卡。
- **[x] ① 已修复** — `deleteDeck` 加 `deleteCards`：先删掉卡全都在被删子树里的笔记（`_notesOnlyInDecks`，分块独占区；收尾独占区里对迟到的卡同样处理），再照旧移走子树里的卡（已删笔记的卡隐藏着，移走只为「恢复笔记」后不落在已删除牌组）。Fushi 只能整条删笔记，所以在子树外还有卡的笔记不删。对话框改成二选一：保留卡片（移到上级）/ 连卡片一起删除。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/srs_db_store_test.dart`「删除牌组可连卡片一起删：子树里的笔记删除，别处的笔记不动」。
- **备注**：
