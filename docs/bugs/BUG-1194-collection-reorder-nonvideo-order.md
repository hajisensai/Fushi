## BUG-1194 · 视频合集详情页拖拽排序打乱非 video 成员的跨种类顺序
- **报告**：2026-07-28（用户：PR#501 审查时顺带发现，属既有缺陷）
- **真实性**：✅ 真 bug（但**不是**报告里说的「成员从合集里掉出去」——见下方「否定的部分」）。
  根因 `hibiki/lib/src/pages/implementations/media_collection_detail_page.dart:96`（`_persistOrder`
  只把可见的 video 成员键喂给 `reorderCollectionItems`）。
- **[x] ① 已修复** — `media_collection_detail_page.dart:96` 改为「保序合并」回写**全表**：
  先 `getCollectionItems` 取全部成员行定义槽位，可见槽按新可见序依次填入，不可见（非
  video / 悬空 video）成员留在其原下标，与 `media_collection_grid_detail_page.dart` 的
  `_onReorder` 同款纪律。提交 `40e8b2850`。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/media_collection_detail_sort_test.dart`
  新增 group「混合种类合集」3 例：拖拽 / 一键按名称 / 一键按导入时间后，断言**成员数不变、
  game 与 epub 成员仍在合集内、sortIndex 致密无碰撞、且非 video 成员相对 video 的手排位置
  不被打乱**。提交 `40e8b2850`。
- **备注**：

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
  `hibiki/lib/src/sync/backup_merge_engine.dart:436` 按 `(name, collectionType)` 自然键对齐、
  裸串写入对端 mediaType：两台设备各建同名合集（一台放书、一台放视频），同步一轮即混合。

混合后在本页拖拽 → video 成员拿到 0..n-1，非 video 成员留着旧 sortIndex 与之**碰撞**；
`getCollectionItems` 平手退化按 `entryKey` 排（`database.dart:3016`），于是：

- 用户在网格详情页（`media_collection_grid_detail_page.dart`，显示全部成员）排好的跨种类
  顺序被打乱成 uid 字典序，等于静默丢弃用户手排意图；
- `reorderCollectionItems` 同事务 bump `orderUpdatedAt = now`，这份碰撞序以 LWW **赢家**身份
  经 `collection_sync_engine.dart:222` 推给全部对端，覆盖对端本来正确的顺序。

严重度：**顺序一致性缺陷**，不是数据丢失；成员集合与跨端并集同步（`collection_sync_engine.dart:184`
的 `aliveMembers` 并集）均不受影响。
