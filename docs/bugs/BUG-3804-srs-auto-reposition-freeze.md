## BUG-3804 · 制卡后自动重排卡死白屏、同步也卡
- **报告**：2026-10-28（用户反馈：电脑上制卡，一自动重排就卡住、白屏、无响应，同步也卡）
- **真实性**：✅ 真 bug。① `fushi/lib/src/anki/anki_deck_reposition.dart` `planCardPositions` 每次把整组新卡重编号 1..N，插入一张就让其后全部卡位置 +1，经 `SrsMiningAnkiRepository.setNewCardPositions` → `SrsDbStore.setNewCardPositions` 每张写一条 `newPos` 修改记录进同步发件箱（实测 2000 张新卡插 1 张 = 998 条）；`apply` 还重发位置没变的卡、写回前整组重读并物化笔记。② `fushi/lib/src/anki/anki_deck_reposition_runner.dart` `plan` 每次在 UI isolate 上对整组每张卡同步查词典（每 32 张才让出一次）。
- **[x] ① 已修复** — 复习侧改用最少移动的位置分配（`packages/fushi_engine/lib/srs/srs_new_card_positions.dart`，之后每挖一张只写 1 条）；只写真正要动的卡；写回前只读卡 id；词典 rank 按（词典集合, 选项）跨次缓存、只查新卡；按耗时（8 ms）让出事件循环。AnkiConnect 路径仍是 1..N。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/srs_new_card_positions_test.dart`、`fushi/test/anki/anki_deck_reposition_test.dart`（含词典 rank 缓存用例）、`fushi/test/srs/srs_mining_test.dart`。
- **备注**：老牌组升级后头 1–2 次自动重排合计约写 1.5N 条，之后降到每次 O(1)。未在真机复测。
