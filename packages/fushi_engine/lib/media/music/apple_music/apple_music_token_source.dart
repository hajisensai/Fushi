/// Apple Music developer token 的取用端（MusicKit 方案 §3.6，P1b）。
///
/// 签发端是排行榜 Worker 的 `GET /v1/musickit/token`（PR hajisensai/Fushi#2712）：返回
/// `{token, expiresAt}`（`expiresAt` 为毫秒时刻），Worker 保证拿到的 token 至少还有半个有效期。
/// 私钥只在 Worker secret 里，app 不持有任何签名材料。
///
/// - 缓存到 `expiresAt` 前 [kAppleMusicTokenRefreshMargin]，并发的取用合并成一次请求；
/// - Worker 未配置（503 `musickit_not_configured`）/ 网络失败统一抛
///   [AppleMusicUnavailableException]：Apple Music 来源整体显示「暂不可用」，不影响别的来源；
/// - catalog 回 401（Apple 侧吊销 / 轮换）时由调用方 [invalidate] 后重取一次。
///
/// 纯 Dart、不碰 Flutter（引擎纯度守卫）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:http/http.dart' as http;

/// 签发端地址（排行榜 Worker 线上域名）。
final Uri kAppleMusicTokenEndpoint = Uri.parse(
  'https://rank.fushi.moe/v1/musickit/token',
);

/// 离 `expiresAt` 还剩这么久就当作过期、重新取（避免请求途中过期）。
const Duration kAppleMusicTokenRefreshMargin = Duration(minutes: 10);

/// 取 token 的单次超时。
const Duration kAppleMusicTokenTimeout = Duration(seconds: 15);

/// Apple Music 暂不可用（签发端未配置 / 不可达 / 回包不合法）。
class AppleMusicUnavailableException implements Exception {
  const AppleMusicUnavailableException(this.reason, {this.httpStatus});

  /// 短码：`not_configured` / `http` / `network` / `bad_response`。
  final String reason;
  final int? httpStatus;

  @override
  String toString() =>
      'AppleMusicUnavailableException($reason'
      '${httpStatus == null ? '' : ', http $httpStatus'})';
}

/// 一枚 developer token。
class AppleMusicDeveloperToken {
  const AppleMusicDeveloperToken({
    required this.token,
    required this.expiresAt,
  });

  final String token;

  /// 过期时刻（毫秒）。
  final int expiresAt;
}

/// 解析签发端回包；不合法返回 null。
AppleMusicDeveloperToken? parseAppleMusicTokenResponse(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, Object?>) return null;
  final Object? token = decoded['token'];
  final Object? expiresAt = decoded['expiresAt'];
  if (token is! String || token.isEmpty || expiresAt is! num) return null;
  return AppleMusicDeveloperToken(token: token, expiresAt: expiresAt.toInt());
}

/// developer token 来源（app 内一份共享实例，跨浏览器实例复用缓存）。
class AppleMusicTokenSource {
  AppleMusicTokenSource({
    http.Client? client,
    Uri? endpoint,
    int Function()? now,
  }) : _client = client,
       _endpoint = endpoint ?? kAppleMusicTokenEndpoint,
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// 注入的客户端（测试）；为 null 时每次取 token 新建一个走应用代理的客户端、用完即关
  /// （一天才取一次，不值得常驻；也让用户改代理后下一次取用立即生效）。
  final http.Client? _client;
  final Uri _endpoint;
  final int Function() _now;

  AppleMusicDeveloperToken? _cached;
  Future<AppleMusicDeveloperToken>? _inFlight;

  /// 当前可用的 token（缓存未过期直接给，否则向签发端取）。失败抛
  /// [AppleMusicUnavailableException]。
  Future<String> token() async {
    final AppleMusicDeveloperToken? c = _cached;
    if (c != null &&
        c.expiresAt - kAppleMusicTokenRefreshMargin.inMilliseconds > _now()) {
      return c.token;
    }
    final Future<AppleMusicDeveloperToken> pending = _inFlight ??= _fetch();
    try {
      final AppleMusicDeveloperToken t = await pending;
      _cached = t;
      return t.token;
    } finally {
      if (identical(_inFlight, pending)) _inFlight = null;
    }
  }

  /// 丢弃缓存（catalog 回 401 时调用，下一次 [token] 重新取）。
  void invalidate() => _cached = null;

  Future<AppleMusicDeveloperToken> _fetch() async {
    final http.Client client = _client ?? createAppHttpIoClient();
    final http.Response res;
    try {
      res = await client
          .get(
            _endpoint,
            headers: const <String, String>{'Accept': 'application/json'},
          )
          .timeout(kAppleMusicTokenTimeout);
    } on TimeoutException {
      throw const AppleMusicUnavailableException('network');
    } on http.ClientException {
      throw const AppleMusicUnavailableException('network');
    } on Exception {
      // SocketException / HandshakeException 等：引擎不 import dart:io 的类型也能统一归到网络。
      throw const AppleMusicUnavailableException('network');
    } finally {
      if (_client == null) client.close();
    }
    if (res.statusCode == 503) {
      throw const AppleMusicUnavailableException(
        'not_configured',
        httpStatus: 503,
      );
    }
    if (res.statusCode != 200) {
      throw AppleMusicUnavailableException('http', httpStatus: res.statusCode);
    }
    final AppleMusicDeveloperToken? t = parseAppleMusicTokenResponse(
      utf8.decode(res.bodyBytes, allowMalformed: true),
    );
    if (t == null) {
      throw const AppleMusicUnavailableException('bad_response');
    }
    return t;
  }
}
