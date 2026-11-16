// 作品级「NSFW」标记的读取口径（`media_nsfw_flags`，v155；拍板台 w04vrhUAaX）。
//
// NSFW 只管**显示**：「模糊 NSFW 封面」开着时封面消费端打模糊，「制卡图片也模糊」
// 开着时从它制的卡用模糊图。与私密（`media_privacy.dart`，管出站）互不蕴含。
//
// 判定口径（与私密同形）：
// - 书 / 漫画 / 在线漫画 / 在线小说（epub_books 行）：本书被标，或它所在的任一合集被标；
// - 字幕书 / 有声书（srt_books）：本书被标，或它所在的任一合集被标；
// - 视频文件：本集被标，或它所在的任一合集被标；
// - 合集：合集自己被标；
// - 游戏：所在的任一合集被标（游戏自己的成人向标记在 `GalgameCustomData.nsfw` /
//   刮削 `metadata.nsfw`，由调用方并入，见 app 端 `GalgameEntry.isNsfw`）。

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';

/// 一次性读出的 NSFW 标记快照（几次批查）。只读，读完不随库变化——app 端按表变更
/// 重新加载。
class MediaNsfwSnapshot {
  MediaNsfwSnapshot._({
    required Set<String> books,
    required Set<String> srtBooks,
    required Set<String> videos,
    required Set<int> collections,
    required Map<String, Set<int>> collectionsOfEntry,
  }) : _books = books,
       _srtBooks = srtBooks,
       _videos = videos,
       _collections = collections,
       _collectionsOfEntry = collectionsOfEntry;

  /// 没有任何 NSFW 标记（测试 / 未接库的调用方用）。
  static final MediaNsfwSnapshot none = MediaNsfwSnapshot._(
    books: const <String>{},
    srtBooks: const <String>{},
    videos: const <String>{},
    collections: const <int>{},
    collectionsOfEntry: const <String, Set<int>>{},
  );

  static Future<MediaNsfwSnapshot> load(FushiDatabase db) async {
    final Set<int> collections = <int>{
      for (final String k in await db.nsfwEntryKeys(TagHostKind.collection))
        ?collectionIdOfTagEntryKey(k),
    };
    final Map<String, Set<int>> collectionsOfEntry = <String, Set<int>>{};
    if (collections.isNotEmpty) {
      // v83 起 EPUB 合集成员键是 `epub_books.uid`（旧行仍可能是 bookKey），判定按
      // bookKey 问：成员键先归一到 bookKey（同 MediaPrivacySnapshot）。
      final Map<String, String> bookKeyByUid = <String, String>{
        for (final TypedResult r
            in await (db.selectOnly(db.epubBooks)..addColumns(
                  <Expression<Object>>[db.epubBooks.uid, db.epubBooks.bookKey],
                ))
                .get())
          if (r.read(db.epubBooks.uid) case final String uid
              when uid.isNotEmpty)
            uid: r.read(db.epubBooks.bookKey)!,
      };
      for (final MediaCollectionItemRow item
          in await (db.select(db.mediaCollectionItems)..where(
                (t) => t.collectionId.isIn(collections),
              ))
              .get()) {
        final String entryKey = item.mediaType == MediaKind.epub.dbValue
            ? (bookKeyByUid[item.entryKey] ?? item.entryKey)
            : item.entryKey;
        (collectionsOfEntry[_memberKey(item.mediaType, entryKey)] ??= <int>{})
            .add(item.collectionId);
      }
    }
    return MediaNsfwSnapshot._(
      books: await db.nsfwEntryKeys(TagHostKind.epub),
      srtBooks: await db.nsfwEntryKeys(TagHostKind.srt),
      videos: await db.nsfwEntryKeys(TagHostKind.video),
      collections: collections,
      collectionsOfEntry: collectionsOfEntry,
    );
  }

  final Set<String> _books;
  final Set<String> _srtBooks;
  final Set<String> _videos;
  final Set<int> _collections;

  /// `mediaType|entryKey` → 它所在的 NSFW 合集 id（只收 NSFW 合集的成员）。
  final Map<String, Set<int>> _collectionsOfEntry;

  static String _memberKey(String mediaType, String entryKey) =>
      '$mediaType|$entryKey';

  bool get isEmpty =>
      _books.isEmpty &&
      _srtBooks.isEmpty &&
      _videos.isEmpty &&
      _collections.isEmpty;

  bool _inNsfwCollection(String mediaType, String entryKey) =>
      _collectionsOfEntry.containsKey(_memberKey(mediaType, entryKey));

  bool isCollectionNsfw(int collectionId) =>
      _collections.contains(collectionId);

  bool isBookNsfw(String bookKey) =>
      _books.contains(bookKey) ||
      _inNsfwCollection(MediaKind.epub.dbValue, bookKey);

  bool isSrtBookNsfw(String uid) =>
      _srtBooks.contains(uid) || _inNsfwCollection(MediaKind.srt.dbValue, uid);

  bool isVideoNsfw(String bookUid) =>
      _videos.contains(bookUid) ||
      _inNsfwCollection(MediaKind.video.dbValue, bookUid);

  /// 游戏只看合集继承；游戏自己的成人向标记由调用方并入。
  bool isGameInNsfwCollection(String gameId) =>
      _inNsfwCollection(MediaKind.game.dbValue, gameId);

  /// 按标签宿主种类问（对话框 / 通用消费端用）。
  bool isNsfw(TagHostKind kind, String entryKey) => switch (kind) {
    TagHostKind.epub => isBookNsfw(entryKey),
    TagHostKind.srt => isSrtBookNsfw(entryKey),
    TagHostKind.video => isVideoNsfw(entryKey),
    TagHostKind.game => isGameInNsfwCollection(entryKey),
    TagHostKind.collection => switch (collectionIdOfTagEntryKey(entryKey)) {
      final int id => isCollectionNsfw(id),
      null => false,
    },
  };
}

/// [kind] / [entryKey] 宿主所在的、被标成 NSFW 的合集（按名字排序）。NSFW 开关用它
/// 说明「这部作品因所在合集 NSFW 而 NSFW」——只能到合集里取消。合集本身恒空。
/// EPUB 成员键 v83 起是 uid、旧行仍是 bookKey，两种都认。
Future<List<MediaCollectionRow>> nsfwCollectionsContaining(
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
  final Set<String> nsfwIds = await db.nsfwEntryKeys(TagHostKind.collection);
  if (nsfwIds.isEmpty) return const <MediaCollectionRow>[];
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
    if (!nsfwIds.contains(collectionTagEntryKey(item.collectionId))) continue;
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
