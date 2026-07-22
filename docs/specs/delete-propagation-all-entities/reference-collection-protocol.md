# 合集删除传播协议（唯一参考实现）精读

> 供「全实体删除传播」实现照抄。路径根为本 worktree，相对路径 + 行号。
> 别名：ENG=`hibiki/lib/src/sync/collection_sync_engine.dart`，MAN=`hibiki/lib/src/sync/collection_manifest.dart`，ORCH=`hibiki/lib/src/sync/sync_orchestrator.dart`，BME=`hibiki/lib/src/sync/backup_merge_engine.dart`，CODEC=`hibiki/lib/src/sync/sync_manifest_codec.dart`，TBL=`packages/hibiki_core/lib/src/database/tables.dart`，DB=`packages/hibiki_core/lib/src/database/database.dart`。

## 四层结构

1. DB 墓碑层（TBL+DB）：`CollectionMemberTombstones` TBL 812-833，自然键 `(collectionName,collectionType,mediaType,entryKey)` + `removedAt`，复合主键**不含时间戳**（单行 LWW）。`mediaType==''&&entryKey==''` 空哨兵 = 合集级删除。用户路径写 now（`deleteMediaCollection` DB 2610-2631 / `removeFromCollection` 2714-2743），同步路径镜像戳（`deleteMediaCollectionRaw` 2905-2910 / `deleteCollectionItemRaw` 2893-2900 / `replaceCollectionTombstonesFor` 2856-2870）。重加清墓碑（`createMediaCollection` 2531 / `addToCollection` 2698）。
2. 清单模型层（MAN+CODEC）：纯 Dart 零 IO。因果戳 `publishedAt`(MAN 317) / `deletedPublishedAt`(143) / `removedAt`(310) / `deletedAt`(137)；文件戳 `lastWrittenAt`(38)**不进 canonicalJson**(84-110)。负值/空键一律 FormatException（脏行不发布）。fromJson 对新字段 additive 降级兼容(60-66,194-201)。
3. 纯函数引擎层（ENG）：`merge` 34-71 → `CollectionSyncOutcome{merged,changes}` 434-439。`_deleteIsNews/_tombIsNews` 255-269：`peer` 侧用 `publishedAt ?? removedAt`，本端侧用 `removedAt`，`> baseline` ⇒ 新删除生效，`<= baseline` 且对端仍活 ⇒ 删后重加要复活。`_stampEntry` 107-141：给空 publishedAt 盖 now，**已有值绝不刷新**（幂等命门）。`combinePeers` 86-102/726-887 折叠多 per-device 清单用 `lastWrittenAt` 而非基线（finding-1，防已发布墓碑下轮被误判复活）。
4. 接线层：云 per-device `syncCollections` ORCH 545-654；互联 host `_syncCollectionsLive` 670-717；备份 `_mergeMediaCollections` BME 327-448。

## 因果裁决心脏

- 两个时钟：基线 `lastSyncedAtMs`（ENG 26，`SyncRepository.get/setCollectionsSyncBaselineMs`）；首发戳 `publishedAt`（墓碑首次进合并结果时盖 now，`now=nextBaseline` 预取防 IO 竞态 ORCH 551-554）。
- `_deleteIsNews(deletedAt, deletedPublishedAt, peer, baseline)`：`at = peer ? (deletedPublishedAt ?? deletedAt) : deletedAt; return at > baseline`（ENG 265-269）。

## apply 本地删除（ENG 575-649，单事务）

- 目标态已删：`deleteMediaCollectionRaw(id)`（真删行+成员，不写墓碑）+ `replaceCollectionTombstonesFor` 只留空哨兵。
- 目标态活：调和成员（`deleteCollectionItemRaw` 删多余 / `upsertCollectionItemAt` 补位）+ 镜像成员墓碑。
- **绝不经 `removeFromCollection`/`deleteMediaCollection`**（会写 now 墓碑污染因果轴）。

## 两后端消费差异

- Live（云/互联）：**双向因果裁决**，publishedAt vs 基线，会复活「删后重加」。
- 备份整库：**单向防复活**，读**本机**墓碑（BME 346-352），旧备份带的成员无时间戳故本地墓碑直接生效、不做裁决。**要传播删除需改成读源侧墓碑 + publishedAt vs 基线守卫**（数据丢失风险最高处）。

## 推广三条红线

1. 发布戳一经确定绝不刷新（ENG 104-106,124-125）——否则破坏回写幂等。
2. 同步路径镜像戳、绝不写 now（ENG 569-574）——否则同步伪装成人为操作污染因果轴。
3. `publishedAt`/`lastWrittenAt` 不进 canonicalJson（MAN 84-110）；`_localMatches` 只比 `removedAt`（ENG 337-338，本地 DB 无 publishedAt 列）。

## 各目标实体现状差距

- **epub 书**：`book_tombstones` 表 + 备份防复活守卫已备（BME 267-285,495-510），但 Live 传播缺失（ORCH 981-982 显式声明不传播）；`importRemoteBooks` 861-899 拉取不查墓碑 → 复活 bug。缺 engine.merge/apply/接线 + 带 publishedAt 的书清单。
- **video_books**：有 `video_manifest.dart` + union diff（ORCH 840-883），书本身删除未走墓碑；统计侧有 `statistics_tombstones`。缺 engine.merge 式因果裁决。
- **dictionary**：备份 `_insertMissing('dictionary_metadata','name')`（BME 130，无 skip 守卫）；Live 有 BUG-086 部分删除传播（ORCH 982 引用 `SyncDeletionTombstones`，DB `clearSyncDeletionTombstone` 3827）——可能是第二条现成模板，实现前先核。
- **有声书**：`deleteAudiobookByBookKey` DB 1887 无墓碑；优先复用 `book_tombstones`（走 bookKey）。
