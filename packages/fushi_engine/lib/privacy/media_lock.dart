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

//// 一次性读出的上锁标记快照（几次批查）。只读，读完不随库变化——app 端按表变更
/// 重新加载。
///
/// 除了按宿主种类判定（[isLocked] 等），还给「不知道键属于哪种宿主」的消费端（收藏 /
/// 制卡历史 / 统计事实 / 活动流：行里只有一个来源键 bookKey / bookUid / gameId /
/// trackUid）一个统一判据 [isSourceKeyLocked]；legacy 没有身份键的行按显示名回退
/// [isTitleLocked]（宁可多藏）。
class MediaLockSnapshot {
  MediaLockSnapshot._({
    required Set<String> books,
    required Set<String> srtBooks,
    required Set<String> videos,
    required Set<String> games,
    required Set<int> collections,
    required Map<String, Set<int>> collectionsOfEntry,
    required Set<String> musicAlbums,
    required Set<String> musicTracks,
    required Set<String> memberKeys,
    required Set<String> titles,
  }) : _books = books,
       _srtBooks = srtBooks,
       _videos = videos,
       _games = games,
       _collections = collections,
       _collectionsOfEntry = collectionsOfEntry,
       _musicAlbums = musicAlbums,
       _musicTracks = musicTracks,
       _memberKeys = memberKeys,
       _titles = titles;

  /// 没有任何上锁标记（测试 / 未接库的调用方用）。
  static final MediaLockSnapshot none = MediaLockSnapshot._(
    books: const <String>{},
    srtBooks: const <String>{},
    videos: const <String>{},
    games: const <String>{},
    collections: const <int>{},
    collectionsOfEntry: const <String, Set<int>>{},
    musicAlbums: const <String>{},
    musicTracks: const <String>{},
    memberKeys: const <String>{},
    titles: const <String>{},
  );

