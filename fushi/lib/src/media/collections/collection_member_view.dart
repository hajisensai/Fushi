/// 合集详情页（书架 / 漫画库 / 游戏库共用的 [MediaCollectionGridDetailPage]）的
/// 成员视图模型与纯函数：排序（卷号 / 添加时间 / 阅读时间 / 手动）、筛选（搜索 /
/// 标签 / 阅读状态）、续读目标、整体进度汇总。
///
/// 详情页是通用的（书 epub / srt、游戏），条目的进度 / 封面 / 读完状态由调用方经
/// [CollectionMemberInfoResolver] 注入；标题与导入时间在页内从四表现查（与「一键
/// 整理」同一份元数据，见 `collection_one_key_sort.dart`）。这里只放与 widget 无关
/// 的纯函数，便于单测。
library;

import 'package:flutter/widgets.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/shelf_sort.dart'
    show ShelfReadStatus, naturalCompare;

/// 成员区的排序方式。[manual] = 合集自身的 sortIndex（可拖排）；其余是**视图排序**，
/// 不落库（菜单「存为手动顺序」才写穿）。
enum CollectionMemberSort { manual, volume, added, read }

/// 成员区的呈现：封面网格 / 紧凑列表。
enum CollectionMemberViewMode { grid, list }

/// 调用方给的单个成员的展示信息。全部可选：没有的维度对应的排序 / 筛选不出现。
@immutable
class CollectionMemberInfo {
  const CollectionMemberInfo({
    this.title,
    this.cover,
    this.progress,
    this.lastReadAt,
    this.completed = false,
  });

  /// 显示名（改过名的书用显示名）；null = 用页内现查的原名。
  final String? title;

  /// 纯封面（无交互、无角标），hero 堆叠封面与列表行缩略图用。
  final Widget? cover;

  /// 阅读进度 0..1；null = 没有进度真值（纯字幕书 / 远端占位）。
  final double? progress;

  /// 最后阅读时刻（毫秒）；null = 没读过。
  final int? lastReadAt;

  /// 用户标了读完。
  final bool completed;

  ShelfReadStatus get readStatus {
    if (completed) return ShelfReadStatus.finished;
    if ((progress ?? 0) > 0 || lastReadAt != null) {
      return ShelfReadStatus.reading;
    }
    return ShelfReadStatus.unread;
  }
}

/// 按成员身份取展示信息；返回 null = 调用方不认识这个成员（只显示卡片本身）。
typedef CollectionMemberInfoResolver = CollectionMemberInfo? Function(
  String mediaType,
  String entryKey,
);

/// 详情页里的一个成员：合集行 + 现查的标题 / 导入时间 + 调用方信息 + 所挂标签。
@immutable
class CollectionMemberEntry {
  const CollectionMemberEntry({
    required this.row,
    required this.title,
    required this.importedAt,
    this.info,
    this.tagIds = const <int>{},
  });

  final MediaCollectionItemRow row;
  final String title;
  final int importedAt;
  final CollectionMemberInfo? info;
  final Set<int> tagIds;

  String get key => '${row.mediaType}|${row.entryKey}';

  /// 显示名：调用方给的优先（改名后的显示名），否则现查原名。
  String get displayTitle => info?.title ?? title;

  ShelfReadStatus? get readStatus => info?.readStatus;
}

