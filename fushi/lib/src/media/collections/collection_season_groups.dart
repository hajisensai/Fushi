import 'package:fushi/src/media/video/video_filename_parser.dart';

/// 合集内分季分组的**单一真相源**：键派生规则、多组判定、分节构建、按季重排。
/// 纯函数无 IO，便于单测。
///
/// 背景（用户拍板「多季直接在合集里面分开」）：文件夹导入按剥掉季号后的系列名
/// 分组，S01/S02/PV 天生混进同一个 playlist 合集；而 Bangumi 一季一条目，「整合集
/// 映射 + 合集下标当集数」会把 S02E01 报成 E13、完结误报给第一季条目。
///
/// **分组是文件名的纯函数，不是持久化状态**——一律在读取时从 `videoPath` 现场
/// 派生，不落库。存储方案（曾试过 `group_key` 列）会制造三个本可不存在的问题：
/// 存量合集要手动补键、旧成员 null 新成员有键的「半截态」、跨端同步对端无键退化。
/// 派生让全部存量/新导入/同步来的多季合集**立即**获得同一语义，零迁移零手动。
/// 消费点：详情页顶部**季 tab**（切 tab 换该季剧集，单季合集不出 tab）、tracking
/// 绕开结构性失真的合集级映射（改走季度感知的按集通道）。

/// 解析不出集号的成员（PV / 特典 / 电影加映）的分组键。
const String kCollectionExtrasGroupKey = 'extras';

/// 由解析出的季/集派生分组键：有集号 → `s<季号>`（无季号视作第 1 季，与
/// 排序规则 `_compareEpisodes` 的「null 视作 1」同口径）；无集号 → PV/特典组。
String collectionSeasonGroupKey({int? season, int? episode}) =>
    episode == null ? kCollectionExtrasGroupKey : 's${season ?? 1}';

/// 从视频文件路径/文件名派生分组键（导入落库与「按季分组」动作同源；解析引擎
/// 与刮削/排序同一个 [parseVideoPath]）。
///
/// 走**整条路径**而非 basename：季号可能只写在父目录上（`Show/Season 2/01.mkv`），
/// 见 [parseVideoPath]。传纯文件名同样可用（无父目录段即退化回 basename 口径）。
String collectionGroupKeyForFilename(String filename) {
  final VideoNameInfo info = parseVideoPath(filename);
  return collectionSeasonGroupKey(season: info.season, episode: info.episode);
}

/// 组键还原季号：`s<N>` → N；[kCollectionExtrasGroupKey] / 未知格式 → null。
int? seasonNumberOfGroupKey(String groupKey) {
  if (!groupKey.startsWith('s')) return null;
  return int.tryParse(groupKey.substring(1));
}

/// 多季判定：派生出的组数 ≥ 2（单季、纯电影、全 PV 都是单组 → 不启用分季语义）。
bool isMultiSeasonGrouped(Iterable<String> keys) {
  final Set<String> distinct = <String>{};
  for (final String key in keys) {
    distinct.add(key);
    if (distinct.length >= 2) return true;
  }
  return false;
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

/// 分节按**季号升序、PV/特典殿后**重排（季 tab 的展示序）。
///
/// [buildCollectionSeasonSections] 用「组键首次出现顺序」，那是列表分节的正确
/// 口径（跟着落盘全序走）；但 tab 是一排并列入口，乱序合集会出现「第 2 季 |
/// 第 1 季 | PV·特典」这种读起来就是错的排列。tab 序与落盘序解耦：只改 tab
/// 的排列，不动节内成员相对序，也不写 sortIndex。
List<CollectionSeasonSection<T>> sortCollectionSeasonSections<T>(
  List<CollectionSeasonSection<T>> sections,
) {
  // extras 无季号 → 排到所有真实季之后（与 regroupMembersBySeason 的殿后同口径）。
  int rank(CollectionSeasonSection<T> s) =>
      seasonNumberOfGroupKey(s.groupKey) ?? (1 << 20);
  return List<CollectionSeasonSection<T>>.of(sections)
    ..sort((CollectionSeasonSection<T> a, CollectionSeasonSection<T> b) {
      final int ra = rank(a);
      final int rb = rank(b);
      if (ra != rb) return ra.compareTo(rb);
      // 同 rank 只可能是多个未知格式键：退回稳定的键字典序。
      return a.groupKey.compareTo(b.groupKey);
    });
}

/// 「按季分组」动作的计算结果：新全序 + 每成员分组键。
class CollectionSeasonRegroup<T> {
  const CollectionSeasonRegroup({required this.ordered, required this.keyOf});

  /// 季升序（extras 组排末尾）→ 集升序 → 标题的新全序。
  final List<T> ordered;

  /// 成员 → 分组键。
  final Map<T, String> keyOf;
}

/// 对合集成员按文件名重算季/集：产出新排序与分组键（「按季排序」动作据此
/// 经 `reorderCollectionItems` 落盘新序；键仅供展示层复用，不落库）。
CollectionSeasonRegroup<T> regroupMembersBySeason<T>({
  required List<T> members,
  required String Function(T member) filenameOf,
  required String Function(T member) titleOf,
}) {
  final Map<T, VideoNameInfo> infoOf = <T, VideoNameInfo>{
    for (final T m in members) m: parseVideoPath(filenameOf(m)),
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
