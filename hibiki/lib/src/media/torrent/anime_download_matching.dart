import 'package:hibiki/src/media/torrent/nyaa_client.dart';
import 'package:hibiki/src/media/video/jimaku_client.dart';

/// 番剧下载选种对话框的纯决策逻辑：Jimaku 字幕按集索引 + 种子↔字幕匹配。
///
/// 全部纯函数/纯数据（不打网络、不碰磁盘），便于单测；对话框只做编排与渲染。

/// 从 Jimaku 文件列表构建的按集索引。
///
/// 只收文本字幕（[JimakuFile.isTextSubtitle]）；每集候选按语言权重升序排列
/// （[jimakuLanguageRank] + [detectSubtitleLanguage]，即 ja 优先），同权重按
/// 文件名（大小写不敏感）tie-break 保证确定性。
class JimakuEpisodeIndex {
  const JimakuEpisodeIndex._({
    required this.byEpisode,
    required this.unnumbered,
  });

  /// 从 [files] 构建索引（非文本字幕直接丢弃）。
  factory JimakuEpisodeIndex.fromFiles(
    List<JimakuFile> files, {
    String? preferredLanguage,
  }) {
    final Map<int, List<JimakuFile>> byEpisode = <int, List<JimakuFile>>{};
    final List<JimakuFile> unnumbered = <JimakuFile>[];
    for (final JimakuFile file in files) {
      if (!file.isTextSubtitle) continue;
      final int? episode = file.episode;
      if (episode == null) {
        unnumbered.add(file);
      } else {
        byEpisode.putIfAbsent(episode, () => <JimakuFile>[]).add(file);
      }
    }
    for (final List<JimakuFile> candidates in byEpisode.values) {
      candidates.sort((JimakuFile a, JimakuFile b) =>
          _compareByLanguagePreference(a, b, preferredLanguage));
    }
    unnumbered.sort((JimakuFile a, JimakuFile b) =>
        _compareByLanguagePreference(a, b, preferredLanguage));
    return JimakuEpisodeIndex._(byEpisode: byEpisode, unnumbered: unnumbered);
  }

  /// 集号 → 该集候选（语言权重升序 = ja 优先，非空列表）。
  final Map<int, List<JimakuFile>> byEpisode;

  /// 认不出集号的文本字幕（剧场版/整季单文件等），同样按语言权重升序。
  final List<JimakuFile> unnumbered;

  /// 索引内文本字幕总数。
  int get totalFiles =>
      unnumbered.length +
      byEpisode.values
          .fold(0, (int sum, List<JimakuFile> list) => sum + list.length);

  /// 索引是否为空（无任何可用文本字幕）。
  bool get isEmpty => totalFiles == 0;
}

