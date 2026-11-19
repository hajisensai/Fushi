## BUG-4778 · 文本导入某一批落库抛异常时这一批刚建的牌组留成空牌组
- **报告**：2026-11-17（PR #3653 审查：BUG-4780 修复后剩下的窄窗口，原只写在 BUG-4780 备注里）
- **真实性**：✅ 真缺陷（代码路径推得，未单独复现）。`packages/fushi_engine/lib/srs/text/srs_text_import.dart` `flush()` 先对本批每条新笔记 `deckOf` → `SrsDbStore.ensureDeckPath`（`packages/fushi_engine/lib/srs/srs_db_store.dart:3570`，内部 `createDeck` 各自一个 `_emit` 事务），再单独一次 `importDrafts`（`srs_db_store.dart:2395`）写笔记；两者不在同一事务里，`importDrafts` 抛异常时刚建出的牌组已落库，留成空牌组。叫停与跳过的行已由 BUG-4780 处理，不会留。
- **[ ] ① 未修复** — 方向：让牌组创建出草稿（类似 `newNoteDrafts` 的牌组版），与本批笔记草稿合进同一次 `importDrafts`；涉及 `createDeck` / `ensureDeckPath` 的写入通道与复活已删除牌组的语义，需单独设计。
- **[ ] ② 未加自动化测试** — 修时在 `packages/fushi_engine/test/srs/text/srs_text_import_test.dart` 注入一批落库失败，断言新牌组不残留。
- **备注**：影响面窄（只在落库本身出错时出现，结果是多一个空牌组，不丢数据）。
