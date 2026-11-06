// 作品级「私密」标记的读取口径（`media_privacy_flags`，v122）。
//
// 私密作品不进公开 / 绑定用户外部账户的出站路径：不上传排行榜（[buildLocalShelf]
// 跳过，已上传过的由书架同步自动从服务端删除），不推 Bangumi 进度、也不拿它的标题
// 去 Bangumi 搜自动映射（`MediaTrackingService`）。每日总字数只是「日期 → 字数」不带
// 作品身份，照常计入。**不**管的范围：互联（自己配对的设备照常看得到、标记本身也搭
// 标签清单同步过去）、备份 / 云盘、匿名元数据刮削请求、用户主动提交的反馈与日志。
//
// 判定口径（宁可多藏）：
// - 书 / 漫画 / 在线漫画 / 在线小说（epub_books 行）：本书被标，或它所在的任一合集被标；
// - 视频文件：本集被标，或它所在的任一合集被标；
// - 视频作品单元 / 合集级追踪：合集被标，或单元里任一集是私密的；
// - 游戏：本游戏被标，或它所在的任一合集被标（游戏也能加入合集）。
// - 隐私来源（`media_sources.is_private`，v140）：扫描根开了隐私开关，它产出的书 /
//   漫画（epub_books.source_id）与视频文件（video_books.source_id）一律当作被标——
//   与作品级标记同一口径，下游（排行榜 / Bangumi）不用各自再判来源。移除来源时
//   这些条目会被逐一补上作品级标记（`deleteMediaSource`），不会因此变回公开。

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';

/// 一次性读出的私密标记快照（几次批查，库规模几千行量级）。只读，读完不随库变化。
class MediaPrivacySnapshot {
  MediaPrivacySnapshot._({
    required Set<String> books,
    required Set<String> videos,
    required Set<int> collections,
    required Set<String> games,
    required Map<String, Set<int>> collectionsOfEntry,
    required Map<int, Set<String>> videoMembersOf,
  }) : _books = books,
       _videos = videos,
       _collections = collections,
       _games = games,
       _collectionsOfEntry = collectionsOfEntry,
       _videoMembersOf = videoMembersOf;

  /// 没有任何私密标记（测试 / 未接库的调用方用）。
  static final MediaPrivacySnapshot none = MediaPrivacySnapshot._(
    books: const <String>{},
    videos: const <String>{},
    collections: const <int>{},
    games: const <String>{},
    collectionsOfEntry: const <String, Set<int>>{},
    videoMembersOf: const <int, Set<String>>{},
  );

  static Future<MediaPrivacySnapshot> load(FushiDatabase db) async {
    final Set<int> privateSources = await db.privateMediaSourceIds();
    final Set<String> books = await db.privateEntryKeys(TagHostKind.epub);
    final Set<String> videos = await db.privateEntryKeys(TagHostKind.video);
    if (privateSources.isNotEmpty) {
      books.addAll(
        await (db.selectOnly(db.epubBooks)
              ..addColumns(<Expression<Object>>[db.epubBooks.bookKey])
              ..where(db.epubBooks.sourceId.isIn(privateSources)))
            .map((TypedResult r) => r.read(db.epubBooks.bookKey)!)
            .get(),
      );
      videos.addAll(
        await (db.selectOnly(db.videoBooks)
              ..addColumns(<Expression<Object>>[db.videoBooks.bookUid])
              ..where(db.videoBooks.sourceId.isIn(privateSources)))
            .map((TypedResult r) => r.read(db.videoBooks.bookUid)!)
            .get(),
      );
    }
    final Set<int> collections = <int>{
      for (final String k in await db.privateEntryKeys(TagHostKind.collection))
        ?collectionIdOfTagEntryKey(k),
    };
    final Map<String, Set<int>> collectionsOfEntry = <String, Set<int>>{};
    final Map<int, Set<String>> videoMembersOf = <int, Set<String>>{};
    // v83 起 EPUB 合集成员键是 `epub_books.uid`（旧行仍可能是 bookKey），而私密
    // 判定与排行榜 / 追踪都按 bookKey 问：成员键先归一到 bookKey，否则私密合集里
    // 的书一本都命不中（fail-open）。
    final Map<String, String> bookKeyByUid = <String, String>{
      for (final TypedResult r
          in await (db.selectOnly(db.epubBooks)..addColumns(
                <Expression<Object>>[db.epubBooks.uid, db.epubBooks.bookKey],
              ))
              .get())
        if (r.read(db.epubBooks.uid) case final String uid when uid.isNotEmpty)
          uid: r.read(db.epubBooks.bookKey)!,
    };
    for (final MediaCollectionItemRow item
        in await db.getAllCollectionItems()) {
      final String entryKey = item.mediaType == MediaKind.epub.dbValue
          ? (bookKeyByUid[item.entryKey] ?? item.entryKey)
          : item.entryKey;
      (collectionsOfEntry[_memberKey(item.mediaType, entryKey)] ??= <int>{})
          .add(item.collectionId);
      if (item.mediaType == MediaKind.video.dbValue) {
        (videoMembersOf[item.collectionId] ??= <String>{}).add(item.entryKey);
      }
    }
    return MediaPrivacySnapshot._(
      books: books,
      videos: videos,
      collections: collections,
      games: await db.privateEntryKeys(TagHostKind.game),
      collectionsOfEntry: collectionsOfEntry,
      videoMembersOf: videoMembersOf,
    );
  }

  final Set<String> _books;
  final Set<String> _videos;
  final Set<int> _collections;
  final Set<String> _games;

