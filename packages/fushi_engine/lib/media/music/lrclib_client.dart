/// LRCLIB（https://lrclib.net）在线歌词客户端（设计 §5.4、D3：在线歌词只装配 LRCLIB）。
///
/// - 精确匹配 `GET /api/get`：标题 + 艺人 + 专辑 + 时长（秒）；服务端按时长 ±2 s 判同一录音，
///   这里再在客户端核一遍（[lrclibDurationMatches]），不信任返回值；
/// - 失败再模糊搜索 `GET /api/search`，结果交给用户挑（不自动采用）；
/// - 出站一律经 `createAppHttpClient`（全应用代理装配），测试注入 [LrclibTransport] 走离线 fixture。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/utils/net/app_http.dart';

/// 一次 GET：返回 (状态码, 响应体)。
typedef LrclibTransport = Future<({int status, String body})> Function(Uri uri);

/// LRCLIB 的一条记录。
class LrclibRecord {
  const LrclibRecord({
    required this.id,
    required this.trackName,
    required this.artistName,
    this.albumName,
    this.durationSec,
    this.instrumental = false,
    this.plainLyrics,
    this.syncedLyrics,
  });

  factory LrclibRecord.fromJson(Map<String, Object?> j) => LrclibRecord(
    id: (j['id'] as num?)?.toInt() ?? 0,
    trackName: (j['trackName'] ?? j['name'] ?? '') as String,
    artistName: (j['artistName'] ?? '') as String,
    albumName: j['albumName'] as String?,
    durationSec: (j['duration'] as num?)?.toDouble(),
    instrumental: j['instrumental'] == true,
    plainLyrics: _nonEmpty(j['plainLyrics']),
    syncedLyrics: _nonEmpty(j['syncedLyrics']),
  );

  final int id;
  final String trackName;
  final String artistName;
  final String? albumName;
  final double? durationSec;
  final bool instrumental;
  final String? plainLyrics;

  /// LRC 文本（带时间）。
  final String? syncedLyrics;

  /// 有可用歌词（纯音乐记录两者都为空）。
  bool get hasLyrics => syncedLyrics != null || plainLyrics != null;

  /// 落库用的原文与格式：优先带时间的 LRC。
  ({String raw, String format})? get bestLyrics {
    final String? synced = syncedLyrics;
    if (synced != null) return (raw: synced, format: 'lrc');
    final String? plain = plainLyrics;
    if (plain != null) return (raw: plain, format: 'txt');
    return null;
  }
}

String? _nonEmpty(Object? v) => v is String && v.trim().isNotEmpty ? v : null;

/// 精确匹配的时长容差（设计 §5.4：±2 s）。
const double kLrclibDurationToleranceSec = 2;

/// 纯函数：记录时长与曲目时长是否在容差内。曲目时长未知时不卡（LRCLIB 自己按其它字段匹配）。
bool lrclibDurationMatches(LrclibRecord r, int? trackDurationMs) {
  if (trackDurationMs == null || trackDurationMs <= 0) return true;
  final double? d = r.durationSec;
  if (d == null) return false;
  return (d - trackDurationMs / 1000).abs() <= kLrclibDurationToleranceSec;
}

/// 纯函数：模糊搜索结果排序——有逐行时间的在前，其次时长差小的在前。
List<LrclibRecord> rankLrclibCandidates(
  List<LrclibRecord> records,
  int? trackDurationMs,
) {
  double diff(LrclibRecord r) {
    if (trackDurationMs == null || r.durationSec == null) return 1e9;
    return (r.durationSec! - trackDurationMs / 1000).abs();
  }

  return List<LrclibRecord>.of(records.where((LrclibRecord r) => r.hasLyrics))
    ..sort((LrclibRecord a, LrclibRecord b) {
      final int synced =
          (b.syncedLyrics != null ? 1 : 0) - (a.syncedLyrics != null ? 1 : 0);
      if (synced != 0) return synced;
      return diff(a).compareTo(diff(b));
    });
}

class LrclibClient {
  LrclibClient({LrclibTransport? transport, Uri? baseUri})
    : _transport = transport ?? _defaultTransport,
      _base = baseUri ?? Uri.parse('https://lrclib.net');

  final LrclibTransport _transport;
  final Uri _base;

  /// LRCLIB 要求客户端自报身份。
  static const String userAgent = 'Fushi (https://github.com/hajisensai/Fushi)';

  static Future<({int status, String body})> _defaultTransport(Uri uri) async {
    final HttpClient client = createAppHttpClient();
    try {
      final HttpClientRequest req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.userAgentHeader, userAgent);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final HttpClientResponse res = await req.close().timeout(
        const Duration(seconds: 20),
      );
      final String body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 20));
      return (status: res.statusCode, body: body);
    } finally {
      client.close(force: true);
    }
  }

  Uri _uri(String path, Map<String, String> query) => _base.replace(
    path: path,
    queryParameters: <String, String>{
      for (final MapEntry<String, String> e in query.entries)
        if (e.value.trim().isNotEmpty) e.key: e.value.trim(),
    },
  );

  /// 精确匹配；没有（404 / 时长对不上 / 纯音乐）返回 null。网络错误照常抛出。
  Future<LrclibRecord?> get({
    required String title,
    required String artist,
    String? album,
    int? durationMs,
  }) async {
    final Uri uri = _uri('/api/get', <String, String>{
      'track_name': title,
      'artist_name': artist,
      'album_name': album ?? '',
      if (durationMs != null && durationMs > 0)
        'duration': (durationMs / 1000).round().toString(),
    });
    final ({int status, String body}) res = await _transport(uri);
    if (res.status == 404) return null;
    if (res.status != 200) {
      throw HttpException('LRCLIB /api/get returned ${res.status}', uri: uri);
    }
    final Object? json = jsonDecode(res.body);
    if (json is! Map<String, Object?>) return null;
    final LrclibRecord r = LrclibRecord.fromJson(json);
    if (!r.hasLyrics || !lrclibDurationMatches(r, durationMs)) return null;
    return r;
  }

  /// 模糊搜索（结果交给用户挑），已按 [rankLrclibCandidates] 排序。
  Future<List<LrclibRecord>> search({
    required String title,
    String? artist,
    int? durationMs,
  }) async {
    final Uri uri = _uri('/api/search', <String, String>{
      'track_name': title,
      'artist_name': artist ?? '',
    });
    final ({int status, String body}) res = await _transport(uri);
    if (res.status != 200) {
      throw HttpException(
        'LRCLIB /api/search returned ${res.status}',
        uri: uri,
      );
    }
    final Object? json = jsonDecode(res.body);
    if (json is! List<Object?>) return const <LrclibRecord>[];
    return rankLrclibCandidates(<LrclibRecord>[
      for (final Object? e in json)
        if (e is Map<String, Object?>) LrclibRecord.fromJson(e),
    ], durationMs);
  }
}
