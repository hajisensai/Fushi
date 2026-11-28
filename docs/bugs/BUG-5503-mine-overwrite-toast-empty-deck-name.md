## BUG-5503 · 覆盖已有卡片后提示「卡片已覆盖到『』」，牌组名为空
- **报告**：2026-11-26（用户：应用内反馈 OGj5irRpo7，Android 3.4.0-debug.32203，「重复制卡，替换的那个提示里面『』里面是空的」）
- **真实性**：✅ 真 bug。`describeMineOutcome`（`fushi/lib/src/utils/misc/error_log_service.dart`）把 `outcome.deckName ?? ''` 直接填进 `card_overwritten(deck:)` / `card_exported(deck:)`，没有「无牌组名」分支；而多条成功路径不带牌组名：
  - 复习库覆写 `SrsMiner.overwrite`（`packages/fushi_engine/lib/srs/srs_miner.dart`）只认笔记的首选牌组 `SrsNoteView.deckId`，首选牌组已删（卡片早挪到别的牌组）或为空时 → deckName null；
  - 来源回看覆写 `source_review_session.dart` `_reviewFields` 返回 `MineOutcome.success(noteId:)`；
  - 视频待写队列 `lookup_mining.part.dart` 的 `MineOutcome.success()`。
- **[x] ① 已修复** — 复习库覆写在没有首选牌组（或已删）时取卡片实际所在的牌组（`_landedDeckName`）；`describeMineOutcome` 在牌组名为空时用不带牌组名的 `card_overwritten_no_deck` / `card_exported_no_deck`，不再出空引号。
- **[x] ② 已加自动化测试** — `fushi/test/anki/describe_mine_outcome_test.dart`「success 认不出牌组名」；`fushi/test/srs/srs_mining_test.dart`「覆写首选牌组已删的笔记」：卡在别的牌组里，覆写结果的 deckName 是那个牌组的全名。
- **备注**：
