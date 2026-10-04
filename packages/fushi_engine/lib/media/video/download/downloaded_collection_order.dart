import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_filename_parser.dart';
import 'package:fushi_engine/sync/collection_sync_engine.dart';

/// 下载管理合集的**派生集序**——单一真相源（BUG-2941）。
///
/// 下载合集的成员是独立下载任务按完成先后一集集落进来的，没有「用户写出来的
/// 顺序」，唯一正确的序是集号序。两处必须得出**同一个**全序：
/// - 本机落库后的自动整理（`VideoBookRepository.reorderDownloadedCollectionEpisodes`）；
/// - 合集同步在两端都没手动排过序时的合并（[loadDownloadedCollectionDerivedOrder]）。
/// 两处口径一旦不同，同步每轮都会判「本地与合并结果不一致」而来回改写。
///
/// 全序：有集号的按季（缺省第 1 季）→ 集；解不出集号的（PV / 特典 / 非视频成员）
/// 殿后；最后按成员键字典序兜底，保证两端对同一成员集得出逐字节相同的顺序。
List<CollectionMemberKey> orderDownloadedCollectionMembers(
  Iterable<CollectionMemberKey> members, {
  required Map<String, String> videoPathByUid,
}) {
  String keyOf(CollectionMemberKey m) => '${m.mediaType}\u0000${m.entryKey}';
  // 本机有集行时用真实路径（季号可能只写在父目录上）；没有（对端独有的成员）
  // 退回 entryKey——下载集的 bookUid 就是 `video/<文件名主干>`，集号同样解得出。
  String pathOf(CollectionMemberKey m) => m.mediaType == MediaKind.video.dbValue
      ? (videoPathByUid[m.entryKey] ?? m.entryKey)
      : m.entryKey;
  final Map<CollectionMemberKey, VideoNameInfo> infoOf =
      <CollectionMemberKey, VideoNameInfo>{
        for (final CollectionMemberKey m in members)
          m: parseVideoPath(pathOf(m)),
      };
  int compare(CollectionMemberKey a, CollectionMemberKey b) {
    final VideoNameInfo ia = infoOf[a]!;
    final VideoNameInfo ib = infoOf[b]!;
    final int extrasA = ia.episode == null ? 1 : 0;
    final int extrasB = ib.episode == null ? 1 : 0;
    if (extrasA != extrasB) return extrasA.compareTo(extrasB);
    final int seasonCmp = (ia.season ?? 1).compareTo(ib.season ?? 1);
    if (seasonCmp != 0) return seasonCmp;
    final int episodeCmp = (ia.episode ?? 0).compareTo(ib.episode ?? 0);
    if (episodeCmp != 0) return episodeCmp;
    return keyOf(a).compareTo(keyOf(b));
  }

  return infoOf.keys.toList()..sort(compare);
}

/// 为合集同步装配 [CollectionDerivedOrder]：仅对本机的下载管理合集给出集号序，
/// 其余合集返回 null（照旧走「平手取远端」）。
///
/// 只需要**一端**知道某合集是下载合集：它合并出的集号序写回共享清单后，另一端
/// 平手取远端时拿到的就是这个序，两端收敛。
Future<CollectionDerivedOrder> loadDownloadedCollectionDerivedOrder(
  FushiDatabase db,
) async {
  final Set<String> managed = <String>{};
  final Map<String, String> videoPathByUid = <String, String>{};
  for (final int id in await db.downloadManagedCollectionIds()) {
    final MediaCollectionRow? row = await db.getMediaCollectionById(id);
    if (row == null) continue;
    managed.add('${row.name}\u0000${row.collectionType}');
    for (final MediaCollectionItemRow item in await db.getCollectionItems(id)) {
      if (item.mediaType != MediaKind.video.dbValue) continue;
      final VideoBookRow? book = await db.getVideoBookByBookUid(item.entryKey);
      if (book != null) videoPathByUid[book.bookUid] = book.videoPath;
    }
  }
  return (
    String name,
    String collectionType,
    List<CollectionMemberKey> members,
  ) {
    if (!managed.contains('$name\u0000$collectionType')) return null;
    return orderDownloadedCollectionMembers(
      members,
      videoPathByUid: videoPathByUid,
    );
  };
}