  static Future<MediaLockSnapshot> load(FushiDatabase db) async {
    final Set<int> collections = <int>{
      for (final String k in await db.lockedEntryKeys(TagHostKind.collection))
        ?collectionIdOfTagEntryKey(k),
    };
    final Map<String, Set<int>> collectionsOfEntry = <String, Set<int>>{};
    // 上锁合集成员的原始成员键（不分种类），给 [isSourceKeyLocked] 用。
    final Set<String> memberKeys = <String>{};
    final Set<String> books = await db.lockedEntryKeys(TagHostKind.epub);
    final Set<String> srtUids = await db.lockedEntryKeys(TagHostKind.srt);
    final Set<String> videos = await db.lockedEntryKeys(TagHostKind.video);
    final Set<String> games = await db.lockedEntryKeys(TagHostKind.game);
    final Set<String> musicAlbums = await db.lockedEntryKeys(
      TagHostKind.musicAlbum,
    );
    // 「生效上锁」的各宿主键（自身上锁 ∪ 在上锁合集里）：显示名回退与 SRT bookKey
    // 登记都按它算。
    final Set<String> effectiveBooks = <String>{...books};
    final Set<String> effectiveSrt = <String>{...srtUids};
    final Set<String> effectiveVideos = <String>{...videos};
    final Set<String> effectiveGames = <String>{...games};
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
          memberKeys.add(key);
        }
        switch (MediaKind.tryParse(item.mediaType)) {
          case MediaKind.epub:
            effectiveBooks.add(entryKey);
          case MediaKind.srt:
            effectiveSrt.add(item.entryKey);
          case MediaKind.video:
            effectiveVideos.add(item.entryKey);
          case MediaKind.game:
            effectiveGames.add(item.entryKey);
          case _:
            break;
        }
      }
    }
    final Set<String> titles = <String>{};
    // 上锁的书也按 uid 登记（合集成员行 / 阅读位置按 uid 问）。
    final Set<String> bookUids = <String>{};
    if (effectiveBooks.isNotEmpty) {
      for (final TypedResult r
          in await (db.selectOnly(db.epubBooks)
                ..addColumns(<Expression<Object>>[
                  db.epubBooks.uid,
                  db.epubBooks.bookKey,
                  db.epubBooks.title,
                ])
                ..where(db.epubBooks.bookKey.isIn(effectiveBooks)))
              .get()) {
        if (r.read(db.epubBooks.title) case final String t when t.isNotEmpty) {
          titles.add(t);
        }
        if (!books.contains(r.read(db.epubBooks.bookKey))) continue;
        if (r.read(db.epubBooks.uid) case final String uid
            when uid.isNotEmpty) {
          bookUids.add(uid);
        }
      }
    }
    // 字幕书 / 有声书：uid 之外也登记 bookKey（收藏 / 制卡 / 统计行里的来源键是
    // bookKey，与 EPUB 共享 `hoshi://book/` 身份）。
    final Set<String> srtBooks = <String>{...srtUids};
    if (effectiveSrt.isNotEmpty) {
      for (final TypedResult r
          in await (db.selectOnly(db.srtBooks)
                ..addColumns(<Expression<Object>>[
                  db.srtBooks.uid,
                  db.srtBooks.bookKey,
                  db.srtBooks.title,
                ])
                ..where(db.srtBooks.uid.isIn(effectiveSrt)))
              .get()) {
        if (r.read(db.srtBooks.title) case final String t when t.isNotEmpty) {
          titles.add(t);
        }
        final String bookKey = r.read(db.srtBooks.bookKey) ?? '';
        if (bookKey.isEmpty) continue;
        if (srtUids.contains(r.read(db.srtBooks.uid))) {
          srtBooks.add(bookKey);
        } else {
          memberKeys.add(bookKey);
        }
      }
    }
    if (effectiveVideos.isNotEmpty) {
      for (final TypedResult r
          in await (db.selectOnly(db.videoBooks)
                ..addColumns(<Expression<Object>>[db.videoBooks.title])
                ..where(db.videoBooks.bookUid.isIn(effectiveVideos)))
              .get()) {
        if (r.read(db.videoBooks.title) case final String t when t.isNotEmpty) {
          titles.add(t);
        }
      }
    }
    if (effectiveGames.isNotEmpty) {
      for (final TypedResult r
          in await (db.selectOnly(db.galgames)
                ..addColumns(<Expression<Object>>[db.galgames.name])
                ..where(db.galgames.id.isIn(effectiveGames)))
              .get()) {
        if (r.read(db.galgames.name) case final String t when t.isNotEmpty) {
          titles.add(t);
        }
      }
    }
    // 上锁专辑的曲目（歌单 / 最近播放 / 歌词制卡行按 trackUid 问）。
    final Set<String> musicTracks = <String>{
      if (musicAlbums.isNotEmpty)
        for (final TypedResult r
            in await (db.selectOnly(db.musicTracks)
                  ..addColumns(<Expression<Object>>[db.musicTracks.trackUid])
                  ..where(db.musicTracks.albumUid.isIn(musicAlbums)))
                .get())
          ?r.read(db.musicTracks.trackUid),
    };
    return MediaLockSnapshot._(
      books: <String>{...books, ...bookUids},
      srtBooks: srtBooks,
      videos: videos,
      games: games,
      collections: collections,
      collectionsOfEntry: collectionsOfEntry,
      musicAlbums: musicAlbums,
      musicTracks: musicTracks,
      memberKeys: memberKeys,
      titles: titles,
    );
  }

  static Future<Map<String, String>> _bookKeyByUid(
    FushiDatabase db,
  ) async => <String, String>{
    for (final TypedResult r
        in await (db.selectOnly(db.epubBooks)..addColumns(<Expression<Object>>[
              db.epubBooks.uid,
              db.epubBooks.bookKey,
            ]))
            .get())
      if (r.read(db.epubBooks.uid) case final String uid when uid.isNotEmpty)
        uid: r.read(db.epubBooks.bookKey)!,
  };

  final Set<String> _books;
  final Set<String> _srtBooks;
  final Set<String> _videos;
  final Set<String> _games;
  final Set<int> _collections;
  final Set<String> _musicAlbums;
  final Set<String> _musicTracks;
  final Set<String> _memberKeys;
  final Set<String> _titles;

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

  /// [uid] 是 `srt_books.uid`；自身上锁的字幕书按它的 bookKey 问也认。
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

  /// 曲目跟着所在专辑上锁。
  bool isMusicTrackLocked(String trackUid) => _musicTracks.contains(trackUid);

  /// 种类不明的来源键（书 bookKey / uid、字幕书 uid / bookKey、视频 bookUid、
  /// 游戏 id、曲目 uid、专辑 uid）属于一部上锁的作品。各宿主的键空间互不重叠
  /// （uuid / `hoshi://` 身份），真撞上了也只会多藏。
  bool isSourceKeyLocked(String key) =>
      key.isNotEmpty &&
      (_books.contains(key) ||
          _srtBooks.contains(key) ||
          _videos.contains(key) ||
          _games.contains(key) ||
          _musicTracks.contains(key) ||
          _musicAlbums.contains(key) ||
          _memberKeys.contains(key));

  /// 显示名属于某部上锁作品。只给没有身份键的 legacy 行（统计 / 活动流）回退用，
  /// 宁可多藏。
  bool isTitleLocked(String title) =>
      title.isNotEmpty && _titles.contains(title);

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
          _deep.equals(_musicTracks, other._musicTracks) &&
          _deep.equals(_collections, other._collections) &&
          _deep.equals(_memberKeys, other._memberKeys) &&
          _deep.equals(_titles, other._titles) &&
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
