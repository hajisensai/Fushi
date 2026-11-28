/// 从库里读出作品图（[WorkGraph]）的输入并建图（AI 库管家 spec
/// `docs/specs/2026-11-18-ai-library-curator-design.md` §4.2）。
///
/// 全部是整表一次读、内存里 join，不逐合集 / 逐条查库（大库几万条目）。
library;

import 'package:drift/drift.dart' show QueryRow, ResultSetImplementation;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/book_series_key.dart';
import 'package:fushi_engine/media/links/work_graph.dart';

/// [loadWorkGraph] 读的全部表（含原生 SQL 里的）。作品图缓存按这些表的
/// `tableUpdates` 失效：只写其中一张（新导入的书只写 `epub_books`、刮削只写
/// `video_metadata_*`）也会改变图——系列合集判定、成员换算、外部 id 都靠它们。
/// 改了 [loadWorkGraph] 的读取就同步改这里。
List<ResultSetImplementation<dynamic, dynamic>> workGraphSourceTables(
  FushiDatabase db,
) => <ResultSetImplementation<dynamic, dynamic>>[
  db.mediaLinks,
  db.mediaCollections,
  db.mediaCollectionItems,
  db.epubBooks,
  db.srtBooks,
  db.videoMetadataWorks,
  db.videoMetadataProviderIdentities,
];

/// 读库建作品图。
///
/// - 连接：全部 `media_links` 行；状态只经 [mediaLinkStateOf] 判定（「已生效」的
///   定义改了这里自动跟上），种类 / 关系认不出的行（对端未来版本新增的值）跳过。
/// - 系列合集：见 [isWorkSeriesCollection]；成员键换算见 [_endpointOfMember]。
/// - 有外部 id 的视频合集端点：合集绑了 AniList id，或挂着带外部身份的刮削作品。
Future<WorkGraph> loadWorkGraph(FushiDatabase db) async {
  final List<MediaLinkRow> linkRows = await db.allMediaLinks();
  final List<MediaCollectionRow> collections = await db
      .getAllMediaCollections();
  final List<MediaCollectionItemRow> items = await db.getAllCollectionItems();
  final List<EpubBookMeta> books = await db.getEpubBookMetas();
  final List<QueryRow> srtRows = await db
      .customSelect('SELECT uid, book_key FROM srt_books')
      .get();
  final List<QueryRow> scrapedRows = await db
      .customSelect(
        'SELECT DISTINCT w.collection_id AS cid '
        'FROM video_metadata_works w '
        'JOIN video_metadata_provider_identities i ON i.work_id = w.id '
        'WHERE w.collection_id IS NOT NULL',
      )
      .get();

  final List<WorkGraphLink> links = <WorkGraphLink>[
    for (final MediaLinkRow row in linkRows) ?_linkOf(row),
  ];

  // epub 成员行的键是 `epub_books.uid`，图谱端点 `book` 的键是 bookKey。
  final Map<String, _Book> bookByUid = <String, _Book>{
    for (final EpubBookMeta b in books)
      if (b.uid.isNotEmpty) b.uid: (bookKey: b.bookKey, title: b.title),
  };
  final Map<String, _Book> bookByKey = <String, _Book>{
    for (final _Book b in bookByUid.values) b.bookKey: b,
  };
  // 有声书字幕书（srt）：有配对 EPUB 的归到那本书，没有的不进图（没有书端点可挂）。
  final Map<String, _Book> pairedBookBySrtUid = <String, _Book>{
    for (final QueryRow r in srtRows)
      if (bookByKey[r.read<String>('book_key')] case final _Book b)
        r.read<String>('uid'): b,
  };

  final Set<int> scrapedCollectionIds = <int>{
    for (final QueryRow r in scrapedRows) r.read<int>('cid'),
  };
  final Set<MediaLinkEndpoint> externalIdEndpoints = <MediaLinkEndpoint>{
    for (final MediaCollectionRow c in collections)
      if (c.anilistId != null || scrapedCollectionIds.contains(c.id))
        videoCollectionEndpoint(c.id),
  };

  final Map<int, List<MediaCollectionItemRow>> itemsByCollection =
      <int, List<MediaCollectionItemRow>>{};
  for (final MediaCollectionItemRow i in items) {
    (itemsByCollection[i.collectionId] ??= <MediaCollectionItemRow>[]).add(i);
  }

  final List<WorkSeriesCollection> series = <WorkSeriesCollection>[];
  for (final MediaCollectionRow c in collections) {
    final List<MediaLinkEndpoint> members = <MediaLinkEndpoint>[];
    final Map<MediaLinkEndpoint, String> bookTitles =
        <MediaLinkEndpoint, String>{};
    bool hasVideo = false;
    for (final MediaCollectionItemRow i
        in itemsByCollection[c.id] ?? const <MediaCollectionItemRow>[]) {
      final ({MediaLinkEndpoint endpoint, String? bookTitle})? m =
          _endpointOfMember(i, bookByUid, pairedBookBySrtUid);
      if (m == null) continue;
      members.add(m.endpoint);
      if (m.bookTitle case final String t) bookTitles[m.endpoint] = t;
      if (m.endpoint.kind == MediaLinkKind.videoEpisode) hasVideo = true;
    }
    if (members.isEmpty) continue;
    if (!isWorkSeriesCollection(
      collectionType: c.collectionType,
      sourceFolderPath: c.sourceFolderPath,
      origin: CollectionOrigin.parse(c.origin),
      organizeKey: c.organizeKey,
      hasVideo: hasVideo,
      hasWorkIdentity:
          hasVideo &&
          externalIdEndpoints.contains(videoCollectionEndpoint(c.id)),
      memberCount: members.toSet().length,
      bookTitles: bookTitles.values,
    )) {
      continue;
    }
    series.add(
      WorkSeriesCollection(
        id: c.id,
        endpoint: hasVideo ? videoCollectionEndpoint(c.id) : null,
        members: members,
      ),
    );
  }

  return WorkGraph.build(
    links: links,
    seriesCollections: series,
    externalIdEndpoints: externalIdEndpoints,
  );
}

