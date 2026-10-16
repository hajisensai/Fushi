/// AnkiConnect 兼容层的 HTTP 外壳（shelf）：Origin 白名单、回环限制、CORS 预检。
///
/// 第六轮审查第 19 条：Fushi API 实际监听所有网卡、没设 key 时一切放行；而 AnkiConnect 的
/// 根路径 POST 用 text/plain 发时不触发预检，任何网页都能经本机浏览器调 addNote。所以：
/// - 请求带 Origin 且不在白名单 → 403（`requestPermission` 例外：回 `{permission: denied}`）；
///   带 Origin 且在白名单 → 响应带对应的 `Access-Control-Allow-Origin`；OPTIONS 预检照此应答。
/// - 没设 Fushi API key 时只接受回环地址来的请求（`fushiIdentify` 例外：只回随机实例 id，
///   供 Fushi 自己的 AnkiConnect 客户端识别「指向了自己」）。
/// - 设了 key 时由 [SrsAnkiConnectHandler] 按 AnkiConnect 语义逐动作校验 body 的 `key`。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shelf/shelf.dart' as shelf;

import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_handler.dart';

/// 默认 Origin 白名单（同 AnkiConnect 的 webCorsOriginList）。含 `http://localhost` 时
/// 还放行 127.0.0.1 的各种写法与浏览器扩展 origin（chrome- / moz- / safari-web-extension://）。
const List<String> kSrsAnkiDefaultCorsOrigins = <String>[
  'http://localhost',
  'http://127.0.0.1',
];

const List<String> _kExtensionOriginPrefixes = <String>[
  'chrome-extension://',
  'moz-extension://',
  'safari-web-extension://',
];

/// [origin] 是否被 [allowList] 放行（`*` = 全部放行，须显式配置）。
bool srsAnkiOriginAllowed(String origin, List<String> allowList) {
  if (allowList.contains('*')) return true;
  if (allowList.contains(origin)) return true;
  if (allowList.contains('http://localhost')) {
    if (origin == 'http://127.0.0.1' ||
        origin == 'https://127.0.0.1' ||
        origin.startsWith('http://127.0.0.1:') ||
        origin.startsWith('http://localhost:')) {
      return true;
    }
    for (final String p in _kExtensionOriginPrefixes) {
      if (origin.startsWith(p) && origin.length > p.length) return true;
    }
  }
  return false;
}

/// shelf 请求是否来自回环地址；拿不到连接信息时按「不是」处理（失败即关闭）。
bool srsAnkiRequestIsLoopback(shelf.Request request) {
  final Object? info = request.context['shelf.io.connection_info'];
  if (info is! HttpConnectionInfo) return false;
  final InternetAddress a = info.remoteAddress;
  if (a.isLoopback) return true;
  final List<int> b = a.rawAddress;
  // IPv4 映射的回环（::ffff:127.x.x.x）。
  return a.type == InternetAddressType.IPv6 &&
      b.length == 16 &&
      b.sublist(0, 10).every((int x) => x == 0) &&
      b[10] == 0xff &&
      b[11] == 0xff &&
      b[12] == 127;
}

class SrsAnkiConnectEndpoint {
  SrsAnkiConnectEndpoint({
    required this.handler,
    List<String> Function()? corsOrigins,
    this.maxBodyBytes = 128 * 1024 * 1024,
  }) : _corsOrigins = corsOrigins;

  final SrsAnkiConnectHandler handler;
  final List<String> Function()? _corsOrigins;
  final int maxBodyBytes;

  List<String> get _origins =>
      _corsOrigins?.call() ?? kSrsAnkiDefaultCorsOrigins;

  static shelf.Response _forbidden(String why, [Map<String, String>? h]) =>
      shelf.Response(
        403,
        body: why,
        headers: <String, String>{
          'content-type': 'text/plain; charset=utf-8',
          ...?h,
        },
      );

