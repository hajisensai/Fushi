## BUG-1194 · 视频合集详情页拖拽排序打乱非 video 成员的跨种类顺序
- **报告**：2026-07-28（用户：PR#501 审查时顺带发现，属既有缺陷）
- **真实性**：✅ 真 bug（但**不是**报告里说的「成员从合集里掉出去」——见下方「否定的部分」）。
  根因 `hibiki/lib/src/pages/implementations/media_collection_detail_page.dart:96`（`_persistOrder`
  只把可见的 video 成员键喂给 `reorderCollectionItems`）。
- **[x] ① 已修复** — 两轮，第二轮才是根因修复：
  - 第一轮（`40e8b2850`，页面级）：`media_collection_detail_page.dart:96` 改为「保序合并」
    回写**全表**——先 `getCollectionItems` 取全部成员行定义槽位，可见槽按新可见序依次填入，
    不可见成员留在其原下标。**治标**：它把不变量交给每个调用方自觉，而合集详情页天然只渲染
    子集，下一个调用方（或下一个新页面）照样能再造出碰撞。
  - 第二轮（根因，本次）：**不变量上移到 DAO**。`HibikiDatabase.reorderCollectionItems`
    (`packages/hibiki_core/lib/src/database/database.dart:3142`) 的契约改为「[ordered] 只表达
    它**点名**的那批成员之间的新相对顺序」，方法自己在同一事务内取全表槽位、保序合并、把
    sortIndex 回写成致密 `0..n-1`。**传子集从此是合法用法**，页面漏做合并不再可能造出碰撞；
    顺带自愈——任何一次重排都把历史遗留的碰撞 sortIndex 抹平。
  - 合并规则抽成唯一真相源纯函数 `mergeCollectionOrder`
    （新文件 `packages/hibiki_core/lib/src/database/collection_order.dart`），DAO 守落盘不变量、
    `media_collection_grid_detail_page._onReorder` 维护内存展示序，两侧同一份实现不会漂开。
    身份键统一为 record `CollectionMemberKey`，**废掉网格页原来的 `'<mediaType>|<entryKey>'`
    拼串键**——entryKey 是用户数据，`('video','a|b')` 与 `('video|a','b')` 会拼成同一个串。
  - `media_collection_detail_page._persistOrder` 的 30 行保序合并块随之整块删除，只传可见
    video 键。
- **[x] ② 已加自动化测试** — 三层：
  - `hibiki/test/database/collection_order_test.dart`（新增，7 例）：纯规则——未点名成员留原
    槽位 / 绝不挤到表尾 / 全量点名等价于直接排序 / 空 subset / 并发移出键丢弃 / 重复键 /
    分隔符出现在 entryKey 里也不误判。
  - `hibiki/test/database/media_collections_dao_test.dart`（新增 group「子集契约」3 例）：
    **根因守卫**——只传可见 video 子集时非 video 成员留原槽位且全表致密无碰撞；用
    `upsertCollectionItemAt` 种出旧版碰撞现场后一次重排自愈；点名已被并发移出的成员不越界。
  - `hibiki/test/pages/media_collection_detail_sort_test.dart` 的 group「混合种类合集」3 例
    （第一轮加的）保留：拖拽 / 一键按名称 / 一键按导入时间后，断言成员数不变、game 与 epub
    成员仍在合集内、sortIndex 致密无碰撞、非 video 成员相对 video 的手排位置不被打乱。
  - `hibiki/test/database/media_collections_dao_test.dart` 再加 1 例「sortIndex 碰撞时
    按 entryKey 定序，并被一次重排冻结成致密序」：DAO 现在把 `getCollectionItems` 的
    结果**冻结**成永久致密序，那个读的定序规则是整套修复的地基。用例刻意让 entryKey
    序与 mediaType 序**相反**，去掉 ORDER BY 的 entryKey 段即转红（实测）。
  - 同时给 `getCollectionItems` / `getAllCollectionItems` 的 ORDER BY 补末位
    `mediaType` 段，让排序键 == 成员身份 `(collectionId, mediaType, entryKey)` 去掉被
    where 钉死的 collectionId → 全序。**诚实标注**：当前 SQLite 计划走复合主键索引
    扫描、本就是 mediaType 升序，删掉这一段行为不变，实测无法用行为测试守它；保留它
    是为了不让"冻结"依赖查询计划的巧合，不是修一个今天可复现的症状。