/// 视频合集的图谱端点（键 = 合集 id 的十进制串，同 `MediaLinkKind.videoCollection`
/// 注释与 `collectionTagEntryKey`）。
MediaLinkEndpoint videoCollectionEndpoint(int collectionId) =>
    (kind: MediaLinkKind.videoCollection, key: '$collectionId');

/// 一个合集算不算作品图里的「系列合集」（成员之间成边）。
///
/// - 只认 `playlist`；主题型 `collection` 不算（spec §4.2）。
/// - 目录合集（[sourceFolderPath] 非空，或来源 `folder`）：含视频成员（[hasVideo]）
///   就算——视频库按目录建的合集本身就是一部作品的各集（所有者 2026-11-18 更正
///   spec），照常产出视频合集端点；只含书 / 漫画 / 游戏的不算（那是磁盘目录，不一定
///   是同一部作品）。
/// - 来源 `rule` / `ai`：一律算（整理器按系列建的）。
/// - 来源 `user`：存量合集全是 `user`（spec §8），用户随手建的阅读清单不能把不相干的
///   书连成一部作品，所以只在「像一个系列」时算：有整理分组键 [organizeKey]；或是带
///   作品身份的视频合集（[hasWorkIdentity]：绑了 AniList id / 挂着带外部 id 的刮削
///   作品）；或只装一个视频的合集（[memberCount] 为 1：合集就是那一个视频的外壳，
///   不可能把不相干的东西连起来；不认的话合集与它唯一那集会成两个互不相干的条目，
///   关系网画成两个一模一样的节点、AI 还会给它俩补「同一作品」）；或书成员里同一个 [parseBookSeriesKey] 系列键的书 ≥ 2 本且**超过全部
///   成员数的一半**（[memberCount] 是换算后的去重成员数——混了视频 / 游戏的合集按
///   全体算过半，比只在书里算过半更严）。
bool isWorkSeriesCollection({
  required String collectionType,
  required String? sourceFolderPath,
  required CollectionOrigin origin,
  required String? organizeKey,
  required bool hasVideo,
  required bool hasWorkIdentity,
  required int memberCount,
  required Iterable<String> bookTitles,
}) {
  if (collectionType != 'playlist') return false;
  if (sourceFolderPath != null || origin == CollectionOrigin.folder) {
    return hasVideo;
  }
  switch (origin) {
    case CollectionOrigin.rule:
    case CollectionOrigin.ai:
      return true;
    case CollectionOrigin.folder:
      return hasVideo; // 上面已处理，这里只为穷尽。
    case CollectionOrigin.user:
      if (organizeKey != null && organizeKey.isNotEmpty) return true;
      if (hasWorkIdentity) return true;
      if (hasVideo && memberCount == 1) return true;
      final Map<String, int> countByKey = <String, int>{};
      for (final String title in bookTitles) {
        final String? key = parseBookSeriesKey(title)?.key;
        if (key == null || key.isEmpty) continue;
        countByKey[key] = (countByKey[key] ?? 0) + 1;
      }
      int top = 0;
      for (final int n in countByKey.values) {
        if (n > top) top = n;
      }
      return top >= 2 && top * 2 > memberCount;
  }
}

