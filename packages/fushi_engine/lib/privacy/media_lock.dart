// 作品级「上锁」标记的读取口径（`media_locked_flags`，v171；拍板台 qiqSbvdxrk）。
//
// 作品隐私分级：公开 < 私密（`media_privacy.dart`，管出站）< 上锁（本文件）。上锁
// 蕴含私密——[MediaPrivacySnapshot] 把上锁的宿主一并算作私密——并且在本次会话解锁
// 之前，app 的库页 / 首页卡片 / 搜索 / 合集等列表消费端都不显示它（app 端
// `media_visibility.dart` 是唯一的过滤入口，消费端不各自判）。NSFW
// （`media_nsfw.dart`）是另一条轴：管封面要不要模糊，与分级互不蕴含。
//
// 判定口径（与 NSFW 同形，宁可多藏）：
// - 书 / 漫画 / 在线漫画 / 在线小说（epub_books 行）：本书上锁，或它所在的任一合集上锁；
//   bookKey 与 uid（合集成员行的键）两种都认；
// - 字幕书 / 有声书（srt_books）、视频文件、游戏：本身上锁，或所在任一合集上锁；
// - 合集：合集自己上锁；
// - 音乐专辑：专辑自己上锁（专辑不进合集）。

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';

/// 一次性读出的上锁标记快照（几次批查）。只读，读完不随库变化——app 端按表变更
/// 重新加载。
class MediaLockSnapshot {
  MediaLockSnapshot._({
    required Set<String> books,
    required Set<String> srtBooks,
    required Set<String> videos,
    required Set<String> games,
    required Set<int> collections,
    required Map<String, Set<int>> collectionsOfEntry,
    required Set<String> musicAlbums,
  }) : _books = books,
       _srtBooks = srtBooks,
       _videos = videos,
       _games = games,
       _collections = collections,
       _collectionsOfEntry = collectionsOfEntry,
       _musicAlbums = musicAlbums;

  /// 没有任何上锁标记（测试 / 未接库的调用方用）。
  static final MediaLockSnapshot none = MediaLockSnapshot._(
    books: const <String>{},
    srtBooks: const <String>{},
    videos: const <String>{},
    games: const <String>{},
    collections: const <int>{},
    collectionsOfEntry: const <String, Set<int>>{},
    musicAlbums: const <String>{},
  );

  static Future<MediaLockSnapshot> load(FushiDatabase db) async {
    final Set<int> collections = <int>{
      for (final String k in await db.lockedEntryKeys(TagHostKind.collection))
        ?collectionIdOfTagEntryKey(k),
    };
    final Map<String, Set<int>> collectionsOfEntry = <String, Set<int>>{};
    final Set<String> books = await db.lockedEntryKeys(TagHostKind.epub);
    if (collections.isNotEmpty) {
      // v83 起 EPUB 合集成员键是 `epub_books.uid`（旧行仍可能是 bookKey）：成员键
      // 归一到 bookKey，原始成员键也登记（书架按 bookKey 问，合集详情页按成员行
      // 的 entryKey 问），同 MediaNsfwSnapshot。
      final Map<String, String> bookKeyByUid = await _bookKeyByUid(db);
      for (final MediaCollectionItemRow item in await (db.select(
        db.mediaCollectionItems,
      )..where((t) => t.collectionId.isIn(collections))).get()) {
        final String entryKey = item.mediaType == MediaKind.epub.dbValue
            ? (bookKeyByUid[item.entryKey] ?? item.entryKey)
            : item.entryKey;
        for (final String key in <String>{entryKey, item.entryKey}) {
          (collectionsOfEntry[_memberKey(item.mediaType, key)] ??= <int>{}).add(
            item.collectionId,
          );
        }
      }
    }
    // 上锁的书也按 uid 登记（合集成员行 / 阅读位置按 uid 问）。
    final Set<String> bookUids = books.isEmpty
        ? const <String>{}
        : <String>{
            for (final TypedResult r
                in await (db.selectOnly(db.epubBooks)
                      ..addColumns(<Expression<Object>>[db.epubBooks.uid])
                      ..where(db.epubBooks.bookKey.isIn(books)))
                    .get())
              if (r.read(db.epubBooks.uid) case final String uid
                  when uid.isNotEmpty)
                uid,
          };
    return MediaLockSnapshot._(
      books: <String>{...books, ...bookUids},
      srtBooks: await db.lockedEntryKeys(TagHostKind.srt),
      videos: await db.lockedEntryKeys(TagHostKind.video),
      games: await db.lockedEntryKeys(TagHostKind.game),
      collections: collections,
      collectionsOfEntry: collectionsOfEntry,
      musicAlbums: await db.lockedEntryKeys(TagHostKind.musicAlbum),
    );
  }

