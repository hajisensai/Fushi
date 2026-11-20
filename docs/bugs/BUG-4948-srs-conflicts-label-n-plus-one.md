## BUG-4948 · 冲突中心逐条读实体名，大冲突量的库上整页重读 63 秒、内存翻倍，停在冲突页时意外退出
- **报告**：2026-11-21（应用内反馈 9Z86HZWTxT，macOS 3.4.0-debug.29093）
- **真实性**：✅ 真 bug。反馈日志里进程死在 `SrsConflictsPage` 前的最后一次内存采样：`core:read:cards 6951x 63381ms`、
  `core:read:edits 6958x 82.3MB`、`core:read:entities 6961x`，`busy=[core:status 65.1s]`，rss 1.6 GB → 3.3 GB（max 3.6 GB）。
  根因 `fushi/lib/src/pages/implementations/srs/srs_conflicts_page.dart` 旧 `_load`（:207 起的循环与 :263 扣住删除的循环）
  对每条冲突各调一次 `store.cardDetail` / `store.note`（:215 / :230 / 旧 `_entityLabel` :314 / :318）只为拿笔记第一个字段当名字；
  `cardDetail`（`packages/fushi_engine/lib/srs/srs_db_store.dart` `cardDetail`）每条是 卡行 + 身份记录 + 修改记录 三次读加一次字段
  寄存器物化，6950 条冲突 ≈ 2 万次跨 isolate 读 + 每条笔记全部字段正文读回 UI isolate，一次整页重读 63 秒、峰值内存翻倍。
  每次处理一条冲突后都整页重读，再跑一遍。
- **[x] ① 已修复** — 新增 `SrsDbStore.sortLabelsOf`（`srs_db_store.dart`）：卡 → 笔记 ID、笔记 → 缓存的 `sort_field`
  （第一个字段去标签，与浏览页排序字段同口径）固定两条批量读；页面 `_load` 改为先收齐冲突 / 扣住删除的实体引用，经
  `_EntityLabels.load` 一次取齐名字（笔记类型名按需一次 `noteTypes()`），删掉逐条的 `_entityLabel`。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_conflicts_labels_batched_test.dart`：`sortLabelsOf` 只发 2 条读、名字正确、
  不存在的 ID 不在结果里；冲突页 1 条与 12 条扣住的删除的读命令数差 < 5（旧代码 9 → 31，差 22，变异实测红）。
- **备注**：
  - 进程退出本身 macOS 没留原因，「峰值 3.3 GB 导致被杀」是推测；本条修的是日志里有直接证据的逐条读放大。
  - 同一反馈里「保留」反复报 `no such conflict`（过时条目不重读）由 BUG-4918（PR #3861，未合）处理，本条不重复改。
  - `conflict_edits` 一次读回 6.9 万行 / 33 MB（`syncConflicts` 全 profile 物化标志 / 设置类候选）耗时 0.46 s，未见是主耗时，未动。