typedef _Book = ({String bookKey, String title});

/// 合集成员行 `(mediaType, entryKey)` → 图谱端点。换算不了（本机没有这本书、
/// 未配对的 srt、未知种类）返回 null。书成员顺带带出书名，供系列判定。
({MediaLinkEndpoint endpoint, String? bookTitle})? _endpointOfMember(
  MediaCollectionItemRow item,
  Map<String, _Book> bookByUid,
  Map<String, _Book> pairedBookBySrtUid,
) {
  if (item.mediaType == MediaKind.epub.dbValue) {
    // 在线漫画（`isOnlineMangaSourceMetadata`）也在 epub_books 里，照常算书。
    final _Book? b = bookByUid[item.entryKey];
    return b == null
        ? null
        : (
            endpoint: (kind: MediaLinkKind.book, key: b.bookKey),
            bookTitle: b.title,
          );
  }
  if (item.mediaType == MediaKind.srt.dbValue) {
    final _Book? b = pairedBookBySrtUid[item.entryKey];
    return b == null
        ? null
        : (
            endpoint: (kind: MediaLinkKind.book, key: b.bookKey),
            bookTitle: b.title,
          );
  }
  if (item.mediaType == MediaKind.video.dbValue) {
    return (
      endpoint: (kind: MediaLinkKind.videoEpisode, key: item.entryKey),
      bookTitle: null,
    );
  }
  if (item.mediaType == MediaKind.game.dbValue) {
    return (
      endpoint: (kind: MediaLinkKind.game, key: item.entryKey),
      bookTitle: null,
    );
  }
  return null;
}

/// 一行连接 → 作品层输入。种类 / 关系认不出的返回 null。
WorkGraphLink? _linkOf(MediaLinkRow row) {
  final MediaLinkKind? fromKind = MediaLinkKind.tryParse(row.fromKind);
  final MediaLinkKind? toKind = MediaLinkKind.tryParse(row.toKind);
  final MediaLinkRelation? relation = MediaLinkRelation.tryParse(row.relation);
  if (fromKind == null || toKind == null || relation == null) return null;
  final MediaLinkState state = mediaLinkStateOf(row);
  final WorkLinkStatus status = state == MediaLinkState.confirmed
      ? WorkLinkStatus.effective
      : state == MediaLinkState.suggested
      ? WorkLinkStatus.suggested
      : WorkLinkStatus.rejected;
  return WorkGraphLink(
    from: (kind: fromKind, key: row.fromKey),
    relation: relation,
    to: (kind: toKind, key: row.toKey),
    status: status,
    source: row.source,
  );
}
