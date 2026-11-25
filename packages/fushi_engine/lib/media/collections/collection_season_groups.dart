import 'package:fushi_engine/media/media_extensions.dart'
    show isAudioOnlyMediaPath;
import 'package:fushi_engine/media/video/bluray/bluray_episode.dart'
    show isBlurayEpisodePath;
import 'package:fushi_engine/media/video/disc/disc_format.dart'
    show discRootForMemberPath;
import 'package:fushi_engine/media/video/video_filename_parser.dart';

/// 合集内分季分组的**单一真相源**：键派生规则、多组判定、分节构建、按季重排。
/// 纯函数无 IO，便于单测。
///
/// 背景（用户拍板「多季直接在合集里面分开」）：文件夹导入按剥掉季号后的系列名
/// 分组，S01/S02/PV 天生混进同一个 playlist 合集；而 Bangumi 一季一条目，「整合集
/// 映射 + 合集下标当集数」会把 S02E01 报成 E13、完结误报给第一季条目。
///
/// **分组默认是文件名的纯函数**——在读取时从 `videoPath` 现场派生，不落库。整列
/// 存储方案（曾试过 `group_key` 列）会制造三个本可不存在的问题：存量合集要手动
/// 补键、旧成员 null 新成员有键的「半截态」、跨端同步对端无键退化。派生让全部
/// 存量/新导入/同步来的多季合集**立即**获得同一语义，零迁移零手动。
///
/// 文件名推断不了或推断错的成员（`01`–`08` 的短篇其实是特典）由用户 / AI 显式
/// 指定，按优先级叠在派生键之上（[resolveCollectionSection]，拍板台 iR6ccUys9H）：
/// ① 手动分栏（`video_collection_section_overrides`，稀疏行）→ ② 手动季集指定
/// （`video_episode_binding_overrides`：第 0 季 = 特别篇 → PV·特典，第 N 季 → 第 N
/// 季）→ ③ 文件名派生。没有指定的成员照旧派生，上面三条好处原样保留。
/// 消费点：详情页顶部**季 tab**（切 tab 换该季剧集，单季合集不出 tab）、tracking
/// 绕开结构性失真的合集级映射（改走季度感知的按集通道）。

/// 解析不出集号的成员（PV / 特典 / 电影加映）的分组键。
const String kCollectionExtrasGroupKey = 'extras';

/// 由解析出的季/集派生分组键：有集号 → `s<季号>`（无季号视作第 1 季，与
/// 排序规则 `_compareEpisodes` 的「null 视作 1」同口径）；无集号 → PV/特典组。
///
/// 第 0 季（`S00E01`、`Season 00/`）是特别篇，归 PV/特典组，不单开一个「第 0 季」
/// tab——与手动季集指定到第 0 季（[resolveCollectionSection]）同一口径（拍板台
/// iR6ccUys9H）。
String collectionSeasonGroupKey({int? season, int? episode}) =>
    episode == null || season == 0
    ? kCollectionExtrasGroupKey
    : 's${season ?? 1}';

/// 从视频文件路径/文件名派生分组键（导入落库与「按季分组」动作同源；解析引擎
/// 与刮削/排序同一个 [parseVideoPath]）。
///
/// 走**整条路径**而非 basename：季号可能只写在父目录上（`Show/Season 2/01.mkv`），
/// 见 [parseVideoPath]。传纯文件名同样可用（无父目录段即退化回 basename 口径）。
String collectionGroupKeyForFilename(String filename) {
  // BUG-2835：纯音频（专辑曲目）不是任何一季的分集。`24. 悲愴.flac` 现在解不出
  // 集号只是因为刮削器不剥音频扩展名——这里显式判，不靠那个巧合。
  if (isAudioOnlyMediaPath(filename)) return kCollectionExtrasGroupKey;
  final VideoNameInfo info = parseVideoPath(filename);
  return collectionSeasonGroupKey(season: info.season, episode: info.episode);
}

