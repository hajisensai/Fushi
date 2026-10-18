## BUG-3519 · 复习：新建牌组慢、列表不立即出现新牌组
- **报告**：2026-10-18（用户：新建卡组慢，而且界面没有立刻刷出来）
- **真实性**：✅ 真 bug。新建牌组本身的写库不慢（两次事务、十几条语句），慢的是写完之后的列表重读：
  - `fushi/lib/src/srs/srs_providers.dart:304-319`（修前）：`srsDeckListProvider` 在同一个 Future 里先算
    `deckSummaries()`、再 `await store.syncConflicts()` 与 `notesPendingDecision()`，冲突数并进 `SrsDeckListData`。
    FutureProvider 重算期间保留旧值，于是新牌组要等冲突扫描跑完才出现。
  - `packages/fushi_engine/lib/srs/srs_db_store.dart:2085`（修前 `syncConflicts`）：把本 profile 的**全部**修改记录
    （含每条笔记的字段正文）整表读回 UI isolate，逐条 `jsonDecode` 再分组——每次 `bumpSrsRevision` 都付一遍
    O(全部修改记录)。实测 1500 条笔记 124 ms、1 万条约 0.8 s 以上，且解析在 UI isolate 上。
  - `srs_db_store.dart:1171`（修前 `createDeck`）：身份记录与名字记录分两次事务、两次缓存刷新。
  - 每次刷新缓存里 `_successorsOf`（修前 `srs_db_store.dart:820`）对每张脏卡按无索引的 `field_key` 扫一遍修改记录表
    （评分 / 移卡这类写入每次至少一次全表扫描）。
- **[x] ① 已修复** — 本分支提交（见 git log「fix(srs): deck list refresh + background apkg import」）：
  - 冲突数拆成独立的 `srsConflictCountProvider`（`srs_providers.dart`），牌组列表只等牌组行；顶栏冲突角标读新 provider。
  - `syncConflicts` 先在 SQLite 侧 `GROUP BY ... HAVING COUNT(*) > 1` 挑出有 ≥ 2 条记录的字段键，只读回这些记录
    （被支配的记录落库时就删了，单条记录的字段键不可能有冲突）。
  - `createDeck` 身份记录 + 修改记录一个事务（`newEditEvents`）；`_successorIndex` 每次刷新只扫一次。
- **[x] ② 已加自动化测试** —
  - `packages/fushi_engine/test/srs/srs_write_path_roundtrips_test.dart`：「同步冲突扫描：没有冲突时不把修改记录整表读回」
    （读回行数 = 0，修前约 1000 行）、「新建牌组：语句数不随库里的笔记数增长」；冲突仍能被发现由既有
    `srs_db_store_test.dart`「标志类并发…进同步冲突记录」覆盖。
  - `fushi/test/srs/srs_import_task_test.dart`：「[MD3]/[Apple] 牌组列表：新建牌组立即出现，不等同步冲突扫描」
    （冲突 provider 永不完成，新牌组照样出现）。
- **备注**：`deckSummaries` 仍把本 profile 的卡片缓存行整表读回计数（1 万笔记 / 2 万卡约 200 ms，后台 isolate 读 +
  UI isolate 计数）。没有改成 SQL 聚合：BUG-3502 刚按 Anki limit tree 重写过计数，聚合需要「今日已学卡集合」按牌组
  分摊，改动面大；量级上已不再是瓶颈，记此待后续。
