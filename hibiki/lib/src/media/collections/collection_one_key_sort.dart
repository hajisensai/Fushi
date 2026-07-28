import 'package:hibiki/src/media/collections/shelf_sort.dart'
    show naturalCompare;
import 'package:hibiki/src/mining/metadata/galgame_metadata_merge.dart'
    show GalgameCustomData;
import 'package:hibiki_core/hibiki_core.dart';

/// 排序一个合集成员所需的最小事实：显示标题、导入时刻、身份键。
///
/// 身份键只用于**平局兜底**：标题与导入时刻都相同时，若不再比一个稳定的键，
/// `List.sort`（非稳定排序）会让这些条目每次落盘顺序都可能不同。
typedef CollectionSortMeta = ({String title, int importedAt, String key});

/// 合集「一键整理」的**比较规则**——唯一真相源。
///
/// 三个入口（书架网格详情页 / 视频合集详情页 / 三库页合集右键菜单）共用本函数，
/// 各自只负责把成员翻译成 [CollectionSortMeta]（元数据来源天然不同：网格详情页与
/// 右键菜单要现查四表，视频详情页的成员行已经在内存里）。**规则**收口在这里，
/// 「怎么拿到标题」不强行收口——那是 IO，不是规则。
///
/// - [byTitle]：按名称 natural（卷1 < 卷2 < 卷10），平局比导入时刻，再平局比身份键；
/// - 否则按导入时刻旧→新，平局比名称，再平局比身份键。
int compareCollectionMembers(
  CollectionSortMeta a,
  CollectionSortMeta b, {
  required bool byTitle,
}) {
  if (byTitle) {
    final int byName = naturalCompare(a.title, b.title);
    if (byName != 0) return byName;
    final int byTime = a.importedAt.compareTo(b.importedAt);
    return byTime != 0 ? byTime : a.key.compareTo(b.key);
  }
  final int byTime = a.importedAt.compareTo(b.importedAt);
  if (byTime != 0) return byTime;
  final int byName = naturalCompare(a.title, b.title);
  return byName != 0 ? byName : a.key.compareTo(b.key);
}

/// 合集「一键整理」在**库页右键菜单 / 书架网格详情页**的实现：成员行只有身份键，
/// 故标题 / 导入时间从 epub / srt / galgames / videoBooks 四表现查；查不到的成员
/// （孤儿 / 对端未知种类）按 `(entryKey, 0)` 兜底排序，不 throw。游戏标题取用户
/// 覆盖名（customDataJson.name）优先；视频改名直接写 `videoBooks.title`，raw 列
/// 即显示名。
///
/// 排序规则本身走共享的 [compareCollectionMembers]。落盘走
/// [HibikiDatabase.reorderCollectionItems]，库页合集行 / 播放器换集读同一
/// `getCollectionItems`，落盘即同序。
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
  CollectionSortMeta sortMetaOf(MediaCollectionItemRow r) {
    final ({String title, int importedAt}) m = metaOf(r);
    return (
      title: m.title,
      importedAt: m.importedAt,
      key: '${r.mediaType}|${r.entryKey}',
    );
  }

  return List<MediaCollectionItemRow>.of(rows)
    ..sort(
      (MediaCollectionItemRow a, MediaCollectionItemRow b) =>
          compareCollectionMembers(
        sortMetaOf(a),
        sortMetaOf(b),
        byTitle: byTitle,
      ),
    );
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
