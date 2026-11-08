/// 资源搜索结果的相关度排序：先按「是不是用户要的那一季」，再按标题贴合度，
/// 最后才是做种数。
///
/// 为什么需要这一层：Nyaa 只做站内模糊词匹配，搜 `Hibike! Euphonium 2` 会把 S1、
/// S3、剧场版、Ensemble Contest OVA 一起返回；而唯一的排序
/// [deduplicateVideoResources] 是 providerPriority → seeders 降序，老季种子做种多，
/// 必然压在正确季前面。这里复用刮削侧同一套识别件（[FilenameParser] +
/// [TitleNormalizer]）把每条结果的「标题 + 季号」解析出来再排 —— 识别与查询分离，
/// 和资料刮削链路是同一个思路。
library;

import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/season_marker_parser.dart';
import 'package:fushi_engine/media/video/scraper/filename_parser.dart';
import 'package:fushi_engine/media/video/scraper/scraper_types.dart';
import 'package:fushi_engine/media/video/scraper/title_normalizer.dart';

/// 从一条发布标题（或用户查询词）里读出的身份。
class VideoResourceTitleIdentity {
  const VideoResourceTitleIdentity({
    required this.titles,
    required this.season,
  });

  /// 归一化后的**基础**标题集合（季号后缀已剥掉）。一条发布常把中/日/英三种
  /// 写法用 `/` 或 `|` 并列，全部收进来，任一命中即算标题贴合。
  final Set<String> titles;

  /// 解析出的季号；解析不出时为 null（未知，不等于第一季）。
  final int? season;
}

/// 番剧圈的季号有两种写法：`S3` / `Season 3`（[FilenameParser] 已认）与
/// 直接跟在标题后的裸数字 `Hibike! Euphonium 2`（[FilenameParser] **有意**保留在
/// 标题里，不能去动它——刮削侧靠完整标题去搜作品）。这里只在排序用途上补认后者。
final RegExp _trailingSeason = RegExp(r'^(.*?)[\s]+(\d{1,2})$');

/// 拆并列标题用的分隔符：`/`（VCB/DBD 风格）与 `|`（Okay-Subs 风格）。
final RegExp _titleSeparators = RegExp(r'[/|]');

VideoResourceTitleIdentity parseVideoResourceIdentity(String raw) {
  final ParsedMediaName parsed = FilenameParser.parse(raw);
  final Set<String> titles = <String>{};
  final Set<int> trailingSeasons = <int>{};
  for (final String segment in <String>[
    parsed.title,
    if (parsed.secondaryTitle != null) parsed.secondaryTitle!,
  ].expand((String value) => value.split(_titleSeparators))) {
    final String normalized = TitleNormalizer.normalize(segment);
    if (normalized.isEmpty) continue;
    final RegExpMatch? match = _trailingSeason.firstMatch(normalized);
    if (match == null) {
      titles.add(normalized);
      continue;
    }
    final String base = match.group(1)!.trim();
    final int number = int.parse(match.group(2)!);
    if (base.isEmpty) {
      titles.add(normalized);
      continue;
    }
    titles.add(base);
    trailingSeasons.add(number);
  }
  // [FilenameParser] 按位置剥括号块，`(Season 3)` / `[S3]` 这类整块会被当噪音丢
  // 掉；[detectVideoSeasonsInText] 是归一化后全串扫描，正好补上这一半。
  final Set<int> markedSeasons = detectVideoSeasonsInText(raw);
  return VideoResourceTitleIdentity(
    titles: titles,
    // 优先级：位置化解析 → 全串季号记号 → 并列标题一致的裸数字。后两者都只在
    // **唯一**时才敢认，避免 "S1+S2 合集" 这种被随便挑一个。
    season:
        parsed.season ??
        (markedSeasons.length == 1 ? markedSeasons.single : null) ??
        (trailingSeasons.length == 1 ? trailingSeasons.single : null),
  );
}

