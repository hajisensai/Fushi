// 作品级「私密」标记的读取口径（`media_privacy_flags`，v121）。
//
// 私密作品不离开本机：不上传排行榜（[buildLocalShelf] 跳过，已上传过的由书架同步
// 自动从服务端删除），不推 Bangumi 进度、也不拿它的标题去 Bangumi 搜自动映射
// （`MediaTrackingService`）。每日总字数只是「日期 → 字数」不带作品身份，照常计入。
//
// 判定口径（宁可多藏）：
// - 书 / 漫画 / 在线漫画 / 在线小说（epub_books 行）：本书被标，或它所在的任一合集被标；
// - 视频文件：本集被标，或它所在的任一合集被标；
// - 视频作品单元 / 合集级追踪：合集被标，或单元里任一集是私密的；
// - 游戏：本游戏被标。

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
    final Set<int> collections = <int>{
      for (final String k in await db.privateEntryKeys(TagHostKind.collection))
        ?collectionIdOfTagEntryKey(k),
    };
    final Map<String, Set<int>> collectionsOfEntry = <String, Set<int>>{};
    final Map<int, Set<String>> videoMembersOf = <int, Set<String>>{};
    for (final MediaCollectionItemRow item
        in await db.getAllCollectionItems()) {
      (collectionsOfEntry[_memberKey(item.mediaType, item.entryKey)] ??=
              <int>{})
          .add(item.collectionId);
      if (item.mediaType == MediaKind.video.dbValue) {
        (videoMembersOf[item.collectionId] ??= <String>{}).add(item.entryKey);
      }
    }
    return MediaPrivacySnapshot._(
      books: await db.privateEntryKeys(TagHostKind.epub),
      videos: await db.privateEntryKeys(TagHostKind.video),
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

  bool isGamePrivate(String gameId) => _games.contains(gameId);
}
