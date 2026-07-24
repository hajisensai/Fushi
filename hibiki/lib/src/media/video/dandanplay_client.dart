import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/video/dandanplay_secret.dart';
import 'package:hibiki/src/media/video/video_danmaku_model.dart';
import 'package:hibiki/src/media/video/video_danmaku_source.dart';

const int kDandanplayHashPrefixBytes = 16 * 1024 * 1024;

/// Dandanplay 弹幕来源配置（全局偏好）：自建/镜像服务器地址 + 可选 API 凭据。
///
/// - [baseUrl] 空 = 用官方 `https://api.dandanplay.net`；非空 = 自建/镜像 dandanplay
///   API 根地址（兼容同协议的私有部署，TODO-277）。
/// - [appId] / [appSecret] 是用户自填的**覆盖**凭据；留空时回退到内置的
///   [embeddedAppId] / [embeddedAppSecret]（编译期从 `dandanplay_secret.dart` 注入），
///   使官方在线弹幕**开箱即用、无需用户手动输入 API**。生效凭据见 [effectiveAppId] /
///   [effectiveAppSecret]，两者同时非空即按 dandanplay **API v2 签名**给每个请求附带
///   `X-AppId` / `X-Timestamp` / `X-Signature` 头（见 [signatureHeaders]）。
@immutable
class DandanplayConfig {
  const DandanplayConfig({
    this.baseUrl = '',
    this.appId = '',
    this.appSecret = '',
  });

  static const DandanplayConfig defaults = DandanplayConfig();

  /// 官方默认 API 根地址（[baseUrl] 为空时回退到此）。
  static const String officialBaseUrl = 'https://api.dandanplay.net';

  final String baseUrl;
  final String appId;
  final String appSecret;

  /// 进程级当前配置：偏好仓库（数据拥有者）在加载/变更时推送到此，
  /// [DandanplayClient] 的默认构造从这里读取，避免改动播放页的零参构造调用点。
  static DandanplayConfig current = defaults;

  /// 内置的官方 dandanplay 开放平台凭据（编译期，来自 `dandanplay_secret.dart`）。
  /// 用户未在偏好里填自己的 [appId] / [appSecret] 时，请求用这套内置凭据签名，
  /// 使弹幕开箱即用、无需用户手动输入 API。可变 static 便于测试注入确定值。
  static String embeddedAppId = kDandanplayAppId;
  static String embeddedAppSecret = kDandanplayAppSecret;

  /// 生效的 AppId：用户显式配置优先，否则回退内置凭据 [embeddedAppId]。
  String get effectiveAppId =>
      appId.trim().isNotEmpty ? appId.trim() : embeddedAppId.trim();

  /// 生效的 AppSecret：用户显式配置优先，否则回退内置凭据 [embeddedAppSecret]。
  String get effectiveAppSecret =>
      appSecret.trim().isNotEmpty ? appSecret.trim() : embeddedAppSecret.trim();

