/// 资源搜索（种子 RSS 搜索站等）的查询词生成：同一作品的多拼写查询。
///
/// 原住在已删除的内置搜索站 provider 里，行为逐字保留，只换成与站点无关的名字——种子站
/// 发布名绝大多数是罗马字 / 英文，这套规则对用户自配的任意 RSS 搜索站都成立。
library;

import 'package:fushi_engine/media/torrent/search_query_script.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';

/// 作品在种子站上的**默认**检索词：罗马字（拉丁拼写）与日文原名各取一个，都
/// 没有才退回展示标题。显式查询词原样返回（搜索框预填、订阅默认词只要一条）。
///
/// 真正发出的查询集合见 [resourceSearchQueries]——这里只是「首选词」。
List<String> preferredResourceSearchQueries(
  VideoResourceSearchRequest request,
) {
  final String explicitQuery = request.query?.trim() ?? '';
  if (explicitQuery.isNotEmpty) return <String>[explicitQuery];
  return _workQueries(request, maxRomanized: 1);
}

/// 同一作品最多查几种拉丁拼写（BUG-2818）。
///
/// 元数据排在最前的「罗马字」不一定是发布组用的写法：TMDB 的 JP 区别名可能是
/// 官方风格化写法 `FX Senshi KURUMICHAN`，发布名却一律是 `FX Senshi Kurumi-chan`
/// ——种子站把 `KURUMICHAN` 当成另一个词，0 条。只查第一个拉丁拼写 = 押宝在元数据
/// 的排序上；罗马字 / 英文名 / 主标题各查一次才不依赖它。上限是请求预算：每个
/// 站点逐词串行请求，每多一种拼写多一次往返。
const int kResourceMaxRomanizedQueries = 3;

/// 作品标题候选（别名 → 原名 → 标题 → 有效查询词，大小写不敏感去重）按书写系统
/// 分组：拉丁拼写取前 [maxRomanized] 个、日文取一个，都没有才退回其它标题一个。
List<String> _workQueries(
  VideoResourceSearchRequest request, {
  required int maxRomanized,
}) {
  final VideoMediaReference? media = request.media;
  final List<String> candidates = <String>[
    if (media != null) ...media.aliases,
    if (media?.originalTitle case final String original) original,
    if (media != null) media.title,
    request.effectiveQuery,
  ];
  final List<String> romanized = <String>[];
  final List<String> japanese = <String>[];
  final List<String> fallback = <String>[];
  final Set<String> seen = <String>{};
  for (final String candidate in candidates) {
    final String value = candidate.trim();
    final String key = value.toLowerCase();
    if (value.isEmpty || !seen.add(key)) continue;
    if (RegExp(r'[A-Za-z]').hasMatch(value) &&
        !RegExp(r'[぀-ヿ㐀-鿿]').hasMatch(value)) {
      romanized.add(value);
    } else if (RegExp(r'[぀-ヿ]').hasMatch(value) ||
        value == media?.originalTitle?.trim()) {
      japanese.add(value);
    } else {
      fallback.add(value);
    }
  }
  return <String>[
    ...romanized.take(maxRomanized),
    ...japanese.take(1),
    if (romanized.isEmpty && japanese.isEmpty) ...fallback.take(1),
  ];
}

/// 实际要发的查询词（BUG-2794）：显式词在前，作品的拼写候选作补充。
///
/// 旧契约是「有显式词就只搜显式词」。可资源页会把首选词**预填**进搜索框，于是
/// 预填词一律变成显式词：TMDB 卡片没有罗马字别名时预填的是日文原名
/// `葬送のフリーレン`，种子站回 0 条（同一作品 `Frieren` 有 75 条），而作品自己的
/// 罗马字 / 日文拼写再也没机会被查——别名被显式词覆盖了。
///
/// 现在显式词只是候选之一。补查作品拼写的条件：
/// * 显式词本身就是这部作品的某个已知标题（标题 / 原名 / 别名，含预填词）——
///   同一作品的另一种拼写，补查不会搜到别的作品；
/// * 或显式词里没有拉丁词（种子站发布名绝大多数是罗马字 / 英文，纯 CJK 词命中率
///   极低）。
/// 用户手输的拉丁词（`Frieren S2 1080p`）是在收窄，不补查，免得把收窄冲掉。
/// 没有作品身份（纯关键词搜索）时只有显式词可查。
///
/// 作品拼写查全部不同的拉丁拼写（至多 [kResourceMaxRomanizedQueries] 个）加日文
/// 原名，不像 [preferredResourceSearchQueries] 那样只各取一个（BUG-2818）。
List<String> resourceSearchQueries(VideoResourceSearchRequest request) {
  final String explicit = request.query?.trim() ?? '';
  final VideoMediaReference? media = request.media;
  if (explicit.isEmpty) {
    return _workQueries(request, maxRomanized: kResourceMaxRomanizedQueries);
  }
  if (media == null) return <String>[explicit];
  final String normalized = _titleKey(explicit);
  final bool knownTitle = <String?>[
    media.title,
    media.originalTitle,
    ...media.aliases,
  ].any((String? title) => title != null && _titleKey(title) == normalized);
  if (!knownTitle && isLatinScriptExpressible(explicit)) {
    return <String>[explicit];
  }
  final Set<String> seen = <String>{normalized};
  return <String>[
    explicit,
    for (final String candidate in _workQueries(
      VideoResourceSearchRequest(media: media),
      maxRomanized: kResourceMaxRomanizedQueries,
    ))
      if (seen.add(_titleKey(candidate))) candidate,
  ];
}

String _titleKey(String value) => foldFullWidthAscii(
  value,
).trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
