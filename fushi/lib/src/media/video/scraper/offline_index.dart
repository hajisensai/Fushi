/// anime-offline-database 离线别名库索引（刮削流水线第④层的零网络数据源）。
///
/// 数据源：manami-project/anime-offline-database minified JSON，顶层
/// `{"data": [{"sources": [...], "title": "...", "synonyms": [...],
///   "type": "TV|MOVIE|OVA|SPECIAL|ONA|UNKNOWN", "episodes": 12,
///   "animeSeason": {"season": "SPRING", "year": 2026},
///   "picture": "https://...", "thumbnail": "https://..."}]}`。
///
/// 使用方式：首次用 [OfflineIndex.parseDatabaseJson]（纯函数，可放
/// compute/isolate）把全库解析成 slim 记录，[OfflineIndex.encodeSlim]
/// 落盘缓存；之后 [OfflineIndex.decodeSlim] 秒开，构造 [OfflineIndex]
/// 内建倒排索引后 [OfflineIndex.search] 查询。
library;

import 'dart:convert';

import 'package:fushi/src/media/video/scraper/scraper_types.dart';
import 'package:fushi/src/media/video/scraper/title_normalizer.dart';

/// slim 记录版本号（slim 缓存格式变更时递增，旧缓存解码失败即重建）。
const int _kSlimFormatVersion = 1;

/// 倒排索引候选池上限：命中 token 数排序后最多细算这么多条，
/// 避免全库线性 similarity（全库几万条时单次 search 控制在 <50ms 量级）。
const int _kCandidatePoolLimit = 400;

/// 离线库 slim 记录（只保留匹配与展示所需字段）。
class OfflineAnimeRecord {
  const OfflineAnimeRecord({
    required this.title,
    this.synonyms = const <String>[],
    this.type = ScrapeEntryType.unknown,
    this.episodes,
    this.year,
    required this.picture,
    required this.sourceId,
  });

  /// 主标题（库内原文，多为罗马字）。
  final String title;

  /// 别名（各语言标题，中文别名常在这里）。
  final List<String> synonyms;

  /// 条目类型（ONA 契约无对应值，映射为 [ScrapeEntryType.tv]，见 `_parseType`）。
  final ScrapeEntryType type;

  /// 总集数（>0 时有效）。
  final int? episodes;

  /// 年份（取 animeSeason.year）。
  final int? year;

  /// 海报图 URL（解析时已跳过无 picture 条目，恒非空）。
  final String picture;

  /// sources 首个 URL 去掉协议头后的可读 id（如
  /// `myanimelist.net/anime/39535`）；无 sources 时退化为标题本身。
  final String sourceId;
}

/// 离线别名库倒排索引。
class OfflineIndex {
  /// 构造时对每条记录的 title+synonyms 归一化并建 token → 记录集 倒排。
  OfflineIndex(this._records) {
    for (int i = 0; i < _records.length; i++) {
      final OfflineAnimeRecord record = _records[i];
      final Set<String> recordTokens = <String>{};
      for (final String name in <String>[record.title, ...record.synonyms]) {
        recordTokens.addAll(TitleNormalizer.tokens(
          TitleNormalizer.normalize(name),
        ));
      }
      for (final String token in recordTokens) {
        (_inverted[token] ??= <int>[]).add(i);
      }
    }
  }

  final List<OfflineAnimeRecord> _records;
  final Map<String, List<int>> _inverted = <String, List<int>>{};

  /// 已索引记录数（测试/诊断用）。
  int get recordCount => _records.length;

