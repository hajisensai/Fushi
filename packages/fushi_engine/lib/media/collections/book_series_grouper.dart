import 'dart:convert';

import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/book_series_key.dart';
import 'package:fushi_engine/media/collections/shelf_sort.dart'
    show naturalCompare;

/// 在线漫画描述符类型标记（写进 `sourceMetadata`，永不变；同
/// `leaderboard/local_shelf.dart`）。在线漫画一行就是一整部作品，不按卷归组。
const Set<String> _onlineMangaMarkers = <String>{
  'hibiki-online-manga',
  'hibiki-mihon',
};

/// 一次归组的可核对结果。
typedef BookSeriesGroupSummary = ({
  List<int> createdCollectionIds,
  List<int> updatedCollectionIds,
});

/// 书架 / 漫画库分卷 → 系列合集（视频 `VideoFolderGroupCoordinator` 的书籍对应物）。
///
/// 一卷 = 一张书架卡：本地 EPUB / PDF / 漫画一行；EPUB 配对的有声书在书架上显示成
/// SRT 卡，所以它的 SRT 行与 EPUB 行一起进合集；无 EPUB 的纯字幕书自成一卷。
///
/// - 漫画与小说分属两个书架，「够不够建合集」按书架分开算；
/// - 已经在任何合集里的卷不动——用户手动整理过的归属优先；
/// - 目标合集：已有 ≥2 个同系列成员的合集（不论名字 / 类型，用户手建的也算）→
///   同名 playlist → 同系列 ≥2 卷时新建 playlist；
/// - 用户删过的同名合集不复活（合集级墓碑）；用户移出过的卷不再加回（成员墓碑，
///   EPUB 按合集 wire 键、SRT 按 uid 比对）；
/// - 合集内按卷号 → natural 书名排；用户手动排过（`orderUpdatedAt > 0`）不重排。
///
/// 幂等：重复调用结果不变，可在每次导入后、打开书架时放心调用。
class BookSeriesGrouper {
  const BookSeriesGrouper(this._database);

  final FushiDatabase _database;

  Future<BookSeriesGroupSummary> groupAll() async {
    final List<int> created = <int>[];
    final List<int> updated = <int>[];
    final List<_Volume> volumes = await _loadVolumes();
    final List<MediaCollectionItemRow> items = await _database
        .getAllCollectionItems();
    final Set<String> inCollection = <String>{
      for (final MediaCollectionItemRow i in items)
        '${i.mediaType}|${i.entryKey}',
    };
    final Map<String, _Volume> byMember = <String, _Volume>{
      for (final _Volume v in volumes)
        for (final _Member m in v.members) m.id: v,
    };
    final Map<String, List<_Volume>> loose = <String, List<_Volume>>{};
    for (final _Volume v in volumes) {
      if (v.members.any((m) => inCollection.contains(m.id))) continue;
      loose.putIfAbsent(v.groupKey, () => <_Volume>[]).add(v);
    }
    if (loose.isEmpty) {
      return (
        createdCollectionIds: const <int>[],
        updatedCollectionIds: const <int>[],
      );
    }
    // 同名 playlist 一趟预取（与 getMediaCollectionByNaturalKey 同判据：名字精确相等、
    // 取 id 最小者）。互联 host 每次出清单都会调本方法，逐系列查一次会让大库（满架
    // 单卷书）每刷一次清单打上千次查询。
    final Map<String, MediaCollectionRow> playlistByName =
        <String, MediaCollectionRow>{};
    for (final MediaCollectionRow c
        in (await _database.getAllMediaCollections())
          ..sort((a, b) => a.id.compareTo(b.id))) {
      if (c.collectionType == 'playlist') {
        playlistByName.putIfAbsent(c.name, () => c);
      }
    }
    for (final List<_Volume> group in loose.values) {
      final int? id = await _groupSeries(
        group,
        items,
        byMember,
        created,
        playlistByName,
      );
      if (id != null && !created.contains(id)) updated.add(id);
    }
    return (
      createdCollectionIds: List<int>.unmodifiable(created),
      updatedCollectionIds: List<int>.unmodifiable(updated),
    );
  }

  Future<List<_Volume>> _loadVolumes() async {
    final List<_Volume> out = <_Volume>[];
    final Map<String, _Volume> byBookKey = <String, _Volume>{};
    for (final EpubBookRow book in await _database.getAllEpubBooks()) {
      if (_isOnlineManga(book.sourceMetadata)) continue;
      final BookSeriesKey? key = parseBookSeriesKey(book.title);
      if (key == null) continue;
      final _Volume v = _Volume(
        title: book.title,
        key: key,
        shelf: BookFormat.parseOrEpub(book.format) == BookFormat.manga
            ? 'manga'
            : 'book',
        members: <_Member>[
          _Member(
            MediaKind.epub,
            book.uid,
            collectionBookWireKey(
              bookKey: book.bookKey,
              sourceMetadata: book.sourceMetadata,
            ),
          ),
        ],
      );
      out.add(v);
      byBookKey[book.bookKey] = v;
    }
    for (final SrtBookRow srt in await _database.getAllSrtBooks()) {
      final _Member member = _Member(MediaKind.srt, srt.uid, srt.uid);
      final _Volume? paired = srt.bookKey.isEmpty
          ? null
          : byBookKey[srt.bookKey];
      if (paired != null) {
        paired.members.add(member);
        continue;
      }
      final BookSeriesKey? key = parseBookSeriesKey(srt.title);
      if (key == null) continue;
      out.add(
        _Volume(
          title: srt.title,
          key: key,
          shelf: 'book',
          members: <_Member>[member],
        ),
      );
    }
    return out;
  }

