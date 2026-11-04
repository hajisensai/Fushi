/// 带用户身份的 Apple Music API 请求（`/v1/me/...` 与需要 Music-User-Token 的 catalog 端点）。
///
/// 两枚 token 必须是**同一套**：网页桥用 Worker 代签的 developer token 配 MusicKit JS 授权得到的
/// 用户 token；Apple 原生用系统为 App ID 生成的那对（MusicKit 方案 §3.6）。取用由 app 侧的
/// [AppleMusicUserCredentialsProvider] 负责（桥授权后才有）。
///
/// 纯 Dart、不碰 Flutter（引擎纯度守卫）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:fushi_engine/media/music/apple_music/apple_music_catalog_client.dart'
    show AppleMusicApiException, kAppleMusicApiBase, kAppleMusicRequestTimeout;
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:http/http.dart' as http;

/// 访问用户私有数据的一对 token。
class AppleMusicUserCredentials {
  const AppleMusicUserCredentials({
    required this.developerToken,
    required this.userToken,
  });

  final String developerToken;
  final String userToken;
}

/// 取当前的一对 token；未登录 / 授权失效时抛（页面显示错误）。
typedef AppleMusicUserCredentialsProvider =
    Future<AppleMusicUserCredentials> Function();

/// 带用户 token 的请求器。
class AppleMusicUserApi {
  AppleMusicUserApi({
    required AppleMusicUserCredentialsProvider credentials,
    http.Client? client,
    Uri? apiBase,
  }) : _credentials = credentials,
       _client = client ?? createAppHttpIoClient(),
       _ownsClient = client == null,
       _apiBase = apiBase ?? kAppleMusicApiBase;

  final AppleMusicUserCredentialsProvider _credentials;
  final http.Client _client;
  final bool _ownsClient;
  final Uri _apiBase;

  /// [path] 是以 `/v1/` 开头的绝对路径（可以就是回包里的 `next`，自带 query）。
  Uri _uri(String path, Map<String, String> query) {
    final Uri rel = Uri.parse(path);
    final Map<String, String> q = <String, String>{
      ...rel.queryParameters,
      ...query,
    };
    return _apiBase.replace(
      path: rel.path,
      queryParameters: q.isEmpty ? null : q,
    );
  }

  /// 发一个请求并解析 JSON 回包。空体（202 / 204）回空 Map。非 2xx 抛 [AppleMusicApiException]。
  Future<Map<String, Object?>> send(
    String method,
    String path, {
    Map<String, String> query = const <String, String>{},
    Object? body,
  }) async {
    final Uri uri = _uri(path, query);
    final AppleMusicUserCredentials c = await _credentials();
    final http.Request req = http.Request(method, uri)
      ..headers.addAll(<String, String>{
        'Authorization': 'Bearer ${c.developerToken}',
        'Music-User-Token': c.userToken,
        'Accept': 'application/json',
      });
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final http.Response res = await http.Response.fromStream(
      await _client.send(req).timeout(kAppleMusicRequestTimeout),
    ).timeout(kAppleMusicRequestTimeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw AppleMusicApiException(res.statusCode, uri.path);
    }
    if (res.bodyBytes.isEmpty) return const <String, Object?>{};
    final Object? decoded = jsonDecode(
      utf8.decode(res.bodyBytes, allowMalformed: true),
    );
    if (decoded is! Map<String, Object?>) {
      throw AppleMusicApiException(res.statusCode, uri.path);
    }
    return decoded;
  }

  Future<Map<String, Object?>> get(
    String path, [
    Map<String, String> query = const <String, String>{},
  ]) => send('GET', path, query: query);

  /// 跟 `next` 翻完（至多 [maxPages] 页）并回全部 `data`。
  Future<List<Object?>> getAll(
    String path, {
    Map<String, String> query = const <String, String>{},
    int maxPages = 30,
  }) async {
    final List<Object?> out = <Object?>[];
    Map<String, Object?> page = await get(path, query);
    for (int i = 0; ; i++) {
      final Object? d = page['data'];
      if (d is List<Object?>) out.addAll(d);
      final Object? next = page['next'];
      if (next is! String || next.isEmpty || i + 1 >= maxPages) break;
      page = await get(next);
    }
    return out;
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
