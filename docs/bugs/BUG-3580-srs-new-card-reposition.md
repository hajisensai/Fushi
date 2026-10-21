## BUG-3580 · 制卡目标为「Fushi 复习」时「新卡按词频重排」（手动 + 制卡后自动）不可用
- **报告**：2026-10-20（用户：挖词目标切到 Fushi 复习后，设置里「按词频重排新卡」「制卡后自动重排」两行消失，复习里也没法按词频排新卡）
- **真实性**：✅ 真缺口（能力缺失，不是偶发）。根因四处：
  1. `fushi/lib/src/settings/settings_schema_card_creation.dart`（`_ankiOnly` 包住 `card_creation.anki.reposition` / `reposition_auto` 两条搜索条目）与 `ankiSectionRowsFor` 只在 Anki 目标下列出这两行——复习目标下整组不渲染、搜不到。
  2. `fushi/lib/src/srs/srs_mining.dart` `SrsMiningAnkiRepository`：`supportsDeckReposition => false`，`listNewCards` / `setNewCardPositions` 直接抛 `UnsupportedError`。
  3. 存储层没有新卡位置：`packages/fushi_engine/lib/srs/srs_db_store.dart` `nextCard` 新卡写死按（`noteCreatedAt`, cardId）出卡，`SrsCardsCache`（`packages/fushi_core/lib/src/database/tables.dart`）没有位置列，`SrsFieldKeys`（`packages/fushi_srs/lib/src/field_edit.dart`）没有可同步的位置键，复习库模拟的 AnkiConnect 也不认 `setSpecificValueOfCard`、`cardsInfo` 的新卡 `due` 恒为 0。
  4. 自动重排装饰器装配顺序：`fushi/lib/src/anki/anki_view_model.dart` 里 `AutoRepositionAnkiRepository` 包在待发队列里面、SRS 层在最外面，而 SRS 层的 `mineEntry` 直接写复习、不调里层——即使能力位打开，复习制卡也永远触发不了自动重排。
- **[x] ① 已修复** —
  - 存储：卡片修改记录新键 `SrsFieldKeys.cardNewPosition`（`newPos`，int；字段类别按 `viewState`：随同步、最后修改生效、不进「同步冲突记录」——两台设备各自重排同一牌组是常态）；`SrsCardFlags.newPosition` 物化；schema v122 → v123 `srs_cards_cache.new_position`（可空，存量库没有位置记录、留 NULL 与事件一致，不重建缓存）。
  - 出卡顺序：`SrsDbStore.compareNewCardOrder`（`nextCard` 与重排取卡共用）——排过的在前按位置升序，没排过的在后按（笔记创建时刻, cardId），从没重排过的库出卡顺序逐张不变。
  - 读写接口：`SrsDbStore.newCardsInDeck(全名)`（含子牌组、含暂停 / 搁置的新卡，没排过的卡按顺序接着已排最大位置编号，只供比较与撤销）与 `setNewCardPositions`（一个批次、只接受此刻仍是可见新卡的卡）。
  - `SrsMiningAnkiRepository` 实现三件套，复用既有纯函数 `planCardPositions`、`AnkiDeckRepositionRunner`、`AnkiAutoRepositionScheduler`；取 rank 的字段按该笔记类型**实际制卡映射**找出表达式 / 读音 / 词频序，以 Lapis 字段名交给 `resolveNoteFieldRoles`（`srsRepositionRoleFields`），内置 Fushi 卡片 / Lapis 改过字段名、自建类型都能认出。
  - 装配：`_withSrsMining` 在 SRS 层外再套一层自动重排（里层那份仍管待发队列补发给 Anki 的卡，两份各管各的落卡处，不会对同一张卡排两次）；重排快照目录按装饰链分开（`backups/srs_reposition` vs `backups/anki_reposition`，`repositionSnapshotFolderFor`）——两边都有「Default」牌组，撤销按牌组名挑最近一份快照，混放会挑到另一边的。
  - AnkiConnect 兼容端点：新增 `setSpecificValueOfCard`（只认新卡的 `due` = 队列位置，形状照插件：逐键 `true` / `[false, 原因]`，卡不存在 `[[false, 原因]]`，长度不符裸 `false`；其它键一律报不支持，不假装写进排程）；`cardsInfo` 新卡 `due` 报位置（没排过仍是 0）。
  - 设置页：两行挪进「Fushi 复习」分组（`_buildSrsRepositionRows`，弹窗的牌组下拉换成复习牌组，`showAnkiDeckRepositionDialog` 新增可选 `decks` / `initialDeckId`），搜索条目可见性 `_repositionVisible` 同步；Anki 分组里的两行不变。
- **[x] ② 已加自动化测试** —
  - `packages/fushi_engine/test/srs/srs_new_card_position_test.dart`：从没排过时出卡 / 取卡按创建时刻；部分排过的混合顺序；学过的卡不接受；子牌组；两设备同步与并发重排最后修改生效、无同步冲突；字段类别。
  - `packages/fushi_engine/test/srs/ankiconnect/srs_ankiconnect_handler_test.dart`：`setSpecificValueOfCard` 形状与新卡限定、`cardsInfo` 的 `due`。
  - `fushi/test/database/migration_v123_srs_new_position_test.dart`：v122 → v123 加列、存量行 NULL、重跑幂等。
  - `fushi/test/srs/srs_mining_test.dart`：Fushi 卡片字段被角色解析认出；手动重排往返（计划 → 写回 → 出卡顺序 → 撤销）；写回时已不是新卡进 failures；制卡后自动重排经外层装饰器触发并排好；装饰链形状与快照目录。
  - `fushi/test/srs/srs_mining_settings_visibility_test.dart`：复习目标下两条搜索条目可见。
- **备注**：已知未做——浏览页按到期排序时新卡仍排最后（不按位置）；导出 `.apkg` 时新卡 `due` 仍按导出遍历顺序编号；复习里「重置为新卡」的卡保留它原来的位置记录（Anki 重置默认排到末尾）。这三处不影响出卡，留作后续。
