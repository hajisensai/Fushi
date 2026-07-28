import 'package:hibiki/src/media/collections/shelf_sort.dart'
    show naturalCompare;
import 'package:hibiki/src/mining/metadata/galgame_metadata_merge.dart'
    show GalgameCustomData;
import 'package:hibiki_core/hibiki_core.dart';

/// 合集「一键整理」（按名称 natural，卷1<卷2<卷10 / 按导入时间旧→新）的共享
/// 实现。此前该逻辑只活在书架网格详情页（`MediaCollectionGridDetailPage`），
/// 视频详情页另有一份内存版，三库页合集右键菜单则完全没有排序入口；现收口成
/// 唯一真相源：详情页与合集右键菜单同一比较器、同一落盘路径
/// （[HibikiDatabase.reorderCollectionItems]），库页合集行 / 播放器换集读同一
/// `getCollectionItems`，落盘即同序。
///
/// 成员标题 / 导入时间从 epub / srt / galgames / videoBooks 四表现查（成员行只
/// 有身份键）；查不到的成员（孤儿 / 对端未知种类）按 `(entryKey, 0)` 兜底排序，
/// 不 throw。游戏标题取用户覆盖名（customDataJson.name）优先；视频改名直接写
/// `videoBooks.title`，raw 列即显示名。
Future<List<MediaCollectionItemRow>> sortedCollectionRows({
  required HibikiDatabase db,
  required List<MediaCollectionItemRow> rows,
  required bool byTitle,
}) async {
  final List<EpubBookRow> epubs = await db.getAllEpubBooks();
  final List<SrtBookRow> srts = await db.getAllSrtBooks();
  final List<GalgameRow> games = await db.getAllGalgames();
  final List<VideoBookRow> videos = await db.allVideoBooks();
  final Map<String, ({String title, int importedAt})> meta =
      <String, ({String title, int importedAt})>{
    for (final EpubBookRow r in epubs)
      MediaKind.epub.compositeKey(r.bookKey): (
        title: r.title,
        importedAt: r.importedAt,
      ),
    for (final SrtBookRow r in srts)
      MediaKind.srt.compositeKey(r.uid): (
        title: r.title,
        importedAt: r.importedAt,
      ),
    for (final GalgameRow r in games)
      MediaKind.game.compositeKey(r.id): (
        title: GalgameCustomData.decode(r.customDataJson).name ?? r.name,
        importedAt: r.addedAt,
      ),
    for (final VideoBookRow r in videos)
      MediaKind.video.compositeKey(r.bookUid): (
        title: r.title,
        // v57 起 importedAt 才有真值；旧数据 null 按 0（最旧）兜底。
        importedAt: r.importedAt ?? 0,
      ),
  };
  ({String title, int importedAt}) metaOf(MediaCollectionItemRow r) =>
      meta['${r.mediaType}|${r.entryKey}'] ??
      (title: r.entryKey, importedAt: 0);
  return List<MediaCollectionItemRow>.of(rows)
    ..sort((MediaCollectionItemRow a, MediaCollectionItemRow b) {
      final ({String title, int importedAt}) ma = metaOf(a);
      final ({String title, int importedAt}) mb = metaOf(b);
      if (byTitle) {
        final int c = naturalCompare(ma.title, mb.title);
        return c != 0 ? c : ma.importedAt.compareTo(mb.importedAt);
      }
      final int c = ma.importedAt.compareTo(mb.importedAt);
      return c != 0 ? c : naturalCompare(ma.title, mb.title);
    });
}

/// 从库页合集右键菜单触发的一键整理：取成员 → [sortedCollectionRows] →
/// 一次落盘 sortIndex。成员少于 2 个时无序可整，直接返回（不空写库）。
Future<void> applyCollectionOneKeySort({
  required HibikiDatabase db,
  required int collectionId,
  required bool byTitle,
}) async {
  final List<MediaCollectionItemRow> rows =
      await db.getCollectionItems(collectionId);
  if (rows.length < 2) return;
  final List<MediaCollectionItemRow> next =
      await sortedCollectionRows(db: db, rows: rows, byTitle: byTitle);
  await db.reorderCollectionItems(
    collectionId,
    <({String mediaType, String entryKey})>[
      for (final MediaCollectionItemRow r in next)
        (mediaType: r.mediaType, entryKey: r.entryKey),
    ],
  );
}
