part of '../fushi_sync_server.dart';

/// 互联「插件中继」端点（协议与门见 `interconnect_plugin_relay.dart` 文件头）。
extension _FushiSyncServerPluginRelay on FushiSyncServer {
  /// 本 host 是否在 `/api/capabilities` 声明 [kInterconnectPluginRelayFeature]：装配了且走
  /// HTTPS（明文下端点一律拒，声明了也用不了）。
  bool get _pluginRelayAvailable =>
      _securityContext != null && pluginRelayHost != null;

  /// 已认证端点的门（与来源共享同一组，顺序也相同）。通过返回 null，否则返回拒绝响应。
  Future<shelf.Response?> _pluginRelayGate(
    InterconnectPluginRelayHost host,
    String? authorization,
  ) async {
    if (_securityContext == null) {
      return _pluginRelayError(403, 'https_required');
    }
    if (!await _validatePeerAuth(authorization)) {
      return _pluginRelayError(403, 'paired_peer_required');
    }
    if (!await host.isPluginRelayEnabled()) {
      return _pluginRelayError(403, 'disabled');
    }
    if (!await host.isOwnerDevicePeer(_basicPassword(authorization!)!)) {
      return _pluginRelayError(403, 'not_owner_device');
    }
    return null;
  }

  /// `/api/interconnect/plugin-relay` 及其子路径（流票路径除外）。
  Future<shelf.Response> _handleInterconnectPluginRelay(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    final InterconnectPluginRelayHost? host = pluginRelayHost;
    if (host == null) return shelf.Response.notFound('Plugin relay off');
    if (reqPath.startsWith(kInterconnectPluginRelayStreamPrefix)) {
      return _handlePluginRelayStream(host, request, method, reqPath);
    }
    final bool catalog = reqPath == kInterconnectPluginRelayPath;
    if (!catalog &&
        reqPath != kInterconnectPluginRelayInvokePath &&
        reqPath != kInterconnectPluginRelayCoversPath &&
        reqPath != kInterconnectPluginRelayMediaPath) {
      return shelf.Response.notFound('Unknown plugin relay route');
    }
    if (method != (catalog ? 'GET' : 'POST')) return shelf.Response(405);
    final String? authorization = request.headers['authorization'];
    final shelf.Response? refused = await _pluginRelayGate(host, authorization);
    if (refused != null) return refused;
    if (catalog) {
      return _pluginRelayJson(<String, Object?>{
        'plugins': await host.pluginRelayCatalog(),
      });
    }
    final Map<String, Object?> body;
    try {
      final Object? decoded = jsonDecode(await readBoundedBodyString(request));
      if (decoded is! Map) throw const FormatException('object body required');
      body = decoded.cast<String, Object?>();
    } on FormatException {
      return _pluginRelayError(400, kPluginRelayBadRequest);
    }
    final Object? plugin = body['plugin'];
    if (plugin is! String || plugin.isEmpty) {
      return _pluginRelayError(400, kPluginRelayBadRequest);
    }
    try {
      if (reqPath == kInterconnectPluginRelayInvokePath) {
        final Object? m = body['method'];
        final Object args = body['args'] ?? const <String, Object?>{};
        if (m is! String || m.isEmpty || args is! Map) {
          return _pluginRelayError(400, kPluginRelayBadRequest);
        }
        final Object? value = await host.pluginRelayInvoke(
          plugin,
          m,
          args.cast<String, Object?>(),
        );
        return _pluginRelayJson(<String, Object?>{'value': value});
      }
      if (reqPath == kInterconnectPluginRelayCoversPath) {
        final Object? urls = body['urls'];
        if (urls is! List || urls.length > 500) {
          return _pluginRelayError(400, kPluginRelayBadRequest);
        }
        final Map<String, String> ok = await host.pluginRelayCheckCovers(
          plugin,
          <String>[
            for (final Object? u in urls)
              if (u is String) u,
          ],
        );
        return _pluginRelayJson(<String, Object?>{'covers': ok});
      }
      final Object? url = body['url'];
      final Object headers = body['headers'] ?? const <String, Object?>{};
      if (url is! String || url.isEmpty || headers is! Map) {
        return _pluginRelayError(400, kPluginRelayBadRequest);
      }
      final InterconnectPluginRelayMediaTarget target = await host
          .pluginRelayResolveMedia(plugin, url, <String, String>{
            for (final MapEntry<Object?, Object?> e in headers.entries)
              if (e.key is String && e.value is String)
                e.key! as String: e.value! as String,
          });
      final String ticket = _pluginRelayTickets.issue(target, authorization!);
      return _pluginRelayJson(<String, Object?>{
        'path': '$kInterconnectPluginRelayStreamPrefix$ticket',
      });
    } on InterconnectPluginRelayError catch (e) {
      return _pluginRelayError(
        e.code == kPluginRelayNotAvailable ? 404 : 422,
        e.code,
        e.message,
      );
    }
  }

  /// GET / HEAD 流票：免 Basic（播放器带不了 Authorization），门是流票 + 签发凭据的现查。
  Future<shelf.Response> _handlePluginRelayStream(
    InterconnectPluginRelayHost host,
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    if (method != 'GET' && method != 'HEAD') return shelf.Response(405);
    final String ticket = reqPath.substring(
      kInterconnectPluginRelayStreamPrefix.length,
    );
    final ({InterconnectPluginRelayMediaTarget target, String authorization})?
    entry = ticket.isEmpty || ticket.contains('/')
        ? null
        : _pluginRelayTickets.lookup(ticket);
    if (entry == null) return shelf.Response.notFound('Unknown stream ticket');
    // 签发之后凭据被吊销、不再是「我的设备」或 host 关了开关：票一并失效。
    if (await _pluginRelayGate(host, entry.authorization) != null) {
      return shelf.Response.forbidden('Stream ticket revoked');
    }
    final InterconnectPluginRelayUpstream upstream;
    try {
      upstream = await host.pluginRelayOpenMedia(
        entry.target,
        range: request.headers['range'],
        head: method == 'HEAD',
      );
    } on InterconnectPluginRelayError catch (e) {
      return _pluginRelayError(502, e.code, e.message);
    }
    return shelf.Response(
      upstream.statusCode,
      body: method == 'HEAD' ? null : upstream.body,
      headers: <String, String>{
        ...upstream.headers,
        'Cache-Control': 'no-store',
      },
      // 媒体流不进 gzip / 不缓冲：按块直接写给播放器。
      context: const <String, Object>{'shelf.io.buffer_output': false},
    );
  }
}

/// 是否为插件中继的流票路径（免 Basic 路由表用，handler 自己校验流票）。
bool _isPluginRelayStreamPath(String path) =>
    path.startsWith(kInterconnectPluginRelayStreamPrefix) &&
    path.length > kInterconnectPluginRelayStreamPrefix.length;

shelf.Response _pluginRelayJson(Map<String, Object?> body) => shelf.Response.ok(
  jsonEncode(body),
  headers: const <String, String>{
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
  },
);

shelf.Response _pluginRelayError(int status, String code, [String? message]) =>
    shelf.Response(
      status,
      body: jsonEncode(<String, String>{'error': code, 'message': ?message}),
      headers: const <String, String>{
        'content-type': 'application/json',
        'Cache-Control': 'no-store',
      },
    );