  static Future<Map<String, String>> _bookKeyByUid(FushiDatabase db) async =>
      <String, String>{
        for (final TypedResult r
            in await (db.selectOnly(db.epubBooks)..addColumns(
                  <Expression<Object>>[db.epubBooks.uid, db.epubBooks.bookKey],
                ))
                .get())
          if (r.read(db.epubBooks.uid) case final String uid
              when uid.isNotEmpty)
            uid: r.read(db.epubBooks.bookKey)!,
      };

  final Set<String> _books;
  final Set<String> _srtBooks;
  final Set<String> _videos;
  final Set<String> _games;
  final Set<int> _collections;
  final Set<String> _musicAlbums;

  /// `mediaType|entryKey` → 它所在的上锁合集 id（只收上锁合集的成员）。
  final Map<String, Set<int>> _collectionsOfEntry;

  static String _memberKey(String mediaType, String entryKey) =>
      '$mediaType|$entryKey';

  bool get isEmpty =>
      _books.isEmpty &&
      _srtBooks.isEmpty &&
      _videos.isEmpty &&
      _games.isEmpty &&
      _musicAlbums.isEmpty &&
      _collections.isEmpty;

  bool _inLockedCollection(String mediaType, String entryKey) =>
      _collectionsOfEntry.containsKey(_memberKey(mediaType, entryKey));

  bool isCollectionLocked(int collectionId) =>
      _collections.contains(collectionId);

  /// [bookKey] 也可以是 `epub_books.uid`（合集成员行的键），两种都认。
  bool isBookLocked(String bookKey) =>
      _books.contains(bookKey) ||
      _inLockedCollection(MediaKind.epub.dbValue, bookKey);

  bool isSrtBookLocked(String uid) =>
      _srtBooks.contains(uid) ||
      _inLockedCollection(MediaKind.srt.dbValue, uid);

  bool isVideoLocked(String bookUid) =>
      _videos.contains(bookUid) ||
      _inLockedCollection(MediaKind.video.dbValue, bookUid);

  bool isGameLocked(String gameId) =>
      _games.contains(gameId) ||
      _inLockedCollection(MediaKind.game.dbValue, gameId);

  /// 音乐专辑只看自己的标记（专辑不进合集）。
  bool isMusicAlbumLocked(String albumUid) => _musicAlbums.contains(albumUid);

  /// 按标签宿主种类问（对话框 / 通用消费端用）。
  bool isLocked(TagHostKind kind, String entryKey) => switch (kind) {
    TagHostKind.epub => isBookLocked(entryKey),
    TagHostKind.srt => isSrtBookLocked(entryKey),
    TagHostKind.video => isVideoLocked(entryKey),
    TagHostKind.game => isGameLocked(entryKey),
    TagHostKind.collection => switch (collectionIdOfTagEntryKey(entryKey)) {
      final int id => isCollectionLocked(id),
      null => false,
    },
    TagHostKind.musicAlbum => isMusicAlbumLocked(entryKey),
  };

  static const DeepCollectionEquality _deep = DeepCollectionEquality();

  /// 内容相同。app 端按表变更重读后用它判断要不要广播新快照。
  bool sameAs(MediaLockSnapshot other) =>
      identical(this, other) ||
      (_deep.equals(_books, other._books) &&
          _deep.equals(_srtBooks, other._srtBooks) &&
          _deep.equals(_videos, other._videos) &&
          _deep.equals(_games, other._games) &&
          _deep.equals(_musicAlbums, other._musicAlbums) &&
          _deep.equals(_collections, other._collections) &&
          _deep.equals(_collectionsOfEntry, other._collectionsOfEntry));
}

/// [kind] / [entryKey] 宿主所在的、上锁的合集（按名字排序）。隐私对话框用它说明
/// 「这部作品因所在合集上锁而上锁」——只能到合集里解除。合集本身与音乐专辑恒空。
/// EPUB 成员键 v83 起是 uid、旧行仍是 bookKey，两种都认。
Future<List<MediaCollectionRow>> lockedCollectionsContaining(
  FushiDatabase db,
  TagHostKind kind,
  String entryKey,
) async {
  final String? mediaType = switch (kind) {
    TagHostKind.epub => MediaKind.epub.dbValue,
    TagHostKind.srt => MediaKind.srt.dbValue,
    TagHostKind.video => MediaKind.video.dbValue,
    TagHostKind.game => MediaKind.game.dbValue,
    TagHostKind.collection || TagHostKind.musicAlbum => null,
  };
  if (mediaType == null) return const <MediaCollectionRow>[];
  final Set<String> lockedIds = await db.lockedEntryKeys(
    TagHostKind.collection,
  );
  if (lockedIds.isEmpty) return const <MediaCollectionRow>[];
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
    if (!lockedIds.contains(collectionTagEntryKey(item.collectionId))) continue;
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
