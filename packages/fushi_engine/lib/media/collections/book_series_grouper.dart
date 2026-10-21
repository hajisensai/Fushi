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
    final List<MediaCollectionRow> collections =
        (await _database.getAllMediaCollections())
          ..sort((a, b) => a.id.compareTo(b.id));
    if (loose.isNotEmpty) {
      // 同名 playlist 一趟预取（与 getMediaCollectionByNaturalKey 同判据：名字精确
      // 相等、取 id 最小者）。互联 host 每次出清单都会调本方法，逐系列查一次会让大库
      // （满架单卷书）每刷一次清单打上千次查询。
      final Map<String, MediaCollectionRow> playlistByName =
          <String, MediaCollectionRow>{};
      for (final MediaCollectionRow c in collections) {
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
    }
    final BookSeriesOrder order = BookSeriesOrder._(byMember);
    for (final MediaCollectionRow c in collections) {
      if (created.contains(c.id) || updated.contains(c.id)) continue;
      if (await _healSeriesOrder(c, items, order)) updated.add(c.id);
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
      if (isOnlineMangaSourceMetadata(book.sourceMetadata)) continue;
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
        // v124（AI 整理库 spec §6）：规则建的合集归整理器管，分组键与 AI 整理同一
        // 口径（系列名折叠），日文书 AI 给出的原名与它一致时天然认成一个。
        origin: CollectionOrigin.rule,
        organizeKey: titleOrganizeKey(
          volumes.first.shelf == 'manga'
              ? CollectionShelfDomain.manga.name
              : CollectionShelfDomain.books.name,
          name,
        ),
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
        await _database.addToCollection(
          collection.id,
          m.kind,
          m.uid,
          userIntent: false,
        );
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

  /// 自愈已有系列合集的卷序（用户实报：17 卷的合集里第 2 卷排在最后，首页续读
  /// 读完第 2 卷就以为整套读完、不推第 3 卷）。手动「建系列 / 并入合集」按选择
  /// 顺序尾插，不经 [_sortMembers]；这里在之后任一次归组时补排。
  ///
  /// 只动用户没手动排过（`orderUpdatedAt == 0`）、且 [BookSeriesOrder.orderOf]
  /// 能完整定序的合集；顺序已对时不写库。返回是否重排了。合集同步合并时走同一判据
  /// （`loadBookSeriesRuleOrder`），本地与共享清单不会各持一序来回翻。
  Future<bool> _healSeriesOrder(
    MediaCollectionRow collection,
    List<MediaCollectionItemRow> allItems,
    BookSeriesOrder order,
  ) async {
    if (collection.orderUpdatedAt != 0) return false;
    final List<MediaCollectionItemRow> rows =
        <MediaCollectionItemRow>[
          for (final MediaCollectionItemRow i in allItems)
            if (i.collectionId == collection.id) i,
        ]..sort((MediaCollectionItemRow a, MediaCollectionItemRow b) {
          // 与 getCollectionItems 同一全序（sortIndex → entryKey → mediaType）。
          final int s = a.sortIndex.compareTo(b.sortIndex);
          if (s != 0) return s;
          final int k = a.entryKey.compareTo(b.entryKey);
          return k != 0 ? k : a.mediaType.compareTo(b.mediaType);
        });
    final List<CollectionMemberKey> current = <CollectionMemberKey>[
      for (final MediaCollectionItemRow i in rows)
        (mediaType: i.mediaType, entryKey: i.entryKey),
    ];
    final List<CollectionMemberKey>? sorted = order.orderOf(current);
    if (sorted == null || _sameMemberOrder(current, sorted)) return false;
    await _database.reorderCollectionItemsAutomatically(collection.id, sorted);
    return true;
  }

  /// 合集内能解析出卷号的成员按卷号（无卷号当第 0 卷）→ natural 书名排；同卷的
  /// EPUB 与 SRT 相邻。其余成员（别的种类 / 解析不出）原位不动。
  Future<void> _sortMembers(int collectionId) async {
    final Map<String, _Volume> byMember = <String, _Volume>{
      for (final _Volume v in await _loadVolumes())
        for (final _Member m in v.members) m.id: v,
    };
    final List<CollectionMemberKey> members = <CollectionMemberKey>[
      for (final MediaCollectionItemRow i in await _database.getCollectionItems(
        collectionId,
      ))
        if (byMember.containsKey('${i.mediaType}|${i.entryKey}'))
          (mediaType: i.mediaType, entryKey: i.entryKey),
    ];
    members.sort(
      (CollectionMemberKey a, CollectionMemberKey b) =>
          _compareMembers(a, b, byMember),
    );
    await _database.reorderCollectionItemsAutomatically(collectionId, members);
  }
}

/// 书系列合集的规则卷序判据（[BookSeriesGrouper] 归组自愈与合集同步合并共用一份，
/// 不各写一套：两边判据一有出入，本地自愈与同步落盘就会各持一序、每轮来回翻）。
///
/// 成员键是**本地**键域（epub = `epub_books.uid`，srt = uid），与合集成员表一致。
class BookSeriesOrder {
  BookSeriesOrder._(this._byMember);

  /// 读一次本机书架（EPUB / PDF / 漫画 + SRT），建好成员 → 分卷索引。
  static Future<BookSeriesOrder> load(FushiDatabase db) async {
    final List<_Volume> volumes = await BookSeriesGrouper(db)._loadVolumes();
    return BookSeriesOrder._(<String, _Volume>{
      for (final _Volume v in volumes)
        for (final _Member m in v.members) m.id: v,
    });
  }

  final Map<String, _Volume> _byMember;

  /// [members]（当前顺序）是「规则能完整定序」的系列合集时，返回按卷号排好的
  /// 顺序（可能与输入相同）；否则 null（不定序，调用方保持原序）。
  ///
  /// 能完整定序 = 每个成员都是本机书架上同一系列（同书架）的分卷、卷号互不重复且
  /// 至多一卷无卷号（当第 1 卷）、成员键无重复。混了外传 / 汉字卷号 / 别的系列 /
  /// 本机没有的书（透传成员）的合集留给 AI 排序或原序，这里不碰，免得互相覆盖。
  /// 同卷多个成员（EPUB + SRT）按种类 → 成员键排，是全序：结果只取决于成员集合，
  /// 不取决于输入顺序，也不受 `List.sort` 不稳定影响。
  List<CollectionMemberKey>? orderOf(List<CollectionMemberKey> members) {
    final Set<String> seen = <String>{};
    final Set<_Volume> volumes = <_Volume>{};
    for (final CollectionMemberKey m in members) {
      final String id = '${m.mediaType}|${m.entryKey}';
      if (!seen.add(id)) return null;
      final _Volume? v = _byMember[id];
      if (v == null) return null;
      volumes.add(v);
    }
    if (volumes.length < 2) return null;
    if (volumes.map((_Volume v) => v.shelf).toSet().length != 1) return null;
    if (sharedBookSeriesKey(<String>[
          for (final _Volume v in volumes) v.title,
        ]) ==
        null) {
      return null;
    }
    final List<num?> numbers = <num?>[
      for (final _Volume v in volumes) v.key.volume,
    ];
    if (numbers.where((num? n) => n == null).length > 1) return null;
    if (numbers.toSet().length != numbers.length) return null;
    return List<CollectionMemberKey>.of(members)..sort(
      (CollectionMemberKey a, CollectionMemberKey b) =>
          _compareMembers(a, b, _byMember),
    );
  }
}

bool _sameMemberOrder(
  List<CollectionMemberKey> a,
  List<CollectionMemberKey> b,
) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 按卷号（无卷号当第 0 卷）→ natural 书名 → 种类 → 成员键排；同卷的 EPUB 与 SRT
/// 相邻。末位成员键让同卷同种类（同卷只有一个 EPUB，并列只出在配了多条 SRT 时）
/// 也有确定先后：SRT uid 即 wire 键、跨端稳定，各端排出同一个序；不用行 id（各端不同）。
int _compareMembers(
  CollectionMemberKey a,
  CollectionMemberKey b,
  Map<String, _Volume> byMember,
) {
  final _Volume va = byMember['${a.mediaType}|${a.entryKey}']!;
  final _Volume vb = byMember['${b.mediaType}|${b.entryKey}']!;
  final int c = (va.key.volume ?? 0).compareTo(vb.key.volume ?? 0);
  if (c != 0) return c;
  final int t = naturalCompare(va.title, vb.title);
  if (t != 0) return t;
  final int k = a.mediaType.compareTo(b.mediaType);
  return k != 0 ? k : a.entryKey.compareTo(b.entryKey);
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

/// 在线漫画（Mihon / mokuro 在线源的书架条目）：不归组、不交 AI 整理——它们的
/// 「卷」是在线章节容器，不是本地书。
bool isOnlineMangaSourceMetadata(String? sourceMetadata) {
  if (sourceMetadata == null) return false;
  try {
    final Object? value = jsonDecode(sourceMetadata);
    return value is Map<String, dynamic> &&
        _onlineMangaMarkers.contains(value['type']);
  } on FormatException {
    return false;
  }
}
