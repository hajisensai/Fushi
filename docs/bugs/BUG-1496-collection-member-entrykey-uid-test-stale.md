## BUG-1496 · 合集详情焦点测试用 bookKey 加成员，v83 entryKey 切 uid 后合集行不渲染
- **报告**：2026-08-11（用户：巡检发现 develop 常驻红）
- **真实性**：✅ 真 bug（测试与实现契约脱节，非并发伪红）。`develop@0c6ca0a0fd` 上
  `fushi/test/pages/collection_detail_focus_id_test.dart` 唯一一条用例红：
  `FLUTTER TEST VERDICT: FAILED ... (tests completed: 1, flutter exit code: 1)`，
  断言原文
  `The finder "Found 0 widgets with text "查看全部": []" (used in a call to "tap()") could not find any matching widgets.`
  （`collection_detail_focus_id_test.dart:153`）。
  - 根因链（`2ceccf8bda`，P3 Stage 2/v83「合集与书架 epub 域 entryKey 切稳定 uid」）：
    1. `packages/fushi_core/lib/src/database/database_content_misc.part.dart:109`
       `insertEpubBook` 在 companion 未带 uid 时**单点自动生成** uid；
    2. `fushi/lib/src/pages/implementations/reader_fushi_history_page.dart:802`
       建 `_epubUidByKey`，`:1328` 分组键取 `entryKey: _epubUidByKey[k] ?? k` ⇒ **uid**；
    3. 测试 `:134` 仍用 **bookKey** 播种成员
       （`db.addToCollection(cid, MediaKind.epub, 'memberKey')`）；
    4. ⇒ 分组查 `'epub|<uid>'` 落空 → 书退化成散卡 → `CollectionShelfRow` 整行不渲染
       → 行尾的 `t.collection_view_all`（「查看全部」）自然 0 个 → `tap()` 抛。
- **[x] ① 已修复** — 测试侧对齐 v83 契约：`seedEpub` 之后经
  `db.resolveEpubBookUid('memberKey')` 取真 uid 再 `addToCollection`，并加一条
  `expect(memberUid, isNotNull)` 把「uid 没生成」与「合集没渲染」两种失败分开。
  **刻意不动产品代码**：给 `groupByCollections` 加 bookKey 兜底会把 v83 刚收敛掉的
  双键歧义原样放回来。
- **[x] ② 已加自动化测试** — 就是这条被修复的用例本身
  （`fushi/test/pages/collection_detail_focus_id_test.dart`）。修后实测
  `FLUTTER TEST VERDICT: PASSED - 1 tests ran, all tests passed`。
- **备注**：与 BUG-1495 / BUG-1497 同源——P3 v82/v83 的 uid 迁移改了三处键/契约，
  配套测试没跟上；产品行为本身没坏。