  DandanplayConfig copyWith({
    String? baseUrl,
    String? appId,
    String? appSecret,
  }) {
    return DandanplayConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      appId: appId ?? this.appId,
      appSecret: appSecret ?? this.appSecret,
    );
  }

  /// 解析出的 API 根地址：[baseUrl] 合法（http/https 且有 host）则用它，否则回退官方。
  Uri get resolvedBaseUri {
    final String trimmed = baseUrl.trim();
    if (trimmed.isEmpty) return Uri.parse(officialBaseUrl);
    final Uri? parsed = Uri.tryParse(trimmed);
    if (parsed == null ||
        parsed.host.isEmpty ||
        (parsed.scheme != 'http' && parsed.scheme != 'https')) {
      return Uri.parse(officialBaseUrl);
    }
    // 只取 scheme+host(+port)，丢掉用户可能误填的尾部 path/query（请求自带 /api/v2/...）。
    return Uri(
        scheme: parsed.scheme,
        host: parsed.host,
        port: parsed.hasPort ? parsed.port : null);
  }

  /// 是否启用 API v2 签名（[effectiveAppId] 与 [effectiveAppSecret] 同时非空）。
  bool get isSigned =>
      effectiveAppId.isNotEmpty && effectiveAppSecret.isNotEmpty;

  /// 为请求 [path]（如 `/api/v2/match`）生成 dandanplay API v2 签名头。
  ///
  /// 规约（dandanplay 开放平台 v2）：
  /// `X-Signature = Base64(SHA256(AppId + UnixTimestampSeconds + Path + AppSecret))`，
  /// 连同 `X-AppId` / `X-Timestamp` 一起发送。未启用签名时返回空 map（不附任何头）。
  Map<String, String> signatureHeaders(String path, {DateTime? now}) {
    if (!isSigned) return const <String, String>{};
    final int timestamp =
        (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000;
    final String id = effectiveAppId;
    final String secret = effectiveAppSecret;
    final List<int> payload = utf8.encode('$id$timestamp$path$secret');
    final String signature = base64.encode(sha256.convert(payload).bytes);
    return <String, String>{
      'X-AppId': id,
      'X-Timestamp': '$timestamp',
      'X-Signature': signature,
    };
  }

  static String encode(DandanplayConfig config) => jsonEncode(<String, dynamic>{
        'baseUrl': config.baseUrl,
        'appId': config.appId,
        'appSecret': config.appSecret,
      });

  static DandanplayConfig decode(String? json) {
    if (json == null || json.isEmpty) return defaults;
    try {
      final dynamic d = jsonDecode(json);
      if (d is! Map) return defaults;
      String str(Object? v) => v is String ? v : '';
      return DandanplayConfig(
        baseUrl: str(d['baseUrl']),
        appId: str(d['appId']),
        appSecret: str(d['appSecret']),
      );
    } catch (_) {
      return defaults;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is DandanplayConfig &&
      other.baseUrl == baseUrl &&
      other.appId == appId &&
      other.appSecret == appSecret;

  @override
  int get hashCode => Object.hash(baseUrl, appId, appSecret);
}

enum DandanplayFetchStatus {
  hit,
  noMatch,
  needsSelection,
  networkError,
  serverError,
}

class DandanplayMatch {
  const DandanplayMatch({
    required this.episodeId,
    this.animeTitle,
    this.episodeTitle,
    this.shiftSeconds = 0,
  });

  final int episodeId;
  final String? animeTitle;
  final String? episodeTitle;
  final double shiftSeconds;

  static DandanplayMatch? fromJson(Map<dynamic, dynamic> json) {
    final Object? id = json['episodeId'];
    if (id is! num) return null;
    return DandanplayMatch(
      episodeId: id.toInt(),
      animeTitle: json['animeTitle']?.toString(),
      episodeTitle: json['episodeTitle']?.toString(),
      shiftSeconds:
          json['shift'] is num ? (json['shift'] as num).toDouble() : 0,
    );
  }
}

class DandanplayFetchResult {
  const DandanplayFetchResult({
    required this.status,
    this.items = const <VideoDanmakuItem>[],
    this.matches = const <DandanplayMatch>[],
    this.match,
    this.error,
  });

  final DandanplayFetchStatus status;
  final List<VideoDanmakuItem> items;
  final List<DandanplayMatch> matches;
  final DandanplayMatch? match;
  final Object? error;
}

/// 手动搜索命中的一集（TODO-1376）：episodeId 用于拉取弹幕，标题供列表展示。
@immutable
class DandanplaySearchEpisode {
  const DandanplaySearchEpisode({
    required this.episodeId,
    required this.episodeTitle,
  });

  final int episodeId;
  final String episodeTitle;

  static DandanplaySearchEpisode? fromJson(Map<dynamic, dynamic> json) {
    final Object? id = json['episodeId'];
    if (id is! num) return null;
    return DandanplaySearchEpisode(
      episodeId: id.toInt(),
      episodeTitle: json['episodeTitle']?.toString() ?? '',
    );
  }
}

/// 手动搜索命中的一部番剧（TODO-1376）：含其下可选的分集列表。
@immutable
class DandanplaySearchAnime {
  const DandanplaySearchAnime({
    required this.animeId,
    required this.animeTitle,
    this.typeDescription,
    this.episodes = const <DandanplaySearchEpisode>[],
  });

  final int animeId;
  final String animeTitle;
  final String? typeDescription;
  final List<DandanplaySearchEpisode> episodes;
}

/// 手动搜索结果（TODO-1376）：复用 [DandanplayFetchStatus] 的 hit/noMatch/
/// networkError/serverError 语义，[animes] 仅在 hit 时非空。
@immutable
class DandanplaySearchResult {
  const DandanplaySearchResult({
    required this.status,
    this.animes = const <DandanplaySearchAnime>[],
    this.error,
  });

  final DandanplayFetchStatus status;
  final List<DandanplaySearchAnime> animes;
  final Object? error;
}

class DandanplayClient {
  /// [config] 缺省读取进程级 [DandanplayConfig.current]（偏好仓库推送），使
  /// 播放页的零参 `DandanplayClient()` 自动吃到用户配置的服务器/凭据。显式 [baseUri]
  /// 优先于 [config] 的服务器地址（测试注入 / 强制覆盖用）。
  ///
  /// 超时分两档（BUG-1057）：[timeout] 给轻量请求（match / search，响应几 KB），
  /// [commentTimeout] 给 `/api/v2/comment/{id}`——后者在 `withRelated=true` 时要由
  /// 服务端聚合第三方弹幕源，响应体可达数 MB，而 `http.get().timeout()` 计的是
  /// **整个响应体下载完**的时间；两者共用 8s 会让正片弹幕稳定超时。
  DandanplayClient({
    http.Client? httpClient,
    Uri? baseUri,
    DandanplayConfig? config,
    Duration timeout = const Duration(seconds: 8),
    Duration commentTimeout = const Duration(seconds: 30),
  })  : _client = httpClient ?? http.Client(),
        _config = config ?? DandanplayConfig.current,
        _baseUri =
            baseUri ?? (config ?? DandanplayConfig.current).resolvedBaseUri,
        _timeout = timeout,
        _commentTimeout = commentTimeout;

  final http.Client _client;
  final DandanplayConfig _config;
  final Uri _baseUri;
  final Duration _timeout;
  final Duration _commentTimeout;

  void close() => _client.close();

  /// 为请求 [path] 组装请求头：可选 [extra] + （配置了 AppId/Secret 时的）v2 签名头。
  Map<String, String> _headersFor(
    String path, {
    Map<String, String> extra = const <String, String>{},
  }) {
    final Map<String, String> headers = <String, String>{...extra};
    headers.addAll(_config.signatureHeaders(path));
    return headers;
  }

  Future<DandanplayFetchResult> fetchBestDanmakuForFile(File file) async {
    try {
      final DandanplayFetchResult matched = await matchFile(file);
      if (matched.status != DandanplayFetchStatus.hit ||
          matched.match == null) {
        return matched;
      }
      final DandanplayFetchResult comments =
          await fetchCommentsForMatch(matched.match!);
      // 拉弹幕失败时如实上抛失败状态（此前被吞成「命中且 0 条」，见 BUG-1057）；
      // 匹配信息仍保留，供 UI 展示已匹配到哪一集。
      return DandanplayFetchResult(
        status: comments.status,
        items: comments.items,
        match: matched.match,
        matches: matched.matches,
        error: comments.error,
      );
    } catch (e) {
      return DandanplayFetchResult(status: _statusForError(e), error: e);
    }
  }

  Future<DandanplayFetchResult> matchFile(File file) async {
    const String path = '/api/v2/match';
    final Uri uri = _baseUri.replace(path: path);
    final Map<String, dynamic> body = <String, dynamic>{
      'fileName': p.basenameWithoutExtension(file.path),
      'fileHash': await dandanplayFileHash(file),
      'fileSize': file.lengthSync(),
      'matchMode': 'hashAndFileName',
    };
    final http.Response response = await _client
        .post(
          uri,
          headers: _headersFor(
            path,
            extra: const <String, String>{
              HttpHeaders.contentTypeHeader: 'application/json',
            },
          ),
          body: jsonEncode(body),
        )
        .timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return DandanplayFetchResult(
        status: DandanplayFetchStatus.serverError,
        error: response.statusCode,
      );
    }
    final dynamic decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      return const DandanplayFetchResult(
        status: DandanplayFetchStatus.serverError,
      );
    }
    if (decoded['success'] == false) {
      return DandanplayFetchResult(
        status: DandanplayFetchStatus.serverError,
        error: decoded['errorMessage'],
      );
    }
    final List<DandanplayMatch> matches = _matchesFromJson(decoded['matches']);
    if (matches.isEmpty) {
      return const DandanplayFetchResult(status: DandanplayFetchStatus.noMatch);
    }
    if (decoded['isMatched'] == true && matches.length == 1) {
      return DandanplayFetchResult(
        status: DandanplayFetchStatus.hit,
        matches: matches,
        match: matches.single,
      );
    }
    return DandanplayFetchResult(
      status: DandanplayFetchStatus.needsSelection,
      matches: matches,
    );
  }

  /// 拉取 [match] 那一集的弹幕。
  ///
  /// 返回**带状态**的结果而不是裸列表（BUG-1057）：此前任何非 2xx 都被压成
  /// `const []`，调用方无从区分「这一集真的 0 条弹幕」与「403 凭据/权限被拒、
  /// 404 无此集、5xx、超时」。后果是手动绑定在服务器拒绝时反而「成功」——面板关闭、
  /// episodeId 落库、弹幕为空、零提示；自动加载则把错误当成缓存失效，白跑一次
  /// 16MiB 文件 hash + `/api/v2/match`。
  ///
  /// `hit` 允许 [DandanplayFetchResult.items] 为空：那是「该集有效但暂无弹幕」，
  /// 与错误是两回事，由调用方分别给反馈。
  Future<DandanplayFetchResult> fetchCommentsForMatch(
    DandanplayMatch match,
  ) async {
    final String path = '/api/v2/comment/${match.episodeId}';
    final Uri uri = _baseUri.replace(
      path: path,
      queryParameters: const <String, String>{
        'withRelated': 'true',
      },
    );
    try {
      final http.Response response = await _client
          .get(uri, headers: _headersFor(path))
          .timeout(_commentTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return DandanplayFetchResult(
          status: DandanplayFetchStatus.serverError,
          match: match,
          error: response.statusCode,
        );
      }
      final dynamic decoded = jsonDecode(response.body);
      if (decoded is! Map || decoded['comments'] is! List) {
        return DandanplayFetchResult(
          status: DandanplayFetchStatus.serverError,
          match: match,
        );
      }
      return DandanplayFetchResult(
        status: DandanplayFetchStatus.hit,
        items: dandanplayCommentsToDanmaku(
          decoded['comments'] as List<dynamic>,
          shiftMs: (match.shiftSeconds * 1000).round(),
        ),
        match: match,
      );
    } catch (e) {
      return DandanplayFetchResult(
        status: _statusForError(e),
        match: match,
        error: e,
      );
    }
  }

  /// 手动按番剧名 [keyword] 搜索候选集（TODO-1376，dandanplay `/api/v2/search/episodes`）。
  /// 自动匹配（[matchFile]）失败或匹配错集时的用户兜底入口；结果按番剧分组、各含分集。
  Future<DandanplaySearchResult> searchEpisodes(String keyword) async {
    final String trimmed = keyword.trim();
    if (trimmed.isEmpty) {
      return const DandanplaySearchResult(
          status: DandanplayFetchStatus.noMatch);
    }
    const String path = '/api/v2/search/episodes';
    final Uri uri = _baseUri.replace(
      path: path,
      queryParameters: <String, String>{'anime': trimmed},
    );
    try {
      final http.Response response =
          await _client.get(uri, headers: _headersFor(path)).timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return DandanplaySearchResult(
          status: DandanplayFetchStatus.serverError,
          error: response.statusCode,
        );
      }
      final dynamic decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        return const DandanplaySearchResult(
          status: DandanplayFetchStatus.serverError,
        );
      }
      if (decoded['success'] == false) {
        return DandanplaySearchResult(
          status: DandanplayFetchStatus.serverError,
          error: decoded['errorMessage'],
        );
      }
      final List<DandanplaySearchAnime> animes =
          _animesFromJson(decoded['animes']);
      if (animes.isEmpty) {
        return const DandanplaySearchResult(
          status: DandanplayFetchStatus.noMatch,
        );
      }
      return DandanplaySearchResult(
        status: DandanplayFetchStatus.hit,
        animes: animes,
      );
    } catch (e) {
      return DandanplaySearchResult(status: _statusForError(e), error: e);
    }
  }
}

