import 'dart:convert';

import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/shelf_sort.dart'
    show naturalCompare;
import 'package:fushi_engine/media/manga/manga_series_key.dart';

/// 在线漫画描述符类型标记（写进 `sourceMetadata`，永不变；同
/// `leaderboard/local_shelf.dart`）。在线漫画一行就是一整部作品，不按卷归组。
const Set<String> _onlineMangaMarkers = <String>{
  'hibiki-online-manga',
  'hibiki-mihon',
};

/// 一次归组的可核对结果。
typedef MangaSeriesGroupSummary = ({
  List<int> createdCollectionIds,
  List<int> updatedCollectionIds,
});

/// 本地漫画分卷 → 系列合集（与视频的 `VideoFolderGroupCoordinator` 同一套规则）：
///
/// - 只看本地漫画（`format == 'manga'`、非在线描述符）；
/// - 已经在任何合集里的卷不动——用户手动整理过的归属优先；
/// - 同系列 ≥2 卷且没有同名合集 → 新建 `playlist` 合集；已有同名 playlist（自然键）
///   → 新卷补进去（单卷也补）；
/// - 用户删过的同名合集不复活（合集级墓碑）；用户移出过的卷不再加回（成员墓碑，
///   按合集 wire 键比对，见 `collectionBookWireKey`）；
/// - 合集内按卷号 → natural 书名排；用户手动排过（`orderUpdatedAt > 0`）不重排。
///
/// 幂等：重复调用结果不变，可在每次导入后、打开漫画库时放心调用。
class MangaSeriesGrouper {
  const MangaSeriesGrouper(this._database);

  final FushiDatabase _database;

  Future<MangaSeriesGroupSummary> groupAll() async {
    final List<int> created = <int>[];
    final List<int> updated = <int>[];
    final Set<String> inCollection = <String>{
      for (final MediaCollectionItemRow item
          in await _database.getAllCollectionItems())
        if (item.mediaType == MediaKind.epub.dbValue) item.entryKey,
    };
    final Map<String, List<_Volume>> bySeries = <String, List<_Volume>>{};
    for (final EpubBookRow book in await _database.getAllEpubBooks()) {
      if (book.format != 'manga' || _isOnlineManga(book.sourceMetadata)) {
        continue;
      }
      if (inCollection.contains(book.uid)) continue;
      final MangaSeriesKey? key = parseMangaSeriesKey(book.title);
      if (key == null) continue;
      bySeries.putIfAbsent(key.key, () => <_Volume>[]).add(_Volume(book, key));
    }
    for (final List<_Volume> volumes in bySeries.values) {
      final int? id = await _groupSeries(volumes, created);
      if (id != null && !created.contains(id)) updated.add(id);
    }
    return (
      createdCollectionIds: List<int>.unmodifiable(created),
      updatedCollectionIds: List<int>.unmodifiable(updated),
    );
  }

  /// 归一个系列；有成员落进合集返回合集 id，否则 null。
  Future<int?> _groupSeries(List<_Volume> volumes, List<int> created) async {
    final String name = volumes.first.key.seriesTitle;
    MediaCollectionRow? collection = await _database
        .getMediaCollectionByNaturalKey(name, 'playlist');
    if (collection == null) {
      if (volumes.length < 2) return null;
      if (await _database.hasCollectionDeletionTombstone(name, 'playlist')) {
        return null;
      }
      final int id = await _database.createMediaCollection(
        name,
        collectionType: 'playlist',
      );
      created.add(id);
      collection = (await _database.getMediaCollectionById(id))!;
    }
    final Set<String> removed = await _removedMembers(name);
    bool added = false;
    for (final _Volume v in volumes) {
      final String wireKey = collectionBookWireKey(
        bookKey: v.book.bookKey,
        sourceMetadata: v.book.sourceMetadata,
      );
      if (removed.contains(wireKey)) continue;
      await _database.addToCollection(
        collection.id,
        MediaKind.epub,
        v.book.uid,
      );
      added = true;
    }
    if (!added) return null;
    if (collection.orderUpdatedAt == 0) await _sortMembers(collection.id);
    return collection.id;
  }

  Future<Set<String>> _removedMembers(String collectionName) async {
    final List<CollectionMemberTombstoneRow> rows =
        await (_database.select(_database.collectionMemberTombstones)..where(
              (t) =>
                  t.collectionName.equals(collectionName) &
                  t.collectionType.equals('playlist') &
                  t.mediaType.equals(MediaKind.epub.dbValue),
            ))
            .get();
    return <String>{
      for (final CollectionMemberTombstoneRow r in rows) r.entryKey,
    };
  }

  /// 合集内全部本地漫画成员按卷号（无卷号当第 0 卷）→ natural 书名排。
  Future<void> _sortMembers(int collectionId) async {
    final Map<String, EpubBookRow> booksByUid = <String, EpubBookRow>{
      for (final EpubBookRow b in await _database.getAllEpubBooks()) b.uid: b,
    };
    final List<_Volume> members = <_Volume>[];
    for (final MediaCollectionItemRow item
        in await _database.getCollectionItems(collectionId)) {
      if (item.mediaType != MediaKind.epub.dbValue) continue;
      final EpubBookRow? book = booksByUid[item.entryKey];
      final MangaSeriesKey? key = book == null
          ? null
          : parseMangaSeriesKey(book.title);
      if (book != null && key != null) members.add(_Volume(book, key));
    }
    members.sort(_compareVolumes);
    await _database.reorderCollectionItemsAutomatically(
      collectionId,
      <CollectionMemberKey>[
        for (final _Volume v in members)
          (mediaType: MediaKind.epub.dbValue, entryKey: v.book.uid),
      ],
    );
  }
}

class _Volume {
  const _Volume(this.book, this.key);

  final EpubBookRow book;
  final MangaSeriesKey key;
}

int _compareVolumes(_Volume a, _Volume b) {
  final int c = (a.key.volume ?? 0).compareTo(b.key.volume ?? 0);
  return c != 0 ? c : naturalCompare(a.book.title, b.book.title);
}

bool _isOnlineManga(String? sourceMetadata) {
  if (sourceMetadata == null) return false;
  try {
    final Object? value = jsonDecode(sourceMetadata);
    return value is Map<String, dynamic> &&
        _onlineMangaMarkers.contains(value['type']);
  } on FormatException {
    return false;
  }
}
