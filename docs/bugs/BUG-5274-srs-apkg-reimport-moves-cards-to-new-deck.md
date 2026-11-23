## BUG-5274 · 重导新版 apkg 把已有卡整批挪进新建的同源牌组，删掉新牌组连带删光旧牌组的卡和笔记
- **报告**：2026-11-23（用户：应用内反馈 X5FYYdCXXm（macOS 3.4.0-debug.31242，eggrolls-JLPT10k 卡组）；QQ 群机器人代提交 Z8uKJRBeSD（Windows，「01正在背::蛋卷词汇卡组::5-N1::1-高频」筛选为 0 张，同群第二人复述同一步骤））
- **真实性**：✅ 真 bug（按代码路径推出，未拿到用户的库）。两份反馈步骤一致：本机已有旧版蛋卷卡组 → 导入网上下的新版 apkg → 出现第二个牌组 → 删掉新牌组（「删除牌组」连卡）→ 旧牌组的卡和笔记全没了。
  - 链路：
    1. `packages/fushi_engine/lib/srs/apkg/srs_apkg_import.dart:1095-1100` 牌组只按**全名路径**（叶名 + 父牌组）认领。用户把先前导入的牌组改过名 / 挪到别的父牌组下（Z8uKJRBeSD 的牌组挂在自建的「01正在背」下），或新版 apkg 的牌组名变了，就认不出，`:1106-1112` 按 `deckIdForNew` 另建一个新牌组（`renamedImport` 分支甚至明确知道这是「用户改过名的同源牌组」）。
    2. 笔记按来源 guid 派生 ID（铁律 C），新版里的笔记全部命中本机已有笔记；来源 `mod` 比本机新 → 走「较新时更新」（`:1967` 起），`update = true`。
    3. `_importCardFlags`（`:2080-2081`）对已有卡：`row.deckId != deck && !localNewer(cardDeck)` 就写 `cardDeck = <新牌组>`。用户只是改了**牌组**名 / 父牌组，卡片自身没有 `cardDeck` 修改记录，`localNewer` 恒为 false → 旧牌组里每张同源卡都被挪进新牌组，旧牌组变空。
    4. 用户删新牌组时选了连卡删除：`SrsDbStore.deleteDeck(deleteCards: true)`（`packages/fushi_engine/lib/srs/srs_db_store.dart:4014`，内核 `deck_delete`）删掉「只在这个子树里有卡」的笔记——此刻所有同源笔记的卡都在新牌组里，于是整批笔记被删，旧牌组「卡片和笔记都没有了」。
  - 与 Anki 不一致（推测，按 Anki 新导入器 `rslib/src/import_export/package/apkg/import/cards.rs` 的行为：已存在的卡跳过、不改所在牌组，只更新笔记内容）：Anki 里同样的操作旧牌组不受影响。BUG-3554 只把「无条件改回来源牌组」收成「按 mod 比较」，没覆盖「本机改的是牌组本身而不是卡」这一情形。
- **[x] ① 已修复** — 对齐 Anki：本机已有的卡**不随重导换牌组**（`srs_apkg_import.dart` `_importCardFlags`）。只有恢复的笔记（本机删过、这次导回）的卡回到来源牌组；暂停状态仍按 BUG-3554 的「较新时更新」。来源牌组认不出时照旧另建同源牌组（同 Anki 按名认牌组），但它只收新笔记的卡，删掉它不会波及旧牌组。导入报告新增「已有卡片留在本机原来的牌组：N 张」（`SrsImportReport.cardsKeptInDeck`，i18n `srs_import_report_cards_kept_deck`）。取舍：「从 Anki 再迁一次」不再同步用户在 Anki 里挪过牌组的已有卡（Anki 自己的导入也不同步）。已中招的用户可用删牌组前内核打的还原点（`deleteDeck` §10.2）找回。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/apkg/srs_apkg_import_test.dart`「重导新版包：牌组改过名 / 挪过父牌组时已有卡留在原牌组，删掉新建的同源牌组不删笔记（BUG-5274）」：改名、挪到自建父牌组下两种，来源笔记与卡片 mod 都更新的最坏情形，断言卡不换牌组、`cardsKeptInDeck == 2`、`deleteDeck(新牌组, deleteCards: true)` 返回空且笔记未删；BUG-3554 测试的牌组断言随之改为「来源卡片更新也不换牌组」。
- **备注**：同根因反馈 X5FYYdCXXm、Z8uKJRBeSD。