  /// 解析完整库 JSON 为 slim 记录列表。纯函数，可被 compute/isolate 调用。
  ///
  /// 容忍缺字段：无 title / 无 picture 的条目跳过（没有海报就没有刮削价值），
  /// 其余字段缺失按 null/默认处理；顶层结构不对抛 [FormatException]。
  static List<OfflineAnimeRecord> parseDatabaseJson(String jsonText) {
    final Object? decoded = json.decode(jsonText);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('offline db: top-level is not an object');
    }
    final Object? data = decoded['data'];
    if (data is! List<Object?>) {
      throw const FormatException('offline db: missing "data" array');
    }
    final List<OfflineAnimeRecord> records = <OfflineAnimeRecord>[];
    for (final Object? item in data) {
      if (item is! Map<String, Object?>) {
        continue;
      }
      final Object? title = item['title'];
      final Object? picture = item['picture'];
      if (title is! String || title.isEmpty) {
        continue;
      }
      if (picture is! String || picture.isEmpty) {
        continue; // 无海报条目对刮削无用，跳过。
      }
      final Object? synonymsRaw = item['synonyms'];
      final List<String> synonyms = synonymsRaw is List<Object?>
          ? synonymsRaw.whereType<String>().toList(growable: false)
          : const <String>[];
      final Object? episodesRaw = item['episodes'];
      final int? episodes =
          episodesRaw is int && episodesRaw > 0 ? episodesRaw : null;
      final Object? seasonRaw = item['animeSeason'];
      final Object? yearRaw =
          seasonRaw is Map<String, Object?> ? seasonRaw['year'] : null;
      final int? year = yearRaw is int && yearRaw > 0 ? yearRaw : null;
      final Object? sourcesRaw = item['sources'];
      final String? firstSource = sourcesRaw is List<Object?>
          ? sourcesRaw.whereType<String>().cast<String?>().firstWhere(
                (String? s) => s != null && s.isNotEmpty,
                orElse: () => null,
              )
          : null;
      records.add(OfflineAnimeRecord(
        title: title,
        synonyms: synonyms,
        type: _parseType(item['type']),
        episodes: episodes,
        year: year,
        picture: picture,
        sourceId: firstSource != null ? _stripScheme(firstSource) : title,
      ));
    }
    return records;
  }

  /// slim 缓存序列化（紧凑数组形式，避免重复键名膨胀体积）。
  static String encodeSlim(List<OfflineAnimeRecord> records) {
    return json.encode(<String, Object?>{
      'v': _kSlimFormatVersion,
      'd': <Object?>[
        for (final OfflineAnimeRecord r in records)
          <Object?>[
            r.title,
            r.synonyms,
            r.type.name,
            r.episodes,
            r.year,
            r.picture,
            r.sourceId,
          ],
      ],
    });
  }

  /// slim 缓存反序列化；版本或结构不符抛 [FormatException]（调用方重建缓存）。
  static List<OfflineAnimeRecord> decodeSlim(String slimText) {
    final Object? decoded = json.decode(slimText);
    if (decoded is! Map<String, Object?> ||
        decoded['v'] != _kSlimFormatVersion ||
        decoded['d'] is! List<Object?>) {
      throw const FormatException('offline db slim cache: bad format');
    }
    final List<OfflineAnimeRecord> records = <OfflineAnimeRecord>[];
    for (final Object? row in decoded['d']! as List<Object?>) {
      if (row is! List<Object?> || row.length != 7) {
        throw const FormatException('offline db slim cache: bad row');
      }
      final Object? title = row[0];
      final Object? synonyms = row[1];
      final Object? typeName = row[2];
      final Object? episodes = row[3];
      final Object? year = row[4];
      final Object? picture = row[5];
      final Object? sourceId = row[6];
      if (title is! String || picture is! String || sourceId is! String) {
        throw const FormatException('offline db slim cache: bad row field');
      }
      records.add(OfflineAnimeRecord(
        title: title,
        synonyms: synonyms is List<Object?>
            ? synonyms.whereType<String>().toList(growable: false)
            : const <String>[],
        type: typeName is String
            ? ScrapeEntryType.values.asNameMap()[typeName] ??
                ScrapeEntryType.unknown
            : ScrapeEntryType.unknown,
        episodes: episodes is int ? episodes : null,
        year: year is int ? year : null,
        picture: picture,
        sourceId: sourceId,
      ));
    }
    return records;
  }

  /// 查询：归一化 → 倒排取候选池（按命中 token 数取前
  /// [_kCandidatePoolLimit] 条）→ 对候选池按 title 与全部 synonyms 的
  /// 最大 [TitleNormalizer.similarity] 排序 → 转 [ScrapeCandidate]。
  List<ScrapeCandidate> search(String rawTitle, {int limit = 8}) {
    final String normalized = TitleNormalizer.normalize(rawTitle);
    if (normalized.isEmpty || limit <= 0) {
      return const <ScrapeCandidate>[];
    }
    final List<String> queryTokens = TitleNormalizer.tokens(normalized);
    // 命中计数：token 命中越多越可能相关。
    final Map<int, int> hitCounts = <int, int>{};
    for (final String token in queryTokens.toSet()) {
      final List<int>? postings = _inverted[token];
      if (postings == null) {
        continue;
      }
      for (final int recordIndex in postings) {
        hitCounts[recordIndex] = (hitCounts[recordIndex] ?? 0) + 1;
      }
    }
    if (hitCounts.isEmpty) {
      return const <ScrapeCandidate>[];
    }
    final List<int> pool = hitCounts.keys.toList()
      ..sort((int a, int b) => hitCounts[b]!.compareTo(hitCounts[a]!));
    final List<int> limitedPool = pool.length > _kCandidatePoolLimit
        ? pool.sublist(0, _kCandidatePoolLimit)
        : pool;
    // 细算相似度并排序。主键 = title+synonyms 的最大相似度；打平时 tiebreaker = 主
    // 标题本身的相似度：借来的别名蹭分的联动/CM（如「Suntory×君の名は」CM 把「君の名は」
    // 塞进 synonyms）主标题与查询几乎无关，应排到「真名直接命中」的正片之后（BUG-1080）。
    final List<(int, double, double)> scored = <(int, double, double)>[
      for (final int recordIndex in limitedPool)
        (
          recordIndex,
          _bestSimilarity(rawTitle, _records[recordIndex]),
          TitleNormalizer.similarity(rawTitle, _records[recordIndex].title),
        ),
    ]..sort(((int, double, double) a, (int, double, double) b) {
        final int byBest = b.$2.compareTo(a.$2);
        return byBest != 0 ? byBest : b.$3.compareTo(a.$3);
      });
    return <ScrapeCandidate>[
      for (final (int recordIndex, double _, double _) in scored.take(limit))
        _toCandidate(recordIndex, _records[recordIndex]),
    ];
  }

  /// 查询串对一条记录 title+synonyms 的最大相似度。
  static double _bestSimilarity(String query, OfflineAnimeRecord record) {
    double best = TitleNormalizer.similarity(query, record.title);
    for (final String synonym in record.synonyms) {
      if (best >= 1.0) {
        break;
      }
      final double s = TitleNormalizer.similarity(query, synonym);
      if (s > best) {
        best = s;
      }
    }
    return best;
  }

  /// slim 记录 → 契约候选。
  static ScrapeCandidate _toCandidate(
    int recordIndex,
    OfflineAnimeRecord record,
  ) {
    return ScrapeCandidate(
      source: ScrapeSource.offlineDb,
      entryId: record.sourceId,
      title: record.title,
      aliases: record.synonyms,
      year: record.year,
      type: record.type,
      episodeCount: record.episodes,
      posterUrl: record.picture,
      // sourceId 来自 URL 时补回协议头作为详情页链接。
      detailUrl:
          record.sourceId.contains('/') ? 'https://${record.sourceId}' : null,
    );
  }

  /// 库内 type 字符串 → 契约枚举。
  /// ONA（网络连载）在契约中无对应值，按剧集形态归入 tv，
  /// 保证与 isMovieHint 互验时语义正确。
  static ScrapeEntryType _parseType(Object? raw) {
    switch (raw is String ? raw.toUpperCase() : '') {
      case 'TV':
      case 'ONA':
        return ScrapeEntryType.tv;
      case 'MOVIE':
        return ScrapeEntryType.movie;
      case 'OVA':
        return ScrapeEntryType.ova;
      case 'SPECIAL':
        return ScrapeEntryType.special;
      default:
        return ScrapeEntryType.unknown;
    }
  }

  /// 去掉 URL 协议头，保留可读主体。
  static String _stripScheme(String url) {
    return url.replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), '');
  }
}
