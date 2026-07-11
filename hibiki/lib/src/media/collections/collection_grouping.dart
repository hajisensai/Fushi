import 'package:hibiki_core/hibiki_core.dart';

/// 统一合集 Phase 4：库网格分组核心（纯函数，widget-free 单测）。
///
/// 把已排序的媒体条目按「所属合集」折叠——不属任何合集的条目单卡；属某合集的条目折进
/// 该合集卡。折叠归属用 [HibikiDatabase.getPrimaryCollectionIdByEntry] 的「最小
/// collectionId」（一条目属多合集时只折进 id 最小的那张；其余合集卡照常显示、详情页
/// 照常含该条目）。与旧 `groupAndSortShelfEntries`（按 [ShelfEntries].seriesId 折叠）同
/// 范式，只是折叠键从 seriesId 换成 [MediaCollectionItems] 引用表。
///
/// 排序：散条目卡片序取其 shelf `sortOrder`（[ShelfEntries]，Phase 6 前保留）；合集卡序取
/// [MediaCollectionRow.sortOrder]；两者同层混排。组内成员按 `sortOrder asc, importedAt
/// desc, entryKey asc`（无 shelf 行退化 importedAt 倒序，向后兼容）。

/// 一个待分组条目的最小身份 + 排序回退键 + 渲染载荷。
class CollectionOrderingItem<T> {
  const CollectionOrderingItem({
    required this.mediaType,
    required this.entryKey,
    required this.importedAt,
    required this.payload,
  });

  /// 'epub' | 'srt' | 'video'。
  final String mediaType;

  /// 稳定身份：epub=bookKey / srt=uid / video=bookUid。
  final String entryKey;

  /// 排序回退键（importedAt 毫秒；无 sortOrder 时按此倒序）。
  final int importedAt;

  /// 渲染层透传的原始条目。
  final T payload;
}

/// 散条目或一个合集折叠后的展示单元。
class CollectionGroup<T> {
  const CollectionGroup({
    required this.collection,
    required this.groupSortOrder,
    required this.items,
  });

  /// null = 散条目（单卡，[items] 长度恒 1）；非 null = 折叠合集卡（[items] 为该合集在本
  /// surface 的全部成员，已按组内序排好）。
  final MediaCollectionRow? collection;

  /// 卡片间排序权重（合集取 [MediaCollectionRow.sortOrder]；散条目取其 shelf sortOrder）。
  final int groupSortOrder;

  /// 组内已排序成员。
  final List<CollectionOrderingItem<T>> items;

  /// 封面 = 组内排序最小成员（散条目即其唯一成员）。
  CollectionOrderingItem<T> get coverItem => items.first;
}

String _composite(String mediaType, String entryKey) => '$mediaType|$entryKey';

/// 把 [items] 按所属合集折叠 + 排序，返回同层混排的 group 列表。
///
/// [primaryCollectionIdByEntry]：`'<mediaType>|<entryKey>'` → 该条目折叠归属的最小
///   collectionId（[HibikiDatabase.getPrimaryCollectionIdByEntry]）。
/// [collectionsById]：collectionId → 合集行（取 sortOrder / 名 / 类型）。归属 id 不在此
///   映射（合集已删的孤儿引用）→ 该条目退化为散条目。
/// [itemSortOrder]：`'<mediaType>|<entryKey>'` → shelf sortOrder（散条目卡片序 + 组内序）。
List<CollectionGroup<T>> groupByCollections<T>({
  required List<CollectionOrderingItem<T>> items,
  required Map<String, int> primaryCollectionIdByEntry,
  required Map<int, MediaCollectionRow> collectionsById,
  required Map<String, int> itemSortOrder,
}) {
  int sortOrderOf(CollectionOrderingItem<T> it) =>
      itemSortOrder[_composite(it.mediaType, it.entryKey)] ?? 0;
  int? collectionIdOf(CollectionOrderingItem<T> it) {
    final int? cid =
        primaryCollectionIdByEntry[_composite(it.mediaType, it.entryKey)];
    if (cid == null || !collectionsById.containsKey(cid)) return null;
    return cid;
  }

  int compareItems(CollectionOrderingItem<T> a, CollectionOrderingItem<T> b) {
    final int so = sortOrderOf(a).compareTo(sortOrderOf(b));
    if (so != 0) return so;
    final int ia = b.importedAt.compareTo(a.importedAt); // desc
    if (ia != 0) return ia;
    return a.entryKey.compareTo(b.entryKey);
  }

  final List<CollectionOrderingItem<T>> loose = <CollectionOrderingItem<T>>[];
  final Map<int, List<CollectionOrderingItem<T>>> byCollection =
      <int, List<CollectionOrderingItem<T>>>{};
  for (final CollectionOrderingItem<T> it in items) {
    final int? cid = collectionIdOf(it);
    if (cid == null) {
      loose.add(it);
    } else {
      (byCollection[cid] ??= <CollectionOrderingItem<T>>[]).add(it);
    }
  }

  final List<CollectionGroup<T>> groups = <CollectionGroup<T>>[];
  for (final CollectionOrderingItem<T> it in loose) {
    groups.add(CollectionGroup<T>(
      collection: null,
      groupSortOrder: sortOrderOf(it),
      items: <CollectionOrderingItem<T>>[it],
    ));
  }
  for (final MapEntry<int, List<CollectionOrderingItem<T>>> e
      in byCollection.entries) {
    final List<CollectionOrderingItem<T>> members = e.value..sort(compareItems);
    groups.add(CollectionGroup<T>(
      collection: collectionsById[e.key],
      groupSortOrder: collectionsById[e.key]?.sortOrder ?? 0,
      items: members,
    ));
  }

  groups.sort((CollectionGroup<T> a, CollectionGroup<T> b) {
    final int so = a.groupSortOrder.compareTo(b.groupSortOrder);
    if (so != 0) return so;
    final int ia = b.coverItem.importedAt.compareTo(a.coverItem.importedAt);
    if (ia != 0) return ia;
    return a.coverItem.entryKey.compareTo(b.coverItem.entryKey);
  });

  return groups;
}
