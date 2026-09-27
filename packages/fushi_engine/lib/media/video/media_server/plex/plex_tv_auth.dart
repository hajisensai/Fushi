/// plex.tv 账号侧：PIN 登录 + 账号下的服务器清单（resources）+ 连接地址选择。
///
/// PIN 流程（Plex 官方「第三方应用登录」口径）：
/// 1. `POST https://plex.tv/api/v2/pins?strong=true` 建 PIN（带 `X-Plex-*` 身份头）；
/// 2. 用户在浏览器打开 [PlexTvApi.authUrl]（`https://app.plex.tv/auth#?clientID=…
///    &code=…`）登录并授权本客户端；
/// 3. 客户端轮询 `GET /api/v2/pins/{id}`，`authToken` 非空即拿到账号 token；
///    PIN 过期（`expiresAt` 已过 / 404）即失败。
///
/// 然后 `GET https://clients.plex.tv/api/v2/resources?includeHttps=1&includeRelay=1`
/// 列出账号能访问的服务器，每台带多条 connection（局域网 / 公网 / relay），
/// [orderPlexConnections] 排优先级、[firstReachablePlexConnection] 逐条探测。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:fushi_engine/media/metadata/credential_redaction.dart'
    show redactCredentialsInText;
import 'package:fushi_engine/media/video/media_server/plex/plex_api.dart';
import 'package:fushi_engine/utils/net/app_http.dart';

/// 一个 plex.tv PIN。
class PlexPin {
  const PlexPin({
    required this.id,
    required this.code,
    this.authToken,
    this.expiresAt,
  });

  final int id;
  final String code;

  /// 用户授权后才非空。
  final String? authToken;
  final DateTime? expiresAt;

  bool get isAuthorized => authToken != null && authToken!.isNotEmpty;

  bool isExpiredAt(DateTime now) =>
      expiresAt != null && !now.isBefore(expiresAt!);
}

/// plex.tv 账号信息（`/api/v2/user`）。
class PlexTvUser {
  const PlexTvUser({required this.id, required this.username});

  /// 账号数字 id（字符串化）。
  final String id;
  final String username;
}

/// 服务器的一条连接地址。
class PlexConnection {
  const PlexConnection({
    required this.uri,
    this.local = false,
    this.relay = false,
    this.ipv6 = false,
  });

  final String uri;
  final bool local;
  final bool relay;
  final bool ipv6;
}

/// 账号下的一台服务器（`resources` 里 `provides` 含 `server` 的项）。
class PlexResource {
  const PlexResource({
    required this.name,
    required this.clientIdentifier,
    required this.connections,
    this.accessToken,
    this.owned = false,
  });

  final String name;

  /// 服务器的 machineIdentifier（与 PMS `/identity` 一致）——本机身份锚。
  final String clientIdentifier;

  /// 访问**这台**服务器的 token（别人分享的服务器与账号 token 不同）。
  final String? accessToken;
  final bool owned;
  final List<PlexConnection> connections;
}

/// 连接地址优先级：局域网直连 → 公网直连 → relay；同档内 IPv4 先于 IPv6，
/// 其余保持服务器给出的顺序（稳定排序）。
List<PlexConnection> orderPlexConnections(List<PlexConnection> connections) {
  int rank(PlexConnection c) =>
      (c.relay ? 4 : (c.local ? 0 : 2)) + (c.ipv6 ? 1 : 0);
  final List<(int, int, PlexConnection)> keyed =
      <(int, int, PlexConnection)>[
        for (int i = 0; i < connections.length; i++)
          (rank(connections[i]), i, connections[i]),
      ]..sort(((int, int, PlexConnection) a, (int, int, PlexConnection) b) {
        final int byRank = a.$1.compareTo(b.$1);
        return byRank != 0 ? byRank : a.$2.compareTo(b.$2);
      });
  return <PlexConnection>[for (final (_, _, PlexConnection c) in keyed) c];
}

/// 按 [ordered] 顺序逐条 [probe]，返回第一条可达的 uri；全不通返回 null。
/// 探测失败（抛异常 / false）只算不可达，不向上抛。
Future<String?> firstReachablePlexConnection(
  List<PlexConnection> ordered,
  Future<bool> Function(String uri) probe,
) async {
  for (final PlexConnection c in ordered) {
    try {
      if (await probe(c.uri)) return c.uri;
    } catch (_) {
      // 不可达：试下一条。
    }
  }
  return null;
}

/// PIN 轮询的结局。
enum PlexPinPollOutcome { authorized, expired, cancelled }

/// 轮询 [check] 直到拿到 token / PIN 过期 / 被取消。
///
/// [delay] 与 [now] 是测试注入点（缺省真等待 / 真时钟）。[check] 抛
/// [PlexApiException] 404 视为过期（plex.tv 对过期 PIN 回 404）；其它异常（偶发断网）
/// 不终止轮询，下一轮再试，直到 [timeout]。
Future<({PlexPinPollOutcome outcome, String? token})> pollPlexPin({
  required Future<PlexPin> Function() check,
  required bool Function() isCancelled,
  Duration interval = const Duration(seconds: 2),
  Duration timeout = const Duration(minutes: 10),
  Future<void> Function(Duration)? delay,
  DateTime Function()? now,
}) async {
  final Future<void> Function(Duration) wait = delay ?? Future<void>.delayed;
  final DateTime Function() clock = now ?? DateTime.now;
  final DateTime deadline = clock().add(timeout);
  while (true) {
    if (isCancelled()) {
      return (outcome: PlexPinPollOutcome.cancelled, token: null);
    }
    try {
      final PlexPin pin = await check();
      if (pin.isAuthorized) {
        return (outcome: PlexPinPollOutcome.authorized, token: pin.authToken);
      }
      if (pin.isExpiredAt(clock())) {
        return (outcome: PlexPinPollOutcome.expired, token: null);
      }
    } on PlexApiException catch (e) {
      if (e.statusCode == 404) {
        return (outcome: PlexPinPollOutcome.expired, token: null);
      }
    } catch (_) {
      // 偶发网络失败：下一轮再试。
    }
    if (!clock().isBefore(deadline)) {
      return (outcome: PlexPinPollOutcome.expired, token: null);
    }
    await wait(interval);
  }
}

