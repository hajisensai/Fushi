## BUG-3543 · 复习：删除牌组奇慢无比（几千张卡几十秒），删除期间无任何反馈
- **报告**：2026-10-19（用户：删除牌组奇慢无比，不知道是不是和导入同类问题，类似的全部根本性修复）
- **真实性**：✅ 真 bug，与 BUG-3549 同一根因族（逐条往返）。基准 `packages/fushi_engine/test/srs/srs_bulk_ops_bench_test.dart`
  （临时文件库 + `createInBackground`，与 app 同一种连接）：修前 1500 条笔记 / 3000 张卡删父牌组 **33.3 s**，
  40519 次语句往返、**3002 个事务**。根因（修前行号，提交 9fda0951b2）：
  - `packages/fushi_engine/lib/srs/srs_db_store.dart:1623-1641`（`deleteDeck`）：子树里每张卡一次 `editField`，
    每次 = 读现值两次往返（修改记录 + 服务器时刻）+ 一个事务 + 一次缓存刷新 + 一次存本机状态；
  - 每次缓存刷新 `_successorIndex`（`:1178`）按无索引的 `field_key` 全表扫描修改记录表，`_refreshCardById`（`:1388`）
    每张卡再查卡片缓存 / 笔记缓存 / 血统修改记录 / 日志 / 服务器时刻各一次——几千张卡 = 几千次全表扫描，随表长成平方级；
  - UI（`fushi/lib/src/pages/implementations/srs/srs_deck_list_page.dart:148-160`，修前）`await store.deleteDeck` 期间
    行上没有任何状态，看起来像卡死；计算（JSON 解析、历史重放）在 UI isolate 上，几千个事务之间的往返让界面一直卡顿。
- **[x] ① 已修复** — 提交 ded1fcddc9、8ee4eebb0b：
  - `deleteDeck`（`srs_db_store.dart:1885`）按 500 张卡一块：块内现值分块一次预读（`_entityEditsMany`）、序号紧接着分配、
    一个事务一次落库一次缓存刷新（`_editEach`，`:1918`），每块一个独占区；卡都移完后最后一块写牌组删除标记——与以前逐张
    `editField` 的记录、顺序、「值没变的卡不写」完全相同；`onProgress` 按卡数报进度。
  - 缓存刷新（`_flushCachesNow` `:1106` / `_refreshCardChunk` `:1213`）：卡片缓存行、笔记缓存行、整条血统（含前身卡）的
    修改记录 / 日志 / 服务器时刻按 200 张一块预读，写入合成一个 Drift batch；`_successorIndex`（`:1405`）走 v119 的部分覆盖
    索引 `idx_srs_field_edits_history_from`，只扫前身链接那几行。
  - UI：删除中该牌组及其子牌组的行变淡、不可点 / 不进焦点，副标题换成「正在删除…」+ 进度条（尺寸 + 淡入淡出动画，
    MD3 / Apple 同一套 `FushiLinearProgressIndicator`）；删完立即重读列表，牌组消失（等重读回来才撤掉删除中状态，不闪回）。
  - 提速：1500 条 / 3000 张卡 33.3 s → **0.85 s**（语句 40519 → 190，事务 3002 → 7）；1 万条 / 2 万张卡 12.5 s（41 个事务，期间
    界面照常可用、有进度）。语句计数：160 条笔记 / 320 张卡 4345 → **35**。
- **[x] ② 已加自动化测试** —
  - `packages/fushi_engine/test/srs/srs_bulk_ops_roundtrips_test.dart`「删牌组（含子牌组）：语句数不随卡数增长」（40 → 160 条笔记，
    修前 1105 → 4345，修后 27 → 35）。
  - `packages/fushi_engine/test/srs/srs_bulk_ops_equivalence_test.dart`「删牌组 = 逐张 editField 移卡、再逐个标删除」「删大牌组跨多块」：
    与修前算法逐表逐字节相同（事件、发件箱、本机状态、缓存），缓存与整体重建一致，进度首尾为 (0, n) / (n, n)。
  - `fushi/test/srs/srs_import_task_test.dart`「[MD3]/[Apple] 删牌组：进行中显示「正在删除」与进度条、行不可点；删完立即消失」。
- **备注**：
  - 1 万条笔记仍需十几秒：剩下的是每张卡缓存行的历史重放与 JSON 解析（UI isolate 上按 200 张一块、块间是真实的跨 isolate
    往返，界面不冻结）。把整个副本搬进后台 isolate 需要改 `SrsDbStore` 的架构（写入者状态在主 isolate），未在本次做。
  - 同类批量操作见 BUG-3544，序号分配与落库乱序见 BUG-3545。
  - 未做设备肉眼复测（真实大牌组 + 删除时切页）。
