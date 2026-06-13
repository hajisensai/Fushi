import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/video/video_danmaku_model.dart';
import 'package:hibiki/src/media/video/video_danmaku_source.dart';

const int kDandanplayHashPrefixBytes = 16 * 1024 * 1024;

/// Dandanplay 弹幕来源配置（全局偏好）：自建/镜像服务器地址 + 可选 API 凭据。
///
/// - [baseUrl] 空 = 用官方 `https://api.dandanplay.net`；非空 = 自建/镜像 dandanplay
///   API 根地址（兼容同协议的私有部署，TODO-277）。
/// - [appId] / [appSecret] 同时非空时，按 dandanplay **API v2 签名**给每个请求附带
///   `X-AppId` / `X-Timestamp` / `X-Signature` 头（见 [signatureHeaders]）；任一为空则
///   不签名（官方公共端点旧契约，向后兼容）。
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

  /// 是否启用 API v2 签名（[appId] 与 [appSecret] 同时非空）。
  bool get isSigned => appId.trim().isNotEmpty && appSecret.trim().isNotEmpty;

  /// 为请求 [path]（如 `/api/v2/match`）生成 dandanplay API v2 签名头。
  ///
  /// 规约（dandanplay 开放平台 v2）：
  /// `X-Signature = Base64(SHA256(AppId + UnixTimestampSeconds + Path + AppSecret))`，
  /// 连同 `X-AppId` / `X-Timestamp` 一起发送。未启用签名时返回空 map（不附任何头）。
  Map<String, String> signatureHeaders(String path, {DateTime? now}) {
    if (!isSigned) return const <String, String>{};
    final int timestamp =
        (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000;
    final String id = appId.trim();
    final String secret = appSecret.trim();
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

class DandanplayClient {
  /// [config] 缺省读取进程级 [DandanplayConfig.current]（偏好仓库推送），使
  /// 播放页的零参 `DandanplayClient()` 自动吃到用户配置的服务器/凭据。显式 [baseUri]
  /// 优先于 [config] 的服务器地址（测试注入 / 强制覆盖用）。
  DandanplayClient({
    http.Client? httpClient,
    Uri? baseUri,
    DandanplayConfig? config,
    Duration timeout = const Duration(seconds: 8),
  })  : _client = httpClient ?? http.Client(),
        _config = config ?? DandanplayConfig.current,
        _baseUri =
            baseUri ?? (config ?? DandanplayConfig.current).resolvedBaseUri,
        _timeout = timeout;

  final http.Client _client;
  final DandanplayConfig _config;
  final Uri _baseUri;
  final Duration _timeout;

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
      final List<VideoDanmakuItem> items =
          await fetchCommentsForMatch(matched.match!);
      return DandanplayFetchResult(
        status: DandanplayFetchStatus.hit,
        items: items,
        match: matched.match,
        matches: matched.matches,
      );
    } on SocketException catch (e) {
      return DandanplayFetchResult(
        status: DandanplayFetchStatus.networkError,
        error: e,
      );
    } on http.ClientException catch (e) {
      return DandanplayFetchResult(
        status: DandanplayFetchStatus.networkError,
        error: e,
      );
    } on TimeoutException catch (e) {
      return DandanplayFetchResult(
        status: DandanplayFetchStatus.networkError,
        error: e,
      );
    } catch (e) {
      return DandanplayFetchResult(
        status: DandanplayFetchStatus.serverError,
        error: e,
      );
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

  Future<List<VideoDanmakuItem>> fetchCommentsForMatch(
    DandanplayMatch match,
  ) async {
    final String path = '/api/v2/comment/${match.episodeId}';
    final Uri uri = _baseUri.replace(
      path: path,
      queryParameters: const <String, String>{
        'withRelated': 'true',
      },
    );
    final http.Response response =
        await _client.get(uri, headers: _headersFor(path)).timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return const <VideoDanmakuItem>[];
    }
    final dynamic decoded = jsonDecode(response.body);
    if (decoded is! Map) return const <VideoDanmakuItem>[];
    final dynamic comments = decoded['comments'];
    if (comments is! List) return const <VideoDanmakuItem>[];
    return dandanplayCommentsToDanmaku(
      comments,
      shiftMs: (match.shiftSeconds * 1000).round(),
    );
  }
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