/// plex.tv 账号 API。
class PlexTvApi {
  PlexTvApi({required this.clientInfo, http.Client? client})
    : _client = client ?? createAppHttpIoClient();

  static const String kPlexTvBase = 'https://plex.tv';
  static const String kClientsBase = 'https://clients.plex.tv';
  static const String kAuthAppBase = 'https://app.plex.tv/auth';

  final PlexClientInfo clientInfo;
  final http.Client _client;

  Map<String, String> _headers([String? token]) => <String, String>{
    'Accept': 'application/json',
    ...clientInfo.headers,
    if (token != null) 'X-Plex-Token': token,
  };

  Future<Object?> _json(String method, Uri uri, {String? token}) async {
    try {
      final http.Request req = http.Request(method, uri);
      req.headers.addAll(_headers(token));
      final http.StreamedResponse streamed = await _client
          .send(req)
          .timeout(PlexApi.kRequestTimeout);
      final http.Response res = await http.Response.fromStream(
        streamed,
      ).timeout(PlexApi.kRequestTimeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw PlexApiException(res.statusCode, uri.path);
      }
      return jsonDecode(utf8.decode(res.bodyBytes));
    } on http.ClientException catch (e) {
      throw Exception(redactCredentialsInText(e.toString()));
    }
  }

  /// 建一个 strong PIN。
  Future<PlexPin> createPin() async => parsePin(
    await _json('POST', Uri.parse('$kPlexTvBase/api/v2/pins?strong=true')),
  );

  /// 查 PIN 状态（授权后带 authToken）。
  Future<PlexPin> checkPin(PlexPin pin) async => parsePin(
    await _json(
      'GET',
      Uri.parse(
        '$kPlexTvBase/api/v2/pins/${pin.id}',
      ).replace(queryParameters: <String, String>{'code': pin.code}),
    ),
  );

  /// 用户在浏览器里打开的授权页。参数在 `#` 片段里（Plex 的约定）。
  String authUrl(PlexPin pin) {
    final String query = Uri(
      queryParameters: <String, String>{
        'clientID': clientInfo.clientIdentifier,
        'code': pin.code,
        'context[device][product]': clientInfo.product,
      },
    ).query;
    return '$kAuthAppBase#?$query';
  }

  Future<PlexTvUser> user(String token) async => parseUser(
    await _json('GET', Uri.parse('$kPlexTvBase/api/v2/user'), token: token),
  );

  /// 账号可访问的服务器（已滤掉播放器 / 其它非 server 资源）。
  Future<List<PlexResource>> resources(String token) async => parseResources(
    await _json(
      'GET',
      Uri.parse('$kClientsBase/api/v2/resources?includeHttps=1&includeRelay=1'),
      token: token,
    ),
  );

  void close() => _client.close();

  // ── 纯 JSON 解析 ────────────────────────────────────────────────────

  static PlexPin parsePin(Object? json) {
    final Map<Object?, Object?> m = json is Map
        ? json
        : const <Object?, Object?>{};
    final Object? id = m['id'];
    final String? token = m['authToken'] as String?;
    return PlexPin(
      id: id is num ? id.toInt() : int.tryParse('$id') ?? 0,
      code: (m['code'] as String?) ?? '',
      authToken: token == null || token.isEmpty ? null : token,
      expiresAt: DateTime.tryParse((m['expiresAt'] as String?) ?? ''),
    );
  }

  static PlexTvUser parseUser(Object? json) {
    final Map<Object?, Object?> m = json is Map
        ? json
        : const <Object?, Object?>{};
    final Object? id = m['id'];
    return PlexTvUser(
      id: id == null ? '' : '$id',
      username:
          (m['username'] as String?) ??
          (m['title'] as String?) ??
          (m['email'] as String?) ??
          '',
    );
  }

  static List<PlexResource> parseResources(Object? json) {
    final List<Object?> list = json is List ? json : const <Object?>[];
    return <PlexResource>[
      for (final Object? raw in list)
        if (raw is Map &&
            ((raw['provides'] as String?) ?? '')
                .split(',')
                .contains('server') &&
            ((raw['clientIdentifier'] as String?) ?? '').isNotEmpty)
          PlexResource(
            name: (raw['name'] as String?) ?? '',
            clientIdentifier: raw['clientIdentifier'] as String,
            accessToken: raw['accessToken'] as String?,
            owned: raw['owned'] == true,
            connections: <PlexConnection>[
              for (final Object? c
                  in (raw['connections'] as List?) ?? const <Object?>[])
                if (c is Map && ((c['uri'] as String?) ?? '').isNotEmpty)
                  PlexConnection(
                    uri: PlexApi.normalizeServerUrl(c['uri'] as String),
                    local: c['local'] == true,
                    relay: c['relay'] == true,
                    ipv6: c['IPv6'] == true,
                  ),
            ],
          ),
    ];
  }
}
