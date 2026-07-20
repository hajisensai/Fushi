import 'package:hibiki_core/hibiki_core.dart';

/// 统一合集 Phase 4：库网格分组核心（纯函数，widget-free 单测）。
///
/// 把媒体条目按「所属合集」折叠——不属任何合集的条目单卡；属某合集的条目折进
/// 该合集卡。折叠归属用 [HibikiDatabase.getPrimaryCollectionIdByEntry] 的「最小
/// collectionId」（一条目属多合集时只折进 id 最小的那张；其余合集卡照常显示、详情页
/// 照常含该条目）。
///
/// 排序 v2（排序交互重设计 2026-07-12）：本函数只负责**折叠**，不再承担卡片间排序
/// （旧 `itemSortOrder`/`groupSortOrder` 死权重已随整理页删除）——散 group 保持输入
/// 序、合集 group 出现在其首个成员的位置；页面拿到 groups 后按当前排序模式
/// （`compareShelfSortKeys` 聚合键）自行排序。组内成员按 [groupByCollections] 的
/// `memberSortIndex`（= 该条目在其主折叠合集里的 [MediaCollectionItems].sortIndex）
/// 升序 → importedAt 倒序 → entryKey 排——与详情页/播放器 `getCollectionItems`
/// 同源，一处落盘（`reorderCollectionItems`）三处同序。

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

  /// 组内排序回退键（importedAt 毫秒；无 sortIndex 行时按此倒序）。
  final int importedAt;

  /// 渲染层透传的原始条目。
  final T payload;
}

/// 散条目或一个合集折叠后的展示单元。
class CollectionGroup<T> {
  const CollectionGroup({
    required this.collection,
    required this.items,
  });

  /// null = 散条目（单卡，[items] 长度恒 1）；非 null = 折叠合集卡（[items] 为该合集在本
  /// surface 的全部成员，已按组内序排好）。
  final MediaCollectionRow? collection;

  /// 组内已排序成员。
  final List<CollectionOrderingItem<T>> items;

  /// 封面 = 组内序首成员（散条目即其唯一成员）。
  CollectionOrderingItem<T> get coverItem => items.first;
}

String _composite(String mediaType, String entryKey) => '$mediaType|$entryKey';

/// 标签筛选下判断一个媒体条目是否应存活到 [groupByCollections] 折叠阶段。
///
/// 根因（BUG-940）：成员级标签过滤发生在折叠**之前**。当一个合集自身打了标签、
/// 但其成员没打时，只按成员标签过滤会把成员全部剥光，导致折叠不出该合集组；
/// 之后页面按合集标签保留组的 `collectionFilter` 便无组可留，合集永远筛不出来
/// （用户实报「打了标签的合集筛不出来」）。
///
/// 修法（消除特例）：条目存活当且仅当 —— 条目自身命中全部选中标签
/// （[memberMatched]），**或**其主折叠合集（[primaryCollectionId]，与
/// [groupByCollections] 折叠归属同源）命中全部选中标签（在 [collectionFilter] 内）。
/// 后者让被标签命中的合集其成员整组存活、折叠出合集组，再由页面的 collectionFilter
/// 保留该组。[collectionFilter] 为 null（无选中合集标签维度）或 [primaryCollectionId]
/// 为 null（散条目/无归属）时，仅按 [memberMatched] 判定，与旧语义一致。
bool keepMemberUnderTagFilter({
  required bool memberMatched,
  required int? primaryCollectionId,
  required Set<int>? collectionFilter,
}) {
  if (memberMatched) return true;
  if (collectionFilter == null || primaryCollectionId == null) return false;
  return collectionFilter.contains(primaryCollectionId);
}

/// 把 [items] 按所属合集折叠，返回 group 列表（散 group 保持输入序、合集 group 在
/// 首成员位置；卡片间最终排序由页面按排序模式完成）。
///
/// [primaryCollectionIdByEntry]：`'<mediaType>|<entryKey>'` → 该条目折叠归属的最小
///   collectionId（[HibikiDatabase.getPrimaryCollectionIdByEntry]）。
/// [collectionsById]：collectionId → 合集行。归属 id 不在此映射（合集已删的孤儿
///   引用）→ 该条目退化为散条目。
/// [memberSortIndex]：`'<mediaType>|<entryKey>'` → 该条目在其主折叠合集里的
///   [MediaCollectionItems].sortIndex（组内序真相源；缺行退化 importedAt 倒序）。
List<CollectionGroup<T>> groupByCollections<T>({
  required List<CollectionOrderingItem<T>> items,
  required Map<String, int> primaryCollectionIdByEntry,
  required Map<int, MediaCollectionRow> collectionsById,
  required Map<String, int> memberSortIndex,
}) {
  const int noSortIndex = 1 << 30;
  int sortIndexOf(CollectionOrderingItem<T> it) =>
      memberSortIndex[_composite(it.mediaType, it.entryKey)] ?? noSortIndex;
  int? collectionIdOf(CollectionOrderingItem<T> it) {
    final int? cid =
        primaryCollectionIdByEntry[_composite(it.mediaType, it.entryKey)];
    if (cid == null || !collectionsById.containsKey(cid)) return null;
    return cid;
  }

  int compareMembers(CollectionOrderingItem<T> a, CollectionOrderingItem<T> b) {
    final int si = sortIndexOf(a).compareTo(sortIndexOf(b));
    if (si != 0) return si;
    final int ia = b.importedAt.compareTo(a.importedAt); // desc
    if (ia != 0) return ia;
    return a.entryKey.compareTo(b.entryKey);
  }

  // sequence 保留展示单元的出现序：散条目本体 / 合集 id（首成员处登记一次）。
  final List<Object> sequence = <Object>[];
  final Map<int, List<CollectionOrderingItem<T>>> byCollection =
      <int, List<CollectionOrderingItem<T>>>{};
  for (final CollectionOrderingItem<T> it in items) {
    final int? cid = collectionIdOf(it);
    if (cid == null) {
      sequence.add(it);
    } else {
      final List<CollectionOrderingItem<T>>? members = byCollection[cid];
      if (members == null) {
        byCollection[cid] = <CollectionOrderingItem<T>>[it];
        sequence.add(cid);
      } else {
        members.add(it);
      }
    }
  }

  return <CollectionGroup<T>>[
    for (final Object unit in sequence)
      if (unit is int)
        CollectionGroup<T>(
          collection: collectionsById[unit],
          items: byCollection[unit]!..sort(compareMembers),
        )
      else
        CollectionGroup<T>(
          collection: null,
          items: <CollectionOrderingItem<T>>[
            unit as CollectionOrderingItem<T>,
          ],
        ),
  ];
}