  /// 归一个系列；有成员落进合集返回合集 id，否则 null。
  Future<int?> _groupSeries(
    List<_Volume> volumes,
    List<MediaCollectionItemRow> items,
    Map<String, _Volume> byMember,
    List<int> created,
    Map<String, MediaCollectionRow> playlistByName,
  ) async {
    final String groupKey = volumes.first.groupKey;
    MediaCollectionRow? collection = await _collectionHoldingSeries(
      groupKey,
      items,
      byMember,
    );
    final String name = volumes.first.key.seriesTitle;
    collection ??= playlistByName[name];
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
      playlistByName[name] = collection;
    }
    final Set<String> removed = await _removedMembers(collection);
    bool added = false;
    for (final _Volume v in volumes) {
      for (final _Member m in v.members) {
        if (removed.contains('${m.kind.dbValue}|${m.tombstoneKey}')) continue;
        await _database.addToCollection(collection.id, m.kind, m.uid);
        added = true;
      }
    }
    if (!added) return null;
    if (collection.orderUpdatedAt == 0) await _sortMembers(collection.id);
    return collection.id;
  }

  /// 已有 ≥2 个同系列（同书架）成员的合集，取成员最多者；没有则 null。
  /// 只有一卷碰巧在主题合集（如「百合」）里不算，免得把整套书拉进去。
  Future<MediaCollectionRow?> _collectionHoldingSeries(
    String groupKey,
    List<MediaCollectionItemRow> items,
    Map<String, _Volume> byMember,
  ) async {
    final Map<int, Set<_Volume>> hits = <int, Set<_Volume>>{};
    for (final MediaCollectionItemRow i in items) {
      final _Volume? v = byMember['${i.mediaType}|${i.entryKey}'];
      if (v == null || v.groupKey != groupKey) continue;
      hits.putIfAbsent(i.collectionId, () => <_Volume>{}).add(v);
    }
    int? best;
    for (final MapEntry<int, Set<_Volume>> e in hits.entries) {
      if (e.value.length < 2) continue;
      if (best == null || e.value.length > hits[best]!.length) best = e.key;
    }
    return best == null ? null : _database.getMediaCollectionById(best);
  }

  Future<Set<String>> _removedMembers(MediaCollectionRow collection) async {
    final List<CollectionMemberTombstoneRow> rows =
        await (_database.select(_database.collectionMemberTombstones)..where(
              (t) =>
                  t.collectionName.equals(collection.name) &
                  t.collectionType.equals(collection.collectionType),
            ))
            .get();
    return <String>{
      for (final CollectionMemberTombstoneRow r in rows)
        '${r.mediaType}|${r.entryKey}',
    };
  }

  /// 合集内能解析出卷号的成员按卷号（无卷号当第 0 卷）→ natural 书名排；同卷的
  /// EPUB 与 SRT 相邻。其余成员（别的种类 / 解析不出）原位不动。
  Future<void> _sortMembers(int collectionId) async {
    final Map<String, _Volume> byMember = <String, _Volume>{
      for (final _Volume v in await _loadVolumes())
        for (final _Member m in v.members) m.id: v,
    };
    final List<MediaCollectionItemRow> members = <MediaCollectionItemRow>[
      for (final MediaCollectionItemRow i in await _database.getCollectionItems(
        collectionId,
      ))
        if (byMember.containsKey('${i.mediaType}|${i.entryKey}')) i,
    ];
    members.sort((MediaCollectionItemRow a, MediaCollectionItemRow b) {
      final _Volume va = byMember['${a.mediaType}|${a.entryKey}']!;
      final _Volume vb = byMember['${b.mediaType}|${b.entryKey}']!;
      final int c = (va.key.volume ?? 0).compareTo(vb.key.volume ?? 0);
      if (c != 0) return c;
      final int t = naturalCompare(va.title, vb.title);
      return t != 0 ? t : a.mediaType.compareTo(b.mediaType);
    });
    await _database.reorderCollectionItemsAutomatically(
      collectionId,
      <CollectionMemberKey>[
        for (final MediaCollectionItemRow i in members)
          (mediaType: i.mediaType, entryKey: i.entryKey),
      ],
    );
  }
}

/// 合集成员：[uid] 是成员行键，[tombstoneKey] 是移出墓碑的键域（EPUB = wire 键）。
class _Member {
  const _Member(this.kind, this.uid, this.tombstoneKey);

  final MediaKind kind;
  final String uid;
  final String tombstoneKey;

  String get id => '${kind.dbValue}|$uid';
}

/// 一卷 = 书架上一张卡（EPUB 有声书是 EPUB + SRT 两个成员）。
class _Volume {
  _Volume({
    required this.title,
    required this.key,
    required this.shelf,
    required this.members,
  });

  final String title;
  final BookSeriesKey key;

  /// 'manga' | 'book'：两个书架分开判「同系列」。
  final String shelf;
  final List<_Member> members;

  String get groupKey => '$shelf|${key.key}';
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
