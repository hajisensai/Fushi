import 'dart:convert';

import 'package:http/http.dart' as http;

/// AniList 媒体（番剧）搜索结果的最小模型。
class AniListMedia {
  const AniListMedia({
    required this.id,
    this.romaji,
    this.english,
    this.native,
    this.coverUrl,
    this.episodes,
    this.seasonYear,
  });

  /// AniList 媒体 id（用于到 Jimaku 按 anilist_id 查字幕）。
  final int id;
  final String? romaji;
  final String? english;
  final String? native;

  /// 封面图 URL（`coverImage.large`）；旧响应/缺字段为 null。
  final String? coverUrl;

  /// 总集数（连载中/未知为 null）。
  final int? episodes;

  /// 放送年份（未知为 null），搜番消歧显示用。
  final int? seasonYear;

  /// 菜单显示用标题：优先罗马字 → 英文 → 日文 → id。
  String get displayTitle => (romaji?.isNotEmpty ?? false)
      ? romaji!
      : (english?.isNotEmpty ?? false)
          ? english!
          : (native?.isNotEmpty ?? false)
              ? native!
              : 'AniList #$id';
}

/// 罗马字长音符（macron）→ **双元音** 展开（修正 Hepburn）。番剧官方 romaji
/// 常用 macron 转写（ū ō ā ī ē，如「Chūnibyō」），但 AniList 的 search 索引
/// 用双元音拼法（如「Chuunibyou」）且**不做 macron 归一化匹配**——用户直接
/// 打/复制带 macron 的标题会 0 结果。
///
/// 实测（live AniList）：`Chūnibyō Demo Koi ga Shitai!` → 0；简单去 macron 的
/// `Chunibyo Demo…`（单元音）→ 仍 0（太短）；双元音 `Chuunibyou Demo…` → 命中。
/// 故按修正 Hepburn 展开长音：ā→aa ī→ii ū→uu ē→ee ō→ou（ō 取最常见的 おう；
/// 少数 おお 词靠 AniList 模糊匹配兜底）。
const Map<int, String> _macronExpand = <int, String>{
  0x0100: 'Aa', 0x0101: 'aa', // Ā ā
  0x0112: 'Ee', 0x0113: 'ee', // Ē ē
  0x012A: 'Ii', 0x012B: 'ii', // Ī ī
  0x014C: 'Ou', 0x014D: 'ou', // Ō ō
  0x016A: 'Uu', 0x016B: 'uu', // Ū ū
};

/// 归一化搜索关键词：把 macron 长音符展开成双元音，让带官方 romaji 长音的
/// 输入也能命中 AniList。预组合字母（ū…）按 [_macronExpand] 展开；分解形式的
/// combining macron U+0304 把前一个元音再写一遍（双写）。纯函数：无 macron 的
/// 输入原样返回（no-op），不会降低正常命中。
String normalizeAniListSearch(String query) {
  final StringBuffer sb = StringBuffer();
  int? prevRune; // 供 combining macron 双写前一元音
  for (final int rune in query.runes) {
    if (rune == 0x0304) {
      // combining macron：分解形式（如 'u' + U+0304）→ 双写前一个字母。
      if (prevRune != null) sb.writeCharCode(prevRune);
      continue;
    }
    final String? expanded = _macronExpand[rune];
    if (expanded != null) {
      sb.write(expanded);
      prevRune = null;
    } else {
      sb.writeCharCode(rune);
      prevRune = rune;
    }
  }
  return sb.toString();
}

/// 解析 AniList GraphQL 搜索响应为 [AniListMedia] 列表。纯函数，容错（结构不符 →
/// 空列表），便于单测。
List<AniListMedia> parseAniListSearchResponse(String body) {
  try {
    final dynamic json = jsonDecode(body);
    if (json is! Map) return const <AniListMedia>[];
    final dynamic data = json['data'];
    if (data is! Map) return const <AniListMedia>[];
    final dynamic page = data['Page'];
    if (page is! Map) return const <AniListMedia>[];
    final dynamic media = page['media'];
    if (media is! List) return const <AniListMedia>[];
    final List<AniListMedia> out = <AniListMedia>[];
    for (final dynamic m in media) {
      if (m is! Map) continue;
      final dynamic id = m['id'];
      if (id is! int) continue;
      final dynamic title = m['title'];
      final dynamic cover = m['coverImage'];
      out.add(AniListMedia(
        id: id,
        romaji: title is Map ? title['romaji'] as String? : null,
        english: title is Map ? title['english'] as String? : null,
        native: title is Map ? title['native'] as String? : null,
        coverUrl: cover is Map ? cover['large'] as String? : null,
        episodes: m['episodes'] is int ? m['episodes'] as int : null,
        seasonYear: m['seasonYear'] is int ? m['seasonYear'] as int : null,
      ));
    }
    return out;
  } catch (_) {
    return const <AniListMedia>[];
  }
}

/// AniList GraphQL 客户端：按标题搜番拿 anilist id（Jimaku 按 anilist_id 查字幕的前置）。
class AniListClient {
  AniListClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const String _endpoint = 'https://graphql.anilist.co';
  static const String _searchQuery = r'''
query ($search: String) {
  Page(perPage: 10) {
    media(search: $search, type: ANIME) {
      id
      title { romaji english native }
      coverImage { large }
      episodes
      seasonYear
    }
  }
}''';

  /// 按 [title] 搜索番剧。网络/解析失败返回空列表（不抛，调用方按空处理）。
  /// 搜索词先做 macron 归一化（见 [normalizeAniListSearch]），让带官方 romaji
  /// 长音（ū ō…）的输入也能命中 AniList。
  Future<List<AniListMedia>> searchAnime(String title) async {
    final String query = normalizeAniListSearch(title.trim());
    if (query.isEmpty) return const <AniListMedia>[];
    try {
      final http.Response res = await _client.post(
        Uri.parse(_endpoint),
        headers: const <String, String>{
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode(<String, dynamic>{
          'query': _searchQuery,
          'variables': <String, dynamic>{'search': query},
        }),
      );
      if (res.statusCode != 200) return const <AniListMedia>[];
      return parseAniListSearchResponse(res.body);
    } catch (_) {
      return const <AniListMedia>[];
    }
  }

  void close() => _client.close();
}
