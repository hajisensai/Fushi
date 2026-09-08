/// erengy/anime-relations 的 `anime-relations.txt` 解析与集号重定向。
///
/// 规则语义照 Taiga `recognition_relations.cpp`：三列 id 为 MAL|Kitsu|AniList，
/// 这里只用 MAL 列；`?` 为未知 id（MAL 列未知的规则整条丢弃）；`~` 复用同一行
/// 源侧对应列；集区间 `a-b`，`b` 为 `?` 表示开区间；单点 `a` 等价 `a-a`；`!`
/// 追加一条目标 id 自映射规则，用于文件名本身就是续作连番的情况。
library;

import 'dart:async';
import 'dart:convert';

import 'package:fushi/src/media/video/metadata/video_metadata_transport.dart';

/// 一条集号重定向规则：`fromMalId:[fromStart-fromEnd] -> toMalId:[toStart-toEnd]`。
/// `fromEnd` / `toEnd` 为 null 表示开区间（上界无限）。
class AnimeEpisodeRedirect {
  const AnimeEpisodeRedirect({
    required this.fromMalId,
    required this.toMalId,
    required this.fromStart,
    required this.toStart,
    required this.fromEnd,
    required this.toEnd,
  });

  final int fromMalId;
  final int toMalId;
  final int fromStart;
  final int toStart;
  final int? fromEnd;
  final int? toEnd;

  bool contains(int episode) {
    final int? end = fromEnd;
    return episode >= fromStart && (end == null || episode <= end);
  }

  /// 目标区间是单点时不加偏移（`1-4 -> 1` 全部落到 1），否则按源起点偏移。
  int destinationEpisode(int episode) {
    if (toEnd == toStart) return toStart;
    return toStart + (episode - fromStart);
  }

  @override
  String toString() =>
      'AnimeEpisodeRedirect($fromMalId:$fromStart-${fromEnd ?? '?'} -> '
      '$toMalId:$toStart-${toEnd ?? '?'})';
}

class AnimeEpisodeRedirection {
  const AnimeEpisodeRedirection({required this.malId, required this.episode});

  final int malId;
  final int episode;

  @override
  bool operator ==(Object other) =>
      other is AnimeEpisodeRedirection &&
      other.malId == malId &&
      other.episode == episode;

  @override
  int get hashCode => Object.hash(malId, episode);

  @override
  String toString() => 'AnimeEpisodeRedirection($malId:$episode)';
}

class AnimeEpisodeRelations {
  const AnimeEpisodeRelations._(this._rulesByMalId, this.ruleCount);

  static const AnimeEpisodeRelations empty =
      AnimeEpisodeRelations._(<int, List<AnimeEpisodeRedirect>>{}, 0);

  final Map<int, List<AnimeEpisodeRedirect>> _rulesByMalId;
  final int ruleCount;

  static AnimeEpisodeRelations parse(String text) {
    final Map<int, List<AnimeEpisodeRedirect>> rules =
        <int, List<AnimeEpisodeRedirect>>{};
    int count = 0;
    bool inMeta = false;
    for (final String rawLine in const LineSplitter().convert(text)) {
      final String line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.startsWith('::')) {
        inMeta = line == '::meta';
        continue;
      }
      if (inMeta || !line.startsWith('-')) continue;
      for (final AnimeEpisodeRedirect rule in _parseRule(line.substring(1))) {
        (rules[rule.fromMalId] ??= <AnimeEpisodeRedirect>[]).add(rule);
        count++;
      }
    }
    return AnimeEpisodeRelations._(rules, count);
  }

  /// 解析一条规则；返回主规则与 `!` 追加的自映射规则（0~2 条）。
  static List<AnimeEpisodeRedirect> _parseRule(String body) {
    String rule = body.trim();
    final bool selfRedirect = rule.endsWith('!');
    if (selfRedirect) rule = rule.substring(0, rule.length - 1).trimRight();
    final List<String> sides = rule.split('->');
    if (sides.length != 2) return const <AnimeEpisodeRedirect>[];
    final _RuleSide? from = _RuleSide.parse(sides[0], source: null);
    if (from == null) return const <AnimeEpisodeRedirect>[];
    final _RuleSide? to = _RuleSide.parse(sides[1], source: from);
    if (to == null) return const <AnimeEpisodeRedirect>[];
    final AnimeEpisodeRedirect primary = AnimeEpisodeRedirect(
      fromMalId: from.malId,
      toMalId: to.malId,
      fromStart: from.start,
      fromEnd: from.end,
      toStart: to.start,
      toEnd: to.end,
    );
    if (!selfRedirect) return <AnimeEpisodeRedirect>[primary];
    return <AnimeEpisodeRedirect>[
      primary,
      AnimeEpisodeRedirect(
        fromMalId: to.malId,
        toMalId: to.malId,
        fromStart: to.start,
        fromEnd: to.end,
        toStart: to.start,
        toEnd: to.end,
      ),
    ];
  }

  /// 把 (malId, episode) 重定向到 (目标 malId, 目标集号)。无规则命中返回 null；
  /// 多条规则命中且结果不同（歧义）返回 null——与 Sonarr/Taiga 一致，歧义即放弃。
  AnimeEpisodeRedirection? redirect(
      {required int malId, required int episode}) {
    if (episode < 0) return null;
    final List<AnimeEpisodeRedirect>? rules = _rulesByMalId[malId];
    if (rules == null) return null;
    AnimeEpisodeRedirection? result;
    for (final AnimeEpisodeRedirect rule in rules) {
      if (!rule.contains(episode)) continue;
      final AnimeEpisodeRedirection candidate = AnimeEpisodeRedirection(
        malId: rule.toMalId,
        episode: rule.destinationEpisode(episode),
      );
      if (result == null) {
        result = candidate;
      } else if (result != candidate) {
        return null;
      }
    }
    return result;
  }

  /// 区间重定向：两端都必须命中且落到同一目标 id，否则 null
  /// （Taiga `SearchEpisodeRedirection`）。
  ({AnimeEpisodeRedirection start, AnimeEpisodeRedirection end})?
      redirectRange({
    required int malId,
    required int start,
    required int end,
  }) {
    if (start > end) return null;
    final AnimeEpisodeRedirection? first =
        redirect(malId: malId, episode: start);
    if (first == null) return null;
    final AnimeEpisodeRedirection? last = redirect(malId: malId, episode: end);
    if (last == null || last.malId != first.malId) return null;
    return (start: first, end: last);
  }

  /// 某个 MAL id 作为源侧的全部规则（只读，测试与诊断用）。
  List<AnimeEpisodeRedirect> rulesFor(int malId) =>
      List<AnimeEpisodeRedirect>.unmodifiable(
          _rulesByMalId[malId] ?? const <AnimeEpisodeRedirect>[]);
}

