## BUG-1497 · 远端书下载进度回填测试假 importer 不落库，v82 uid 闸门后回填永不发生
- **报告**：2026-08-11（用户：巡检发现 develop 常驻红）
- **真实性**：✅ 真 bug（测试替身与真 importer 的后置条件脱节）。`develop@0c6ca0a0fd` 上
  `fushi/test/pages/reader_remote_interconnect_test.dart` 18 条里 1 条红：
  `FLUTTER TEST VERDICT: FAILED ... (1 error event(s), 18 test(s) completed)`，
  用例 `BUG-813: 下载远端书把 host 阅读进度回填进本地 reader_positions`，
  断言原文 `Expected: not null / Actual: <null>`（`:435`，reason
  「BUG-813：下载远端书必须把 host 阅读进度落进 reader_positions」）。
  - 根因 `file:line`：`fushi/lib/src/pages/implementations/reader_history/remote.part.dart:551`
    ```dart
    final String? localUid = await appModel.database.resolveEpubBookUid(localBookKey);
    if (remote.updatedAtMs > 0 && localUid != null) { …upsertReaderPosition… }
    ```
    v82（`7a3505ca7a`，P3 Stage 1b）把 `reader_positions` 等四子表的键从 bookKey 切成
    稳定 uid，回填因此加了 `localUid != null` 闸门（契约：**不得用 bookKey 兜底写入**）。
    而测试注入的假 `remoteBookImporter`（`reader_remote_interconnect_test.dart:119`）
    只 `return importedBookKey;`、**从不真的插 EpubBooks 行** ⇒ `resolveEpubBookUid`
    恒返回 null ⇒ 回填整段被跳过 ⇒ `getReaderPosition` 恒 null。
    也就是说替身的后置条件（「书已在库」）与真 importer 不一致，v82 之前没人依赖这条
    后置条件，迁移之后就露了。
- **[x] ① 已修复** — 让假 importer 与真 importer 的**后置条件**一致：返回 bookKey 前
  真的 `db.insertEpubBook(EpubBooksCompanion.insert(bookKey: key, …))`；
  BUG-813 用例的轮询与断言随之改为「先 `resolveEpubBookUid('local-book-key')` 取 uid、
  再 `getReaderPosition(uid)`」，并补一条 `expect(localUid, isNotNull)` 把「书没导进来」
  与「进度没回填」两种失败分开。
  **刻意不动产品代码**：`localUid != null` 闸门是 v82 契约的正确落地，为了让测试绿而
  松掉它就是把 bookKey 兜底写入放回来。
- **[x] ② 已加自动化测试** — 就是这条被修复的用例本身
  （`fushi/test/pages/reader_remote_interconnect_test.dart`）。修后实测
  `FLUTTER TEST VERDICT: PASSED - 18 tests ran, all tests passed`。
- **备注**：与 BUG-1495 / BUG-1496 同源（P3 v82/v83 uid 迁移的配套面没跟上）。
  留一条通用结论：**替身（fake importer / fake repo）的价值全在它的后置条件；
  一旦下游开始依赖某条后置条件（这里是「书已落库」），替身必须跟着补上，
  否则被测链路会在替身下静默短路成 no-op。**