- **已知残留（不在本 PR 范围）**：备份合并路径不走 DAO，本次不变量管不到它。
  `hibiki/lib/src/sync/backup_merge_engine.dart:437` 用裸 SQL
  `INSERT OR IGNORE ... (collection_id, media_type, entry_key, sort_index)` **原样搬**
  源库的 sort_index，既不致密化也不碰 `orderUpdatedAt`（该文件全文无此列）。所以一次
  备份合并导入仍可能把碰撞 sortIndex 带回本地。影响面比原 bug 小（导入才发生，且下一次
  任何重排会自愈），但要彻底闭合「顺序一致性」得单开一条：合并后按 `(sortIndex, entryKey,
  mediaType)` 对受影响合集重编号，并决定是否传播序时间戳。
- **备注**：**不禁止混合种类合集**——网格详情页本就显示全部成员，混合是被支持的形态。
  「加入合集」弹窗不按种类过滤、同步/备份按 `(name, collectionType)` 自然键对齐，这两条是
  混合**如何产生**的解释，不是要改掉的缺陷；根因修复的方向是让排序在混合下正确，而不是
  加特例阻止混合。

### 否定的部分：不存在数据丢失

报告称「非 video 成员会从合集里掉出去」。沿真实代码路径核对后**证伪**，两道独立防线：

1. `HibikiDatabase.reorderCollectionItems`（`packages/hibiki_core/lib/src/database/database.dart:3142`）
   是**纯 UPDATE 循环** —— 逐条 `update(mediaCollectionItems)..where(collectionId & mediaType &
   entryKey)` 写 `sortIndex`，全程没有任何 `delete`。不在 `ordered` 里的成员行只是保留旧
   `sortIndex`，不会被删。
2. `_persistOrder` 写死 `'video'` 也**不是 bug 本身**：`_members` 是 `List<VideoBookRow>`，由
   调用方 `home_video_page.dart:3305` 的 `loadMembers` 显式 `if (m.mediaType != MediaKind.video.dbValue) continue;`
   过滤而来，所以每个元素**确实**都是 video。写 `'video'` 对这批键是正确的。

真正的缺陷在**遗漏**而非**错写**：全表 sortIndex 被重写成致密 `0..n-1`，但只覆盖可见子集。

### 真实后果（可触发）

`MediaCollectionItems.mediaType` 无 CHECK 约束（`packages/hibiki_core/lib/src/database/tables.dart:869`），
一个合集可混入多种 mediaType，且**无需用户误操作**即可发生：

- `hibiki/lib/src/media/collections/add_to_collection_dialog.dart:23` 用
  `getAllMediaCollections()` 列**全表**，不按 mediaType/collectionType 过滤 → 游戏库
  （`games_library_page.dart:378`）、书架（`reader_hibiki_history_page.dart:2044`）都能把
  game/epub/srt 成员加进一个已含 video 的合集。
- `hibiki/lib/src/sync/collection_sync_engine.dart:624` 与
  `hibiki/lib/src/sync/backup_merge_engine.dart:308` 按 `(name, collectionType)` 自然键对齐、
  裸串写入对端 mediaType：两台设备各建同名合集（一台放书、一台放视频），同步一轮即混合。

混合后在本页拖拽 → video 成员拿到 0..n-1，非 video 成员留着旧 sortIndex 与之**碰撞**；
`getCollectionItems` 平手退化按 `entryKey` 排（`database.dart:3016`），于是：

- 用户在网格详情页（`media_collection_grid_detail_page.dart`，显示全部成员）排好的跨种类
  顺序被打乱成 uid 字典序，等于静默丢弃用户手排意图；
- `reorderCollectionItems` 同事务 bump `orderUpdatedAt = now`，这份碰撞序以 LWW **赢家**身份
  经 `collection_sync_engine.dart:222` 推给全部对端，覆盖对端本来正确的顺序。

严重度：**顺序一致性缺陷**，不是数据丢失；成员集合与跨端并集同步（`collection_sync_engine.dart:184`
的 `aliveMembers` 并集）均不受影响。