/// 规则一侧：`MAL|Kitsu|AniList:range`。只保留 MAL 列。
class _RuleSide {
  const _RuleSide(
      {required this.malId, required this.start, required this.end});

  final int malId;
  final int start;
  final int? end;

  /// [source] 为 null 时解析源侧（`~` 非法）；否则解析目标侧（`~` 复用源侧 MAL id）。
  static _RuleSide? parse(String text, {required _RuleSide? source}) {
    final String trimmed = text.trim();
    final int colon = trimmed.lastIndexOf(':');
    if (colon <= 0 || colon == trimmed.length - 1) return null;
    final List<String> ids = trimmed.substring(0, colon).split('|');
    if (ids.length != 3) return null;
    final String malColumn = ids[0].trim();
    final int? malId;
    if (malColumn == '~') {
      malId = source?.malId;
    } else if (malColumn == '?') {
      malId = null;
    } else {
      malId = int.tryParse(malColumn);
    }
    if (malId == null || malId <= 0) return null;
    final String range = trimmed.substring(colon + 1).trim();
    final int dash = range.indexOf('-');
    final String startText = dash < 0 ? range : range.substring(0, dash);
    final String endText = dash < 0 ? range : range.substring(dash + 1);
    final int? start = int.tryParse(startText.trim());
    if (start == null || start < 0) return null;
    final int? end;
    if (endText.trim() == '?') {
      end = null;
    } else {
      end = int.tryParse(endText.trim());
      if (end == null || end < start) return null;
    }
    return _RuleSide(malId: malId, start: start, end: end);
  }
}

/// 在线加载 anime-relations.txt 并在内存里缓存 24h；构造与 close 形态同
/// `AnimeIdentityMapping`。
class AnimeEpisodeRelationsCatalog {
  AnimeEpisodeRelationsCatalog({
    VideoMetadataHttpClient? httpClient,
    this.cacheTtl = const Duration(hours: 24),
    this.maxResponseBytes = 4 * 1024 * 1024,
    DateTime Function()? now,
  })  : _http = httpClient ?? VideoMetadataHttpClient(),
        _ownsHttp = httpClient == null,
        _now = now ?? DateTime.now;

  static final Uri sourceUri = Uri.parse(
    'https://raw.githubusercontent.com/erengy/anime-relations/master/anime-relations.txt',
  );
  final VideoMetadataHttpClient _http;
  final bool _ownsHttp;
  final DateTime Function() _now;
  final Duration cacheTtl;
  final int maxResponseBytes;
  AnimeEpisodeRelations? _relations;
  DateTime? _expiresAt;
  Future<AnimeEpisodeRelations>? _loading;

  Future<AnimeEpisodeRelations> load() async {
    if (_relations != null && _expiresAt!.isAfter(_now())) return _relations!;
    if (_loading != null) return _loading!;
    final Future<AnimeEpisodeRelations> pending = _download();
    _loading = pending;
    try {
      final AnimeEpisodeRelations relations = await pending;
      _relations = relations;
      _expiresAt = _now().add(cacheTtl);
      return relations;
    } finally {
      _loading = null;
    }
  }

  Future<AnimeEpisodeRedirection?> redirect({
    required int malId,
    required int episode,
  }) async {
    final AnimeEpisodeRelations relations = await load();
    return relations.redirect(malId: malId, episode: episode);
  }

  Future<AnimeEpisodeRelations> _download() async {
    final VideoMetadataHttpResponse response = await _http.get(
      sourceUri,
      operation: 'Anime episode relations',
    );
    if (response.body.length > maxResponseBytes ||
        utf8.encode(response.body).length > maxResponseBytes) {
      throw const FormatException('Anime episode relations exceed size limit');
    }
    return AnimeEpisodeRelations.parse(response.body);
  }

  void close() {
    if (_ownsHttp) _http.close();
  }
}
