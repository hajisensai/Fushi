/// 下载模式资源候选的「版本」聚类（纯函数，参照 RSS-Subtitle-Manager 的
/// Nyaa 版本选择器）：几十条发布流水账 → 少数几张「发布组 › 清晰度」版本卡。
///
/// 订阅模式已有按订阅生效单位的聚合（`groupVideoSubscriptionCandidates`，
/// BUG-1590）；本模块服务**下载模式**：用户最终要挑的是一条具体发布，聚类只
/// 负责把「哪个组哪个清晰度」这层决策折起来，选组后再展开挑集。
library;

import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/scraper/filename_parser.dart';

/// [episodeNumberFromReleaseTitle] 的记忆表。该函数被排序比较器
/// （[_byEpisodeAsc]）与 `episodes` getter 反复调用，同一个标题在一次搜索里会被解析
/// 几十次，而 [FilenameParser.parse] 是整套规则引擎、不是两条正则。记忆是纯的
/// （同输入同输出），上限只为防会话内无界增长——一次搜索的标题数是几十到几百，
/// 命中率不受影响。
const int _kEpisodeMemoLimit = 2048;
final Map<String, int?> _episodeMemo = <String, int?>{};

/// 从发布标题解析集号，认不出返回 null。
///
/// **委托给 [FilenameParser]，这里不再自带规则。** 本函数原先是一套独立的迷你
/// 解析器（`\bS\d+E\d+\b` + `(?:^|\s)-\s*(\d+)(?=\s*[\[\(]|$)` 两条正则），
/// 与刮削/导入/分组共用的 [FilenameParser] 并列——正是 G10 第二步要消灭的那种
/// 「同一个文件名两套引擎解出不同集号」。它比真引擎少认一大批形态
/// （`[4th - 14]`、`[S4 - 14]`、`【组】作品 - 14 【1080P】`、`[01]`、`第04话`、
/// `[13 END]` 全部返回 null），而单独放宽它的正则会让 `firstMatch` 被更靠左的
/// 位置抢答（`[Anime Time - 2] Show - 05` 解成 2、合集 `[01 - 12]` 解成 12、
/// `（1979 - 2005）` 解成 2005）——错值会进版本卡的集号标签和「从第 N 集之后」的
/// 订阅起点，比留空更糟。
///
/// 真引擎两边都对：它先按括号块分类（开头的块是发布组、`[01 - 12]` 与
/// `（1979 - 2005）` 不产出集号），再在括号外文本上跑集号规则。22 条真实发布标题
/// 实测对拍，旧实现有值的每一条新实现给出**相同**的值，另外多解对 6 条（BUG-2146）。
int? episodeNumberFromReleaseTitle(String title) {
  final int? memo = _episodeMemo[title];
  if (memo != null || _episodeMemo.containsKey(title)) return memo;
  final int? episode = FilenameParser.parse(title).episode;
  if (_episodeMemo.length >= _kEpisodeMemoLimit) _episodeMemo.clear();
  _episodeMemo[title] = episode;
  return episode;
}

/// 标题开头的发布组标签（`[SubsPlease] xxx` → `SubsPlease`）。
/// candidate.releaseGroup 缺失时的回退；CRC/分辨率不算组名。
String? releaseGroupTagFromTitle(String title) {
  final RegExpMatch? match = RegExp(
    r'^\s*[\[【]([^\]】]{2,30})[\]】]',
  ).firstMatch(title);
  if (match == null) return null;
  final String tag = match.group(1)!.trim();
  if (tag.isEmpty) return null;
  if (RegExp(r'^[0-9a-fA-F]{8}$').hasMatch(tag)) return null;
  if (RegExp(r'^\d{3,4}[pP]$').hasMatch(tag)) return null;
  return tag;
}

String? _releaseGroupOf(VideoResourceCandidate candidate) {
  final String structured = candidate.releaseGroup?.trim() ?? '';
  if (structured.isNotEmpty) return structured;
  return releaseGroupTagFromTitle(candidate.title);
}

// 下面两条正则**只用于「把集号那一段遮掉」**（下面的模板 key），不是集号解析器
// ——解析是 [episodeNumberFromReleaseTitle] 的事，那里委托给 [FilenameParser]。
// 两件事的判据本来就不同：解析要问「这个标题是第几集」，遮罩要问「标题里哪一段
// 随集数变化」，后者必须是可替换的**子串位置**，所以只能是正则。别把它们合成
// 一个：合起来就是 G10 第二步消灭掉的那种「同一文件名两套引擎」。
final RegExp _episodeMaskSeasonEpisode = RegExp(
  r'\bS(\d{1,3})[ ._-]*E(\d{1,4})(?:v\d+)?\b',
  caseSensitive: false,
);
final RegExp _episodeMaskDash = RegExp(
  r'(?:^|\s)-\s*(\d{1,4})(?:v\d+)?(?=\s*(?:\[|\(|$))',
  caseSensitive: false,
);

