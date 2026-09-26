/// 在线字幕检索「这是第几季」的提示，以及按它从 AniList 候选里挑系列。
///
/// 存在的理由是一个真实故障：AniList 把同一作品的每一季登记成**独立条目**
/// （《Re:Zero》第一季 21355、第四季 189046），Jimaku 也按季各开一个条目并挂各自的
/// `anilist_id`。而 AniList 搜索按相关度排序，番名一样时首条恒为第一季；字幕面板此前
/// 无条件取首条，于是看第四季第 18 集也按第一季的 id 去查 Jimaku，第四季条目里明明
/// 就有 `S04E18` 的字幕却一次都没被问到。视频自身的季号（文件名 `S04E18`、合集名
/// 「… 4th season」）从来没参与选系列。
library;

import 'package:fushi/src/media/video/anilist_client.dart';
import 'package:fushi_engine/media/video/season_marker_parser.dart';
import 'package:fushi_engine/media/video/video_filename_parser.dart';

/// 汇总季号提示。纯函数。
///
/// [parsedSeason] 是文件名/远端标题解析出的季号（最可靠，直接胜出）；否则依次在
/// [titles]（查询词、刮削名、显示名、合集名……）里找**唯一**的季度记号，第一个给出
/// 唯一记号的标题胜出。标题里同时出现多个季号（如「2nd Season Part 3」这类混写）时
/// 不猜，继续看下一个。都没有 → null（调用方保持原行为：取相关度首条）。
int? subtitleSeasonHint({
  int? parsedSeason,
  Iterable<String?> titles = const <String?>[],
}) {
  if (parsedSeason != null && parsedSeason > 0) return parsedSeason;
  for (final String? title in titles) {
    final String text = title?.trim() ?? '';
    if (text.isEmpty) continue;
    final Set<int> seasons = detectVideoSeasonsInText(text);
    if (seasons.length == 1) return seasons.single;
  }
  return null;
}

/// 从文件名（或带 `S04E18` 的远端标题）解析季号；解析不出 null。纯函数。
int? subtitleSeasonFromName(String? name) {
  final String text = name?.trim() ?? '';
  if (text.isEmpty) return null;
  final int? season = parseVideoFilename(text).season;
  return season != null && season > 0 ? season : null;
}

/// 按季号从 AniList 候选里挑本次检索用的系列。纯函数。
///
/// - [season] 为 null 或候选为空：返回首条（相关度最高，= 旧行为）；空列表返回 null。
/// - [season] ≥ 2：取标题（romaji / english / native）季度记号**恰好**是该季的第一条
///   （同季分上下半时先取不带 Part / cour 记号的那条）；
///   没有恰好的就取记号里**含**该季的第一条（「2nd Season Part 2」这类）；都没有
///   （续作改了名、不带季号）回退首条——宁可维持旧行为，也不拿不相干的条目冒充。
/// - [season] == 1：取第一条**不带其它季号**的候选（第一季在 AniList 上通常不写
///   「1st Season」），避免相关度排序偶尔把续作排到前面。
AniListMedia? pickAniListSeriesForSeason(
  List<AniListMedia> matches, {
  required int? season,
}) {
  if (matches.isEmpty) return null;
  if (season == null || season <= 0) return matches.first;
  final List<Set<int>> seasons = <Set<int>>[
    for (final AniListMedia media in matches) _seasonsOf(media),
  ];
  if (season == 1) {
    for (int i = 0; i < matches.length; i++) {
      if (seasons[i].isEmpty ||
          (seasons[i].length == 1 && seasons[i].single == 1)) {
        return matches[i];
      }
    }
    return matches.first;
  }
  // 同一季分上下半（「2nd Season」与「2nd Season Part 2」记号都是 2）时先取不带
  // 分段记号的那条；集号怎么落到后半由 Jimaku 条目自己的文件决定，不在这里猜。
  for (final bool allowSplit in const <bool>[false, true]) {
    for (int i = 0; i < matches.length; i++) {
      if (!allowSplit && _isSplitCour(matches[i])) continue;
      if (seasons[i].length == 1 && seasons[i].single == season) {
        return matches[i];
      }
    }
  }
  for (int i = 0; i < matches.length; i++) {
    if (seasons[i].contains(season)) return matches[i];
  }
  return matches.first;
}

final RegExp _splitCourMarker = RegExp(
  r'\b(?:part|cour)\s*[0-9]+'
  r'|[0-9]+(?:st|nd|rd|th)\s+cour'
  r'|第\s*[0-9一二三四五六七八九十]+\s*クール',
  caseSensitive: false,
);

bool _isSplitCour(AniListMedia media) => <String?>[
  media.romaji,
  media.english,
  media.native,
].any((String? title) => title != null && _splitCourMarker.hasMatch(title));

Set<int> _seasonsOf(AniListMedia media) {
  final Set<int> out = <int>{};
  for (final String? title in <String?>[
    media.romaji,
    media.english,
    media.native,
  ]) {
    final String text = title?.trim() ?? '';
    if (text.isEmpty) continue;
    out.addAll(detectVideoSeasonsInText(text));
  }
  return out;
}
