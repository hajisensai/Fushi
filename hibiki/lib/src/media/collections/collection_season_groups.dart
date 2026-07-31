import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/video/video_filename_parser.dart';

/// 合集内分季分组（schema v64 `media_collection_items.group_key`）的**单一真相源**：
/// 键派生规则、多组判定、分节构建、按季重排。纯函数无 IO，便于单测。
///
/// 背景（用户拍板「多季直接在合集里面分开」）：文件夹导入按剥掉季号后的系列名
/// 分组，S01/S02/PV 天生混进同一个 playlist 合集；而 Bangumi 一季一条目，「整合集
/// 映射 + 合集下标当集数」会把 S02E01 报成 E13、完结误报给第一季条目。分组键把
/// 「这一集属于哪一季」固化成合集成员标签：详情页据此分节展示，tracking 据此绕开
/// 结构性失真的合集级映射（改走季度感知的按集通道）。

/// 解析不出集号的成员（PV / 特典 / 电影加映）的分组键。
const String kCollectionExtrasGroupKey = 'extras';

/// 由解析出的季/集派生分组键：有集号 → `s<季号>`（无季号视作第 1 季，与
/// 排序规则 `_compareEpisodes` 的「null 视作 1」同口径）；无集号 → PV/特典组。
String collectionSeasonGroupKey({int? season, int? episode}) =>
    episode == null ? kCollectionExtrasGroupKey : 's${season ?? 1}';

/// 从视频文件路径/文件名派生分组键（导入落库与「按季分组」动作同源；解析引擎
/// 与刮削/排序同一个 [parseVideoFilename]）。
String collectionGroupKeyForFilename(String filename) {
  final VideoNameInfo info = parseVideoFilename(p.basename(filename));
  return collectionSeasonGroupKey(season: info.season, episode: info.episode);
}

/// 组键还原季号：`s<N>` → N；[kCollectionExtrasGroupKey] / 未知格式 → null。
int? seasonNumberOfGroupKey(String groupKey) {
  if (!groupKey.startsWith('s')) return null;
  return int.tryParse(groupKey.substring(1));
}

/// 多季判定：**全部**成员已分组（非 null）且组数 ≥ 2 才算。部分分组（旧数据里
/// 混进新导入的集）不启用分季语义——半截状态下分节 UI 与上报口径都会漂。
bool isMultiSeasonGrouped(Iterable<String?> keys) {
  final Set<String> distinct = <String>{};
  bool any = false;
  for (final String? key in keys) {
    if (key == null) return false;
    any = true;
    distinct.add(key);
  }
  return any && distinct.length >= 2;
}

/// 一个分节：组键 + 按全局顺序保留相对序的成员。
class CollectionSeasonSection<T> {
  const CollectionSeasonSection({required this.groupKey, required this.items});

  final String groupKey;
  final List<T> items;
}

/// 按「组键首次出现顺序」把有序成员聚成分节（组内保持传入相对序；分节只是
/// 视觉聚合，不改 sortIndex）。null 键防御性归入 PV/特典组（正常调用方应先过
/// [isMultiSeasonGrouped] 门）。
List<CollectionSeasonSection<T>> buildCollectionSeasonSections<T>({
  required List<T> members,
  required String? Function(T member) keyOf,
}) {
  final Map<String, List<T>> byKey = <String, List<T>>{};
  final List<String> firstSeen = <String>[];
  for (final T member in members) {
    final String key = keyOf(member) ?? kCollectionExtrasGroupKey;
    byKey.putIfAbsent(key, () {
      firstSeen.add(key);
      return <T>[];
    }).add(member);
  }
  return <CollectionSeasonSection<T>>[
    for (final String key in firstSeen)
      CollectionSeasonSection<T>(groupKey: key, items: byKey[key]!),
  ];
}

/// 「按季分组」动作的计算结果：新全序 + 每成员分组键。
class CollectionSeasonRegroup<T> {
  const CollectionSeasonRegroup({required this.ordered, required this.keyOf});

  /// 季升序（extras 组排末尾）→ 集升序 → 标题的新全序。
  final List<T> ordered;

  /// 成员 → 分组键。
  final Map<T, String> keyOf;
}

/// 对合集成员按文件名重算季/集：产出新排序与分组键（调用方据此落盘
/// `reorderCollectionItems` + `setCollectionItemGroupKeys`）。
CollectionSeasonRegroup<T> regroupMembersBySeason<T>({
  required List<T> members,
  required String Function(T member) filenameOf,
  required String Function(T member) titleOf,
}) {
  final Map<T, VideoNameInfo> infoOf = <T, VideoNameInfo>{
    for (final T m in members) m: parseVideoFilename(p.basename(filenameOf(m))),
  };
  final List<T> ordered = List<T>.of(members)
    ..sort((T a, T b) {
      final VideoNameInfo ia = infoOf[a]!;
      final VideoNameInfo ib = infoOf[b]!;
      // extras（无集号）排末尾，组内季→集→标题（与导入分组排序同口径）。
      final int sa = ia.episode == null ? 1 << 20 : (ia.season ?? 1);
      final int sb = ib.episode == null ? 1 << 20 : (ib.season ?? 1);
      if (sa != sb) return sa.compareTo(sb);
      final int ea = ia.episode ?? (1 << 30);
      final int eb = ib.episode ?? (1 << 30);
      if (ea != eb) return ea.compareTo(eb);
      return titleOf(a).toLowerCase().compareTo(titleOf(b).toLowerCase());
    });
  return CollectionSeasonRegroup<T>(
    ordered: ordered,
    keyOf: <T, String>{
      for (final T m in members)
        m: collectionSeasonGroupKey(
          season: infoOf[m]!.season,
          episode: infoOf[m]!.episode,
        ),
    },
  );
}
