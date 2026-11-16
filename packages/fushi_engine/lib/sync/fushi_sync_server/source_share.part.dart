part of '../fushi_sync_server.dart';

/// 互联「来源共享」端点（协议与门见 `interconnect_source_share.dart` 文件头）。
extension _FushiSyncServerSourceShare on FushiSyncServer {
  /// 本 host 是否在 `/api/capabilities` 声明 [kInterconnectSourceShareFeature]：
  /// 装配了能力且走 HTTPS（明文下端点一律拒，声明了也用不了）。
  bool get _sourceShareAvailable =>
      _securityContext != null && sourceShareHost != null;

  /// GET [kInterconnectSourceSharePath] / [kInterconnectSourceSharePackagePath]。
  ///
  /// 载荷带服务器密码 / API key 与插件包：必须 HTTPS + per-peer token + 「我的设备」+
  /// host 开关开着，没有写方法。拒绝一律带短码 `{error}`，client 据此区分「关着」与
  /// 「不是我的设备」，不当成故障反复重试。
  Future<shelf.Response> _handleInterconnectSourceShare(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    if (method != 'GET') return shelf.Response(405);
    final InterconnectSourceShareHost? host = sourceShareHost;
    if (host == null) {
      return shelf.Response.notFound('Source share capability off');
    }
    if (_securityContext == null) {
      return _sourceShareError(403, 'https_required');
    }
    final String? authorization = request.headers['authorization'];
    if (!await _validatePeerAuth(authorization)) {
      return _sourceShareError(403, 'paired_peer_required');
    }
    if (!await host.isSourceShareEnabled()) {
      return _sourceShareError(403, 'disabled');
    }
    if (!await host.isOwnerDevicePeer(_basicPassword(authorization!)!)) {
      return _sourceShareError(403, 'not_owner_device');
    }
    if (reqPath == kInterconnectSourceSharePath) {
      final InterconnectSourceShareCatalog catalog = await host
          .sourceShareCatalog();
      return shelf.Response.ok(
        jsonEncode(catalog.toJson()),
        headers: const <String, String>{
          'Content-Type': 'application/json; charset=utf-8',
          'Cache-Control': 'no-store',
        },
      );
    }
    final String? kind = request.url.queryParameters['kind'];
    final String? id = request.url.queryParameters['id'];
    if (kind == null || kind.isEmpty || id == null || id.isEmpty) {
      return _sourceShareError(400, 'bad_request');
    }
    final Uint8List? zip = await host.sourceSharePackage(kind, id);
    if (zip == null) return _sourceShareError(404, 'not_shared');
    return shelf.Response.ok(
      zip,
      headers: <String, String>{
        'Content-Type': 'application/zip',
        'Content-Length': '${zip.length}',
        'Cache-Control': 'no-store',
      },
    );
  }
}

shelf.Response _sourceShareError(int status, String code) => shelf.Response(
  status,
  body: jsonEncode(<String, String>{'error': code}),
  headers: const <String, String>{
    'content-type': 'application/json',
    'Cache-Control': 'no-store',
  },
);