/// 按排序方式与筛选条件排出可见成员（[entries] 是合集手动序）。
///
/// - [CollectionMemberSort.volume]：显示名 natural（卷1 < 卷2 < 卷10），平局手动序；
/// - [CollectionMemberSort.added]：导入时刻旧→新，平局手动序；
/// - [CollectionMemberSort.read]：最后阅读时刻新→旧，没读过的排后面（保持手动序）；
/// - 筛选：[query] 按 [matchesMediaSearch] 匹配显示名与原名；[tagIds] 要求成员挂着
///   **全部**所选标签（与库页标签筛选 AND 同语义）；[status] 只留该阅读状态。
List<CollectionMemberEntry> arrangeCollectionMembers(
  List<CollectionMemberEntry> entries, {
  CollectionMemberSort sort = CollectionMemberSort.manual,
  String query = '',
  Set<int> tagIds = const <int>{},
  ShelfReadStatus? status,
}) {
  final List<({CollectionMemberEntry entry, int index})> decorated =
      <({CollectionMemberEntry entry, int index})>[
    for (int i = 0; i < entries.length; i++)
      if (_keep(entries[i], query: query, tagIds: tagIds, status: status))
        (entry: entries[i], index: i),
  ];
  int byIndex(
    ({CollectionMemberEntry entry, int index}) a,
    ({CollectionMemberEntry entry, int index}) b,
  ) =>
      a.index.compareTo(b.index);
  switch (sort) {
    case CollectionMemberSort.manual:
      break;
    case CollectionMemberSort.volume:
      decorated.sort((a, b) {
        final int c =
            naturalCompare(a.entry.displayTitle, b.entry.displayTitle);
        return c != 0 ? c : byIndex(a, b);
      });
    case CollectionMemberSort.added:
      decorated.sort((a, b) {
        final int c = a.entry.importedAt.compareTo(b.entry.importedAt);
        return c != 0 ? c : byIndex(a, b);
      });
    case CollectionMemberSort.read:
      decorated.sort((a, b) {
        final int? ra = a.entry.info?.lastReadAt;
        final int? rb = b.entry.info?.lastReadAt;
        if (ra == null && rb == null) return byIndex(a, b);
        if (ra == null) return 1;
        if (rb == null) return -1;
        final int c = rb.compareTo(ra);
        return c != 0 ? c : byIndex(a, b);
      });
  }
  return <CollectionMemberEntry>[
    for (final ({CollectionMemberEntry entry, int index}) d in decorated)
      d.entry,
  ];
}

bool _keep(
  CollectionMemberEntry entry, {
  required String query,
  required Set<int> tagIds,
  required ShelfReadStatus? status,
}) {
  if (query.trim().isNotEmpty &&
      !matchesMediaSearch(
        query: query,
        titles: <String>[entry.displayTitle, entry.title],
      )) {
    return false;
  }
  if (tagIds.isNotEmpty && !entry.tagIds.containsAll(tagIds)) return false;
  if (status != null && entry.readStatus != status) return false;
  return true;
}

/// 「继续」按钮的目标（按合集手动序 [entries]）：最近读过且未读完的那本；没有就是
/// 第一本没读完的；全读完 / 没有任何进度信息时是第一本。空合集 null。
CollectionMemberEntry? pickContinueMember(List<CollectionMemberEntry> entries) {
  if (entries.isEmpty) return null;
  CollectionMemberEntry? recent;
  for (final CollectionMemberEntry e in entries) {
    final CollectionMemberInfo? info = e.info;
    if (info == null || info.completed || info.lastReadAt == null) continue;
    if (recent == null || info.lastReadAt! > recent.info!.lastReadAt!) {
      recent = e;
    }
  }
  if (recent != null) return recent;
  for (final CollectionMemberEntry e in entries) {
    if (e.info != null && !e.info!.completed) return e;
  }
  return entries.first;
}

/// hero 的整体进度：读完数 / 有信息的成员数，与平均进度（读完按满格）。没有任何
/// 成员带信息时 progress = null（hero 不画进度条）。
({int finished, int counted, double? progress}) summarizeCollectionMembers(
  List<CollectionMemberEntry> entries,
) {
  int finished = 0;
  int counted = 0;
  double sum = 0;
  for (final CollectionMemberEntry e in entries) {
    final CollectionMemberInfo? info = e.info;
    if (info == null) continue;
    if (info.completed) {
      finished++;
      counted++;
      sum += 1;
    } else if (info.progress != null) {
      counted++;
      sum += info.progress!.clamp(0.0, 1.0);
    } else if (info.lastReadAt == null) {
      // 有信息但没进度真值、也没读过：按 0 计入（未读）。
      counted++;
    }
  }
  return (
    finished: finished,
    counted: counted,
    progress: counted == 0 ? null : sum / counted,
  );
}