  /// `mediaType|entryKey` → 它所在的合集 id。
  final Map<String, Set<int>> _collectionsOfEntry;

  /// 合集 id → 视频成员 bookUid。
  final Map<int, Set<String>> _videoMembersOf;

  static String _memberKey(String mediaType, String entryKey) =>
      '$mediaType|$entryKey';

  bool get isEmpty =>
      _books.isEmpty &&
      _videos.isEmpty &&
      _collections.isEmpty &&
      _games.isEmpty;

  bool _inPrivateCollection(String mediaType, String entryKey) =>
      (_collectionsOfEntry[_memberKey(mediaType, entryKey)] ?? const <int>{})
          .any(_collections.contains);

  bool isCollectionPrivate(int collectionId) =>
      _collections.contains(collectionId);

  bool isBookPrivate(String bookKey) =>
      _books.contains(bookKey) ||
      _inPrivateCollection(MediaKind.epub.dbValue, bookKey);

  bool isVideoPrivate(String bookUid) =>
      _videos.contains(bookUid) ||
      _inPrivateCollection(MediaKind.video.dbValue, bookUid);

  /// 视频作品单元（[collectionId] 为单元所属合集，按文件成单元时为 null）。
  bool isVideoUnitPrivate(Iterable<String> memberUids, {int? collectionId}) =>
      (collectionId != null && _collections.contains(collectionId)) ||
      memberUids.any(isVideoPrivate);

  /// 合集级视频追踪：合集被标，或任一视频成员是私密的。
  bool isVideoCollectionPrivate(int collectionId) => isVideoUnitPrivate(
    _videoMembersOf[collectionId] ?? const <String>{},
    collectionId: collectionId,
  );

  bool isGamePrivate(String gameId) =>
      _games.contains(gameId) ||
      _inPrivateCollection(MediaKind.game.dbValue, gameId);
}

/// [kind] / [entryKey] 宿主所在的、被标成私密的合集（按名字排序）。作品级私密开关
/// 用它说明「这部作品因所在合集私密而私密」——那份私密只能到合集里取消，作品自己
/// 的开关拨不掉它。合集本身（[TagHostKind.collection]）不会再被别的合集收容，恒空。
///
/// 判定口径与 [MediaPrivacySnapshot] 相同：EPUB 成员键 v83 起是 uid、旧行仍是
/// bookKey，两种都认。
Future<List<MediaCollectionRow>> privateCollectionsContaining(
  FushiDatabase db,
  TagHostKind kind,
  String entryKey,
) async {
  final String? mediaType = switch (kind) {
    TagHostKind.epub => MediaKind.epub.dbValue,
    TagHostKind.srt => MediaKind.srt.dbValue,
    TagHostKind.video => MediaKind.video.dbValue,
    TagHostKind.game => MediaKind.game.dbValue,
    TagHostKind.collection => null,
  };
  if (mediaType == null) return const <MediaCollectionRow>[];
  final Set<String> privateIds = await db.privateEntryKeys(
    TagHostKind.collection,
  );
  if (privateIds.isEmpty) return const <MediaCollectionRow>[];
  final String? uid = kind == TagHostKind.epub
      ? await db.resolveEpubBookUid(entryKey)
      : null;
  final Set<String> memberKeys = <String>{entryKey, ?uid};
  final List<MediaCollectionItemRow> items =
      await (db.select(db.mediaCollectionItems)..where(
            (t) => t.mediaType.equals(mediaType) & t.entryKey.isIn(memberKeys),
          ))
          .get();
  final List<MediaCollectionRow> result = <MediaCollectionRow>[];
  final Set<int> seen = <int>{};
  for (final MediaCollectionItemRow item in items) {
    if (!seen.add(item.collectionId)) continue;
    if (!privateIds.contains(collectionTagEntryKey(item.collectionId))) {
      continue;
    }
    final MediaCollectionRow? row = await db.getMediaCollectionById(
      item.collectionId,
    );
    if (row != null) result.add(row);
  }
  result.sort(
    (MediaCollectionRow a, MediaCollectionRow b) => a.name.compareTo(b.name),
  );
  return result;
}

/// [kind] / [entryKey] 宿主所属的、开着隐私开关的来源库（v140 `media_sources.is_private`；
/// 没有 = null）。作品级私密开关用它说明「这部作品因所在来源库私密而私密」——那份私密
/// 只能到来源库里取消。只有书 / 漫画（epub_books）与视频文件（video_books）挂来源库。
Future<MediaSourceRow?> privateSourceLibraryContaining(
  FushiDatabase db,
  TagHostKind kind,
  String entryKey,
) async {
  final int? sourceId = switch (kind) {
    TagHostKind.epub =>
      await (db.selectOnly(db.epubBooks)
            ..addColumns(<Expression<Object>>[db.epubBooks.sourceId])
            ..where(db.epubBooks.bookKey.equals(entryKey))
            ..limit(1))
          .map((TypedResult r) => r.read(db.epubBooks.sourceId))
          .getSingleOrNull(),
    TagHostKind.video =>
      await (db.selectOnly(db.videoBooks)
            ..addColumns(<Expression<Object>>[db.videoBooks.sourceId])
            ..where(db.videoBooks.bookUid.equals(entryKey))
            ..limit(1))
          .map((TypedResult r) => r.read(db.videoBooks.sourceId))
          .getSingleOrNull(),
    TagHostKind.srt || TagHostKind.game || TagHostKind.collection => null,
  };
  if (sourceId == null) return null;
  final MediaSourceRow? source = await db.getMediaSourceById(sourceId);
  return source != null && source.isPrivate ? source : null;
}
