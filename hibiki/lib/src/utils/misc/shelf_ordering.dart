import 'package:hibiki_core/hibiki_core.dart';

/// TODO-616 B 排序 + A 合集的渲染层组装核心（纯函数，widget-free 单测）。
///
/// 书架 / 视频库加载时：本地 + 远端条目 → 各算 `(mediaType, entryKey)` 稳定身份 →
/// 批量查 [ShelfEntries] 一次性预取（避免 N+1）→ 按 seriesId 分组（NULL = 散书，
/// 非 NULL = 折叠系列卡片）→ 组内 / 散书按 `sortOrder asc, importedAt desc` 排。
///
/// 「sortOrder asc, importedAt desc」的退化语义：无 ShelfEntries 行的旧条目
/// sortOrder 视为 0，故全部退化为 importedAt 倒序（向后兼容，Never break userspace）。

/// 一个待排序条目的最小身份 + 排序回退键。渲染层用本地行 / 远端行各构造一个。
class ShelfOrderingItem<T> {
  const ShelfOrderingItem({
    required this.mediaType,
    required this.entryKey,
    required this.importedAt,
    required this.payload,
  });

  /// 媒体种类：'epub' | 'srt' | 'video'。
  final String mediaType;

  /// 稳定身份：本地 = bookKey/srtUid/videoBookUid；远端 = downloadId/video.id。
  final String entryKey;

  /// 排序回退键（importedAt 毫秒戳）。无 sortOrder 行时按此倒序。
  final int importedAt;

  /// 渲染层透传的原始条目（卡片渲染用）。
  final T payload;
}

/// 散书或一个系列折叠后的展示单元。
class ShelfGroup<T> {
  const ShelfGroup({
    required this.seriesId,
    required this.seriesSortOrder,
    required this.items,
  });

  /// NULL = 散书（每个散书条目单独成一个 group，items 长度恒 1）；
  /// 非 NULL = 系列卡片（items 为该系列全部成员，已按组内序排好）。
  final int? seriesId;

  /// 系列卡片之间的排序权重（来自 [SeriesRow.sortOrder]；散书恒 0）。散书与系列
  /// 卡片在书架同层混排，散书的「卡片序」用其首个成员的 entry 排序。
  final int seriesSortOrder;

  /// 组内已排序成员（系列内 sortOrder asc, importedAt desc）。
  final List<ShelfOrderingItem<T>> items;

  /// 系列封面 = 组内排序最小成员（首卷自动）；散书即其唯一成员。
  ShelfOrderingItem<T> get coverItem => items.first;
}

/// 把条目按 ShelfEntries 映射分组 + 排序。
///
/// [items]：本地 + 远端条目（调用方已合并 + 去重，远端被同 entryKey 本地覆盖时由
///   调用方决定保留谁）。
/// [shelfEntries]：一次性预取的全部 [ShelfEntryRow]（内存 join）。
/// [seriesById]：系列 id → 行（用于系列卡片排序权重）。
/// [validEntryKeys]：当前真实存在的 `(mediaType, entryKey)` 集合（本地表 + 远端列表）。
///   ShelfEntries 行的 entryKey 不在此集合 = 孤儿（远端离线 / 改键迁移失败残留），
///   渲染时忽略（不主动删，避免误删「远端暂时离线」的归属）。本函数只过滤 items，
///   孤儿 shelf_entry 行天然不参与（无对应 item）。
///
/// 返回：书架同层混排的 group 列表，已按 `(groupSortOrder asc, fallbackImportedAt
/// desc)` 排好。散书每个单独成 group；同 seriesId 折叠成一个 group。
List<ShelfGroup<T>> groupAndSortShelfEntries<T>({
  required List<ShelfOrderingItem<T>> items,
  required List<ShelfEntryRow> shelfEntries,
  required Map<int, SeriesRow> seriesById,
}) {
  // (mediaType|entryKey) → ShelfEntryRow，O(1) 查 sortOrder/seriesId。
  final Map<String, ShelfEntryRow> entryByKey = <String, ShelfEntryRow>{
    for (final ShelfEntryRow e in shelfEntries)
      _composite(e.mediaType, e.entryKey): e,
  };

  int sortOrderOf(ShelfOrderingItem<T> it) =>
      entryByKey[_composite(it.mediaType, it.entryKey)]?.sortOrder ?? 0;
  int? seriesIdOf(ShelfOrderingItem<T> it) =>
      entryByKey[_composite(it.mediaType, it.entryKey)]?.seriesId;

  // 组内排序比较器：sortOrder asc, importedAt desc, entryKey asc（最终稳定 tie-break）。
  int compareItems(ShelfOrderingItem<T> a, ShelfOrderingItem<T> b) {
    final int so = sortOrderOf(a).compareTo(sortOrderOf(b));
    if (so != 0) return so;
    final int ia = b.importedAt.compareTo(a.importedAt); // desc
    if (ia != 0) return ia;
    return a.entryKey.compareTo(b.entryKey);
  }

  // 1) 按 seriesId 分桶。
  final List<ShelfOrderingItem<T>> looseItems = <ShelfOrderingItem<T>>[];
  final Map<int, List<ShelfOrderingItem<T>>> bySeries =
      <int, List<ShelfOrderingItem<T>>>{};
  for (final ShelfOrderingItem<T> it in items) {
    final int? sid = seriesIdOf(it);
    if (sid == null) {
      looseItems.add(it);
    } else {
      (bySeries[sid] ??= <ShelfOrderingItem<T>>[]).add(it);
    }
  }

  final List<ShelfGroup<T>> groups = <ShelfGroup<T>>[];

  // 2) 散书：每条单独成 group（seriesSortOrder = 其 entry 的 sortOrder）。
  for (final ShelfOrderingItem<T> it in looseItems) {
    groups.add(ShelfGroup<T>(
      seriesId: null,
      seriesSortOrder: sortOrderOf(it),
      items: <ShelfOrderingItem<T>>[it],
    ));
  }

  // 3) 系列：组内排序 + 折叠成一个 group（seriesSortOrder 取 SeriesRow.sortOrder）。
  for (final MapEntry<int, List<ShelfOrderingItem<T>>> e in bySeries.entries) {
    final List<ShelfOrderingItem<T>> members = e.value..sort(compareItems);
    groups.add(ShelfGroup<T>(
      seriesId: e.key,
      seriesSortOrder: seriesById[e.key]?.sortOrder ?? 0,
      items: members,
    ));
  }

  // 4) group 之间排序：seriesSortOrder asc，再按各 group 封面条目的 importedAt desc，
  //    最后 entryKey asc 稳定。
  groups.sort((ShelfGroup<T> a, ShelfGroup<T> b) {
    final int so = a.seriesSortOrder.compareTo(b.seriesSortOrder);
    if (so != 0) return so;
    final int ia = b.coverItem.importedAt.compareTo(a.coverItem.importedAt);
    if (ia != 0) return ia;
    return a.coverItem.entryKey.compareTo(b.coverItem.entryKey);
  });

  return groups;
}

