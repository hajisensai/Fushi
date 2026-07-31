import 'dart:io';

import 'package:hibiki/src/media/video/video_storage.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 合集自有磁盘资产的回收（BUG-1316）。
///
/// ## 为什么必须是「唯一入口」而不是某个页面的私有 helper
///
/// 合集自有封面落在 `video_covers/collections/<id>.jpg`，路径记在
/// `media_collections.cover_path`。[VideoStorage.gcOrphanCovers] 那轮历史 GC
/// **故意**扫不到这个子目录（它非递归、且保留集是全库 `video_books.cover_path`，
/// 合集封面不在其中——见 [VideoStorage.collectionCoversDirName] 注释）。于是
/// 「删合集」是这些文件**唯一**的回收时机：DB 行一删，`<id>` 与 `cover_path`
/// 同时消失，磁盘上那张图再也无法被任何机制识别 = 确定性永久泄漏。
///
/// 而回收此前只挂在 `collection_context_dialog._deleteCollection` 一个 UI 入口
/// 上，另外五条删除路径（两个合集详情页 `_delete`、两处库页批量解散、合集合并
/// 的源合集解散、同步删除传播）全部只删 DB 行不删文件。**根因就是回收挂在某个
/// 调用点上、而不是挂在「删合集」这个动作本身**：只要还有第二个调用点，新入口
/// 就天然漏。所以这里把「删行 + 回收」收成一个函数，全部入口调它。
///
/// ## 顺序约束
///
/// 资产路径只能从**还活着的** DB 行推导。因此 [deleteMediaCollectionWithAssets]
/// 先取行快照、再删行、最后删文件；调用方不得自己颠倒这个顺序。
///
/// ## 误删护栏（三条同时成立才删）
///
/// 1. 路径来自被删合集自己 DB 行的 `coverPath`——不枚举目录、不猜文件名；
/// 2. 规范化后必须**严格落在**合集封面目录内（[VideoStorage.deleteCollectionCover]
///    内部用 `p.isWithin` 判定，杜绝 `..` / 符号链接越界）——用户外部图片、成员
///    封面、原始视频文件一律不碰；
/// 3. 删行后重查全库合集，**任何仍存活的合集引用同一规范化路径则保留**。
///
/// 宁可漏删也不误删：三条中任一不成立就静默保留文件。

/// 一行合集快照里「该合集自有、随合集删除一起回收」的磁盘资产路径。
///
/// 目前只有封面一项。将来给 `media_collections` 加横版 backdrop 之类的自有图片
/// 列时，**在这里加一行**就能让全部六条删除路径同时生效——这正是把回收收成单一
/// 入口的收益（否则新列会原样重演同一个泄漏）。
List<String?> collectionOwnedAssetPaths(MediaCollectionRow collection) {
  return <String?>[collection.coverPath];
}

/// 删除合集的**唯一入口**：删 DB 行（[HibikiDatabase.deleteMediaCollection]，
/// 清成员引用行 + 写合集级墓碑）→ 回收该合集自有的磁盘资产。
///
/// 返回值透传 [HibikiDatabase.deleteMediaCollection]（被删的合集行数），调用方
/// 原有的 `removed > 0` 判据零变化。
///
/// [collectionCoversDirectory] 仅供测试注入；生产走 [VideoStorage] 的真实目录。
Future<int> deleteMediaCollectionWithAssets(
  HibikiDatabase db,
  int collectionId, {
  Directory? collectionCoversDirectory,
}) async {
  // 快照必须在删行**之前**取：行一删，coverPath 就再也推导不出来。
  final MediaCollectionRow? snapshot =
      await db.getMediaCollectionById(collectionId);
  final int removed = await db.deleteMediaCollection(collectionId);
  await reclaimDeletedCollectionAssets(
    db,
    <MediaCollectionRow>[if (snapshot != null) snapshot],
    collectionCoversDirectory: collectionCoversDirectory,
  );
  return removed;
}

/// 回收 [deletedCollections]（DB 行**已删**的合集快照）各自自有的磁盘资产。
///
/// 给「删行发生在事务里、文件 IO 必须挪到事务外」的调用方用（同步删除传播）。
/// 普通调用方直接用 [deleteMediaCollectionWithAssets]。
///
/// 返回实际删掉的文件数（便于测试断言）。删除失败 / 异常不抛——合集已经删掉是
/// 既成事实，一张残留图不该让整个删除流程报错。
Future<int> reclaimDeletedCollectionAssets(
  HibikiDatabase db,
  Iterable<MediaCollectionRow> deletedCollections, {
  Directory? collectionCoversDirectory,
}) async {
  final List<String> candidates = <String>[
    for (final MediaCollectionRow collection in deletedCollections)
      for (final String? path in collectionOwnedAssetPaths(collection))
        if (path != null && path.isNotEmpty) path,
  ];
  // 没有任何自有资产就彻底不碰文件系统（无封面的同步 / 单测路径零 IO）。
  if (candidates.isEmpty) return 0;
  int reclaimed = 0;
  try {
    final List<MediaCollectionRow> survivors =
        await db.getAllMediaCollections();
    final List<String> stillReferenced = <String>[
      for (final MediaCollectionRow collection in survivors)
        for (final String? path in collectionOwnedAssetPaths(collection))
          if (path != null && path.isNotEmpty) path,
    ];
    for (final String candidate in candidates) {
      if (await VideoStorage.deleteCollectionCover(
        deletedCoverPath: candidate,
        stillReferencedCoverPaths: stillReferenced,
        collectionCoversDirectory: collectionCoversDirectory,
      )) {
        reclaimed++;
      }
    }
  } catch (e, stack) {
    ErrorLogService.instance.log('collection.reclaimAssets', e, stack);
  }
  return reclaimed;
}
