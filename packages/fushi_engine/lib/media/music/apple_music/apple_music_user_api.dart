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
///
/// [refresh] 为真时必须绕过缓存重新取：用户在 Apple 账号里撤销后重新授权，或 token 被服务器
/// 作废时，缓存里的 Music-User-Token 已不能用，但本机授权状态仍是「已授权」，不绕缓存会一直
/// 拿到同一枚作废的 token（反馈 caI0UrhA6-）。给不出新 token 的实现（如 MusicKit JS 只有
/// 存储里那一枚）可以原样返回，[AppleMusicUserApi] 见 token 没变就不重发。
typedef AppleMusicUserCredentialsProvider =
    Future<AppleMusicUserCredentials> Function({bool refresh});

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
  ///
  /// 401 / 403 表示这对 token 被服务器拒了（多半是缓存的 Music-User-Token 已作废）：绕过缓存
  /// 重新取一次 token，换到了不同的 token 才用它重发一次；token 没变或重发仍失败就抛原状态码。
  Future<Map<String, Object?>> send(
    String method,
    String path, {
    Map<String, String> query = const <String, String>{},
    Object? body,
  }) async {
    final Uri uri = _uri(path, query);
    final AppleMusicUserCredentials c = await _credentials();
    http.Response res = await _sendWith(c, method, uri, body);
    if (_isTokenRejected(res.statusCode)) {
      final AppleMusicUserCredentials fresh = await _refreshCredentials();
      if (fresh.userToken != c.userToken ||
          fresh.developerToken != c.developerToken) {
        res = await _sendWith(fresh, method, uri, body);
      }
    }
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

  static bool _isTokenRejected(int status) => status == 401 || status == 403;

  /// 进行中的绕缓存重取。并发请求（分页、批量评分）同时吃 401 / 403 时共用这一次，
  /// 不让每个请求各自触发一次重新生成 token。
  Future<AppleMusicUserCredentials>? _refreshing;

  Future<AppleMusicUserCredentials> _refreshCredentials() => _refreshing ??=
      _credentials(refresh: true).whenComplete(() => _refreshing = null);

  Future<http.Response> _sendWith(
    AppleMusicUserCredentials c,
    String method,
    Uri uri,
    Object? body,
  ) async {
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
    return http.Response.fromStream(
      await _client.send(req).timeout(kAppleMusicRequestTimeout),
    ).timeout(kAppleMusicRequestTimeout);
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