/// 没有发布组字段时，用「只抹掉集号」的标题模板识别同一逐集发布系列。
///
/// 不能退成统一空串：那会把不同季、不同编码版本全部混成一组；也不能全部拆成
/// 单条：综合索引器虽然常缺发布组字段，但同一发布者的逐集标题通常仍有稳定模板。
/// 只有真的识别到集号才生成模板；电影/合集等没有逐集身份的候选仍保持单条。
String _unknownReleaseFamilyKey(VideoResourceCandidate candidate) {
  String title = candidate.title.trim().toLowerCase();
  bool replacedEpisode = false;
  title = title.replaceAllMapped(_episodeMaskSeasonEpisode, (Match match) {
    replacedEpisode = true;
    return 's${match.group(1)}e#';
  });
  title = title.replaceAllMapped(_episodeMaskDash, (Match match) {
    replacedEpisode = true;
    return ' - #';
  });
  if (!replacedEpisode) return 'single:${candidate.identityKey}';
  // 每集不同的 CRC 不属于发布系列身份；其它编码、音轨、来源等技术标记保留，
  // 因而 MULTi x264-AMBER 与普通 H264 不会因为同季同清晰度而误合并。
  title = title.replaceAll(RegExp(r'[\[\(][0-9a-f]{8}[\]\)]'), '');
  title = title.replaceAll(RegExp(r'\s+'), ' ').trim();
  return 'template:$title';
}

/// 标题里的清晰度（candidate.resolution 缺失时的回退）。
String? resolutionFromTitle(String title) => RegExp(
  r'\b(2160|1440|1080|720|576|480)[pP]\b',
).firstMatch(title)?.group(0)?.toLowerCase();

/// 这条发布是不是整季合集（batch）。判据（保守，全部对应真实发布形态）：
/// - 显式关键词：batch / complete / 合集 / 全集；
/// - 带界定符的集数区间：`[01-12]` / `第01-12话` / `(01~24 Fin)` ——要求区间
///   由 第/括号 引导**或**以 话/集/END/Fin/完 收尾，两端 1..300 且递增，避免
///   把 `2023-08` 日期、分辨率误判成区间。
bool isLikelyBatchVideoRelease(String title) {
  if (RegExp(r'\b(batch|complete)\b', caseSensitive: false).hasMatch(title)) {
    return true;
  }
  if (title.contains('合集') || title.contains('全集')) return true;
  for (final RegExpMatch match in RegExp(
    r'(?:(?<lead>第|\[|\(|【|（)\s*)?(\d{1,3})\s*[-~〜]\s*(\d{1,3})\s*'
    r'(?<tail>话|話|集|END|Fin|完)?',
    caseSensitive: false,
  ).allMatches(title)) {
    if (match.namedGroup('lead') == null && match.namedGroup('tail') == null) {
      continue;
    }
    final int? first = int.tryParse(match.group(2)!);
    final int? last = int.tryParse(match.group(3)!);
    if (first == null || last == null) continue;
    if (first >= 1 && last <= 300 && last > first) return true;
  }
  return false;
}

/// 一张资源「版本卡」：同来源实例、同发布组、同清晰度、同 trusted 的发布集合。
class VideoResourceVersionGroup {
  VideoResourceVersionGroup._({required this.key, required this.members});

  final String key;

  /// 集号升序（认不出的殿后），同集按发布时间降序。
  final List<VideoResourceCandidate> members;

  String get providerId => members.first.providerId;
  bool get trusted => members.first.trusted;

  String? get releaseGroup => _releaseGroupOf(members.first);

  String? get resolution =>
      members.first.resolution ?? resolutionFromTitle(members.first.title);

  /// 卡标题的组成部分（缺段跳过）：组名、清晰度、来源。
  List<String> get labelParts => <String>[
    if (releaseGroup != null) releaseGroup!,
    if (resolution != null) resolution!,
    providerId,
  ];

  Set<int> get episodes => <int>{
    for (final VideoResourceCandidate member in members)
      if (episodeNumberFromReleaseTitle(member.title) != null)
        episodeNumberFromReleaseTitle(member.title)!,
  };

  int get batchCount => members
      .where(
        (VideoResourceCandidate member) =>
            isLikelyBatchVideoRelease(member.title),
      )
      .length;

  DateTime? get latestPublishedAt {
    DateTime? latest;
    for (final VideoResourceCandidate member in members) {
      final DateTime? at = member.publishedAt;
      if (at != null && (latest == null || at.isAfter(latest))) latest = at;
    }
    return latest;
  }

  int get bestSeeders => members.fold(
    0,
    (int best, VideoResourceCandidate member) =>
        member.seeders > best ? member.seeders : best,
  );

  /// 代表条：做种最多 → 最新 → 标题（全序，渲染稳定）。
  VideoResourceCandidate get representative {
    final List<VideoResourceCandidate> sorted = List<VideoResourceCandidate>.of(
      members,
    )..sort(_bySeedersDesc);
    return sorted.first;
  }
}