/// 一批成员路径的分组键：逐个按 [collectionGroupKeyForFilename] 派生，再按原盘结构
/// 修正（BUG-5391）。「全部播放」被切成各集的蓝光盘上，分集成员
/// （`00001.p03.mpls`，[isBlurayEpisodePath]）是正片 → 第 1 季；同一张盘上没切的
/// 整条播放列表（`00005.mpls`）是特典 → PV·特典——与选片第 7b 步（切了集的盘上
/// 整条标题一律降为特典）同一判据。原盘成员路径里的数字是播放列表号，逐个派生解不出
/// 集号，全落进 PV·特典组，正片与特典混排、特典占集号。
///
/// 只看本批里的路径（纯函数，无 IO）：没有分集成员的盘、非原盘成员照旧逐个派生。
/// 返回值与 [paths] 同序、同长。手动分栏 / 季集指定照样叠在它上面
/// （[resolveCollectionSection]）。
List<String> collectionGroupKeysForPaths(List<String> paths) {
  final Set<String> splitDiscs = _splitDiscRoots(paths);
  return <String>[
    for (final String path in paths)
      switch (_splitDiscRole(path, splitDiscs)) {
        true => 's1',
        false => kCollectionExtrasGroupKey,
        null => collectionGroupKeyForFilename(path),
      },
  ];
}

/// 一批成员路径（合集内顺序）里原盘分集的显示集号：「全部播放」被切成各集的蓝光盘上
/// 的分集成员按出现顺序编 1、2、3…（跨盘接着数，与刮削计划
/// `discOrdinalEpisodeOverrides` 按合集顺序编号同一口径）；同盘特典、别的成员（用户
/// 自己加进来的普通视频按文件名定号）为 null。返回值与 [paths] 同序、同长。
List<int?> discEpisodeOrdinalsOf(List<String> paths) {
  final Set<String> splitDiscs = _splitDiscRoots(paths);
  int next = 0;
  return <int?>[
    for (final String path in paths)
      _splitDiscRole(path, splitDiscs) == true ? ++next : null,
  ];
}

/// [paths] 里带分集成员的盘根（小写、`/` 分隔）。
Set<String> _splitDiscRoots(List<String> paths) => <String>{
  for (final String path in paths)
    if (isBlurayEpisodePath(path))
      if (discRootForMemberPath(path) case final String root) _rootKey(root),
};

/// [path] 在切了集的盘上时：分集 → true、整条标题 → false；否则 null。
bool? _splitDiscRole(String path, Set<String> splitDiscs) {
  if (splitDiscs.isEmpty) return null;
  final String? root = discRootForMemberPath(path);
  if (root == null || !splitDiscs.contains(_rootKey(root))) return null;
  return isBlurayEpisodePath(path);
}

