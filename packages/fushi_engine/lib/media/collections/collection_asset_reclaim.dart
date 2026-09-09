import 'dart:io';
import 'package:fushi_engine/media/video/video_storage.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/foundation/engine_platform_hooks.dart';

/// 合集自有磁盘资产的回收（BUG-1319）。
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
/// 封面一项 + v68 附加图组（media_images，须在删行**前**由调用方快照——行随删
/// 合集 FK cascade 消失，见 [collectionOwnedImagePaths]）。新增自有图片资产时
/// **在这两处加**就能让全部删除路径同时生效——这正是把回收收成单一入口的收益
/// （否则新资产会原样重演同一个泄漏）。
List<String?> collectionOwnedAssetPaths(MediaCollectionRow collection) {
  return <String?>[collection.coverPath];
}

/// 某合集当前的附加图文件路径（v68）。**必须在删行前调用**：`media_images` 行
/// 随删合集 cascade 消失，删后再查恒为空、文件永久泄漏。
Future<List<String>> collectionOwnedImagePaths(
  FushiDatabase db,
  int collectionId,
) async {
  return <String>[
    for (final MediaImageRow row
        in await db.getMediaImagesForCollection(collectionId))
      row.path,
  ];
}

/// 删除合集的**唯一入口**：删 DB 行（[FushiDatabase.deleteMediaCollection]，
/// 清成员引用行 + 写合集级墓碑）→ 回收该合集自有的磁盘资产。
///
/// 返回值透传 [FushiDatabase.deleteMediaCollection]（被删的合集行数），调用方
/// 原有的 `removed > 0` 判据零变化。
///
/// [collectionCoversDirectory] 仅供测试注入；生产走 [VideoStorage] 的真实目录。
Future<int> deleteMediaCollectionWithAssets(
  FushiDatabase db,
  int collectionId, {
  Directory? collectionCoversDirectory,
}) async {
  // 快照必须在删行**之前**取：行一删，coverPath / 附加图行就再也推导不出来。
  final MediaCollectionRow? snapshot =
      await db.getMediaCollectionById(collectionId);
  final List<String> imagePaths =
      await collectionOwnedImagePaths(db, collectionId);
  final int removed = await db.deleteMediaCollection(collectionId);
  await reclaimDeletedCollectionAssets(
    db,
    <MediaCollectionRow>[if (snapshot != null) snapshot],
    ownedImagePaths: imagePaths,
    collectionCoversDirectory: collectionCoversDirectory,
  );
  return removed;
}

/// 清掉合集**自有**封面，回到自动推导（成员借用链 / canonical 海报）。
///
/// 与 [deleteMediaCollectionWithAssets] 的关系：那条是「合集没了，顺手回收它的
/// 图」，这条是「合集还在，只是不要这张图了」。两者共用**同一套误删护栏**——先把
/// `coverPath` 置 null，再把置 null 前的快照当作「已删资产」交给
/// [reclaimDeletedCollectionAssets]。置 null 已经落库，所以那边重查全库时本合集
/// 不再引用该路径，护栏第 3 条自然放行；而别的合集若碰巧引用同一路径，文件照样
/// 保留。这就是为什么这里不自己写一遍删除条件。
///
/// 顺序不可颠倒：先落库置 null，再删文件。反过来一旦删文件后置 null 失败，DB 就
/// 指着一个不存在的文件。
///
/// 合集还活着、UI 还在画这张图，因此删完必须走
/// [evictImageCacheForFile] 双键驱逐解码缓存（app 装配成 `evictLocalCoverCache`：
/// `FileImage` + `resizedFileImage` 两个 key）——否则封面卡会继续画
/// 一张文件已经不在的图直到重启（BUG-1118 同型）。
///
/// 无自有封面时是彻底的空操作（零 IO、零写库）。
Future<void> clearCollectionOwnCover(
  FushiDatabase db,
  int collectionId, {
  Directory? collectionCoversDirectory,
}) async {
  final MediaCollectionRow? snapshot =
      await db.getMediaCollectionById(collectionId);
  final String? coverPath = snapshot?.coverPath;
  if (snapshot == null || coverPath == null || coverPath.isEmpty) return;
  await db.updateMediaCollectionCoverPath(collectionId, null);
  await reclaimDeletedCollectionAssets(
    db,
    <MediaCollectionRow>[snapshot],
    collectionCoversDirectory: collectionCoversDirectory,
  );
  await evictImageCacheForFile(File(coverPath));
}

/// 回收 [deletedCollections]（DB 行**已删**的合集快照）各自自有的磁盘资产。
///
/// 给「删行发生在事务里、文件 IO 必须挪到事务外」的调用方用（同步删除传播）。
/// 普通调用方直接用 [deleteMediaCollectionWithAssets]。
///
/// 返回实际删掉的文件数（便于测试断言）。删除失败 / 异常不抛——合集已经删掉是
/// 既成事实，一张残留图不该让整个删除流程报错。
Future<int> reclaimDeletedCollectionAssets(
  FushiDatabase db,
  Iterable<MediaCollectionRow> deletedCollections, {
  List<String> ownedImagePaths = const <String>[],
  Directory? collectionCoversDirectory,
}) async {
  final List<String> candidates = <String>[
    for (final MediaCollectionRow collection in deletedCollections)
      for (final String? path in collectionOwnedAssetPaths(collection))
        if (path != null && path.isNotEmpty) path,
    // v68 附加图：行已随删行 cascade 消失，路径由调用方删行前快照
    // （[collectionOwnedImagePaths]）。文件与合集封面同目录，共用同一护栏。
    for (final String path in ownedImagePaths)
      if (path.isNotEmpty) path,
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
      for (final MediaImageRow row in await db.getAllMediaImages()) row.path,
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
    engineLog.log('collection.reclaimAssets', e, stack);
  }
  return reclaimed;
}