String _composite(String mediaType, String entryKey) => '$mediaType|$entryKey';

/// 一条书架 / 视频选择键解码后的稳定身份 `(mediaType, entryKey)`。
/// 直接喂 [HibikiDatabase.setSeriesForEntry] / [HibikiDatabase.upsertShelfOrder]。
class ShelfEntryRef {
  const ShelfEntryRef({required this.mediaType, required this.entryKey});

  /// 媒体种类：'epub' | 'srt' | 'video'。
  final String mediaType;

  /// 稳定身份：本地 = bookKey / srtUid / videoBookUid。
  final String entryKey;

  @override
  bool operator ==(Object other) =>
      other is ShelfEntryRef &&
      other.mediaType == mediaType &&
      other.entryKey == entryKey;

  @override
  int get hashCode => Object.hash(mediaType, entryKey);

  @override
  String toString() => 'ShelfEntryRef($mediaType, $entryKey)';
}

/// 选择键所属的来源表面：书架（SRT/EPUB 双类前缀）vs 视频库（裸 bookUid）。
enum ShelfSelectionSurface { books, video }

/// TODO-616 A1：把书架 / 视频库批量选择集里的「选择键」解码成 ShelfEntries 的稳定
/// 身份 `(mediaType, entryKey)`，供「组合成系列」逐条 `setSeriesForEntry` 用。
///
/// 两套选择键编码不对称（计划 §⑦ 风险 6），故按 [surface] 分支：
/// - [ShelfSelectionSurface.books]：书架 `_selectedKeys`——
///   - SRT 键 = `'srt_' + srtUid` → `('srt', srtUid)`；
///   - EPUB 键 = `'hoshi://book/<bookKey>'`（MediaItem.mediaIdentifier）→
///     `('epub', bookKey)`（内联解析 `hoshi://book/` URI，与
///     `ReaderHibikiSource.parseBookKey` 同语义，但保持本函数 widget/DB-free 可单测）。
///   - 无法识别（非 srt_ 前缀且非 hoshi://book/）→ null（调用方跳过该条）。
/// - [ShelfSelectionSurface.video]：视频库 `_selectedUids`——裸 bookUid →
///   `('video', selectionKey)`（视频选择集本就直接是 bookUid，无前缀）。
ShelfEntryRef? shelfSelectionToEntry(
  String selectionKey,
  ShelfSelectionSurface surface,
) {
  switch (surface) {
    case ShelfSelectionSurface.video:
      if (selectionKey.isEmpty) return null;
      return ShelfEntryRef(mediaType: 'video', entryKey: selectionKey);
    case ShelfSelectionSurface.books:
      if (selectionKey.startsWith('srt_')) {
        final String uid = selectionKey.substring(4);
        if (uid.isEmpty) return null;
        return ShelfEntryRef(mediaType: 'srt', entryKey: uid);
      }
      final String? bookKey = _parseHoshiBookKey(selectionKey);
      if (bookKey == null || bookKey.isEmpty) return null;
      return ShelfEntryRef(mediaType: 'epub', entryKey: bookKey);
  }
}

/// 内联解析 `hoshi://book/<bookKey>`（与 ReaderHibikiSource.parseBookKey 同语义，
/// 复制到本 widget-free 文件以便纯函数单测，不引依赖）。
String? _parseHoshiBookKey(String identifier) {
  final Uri? uri = Uri.tryParse(identifier);
  if (uri == null) return null;
  if (uri.scheme == 'hoshi' &&
      uri.host == 'book' &&
      uri.pathSegments.isNotEmpty) {
    return uri.pathSegments.join('/');
  }
  return null;
}