String _rootKey(String root) => root.replaceAll(r'\', '/').toLowerCase();

/// 组键还原季号：`s<N>` → N；[kCollectionExtrasGroupKey] / 未知格式 → null。
int? seasonNumberOfGroupKey(String groupKey) {
  if (!groupKey.startsWith('s')) return null;
  return int.tryParse(groupKey.substring(1));
}

/// 写入口接受的手动分栏键：`extras` 或规范形 `s<N>`（N ≥ 1）。第 0 季不是一栏
/// （特别篇就是 PV·特典栏），`s01` / `s-1` 这类非规范形一律拒收。
bool isValidCollectionSectionKey(String key) {
  if (key == kCollectionExtrasGroupKey) return true;
  final int? season = seasonNumberOfGroupKey(key);
  return season != null && season >= 1 && key == 's$season';
}

/// 一个成员的分栏从哪来（查询接口如实报给调用方，便于核对「为什么在这一栏」）。
enum CollectionSectionSource {
  /// 用户 / AI 手动指定的分栏。
  manual,

  /// 手动季集指定（第 0 季 → PV·特典）。
  pinnedEpisode,

  /// 文件名 / 路径派生（默认）。
  filename,
}

/// 一个成员的生效分栏 + 来源 + 不看任何指定时的派生键。
class CollectionSectionResolution {
  const CollectionSectionResolution({
    required this.groupKey,
    required this.source,
    required this.derivedKey,
  });

  /// 生效分栏键（`s<N>` / `extras`）。
  final String groupKey;

  final CollectionSectionSource source;

  /// 文件名派生键（清掉全部指定后会回到的那一栏）。
  final String derivedKey;
}

/// 按优先级合成生效分栏：手动分栏（形状合法才算）→ 手动季集指定 → 派生键。纯函数。
CollectionSectionResolution resolveCollectionSection({
  required String derivedKey,
  String? manualKey,
  int? pinnedSeason,
}) {
  if (manualKey != null && isValidCollectionSectionKey(manualKey)) {
    return CollectionSectionResolution(
      groupKey: manualKey,
      source: CollectionSectionSource.manual,
      derivedKey: derivedKey,
    );
  }
  if (pinnedSeason != null && pinnedSeason >= 0) {
    return CollectionSectionResolution(
      groupKey: pinnedSeason == 0
          ? kCollectionExtrasGroupKey
          : 's$pinnedSeason',
      source: CollectionSectionSource.pinnedEpisode,
      derivedKey: derivedKey,
    );
  }
  return CollectionSectionResolution(
    groupKey: derivedKey,
    source: CollectionSectionSource.filename,
    derivedKey: derivedKey,
  );
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
    byKey
        .putIfAbsent(key, () {
          firstSeen.add(key);
          return <T>[];
        })
        .add(member);
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

/// 对合集成员按分栏重排：产出新排序与分组键（「按季排序」动作据此
/// 经 `reorderCollectionItems` 落盘新序；键仅供展示层复用，不落库）。
///
/// 先按**生效分栏**分桶（季号升序、PV·特典殿后），桶内按文件名集号 → 标题。
/// [sectionKeyOf] 给生效分栏（手动分栏 / 手动季集指定叠在文件名之上，见
/// `loadCollectionSections`，拍板台 iR6ccUys9H）；不给或返回 null 时按文件名
/// 派生（[collectionGroupKeyForFilename]，第 0 季归 PV·特典）。分桶与 [keyOf]
/// 同一个键，所以重排后的全序与季 tab 分节一致。
CollectionSeasonRegroup<T> regroupMembersBySeason<T>({
  required List<T> members,
  required String Function(T member) filenameOf,
  required String Function(T member) titleOf,
  String? Function(T member)? sectionKeyOf,
}) {
  final Map<T, VideoNameInfo> infoOf = <T, VideoNameInfo>{
    for (final T m in members) m: parseVideoPath(filenameOf(m)),
  };
  final Map<T, String> keyOf = <T, String>{
    for (final T m in members)
      m:
          sectionKeyOf?.call(m) ??
          collectionSeasonGroupKey(
            season: infoOf[m]!.season,
            episode: infoOf[m]!.episode,
          ),
  };
  // extras（及未知形状的键）排末尾。
  int bucketOf(T m) => seasonNumberOfGroupKey(keyOf[m]!) ?? (1 << 20);
  final List<T> ordered = List<T>.of(members)
    ..sort((T a, T b) {
      final int sa = bucketOf(a);
      final int sb = bucketOf(b);
      if (sa != sb) return sa.compareTo(sb);
      final int ea = infoOf[a]!.episode ?? (1 << 30);
      final int eb = infoOf[b]!.episode ?? (1 << 30);
      if (ea != eb) return ea.compareTo(eb);
      return titleOf(a).toLowerCase().compareTo(titleOf(b).toLowerCase());
    });
  return CollectionSeasonRegroup<T>(ordered: ordered, keyOf: keyOf);
}