/// 候选排序键：语言权重升序（ja 优先）→ 文件名（大小写不敏感）tie-break。
int _compareByLanguagePreference(
  JimakuFile a,
  JimakuFile b,
  String? preferredLanguage,
) {
  final int rankA = jimakuLanguageRank(detectSubtitleLanguage(a.name),
      preferred: preferredLanguage);
  final int rankB = jimakuLanguageRank(detectSubtitleLanguage(b.name),
      preferred: preferredLanguage);
  if (rankA != rankB) return rankA.compareTo(rankB);
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

/// 种子「集数身份」的类别。见 [TorrentEpisodeScope]。
enum TorrentEpisodeScopeKind {
  /// 标题写明集号区间（`01-13`）：按区间逐集对位。
  range,

  /// 单集（`- 07` / `第07話` / `S01E07`）。
  single,

  /// 整季 / 全集包：标了季号或 batch / Complete / BD-BOX / `全13話` 这类整季
  /// 标记，但既没有单集号也没写区间——**集号未知，但「这一包覆盖整季」是确定的**。
  season,

  /// 无集数概念（剧场版 / 单文件）。
  unknown,
}

/// 种子的「集数身份」——字幕匹配与覆盖度徽标的**唯一判据**。
///
/// 此前 [chooseSubtitlesFor] 与 [jimakuCoverageFor] 各自用
/// `episodeRange` / `episode` 两个 getter 现推语义，整季包（标题只写 `S1` /
/// `Complete`，不写 `01-13`）在两处被推成不同结论：列表徽标算「有字幕」、
/// 确认页却一条都不给（BUG-1189）。集数身份收敛成这一个值后，两处共用同一分支，
/// 结论不可能再打架。
class TorrentEpisodeScope {
  const TorrentEpisodeScope._(this.kind, {this.range, this.episode});

  /// 集号区间已知（`01-13`）。
  const TorrentEpisodeScope.range((int, int) range)
      : this._(TorrentEpisodeScopeKind.range, range: range);

  /// 单集。
  const TorrentEpisodeScope.single(int episode)
      : this._(TorrentEpisodeScopeKind.single, episode: episode);

  /// 整季包（集号未知）。[episodeCount] 是标题自报的包内集数（`全13話`），
  /// 标题没写为 null。
  const TorrentEpisodeScope.season({int? episodeCount})
      : this._(TorrentEpisodeScopeKind.season, episode: episodeCount);

  /// 无集数概念。
  const TorrentEpisodeScope.unknown() : this._(TorrentEpisodeScopeKind.unknown);

  final TorrentEpisodeScopeKind kind;

  /// [TorrentEpisodeScopeKind.range] 时的集号区间，其余为 null。
  final (int, int)? range;

  /// [TorrentEpisodeScopeKind.single] 时的集号；[TorrentEpisodeScopeKind.season]
  /// 时是标题自报的包内集数（`全13話` → 13）。其余为 null。
  final int? episode;

  /// 整季包标题自报的包内集数（`全13話` → 13）；非 season 或标题没写为 null。
  int? get seasonEpisodeCount =>
      kind == TorrentEpisodeScopeKind.season ? episode : null;
}

/// 整季包标记（标题里表明「这是整季/全集」但不写集号区间的写法）。
/// 季号（`S1` / `Season 2` / `第二季`）由 [NyaaTorrent.season] 单独识别，此处
/// 只补 batch / 完结包关键词。
final RegExp _seasonPackMarker = RegExp(
  r'\b(complete(\s+series)?|batch|bd-?box)\b|全\s*\d{0,3}\s*[话話集]',
  caseSensitive: false,
);

/// 整季包标题自报的集数（`全13話` / `全 26 集` → 13 / 26）。`全話`（无数字）不算。
/// 这是**唯一关于「这一包里有几集」的自述信息**，见 [torrentEpisodeScope]。
final RegExp _seasonPackEpisodeCount = RegExp(r'全\s*(\d{1,3})\s*[话話集]');

/// 判定种子 [t] 的集数身份。纯函数。
///
/// 优先级（区间 > 单集 > 整季 > 无）：合集标题常同时被解析出区间末位当「单集号」，
/// 区间存在时它才是真相；而 `S1 [BDRip]` 这类整季包解不出集号，必须落到
/// [TorrentEpisodeScopeKind.season] 而不是「无集数概念」，否则整季字幕全被丢弃。
TorrentEpisodeScope torrentEpisodeScope(NyaaTorrent t) {
  final (int, int)? range = t.episodeRange;
  if (range != null) return TorrentEpisodeScope.range(range);
  final int? episode = t.episode;
  if (episode != null) return TorrentEpisodeScope.single(episode);
  if (t.isBatch || t.season != null || _seasonPackMarker.hasMatch(t.title)) {
    final RegExpMatch? countMatch = _seasonPackEpisodeCount.firstMatch(t.title);
    return TorrentEpisodeScope.season(
      episodeCount:
          countMatch == null ? null : int.tryParse(countMatch.group(1)!),
    );
  }
  return const TorrentEpisodeScope.unknown();
}

/// 整季包该取几条字幕的上界。纯函数。
///
/// **这一层拿不到「包内实际集数」**：`chooseSubtitlesFor` 的调用点手上只有 Nyaa
/// RSS 结果（[NyaaTorrent] 只有标题 + 体积，没有文件列表；种子要到用户点「推送
/// 下载」之后才 add 进引擎，那时字幕早已下完），所以只能用**自述上界**收敛：
/// - ① 标题自报的包内集数（`全13話`）——关于这一包本身，最强；
/// - ② 调用方给的该季应有集数（[seriesEpisodeCount]，AniList `media.episodes`）——
///   整季包声称覆盖该季，用它当上界；连载中的番 AniList 给 null。
/// 两者都没有 → 返回 null（不设上界，维持原行为）。**不发明魔数**：拍脑袋的
/// 「最多 26 集」对 50 集长番就是静默丢字幕。
///
/// 为什么要收敛：Jimaku 条目常把多季合并编号（24 集），而包只有 12 集；多下的
/// 12 条永远配不上任何视频（落位层 [pairSubtitlesToVideos] 要求集号严格相等），
/// 纯耗带宽和磁盘。
int? seasonSubtitleCap(TorrentEpisodeScope scope, {int? seriesEpisodeCount}) {
  final int? fromTitle = scope.seasonEpisodeCount;
  if (fromTitle != null && fromTitle > 0) return fromTitle;
  if (seriesEpisodeCount != null && seriesEpisodeCount > 0) {
    return seriesEpisodeCount;
  }
  return null;
}

/// 整季包按 [seasonSubtitleCap] 收敛后的集号列表（升序，取最前 cap 个）。
///
/// 取「最前 cap 个」而不是「集号 ≤ cap」：Jimaku 条目按绝对集号编号时（S2 的
/// 字幕编号 13-24），后者一条都不给；前者至少条数正确。集号是否真对得上这一包
/// 本层无从判断——那由 UI 标成「未核对」（见 `torrentEpisodeScope` 的 season 分支
/// 消费方），本轮不做绝对集号换算。
List<int> _seasonEpisodes(
  JimakuEpisodeIndex index,
  TorrentEpisodeScope scope,
  int? seriesEpisodeCount,
) {
  final List<int> episodes = index.byEpisode.keys.toList()..sort();
  final int? cap =
      seasonSubtitleCap(scope, seriesEpisodeCount: seriesEpisodeCount);
  if (cap == null || episodes.length <= cap) return episodes;
  return episodes.sublist(0, cap);
}

/// 计算种子 [t] 的字幕覆盖度（列表徽标「字幕 covered/total」用）。
///
/// 按 [torrentEpisodeScope] 分支，与 [chooseSubtitlesFor] 严格同源
/// （两者必须对同一种子给出一致结论）：
/// - range → `total` = 区间长度，`covered` = 区间内有候选的集数；
/// - single → `total` 1，`covered` 0/1；
/// - season（整季包，应有集数未知）→ `total` null，`covered` = 索引里有候选的
///   集数、按 [seasonSubtitleCap] 收敛（无编号集但有整季单文件字幕时记 1）；
/// - unknown（剧场版/单文件）→ `total` null，`covered` = 索引非空则 1。
///
/// [seriesEpisodeCount]：该季应有集数（AniList），只用于 season 分支收敛条数，
/// 必须与 [chooseSubtitlesFor] 传同一个值，否则徽标数与字幕列表条数会打架。
({int covered, int? total}) jimakuCoverageFor(
  NyaaTorrent t,
  JimakuEpisodeIndex index, {
  int? seriesEpisodeCount,
}) {
  final TorrentEpisodeScope scope = torrentEpisodeScope(t);
  switch (scope.kind) {
    case TorrentEpisodeScopeKind.range:
      final (int, int) range = scope.range!;
      int covered = 0;
      for (int episode = range.$1; episode <= range.$2; episode++) {
        if (index.byEpisode.containsKey(episode)) covered++;
      }
      return (covered: covered, total: range.$2 - range.$1 + 1);
    case TorrentEpisodeScopeKind.single:
      return (
        covered: index.byEpisode.containsKey(scope.episode!) ? 1 : 0,
        total: 1
      );
    case TorrentEpisodeScopeKind.season:
      final List<int> episodes =
          _seasonEpisodes(index, scope, seriesEpisodeCount);
      if (episodes.isNotEmpty) {
        return (covered: episodes.length, total: null);
      }
      return (covered: index.unnumbered.isEmpty ? 0 : 1, total: null);
    case TorrentEpisodeScopeKind.unknown:
      // 与 [chooseSubtitlesFor] 的 unknown 分支同构：只有「有 unnumbered」或
      // 「全部文件恰好 1 条」才真给得出，其余不猜。此前这里一律记 1，于是
      // 「列表徽标说有字幕、点进详情说无字幕」（同 BUG-1189）。
      if (index.unnumbered.isNotEmpty) return (covered: 1, total: null);
      return (covered: index.totalFiles == 1 ? 1 : 0, total: null);
  }
}

/// 为种子 [t] 挑选随下载暂存的字幕清单（`(集号, 文件)`，集号 null = 未知）。
///
/// 按 [torrentEpisodeScope] 分支（与 [jimakuCoverageFor] 同源）：
/// - range → 区间内每集取首选（语言权重最优）各 1 条，缺集跳过；
/// - single → 该集首选 1 条（记录集号）；无候选返回空；
/// - season（整季包）→ 索引里的已知集各取首选（集号升序），条数按
///   [seasonSubtitleCap] 收敛；一集都没有但有整季单文件字幕时退回该单文件
///   （记 episode null）。种子标题没写区间不代表它不含整季，落位仍按集对位；
/// - unknown → 有无集号文件（[JimakuEpisodeIndex.unnumbered]）时取其首选，
///   否则全部文件恰好只有 1 条时给它；其余情况不猜，返回空。两种给出场景
///   均记 episode null（种子本身无集数概念，sidecar 落位不按集对位）。
///
/// [seriesEpisodeCount]：该季应有集数（AniList），见 [seasonSubtitleCap]；
/// 必须与 [jimakuCoverageFor] 传同一个值。
List<(int?, JimakuFile)> chooseSubtitlesFor(
  NyaaTorrent t,
  JimakuEpisodeIndex index, {
  int? seriesEpisodeCount,
}) {
  final TorrentEpisodeScope scope = torrentEpisodeScope(t);
  switch (scope.kind) {
    case TorrentEpisodeScopeKind.range:
      final (int, int) range = scope.range!;
      final List<(int?, JimakuFile)> out = <(int?, JimakuFile)>[];
      for (int episode = range.$1; episode <= range.$2; episode++) {
        final List<JimakuFile>? candidates = index.byEpisode[episode];
        if (candidates != null && candidates.isNotEmpty) {
          out.add((episode, candidates.first));
        }
      }
      return out;
    case TorrentEpisodeScopeKind.single:
      final int episode = scope.episode!;
      final List<JimakuFile>? candidates = index.byEpisode[episode];
      if (candidates == null || candidates.isEmpty) {
        return const <(int?, JimakuFile)>[];
      }
      return <(int?, JimakuFile)>[(episode, candidates.first)];
    case TorrentEpisodeScopeKind.season:
      final List<int> episodes =
          _seasonEpisodes(index, scope, seriesEpisodeCount);
      if (episodes.isNotEmpty) {
        return <(int?, JimakuFile)>[
          for (final int episode in episodes)
            (episode, index.byEpisode[episode]!.first),
        ];
      }
      if (index.unnumbered.isNotEmpty) {
        return <(int?, JimakuFile)>[(null, index.unnumbered.first)];
      }
      return const <(int?, JimakuFile)>[];
    case TorrentEpisodeScopeKind.unknown:
      if (index.unnumbered.isNotEmpty) {
        return <(int?, JimakuFile)>[(null, index.unnumbered.first)];
      }
      if (index.totalFiles == 1) {
        return <(int?, JimakuFile)>[(null, index.byEpisode.values.first.first)];
      }
      return const <(int?, JimakuFile)>[];
  }
}
