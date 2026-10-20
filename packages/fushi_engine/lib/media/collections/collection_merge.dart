import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/collection_asset_reclaim.dart';

/// 把 [sourceIds] 这几个合集并进 [targetId]：源合集成员原样搬进目标（尾插、去重），
/// 源合集解散（[deleteMediaCollectionWithAssets]，只删分组不删条目，写合集级墓碑）。
///
/// 合并的**唯一入口**：书架 / 视频库的批量合并、AI 整理、整理收敛都调这里，
/// 不在页面里各写一份搬成员的循环。
///
/// - 成员按源合集**当前**成员行搬（调用前若开过确认框，框开着期间同步进来的新成员
///   也会被带上，复查 #6 TOCTOU）；
/// - 走 raw 版加成员：行值可能是对端未知种类，tryParse 丢弃会静默丢成员；
/// - 目标合集里用户移出过的成员（成员墓碑）**不**并回来：加成员会清墓碑，等于替
///   用户撤销移出（[skipTombstonedInTarget]）；
/// - [userIntent] 为 false（AI 整理、收敛）时不把目标合集转成用户所有；
/// - [deletedAt]：源合集删除墓碑时刻（缺省 now，见 [FushiDatabase.deleteMediaCollection]）。
///
/// 目标不存在、或源与目标重合的 id 跳过。返回实际解散的源合集数。
Future<int> mergeMediaCollectionsInto(
  FushiDatabase db, {
  required int targetId,
  required Iterable<int> sourceIds,
  bool userIntent = true,
  bool skipTombstonedInTarget = false,
  int? deletedAt,
}) async {
  final MediaCollectionRow? target = await db.getMediaCollectionById(targetId);
  if (target == null) return 0;
  final Set<String> targetTombstones = skipTombstonedInTarget
      ? await db.collectionMemberTombstoneKeysFor(
          target.name,
          target.collectionType,
        )
      : const <String>{};
  int merged = 0;
  for (final int sourceId in sourceIds.toSet()) {
    if (sourceId == targetId) continue;
    final MediaCollectionRow? source = await db.getMediaCollectionById(
      sourceId,
    );
    if (source == null) continue;
    for (final MediaCollectionItemRow m in await db.getCollectionItems(
      sourceId,
    )) {
      if (targetTombstones.isNotEmpty &&
          targetTombstones.contains(
            await db.collectionMemberTombstoneKeyOf(m.mediaType, m.entryKey),
          )) {
        continue;
      }
      await db.addToCollectionRaw(
        targetId,
        m.mediaType,
        m.entryKey,
        userIntent: userIntent,
      );
    }
    await db.absorbOrganizeIdentity(targetId: targetId, source: source);
    await deleteMediaCollectionWithAssets(
      db,
      sourceId,
      deletedAt: deletedAt,
      // 删除记下「并掉」：收到这条删除的设备知道它不是用户拒绝。
      organizeMerged: true,
    );
    merged++;
  }
  return merged;
}