/// 把请求期异常归类成 [DandanplayFetchStatus]：连不上/断流/超时算 `networkError`
/// （用户侧可重试），其余（JSON 畸形等）算 `serverError`。三处调用点共用同一判据，
/// 消除此前每处各写四个 `on ... catch` 的重复分支。
DandanplayFetchStatus _statusForError(Object error) {
  final bool network = error is IOException || // Socket/Handshake/Http 等
      error is http.ClientException ||
      error is TimeoutException;
  return network
      ? DandanplayFetchStatus.networkError
      : DandanplayFetchStatus.serverError;
}

Future<String> dandanplayFileHash(File file) async {
  final int length = file.lengthSync();
  final int end = math.min(length, kDandanplayHashPrefixBytes);
  final Digest digest = await md5.bind(file.openRead(0, end)).first;
  return digest.toString();
}

List<DandanplayMatch> _matchesFromJson(Object? raw) {
  if (raw is! List) return const <DandanplayMatch>[];
  return raw
      .whereType<Map>()
      .map(DandanplayMatch.fromJson)
      .whereType<DandanplayMatch>()
      .toList(growable: false);
}

List<DandanplaySearchAnime> _animesFromJson(Object? raw) {
  if (raw is! List) return const <DandanplaySearchAnime>[];
  final List<DandanplaySearchAnime> out = <DandanplaySearchAnime>[];
  for (final dynamic anime in raw) {
    if (anime is! Map) continue;
    final Object? id = anime['animeId'];
    if (id is! num) continue;
    out.add(DandanplaySearchAnime(
      animeId: id.toInt(),
      animeTitle: anime['animeTitle']?.toString() ?? '',
      typeDescription: anime['typeDescription']?.toString(),
      episodes: _searchEpisodesFromJson(anime['episodes']),
    ));
  }
  return out;
}

List<DandanplaySearchEpisode> _searchEpisodesFromJson(Object? raw) {
  if (raw is! List) return const <DandanplaySearchEpisode>[];
  return raw
      .whereType<Map>()
      .map(DandanplaySearchEpisode.fromJson)
      .whereType<DandanplaySearchEpisode>()
      .toList(growable: false);
}
