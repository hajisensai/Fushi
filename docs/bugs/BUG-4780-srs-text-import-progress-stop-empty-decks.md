## BUG-4780 · 文本导入纯更新时进度一直是 0、点不了停止；叫停后牌组列新建的牌组留成空牌组
- **报告**：2026-11-17（用户：PR #3579 合入后的只读核实遗留项「文本导入进度只在每攒满 500 条新增时上报……准备阶段新建的牌组在叫停或失败后不回滚」）
- **真实性**：✅ 真 bug。根因（修前行号，origin/develop f25fcb3819）：
  - `packages/fushi_engine/lib/srs/text/srs_text_import.dart:518-521` 只在 `batch.length >= _kBatch`（攒满 500 条**新增**）时才调 `onProgress` 与 `shouldStop`；走 `updateExisting` 或被跳过的行不推进度也不看叫停，`:528` 的 `editFieldsBatch` 把全部更新放在一个事务里，期间同样看不了叫停。纯更新 / 大量跳过的导入进度一直停在 0、停止按钮无效。
  - `:338` `deckFor` 在第 1 步逐行映射时就 `store.ensureDeckPath` 落库建牌组，早于任何笔记写入；之后行被跳过、导入被叫停，这些牌组都留成空牌组。
- **[x] ① 已修复** — 进度与叫停改按处理行数：逐行阶段每 `_kBatch` 行（不论新增 / 更新 / 跳过）先落一次本批新增再 `checkpoint`（`srs_text_import.dart:508`、`:514`）；更新阶段改为每 `_kBatch` 条笔记一个 `editFieldsBatch` 事务，批前 `checkpoint`。牌组列里库中没有的牌组只记全名（`_Row.deckId` 为 null + `deckPath`），到这一批新笔记落库前才 `ensureDeckPath`（`deckOf`，`:346`、`:490`）；按牌组查重时还没建的牌组范围为空集（不会有已有笔记）。提交 3b5763a7b4。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/text/srs_text_import_test.dart`「纯更新的导入逐行阶段也报中间进度、能叫停」（1200 行纯更新：第一个批间有 (0,1) 的进度并能抛 `SrsImportStopped`，不叫停时更新阶段也分批报进度、单调到 1）与「牌组列里新的牌组到要写进去时才建」（前 500 行默认牌组、之后用新牌组，第一个批间叫停后不存在新牌组；首字段为空被跳过的行不建牌组）。对修前实现两条均红，修后 `dart test test/srs/text/srs_text_import_test.dart` 12 条全绿。
- **备注**：仍有的窄窗口：某一批落库（`importDrafts`）本身抛异常时，这一批刚建的牌组会留下（叫停与跳过已不会留）；牌组创建与笔记写入不在同一事务，要做到原子需要改 `createDeck` / `importDrafts` 的写入通道，这一轮不扩范围，另登记 BUG-4778。真机未复测（纯 Dart 引擎路径，单测覆盖真实 SrsDbStore）。