/// 季号契合度：2 = 正是这一季，1 = 该条没写季号（未知，不惩罚），0 = 明确是别的季。
int _seasonRank(int? querySeason, int? candidateSeason) {
  if (querySeason == null) return 1;
  if (candidateSeason == null) return 1;
  return candidateSeason == querySeason ? 2 : 0;
}

/// 标题贴合度：基础标题完全相同记 1.0，否则取两两归一化相似度的最大值。
double _titleScore(
  VideoResourceTitleIdentity query,
  VideoResourceTitleIdentity candidate,
) {
  if (query.titles.isEmpty || candidate.titles.isEmpty) return 0;
  double best = 0;
  for (final String want in query.titles) {
    for (final String got in candidate.titles) {
      if (want == got) return 1;
      final double similarity = TitleNormalizer.similarity(want, got);
      if (similarity > best) best = similarity;
    }
  }
  return best;
}

/// 按相关度重排搜索结果。**只重排、不丢弃**——错季的仍然可选，只是沉到底部，
/// 免得把用户真正想要的合集/特典误杀（Nyaa 的命名太脏，过滤会误伤）。
///
/// [query] 是用户实际提交的搜索词；[season] 是调用方已知的季号（订阅链路会传），
/// 传 null 时从 [query] 自己解析。
///
/// [workTitles] 是目标作品的全部已知标题（主标题 / 原名 / 别名）。一部作品在发布
/// 圈常有好几种叫法，provider 也确实拿每个叫法各查一次（BUG-2794/2818），但此前
/// 贴合度只拿 [query] 这**一个**词比：AniList 上《BanG Dream! Ave Mujica》的英文名
/// 是副标题 `Ave Mujica - The Die is Cast -`，被选作首选查询词后，标题恰好写副标题
/// 的低种逐集发布拿满分，写正式名的 BD 全集 / SubsPlease 合集反被当成「不相关」
/// 沉到十名开外（BUG-4243）。所以作品自己的任一已知标题都算贴合，同分时回到上游
/// 做种次序。季号**只**从 [season] / [query] 来——别名里的裸数字不参与，免得
/// 系列别名把错季抬上来。
List<VideoResourceCandidate> rankVideoResourcesByRelevance(
  List<VideoResourceCandidate> candidates, {
  required String query,
  int? season,
  Iterable<String> workTitles = const <String>[],
}) {
  final VideoResourceTitleIdentity parsedQuery = parseVideoResourceIdentity(
    query,
  );
  final VideoResourceTitleIdentity queryIdentity = VideoResourceTitleIdentity(
    titles: <String>{
      ...parsedQuery.titles,
      for (final String title in workTitles)
        if (title.trim().isNotEmpty)
          ...parseVideoResourceIdentity(title).titles,
    },
    season: parsedQuery.season,
  );
  final int? querySeason = season ?? queryIdentity.season;
  if (candidates.length < 2) {
    return List<VideoResourceCandidate>.unmodifiable(candidates);
  }
  final List<(VideoResourceCandidate, int, double, int)> scored =
      <(VideoResourceCandidate, int, double, int)>[];
  for (int index = 0; index < candidates.length; index++) {
    final VideoResourceCandidate candidate = candidates[index];
    final VideoResourceTitleIdentity identity = parseVideoResourceIdentity(
      candidate.title,
    );
    scored.add((
      candidate,
      _seasonRank(querySeason, identity.season),
      _titleScore(queryIdentity, identity),
      index,
    ));
  }
  scored.sort((
    (VideoResourceCandidate, int, double, int) a,
    (VideoResourceCandidate, int, double, int) b,
  ) {
    final int bySeason = b.$2.compareTo(a.$2);
    if (bySeason != 0) return bySeason;
    final int byTitle = b.$3.compareTo(a.$3);
    if (byTitle != 0) return byTitle;
    // 同档内保持上游次序（providerPriority → seeders），并且是稳定的。
    return a.$4.compareTo(b.$4);
  });
  return List<VideoResourceCandidate>.unmodifiable(
    scored.map(((VideoResourceCandidate, int, double, int) entry) => entry.$1),
  );
}