int _bySeedersDesc(VideoResourceCandidate a, VideoResourceCandidate b) {
  final int bySeeders = b.seeders.compareTo(a.seeders);
  if (bySeeders != 0) return bySeeders;
  final DateTime? pa = a.publishedAt;
  final DateTime? pb = b.publishedAt;
  if (pa != null && pb != null) {
    final int byDate = pb.compareTo(pa);
    if (byDate != 0) return byDate;
  } else if (pa != pb) {
    return pa == null ? 1 : -1;
  }
  return a.title.compareTo(b.title);
}

String _groupKeyOf(VideoResourceCandidate candidate) {
  final String? releaseGroup = _releaseGroupOf(candidate);
  return <String>[
    candidate.providerId,
    candidate.providerInstanceId,
    // 发布组缺失时仍允许按稳定的逐集标题模板聚合，但不能退成统一空串。
    releaseGroup?.toLowerCase() ?? _unknownReleaseFamilyKey(candidate),
    (candidate.resolution ?? resolutionFromTitle(candidate.title) ?? '')
        .toLowerCase(),
    candidate.trusted ? 'trusted' : '',
  ].join('\u001f');
}

int _byEpisodeAsc(VideoResourceCandidate a, VideoResourceCandidate b) {
  final int episodeA = episodeNumberFromReleaseTitle(a.title) ?? (1 << 30);
  final int episodeB = episodeNumberFromReleaseTitle(b.title) ?? (1 << 30);
  if (episodeA != episodeB) return episodeA.compareTo(episodeB);
  return _bySeedersDesc(a, b);
}

/// 聚类 + 排序。组间：**输入相关度次序**（组内最靠前那条的名次）→ 最高做种数降序
/// → 最新发布降序 → key（稳定）。
///
/// 相关度必须是主键，不能上来就按做种数排：`VideoResourceRegistry` 在返回前专门跑过
/// `rankVideoResourcesByRelevance`（按季号/标题贴合度），它存在的全部理由就是
/// 「Nyaa 只做模糊词匹配，搜 "xxx 2" 会被做种更多的 S1/S3 压在前面」。组间再按做种数
/// 重排等于把那个已修的 bug 原样放回主路径——用户搜第二季，第一季的版本卡回到第一位。
/// 做种数退为**同等相关度内**的次级信号。
List<VideoResourceVersionGroup> buildVideoResourceVersionGroups(
  Iterable<VideoResourceCandidate> candidates,
) {
  final Map<String, List<VideoResourceCandidate>> byKey =
      <String, List<VideoResourceCandidate>>{};
  // 输入次序 = 上游给的相关度名次；记下每组里最靠前的那个名次。
  final Map<String, int> bestRank = <String, int>{};
  int rank = 0;
  for (final VideoResourceCandidate candidate in candidates) {
    final String key = _groupKeyOf(candidate);
    byKey.putIfAbsent(key, () => <VideoResourceCandidate>[]).add(candidate);
    final int? seen = bestRank[key];
    if (seen == null || rank < seen) bestRank[key] = rank;
    rank++;
  }
  final List<VideoResourceVersionGroup> groups = <VideoResourceVersionGroup>[
    for (final MapEntry<String, List<VideoResourceCandidate>> entry
        in byKey.entries)
      VideoResourceVersionGroup._(
        key: entry.key,
        members: List<VideoResourceCandidate>.unmodifiable(
          entry.value..sort(_byEpisodeAsc),
        ),
      ),
  ];
  groups.sort((VideoResourceVersionGroup a, VideoResourceVersionGroup b) {
    final int byRank = (bestRank[a.key] ?? 1 << 30).compareTo(
      bestRank[b.key] ?? 1 << 30,
    );
    if (byRank != 0) return byRank;
    final int bySeeders = b.bestSeeders.compareTo(a.bestSeeders);
    if (bySeeders != 0) return bySeeders;
    final DateTime? pa = a.latestPublishedAt;
    final DateTime? pb = b.latestPublishedAt;
    if (pa != null && pb != null) {
      final int byDate = pb.compareTo(pa);
      if (byDate != 0) return byDate;
    } else if (pa != pb) {
      return pa == null ? 1 : -1;
    }
    return a.key.compareTo(b.key);
  });
  return List<VideoResourceVersionGroup>.unmodifiable(groups);
}

/// 从版本卡解析「用户要的那一集」：
/// - [episode] 非空：集号精确命中 → 该发布（同集多条取代表序最优）；否则 null；
/// - [episode] 为空：组里恰 1 条 → 它；否则 null（UI 展开手选）。
VideoResourceCandidate? pickResourceVersionCandidate(
  VideoResourceVersionGroup group, {
  int? episode,
}) {
  if (episode != null) {
    final List<VideoResourceCandidate> hits =
        group.members
            .where(
              (VideoResourceCandidate member) =>
                  episodeNumberFromReleaseTitle(member.title) == episode,
            )
            .toList()
          ..sort(_bySeedersDesc);
    return hits.isEmpty ? null : hits.first;
  }
  return group.members.length == 1 ? group.members.single : null;
}