  /// 处理一个打到兼容端点（根路径）的请求。
  Future<shelf.Response> handle(shelf.Request request) async {
    final String method = request.method.toUpperCase();
    final String? origin = request.headers['origin'];
    final bool originAllowed =
        origin == null || srsAnkiOriginAllowed(origin, _origins);
    final Map<String, String> cors = <String, String>{
      if (origin != null && originAllowed)
        'Access-Control-Allow-Origin': origin,
      if (originAllowed) 'Access-Control-Allow-Headers': '*',
      'Vary': 'Origin',
    };

    if (method == 'OPTIONS') {
      if (!originAllowed) return _forbidden('Origin not allowed');
      return shelf.Response.ok(
        '',
        headers: <String, String>{
          ...cors,
          'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
          'Access-Control-Max-Age': '600',
          if (request.headers['access-control-request-private-network'] ==
              'true')
            'Access-Control-Allow-Private-Network': 'true',
        },
      );
    }
    if (method != 'POST' && method != 'GET') {
      return shelf.Response(405, body: 'Method Not Allowed', headers: cors);
    }

    final bool loopback = srsAnkiRequestIsLoopback(request);
    final bool keyed = handler.keyConfigured;
    final Uint8List? raw = await _readBody(request);
    if (raw == null) {
      return shelf.Response(413, body: 'Payload Too Large', headers: cors);
    }

    if (raw.isEmpty) {
      if (!originAllowed) return _forbidden('Origin not allowed');
      if (!loopback && !keyed) return _forbidden(_loopbackOnly);
      return shelf.Response.ok(
        'AnkiConnect v.$kSrsAnkiConnectVersion',
        headers: <String, String>{
          ...cors,
          'content-type': 'text/plain; charset=utf-8',
        },
      );
    }

    Map<String, Object?>? body;
    try {
      final Object? decoded = jsonDecode(utf8.decode(raw));
      if (decoded is Map) body = decoded.cast<String, Object?>();
    } on FormatException {
      body = null;
    }
    final Object? action = body?['action'];

    if (!loopback && !keyed && action != 'fushiIdentify') {
      return _forbidden(_loopbackOnly);
    }
    if (!originAllowed) {
      if (action == 'requestPermission') {
        // AnkiConnect：被拒的 origin 也能读到「denied」，以便页面提示用户。
        final Object? v = body?['version'];
        final Map<String, Object?> denied = <String, Object?>{
          'permission': 'denied',
        };
        return _json(
          v is int && v <= 4
              ? denied
              : <String, Object?>{'result': denied, 'error': null},
          <String, String>{
            'Access-Control-Allow-Origin': origin,
            'Vary': 'Origin',
          },
        );
      }
      return _forbidden('Origin not allowed');
    }
    if (body == null || action is! String || action.isEmpty) {
      return _json(<String, Object?>{
        'result': null,
        'error': body == null
            ? 'request body must be a JSON object'
            : 'action is required',
      }, cors);
    }

    final Object? result = await handler.handle(
      body,
      caller: SrsAnkiConnectCaller(
        originAllowed: true,
        headerKey: _headerKey(request),
        sourceUrl: _referer(request),
      ),
    );
    return _json(result, cors);
  }

  static const String _loopbackOnly =
      'AnkiConnect compatibility endpoint only accepts loopback requests '
      'when no Fushi API key is set';

  static shelf.Response _json(Object? body, Map<String, String> headers) =>
      shelf.Response.ok(
        jsonEncode(body),
        headers: <String, String>{
          ...headers,
          'content-type': 'application/json; charset=utf-8',
        },
      );

  Future<Uint8List?> _readBody(shelf.Request request) async {
    final BytesBuilder out = BytesBuilder(copy: false);
    await for (final List<int> chunk in request.read()) {
      out.add(chunk);
      if (out.length > maxBodyBytes) return null;
    }
    return out.takeBytes();
  }

  static String? _headerKey(shelf.Request request) {
    final String? x = request.headers['x-api-key'];
    if (x != null && x.isNotEmpty) return x;
    final String? auth = request.headers['authorization'];
    const String bearer = 'bearer ';
    if (auth != null &&
        auth.length > bearer.length &&
        auth.toLowerCase().startsWith(bearer)) {
      return auth.substring(bearer.length);
    }
    return null;
  }

  static String? _referer(shelf.Request request) {
    final String? r = request.headers['referer'];
    if (r == null) return null;
    final Uri? u = Uri.tryParse(r);
    if (u == null || (u.scheme != 'http' && u.scheme != 'https')) return null;
    return r;
  }
}
