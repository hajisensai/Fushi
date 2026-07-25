/// Bangumi（番组计划）API v0 的**跨媒体共享传输层**。
///
/// 背景：视频海报刮削（`media/video/scraper/bangumi_client.dart`）与 galgame 元数据
/// （`mining/metadata/adapters/bangumi_adapter.dart`）此前各写了一份 Bangumi 客户端，
/// 打的是**同一套** API v0 端点（`POST /search/subjects`、`GET /subjects/{id}`），只是
/// ① 过滤的 subject 类型不同（动画 2 / 游戏 4 / 书籍 1）② 映射到不同领域对象。真正重复的
/// 是**传输层**：URL 构造、请求头、POST 搜索体、超时、`utf8(bodyBytes)` 解码、传输异常
/// 边界——本文件把它收成唯一一份。
///
/// **本层只负责传输**，刻意不做以下事情（它们是各调用方的策略，合理地不同，不该强并）：
/// - subject 类型选择（由调用方传 [subjectType]）；
/// - HTTP 非 2xx → 领域异常的映射（视频抛 `ScrapeNetworkException`，galgame 抛
///   `GalgameMetadataException`，各自保留）；
/// - 404 策略（视频当异常降级；galgame 当「条目不存在」返回 null）；
/// - JSON → 领域对象映射（`parseBangumiSubject*` 等薄映射器各留各的）；
/// - 限流（galgame 有 `GalgameRateLimiter`，通过 [gate] 钩子注入；视频不需要）。
///
/// 代理：`package:http` 走 `dart:io` 的 `HttpClient`，自动尊重系统 / 环境代理（`HTTP_PROXY`
/// / `HTTPS_PROXY`），本层不管。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Bangumi `filter.type` 条目类型常量（避免各处散落魔法数字）。
const int kBangumiSubjectTypeBook = 1;
const int kBangumiSubjectTypeAnime = 2;
const int kBangumiSubjectTypeMusic = 3;
const int kBangumiSubjectTypeGame = 4;
const int kBangumiSubjectTypeReal = 6;

/// 传输层失败：网络不通 / 超时 / 无 HTTP 响应时抛出。
///
/// **HTTP 非 2xx 不在此抛**——那是有响应的正常返回，交由调用方按各自的状态码策略
/// （含 404 语义）处理。本异常只表示「根本没拿到响应」。调用方捕获后再包装成自己的
/// 领域异常。
class BangumiTransportException implements Exception {
  const BangumiTransportException(this.message);

  /// 英文技术描述（本层不含用户可见 UI 字符串）。
  final String message;

  @override
  String toString() => 'BangumiTransportException: $message';
}

/// 一次 Bangumi API 调用的原始结果：HTTP 状态码 + `utf8` 解码后的 body + 响应头。
///
/// 刻意不做 JSON 解码，也不做领域映射——那是各领域薄映射器的职责。响应头透出是为了让
/// 注入的限流 [BangumiSendGate] 读 `Retry-After` 等头。
class BangumiRawResponse {
  const BangumiRawResponse({
    required this.statusCode,
    required this.body,
    required this.headers,
  });

  final int statusCode;

  /// `utf8.decode(bodyBytes)` 的结果：走 bodyBytes 而非 `http.Response.body`，避免缺
  /// charset 时按 latin1 解码毁掉中日文。
  final String body;

  final Map<String, String> headers;

  bool get isOk => statusCode >= 200 && statusCode < 300;
}

/// 发送钩子：包住「实际发一次请求」，用于注入限流 / 观测。默认直发（[_directSend]）。
///
/// galgame 侧传入 `(send) => rateLimiter.run(() async { final r = await send();
/// rateLimiter.noteResponse(r.statusCode, r.headers); return r; })`，把限流留在自己层。
typedef BangumiSendGate = Future<http.Response> Function(
  Future<http.Response> Function() send,
);

/// Bangumi API v0 共享传输客户端。
class BangumiApiClient {
  BangumiApiClient({
    http.Client? client,
    required this.userAgent,
    this.baseUrl = 'https://api.bgm.tv/v0',
    this.timeout = const Duration(seconds: 15),
    this.accessToken,
    BangumiSendGate? gate,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        _gate = gate ?? _directSend;

  final http.Client _client;
  final bool _ownsClient;

  /// Bangumi 要求可识别的 User-Agent，否则可能被限流 / 拒绝；各调用方各报各的身份。
  final String userAgent;

  final String baseUrl;
  final Duration timeout;

  /// 可选 access token（Bearer）：只有 R18 条目才必须带（galgame 侧用）。
  final String? accessToken;

  final BangumiSendGate _gate;

  static Future<http.Response> _directSend(
    Future<http.Response> Function() send,
  ) =>
      send();

  /// `POST /search/subjects`，`filter.type = [subjectType]`，最多 [limit] 条。
  Future<BangumiRawResponse> searchSubjects(
    String keyword, {
    required int subjectType,
    int limit = 10,
  }) {
    final Uri uri = Uri.parse('$baseUrl/search/subjects').replace(
      queryParameters: <String, String>{'limit': '${limit.clamp(1, 50)}'},
    );
    final String requestBody = jsonEncode(<String, Object?>{
      'keyword': keyword,
      'filter': <String, Object?>{
        'type': <int>[subjectType],
      },
    });
    return _run(
      () => _client
          .post(uri, headers: _headers(json: true), body: requestBody)
          .timeout(timeout),
    );
  }

  /// `GET /subjects/{id}`：拉条目详情（简介/评分/放送/话数/标签/infobox）。
  Future<BangumiRawResponse> fetchSubject(String subjectId) {
    final Uri uri = Uri.parse('$baseUrl/subjects/$subjectId');
    return _run(
      () => _client.get(uri, headers: _headers()).timeout(timeout),
    );
  }

  Future<BangumiRawResponse> _run(
    Future<http.Response> Function() send,
  ) async {
    final http.Response response;
    try {
      response = await _gate(send);
    } on TimeoutException {
      throw const BangumiTransportException('request timed out');
    } on BangumiTransportException {
      rethrow;
    } catch (e) {
      throw BangumiTransportException('request failed: $e');
    }
    return BangumiRawResponse(
      statusCode: response.statusCode,
      body: utf8.decode(response.bodyBytes),
      headers: response.headers,
    );
  }

  Map<String, String> _headers({bool json = false}) {
    final Map<String, String> headers = <String, String>{
      'User-Agent': userAgent,
      'Accept': 'application/json',
    };
    if (json) {
      headers['Content-Type'] = 'application/json';
    }
    final String? token = accessToken;
    if (token != null && token.trim().isNotEmpty) {
      headers['Authorization'] = 'Bearer ${token.trim()}';
    }
    return headers;
  }

  /// 关闭内部 client（若为默认自建）。注入的 mock client 由调用方自行管理。
  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }
}
