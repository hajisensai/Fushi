part of '../fushi_sync_server.dart';

/// 统一流票的三条路由（设计 docs/specs/2026-11-23-interconnect-music-library-design.md §3.5 / §4.3）：
///
/// - `POST /api/library/media/streamurl` `{kind, id}` → `{url, ticket}`（Basic）；
/// - `GET|HEAD /api/library/media/stream?token=`（免 Basic，见 auth.part.dart `_kPublicRoutes`）；
/// - `POST /api/library/media/streamrelease?ticket=` → 204（Basic，幂等）。
///
/// 视频不经这里签发（要带转码档 / 集号 / 蓝光段表），仍走 `/api/library/videos/<id>/streamurl` 老路径，
/// 但票在同一张 [LibraryMediaStreams] 表里，吊销 / 释放 / TTL / 上限同一套。
bool isLibraryMediaStreamRoute(String path) =>
    path == kLibraryMediaStreamUrlPath ||
    path == kLibraryMediaStreamPath ||
    path == kLibraryMediaStreamReleasePath;

bool _isLibraryMediaStreamPath(String path) => path == kLibraryMediaStreamPath;

extension _MediaStreamsDomain on FushiSyncServer {
  /// 把已过鉴权的请求打包给模块：凭据指纹、已配对身份一次算好。
  InterconnectRequest _interconnectRequest(
    shelf.Request request,
    String reqPath,
  ) {
    final String? authorization = request.headers['authorization'];
    final String? password = authorization == null
        ? null
        : _basicPassword(authorization);
    return InterconnectRequest(
      raw: request,
      path: reqPath,
      credentialFingerprint: password == null
          ? null
          : _credentialFingerprint(password),
      basicPassword: password,
      isPairedPeer: () => _validatePeerAuth(authorization),
      hostId: hostId,
      streams: _mediaStreams,
    );
  }

  Future<shelf.Response> _handleLibraryMediaStreams(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    if (reqPath == kLibraryMediaStreamPath) {
      if (method != 'GET' && method != 'HEAD') return shelf.Response(405);
      return _serveLibraryMediaStream(request);
    }
    if (reqPath == kLibraryMediaStreamUrlPath) {
      if (method != 'POST') return shelf.Response(405);
      return _issueLibraryMediaStream(request);
    }
    // streamrelease
    if (method != 'POST') return shelf.Response(405);
    final String? ticket = request.url.queryParameters['ticket'];
    if (ticket == null || ticket.isEmpty) {
      return shelf.Response(400, body: 'Missing ticket');
    }
    final LibraryMediaGrant? grant = _mediaStreams[ticket];
    // 只有签发者能释放自己的票（票值本身就是秘密，这是多一道门）；视频票走视频的老释放路径，
    // 那里要连带取消转码工作。票已不在 → 幂等 204。
    if (grant != null &&
        grant.kind != LibraryMediaStreamKind.video &&
        grant.issuer == _requestCredentialFingerprint(request)) {
      _mediaStreams.release(kind: grant.kind, id: grant.id, ticket: ticket);
    }
    return shelf.Response(204);
  }

  Future<shelf.Response> _issueLibraryMediaStream(shelf.Request request) async {
    final Object? body;
    try {
      body = jsonDecode(await request.readAsString());
    } on FormatException {
      return shelf.Response(400, body: 'Invalid JSON');
    }
    if (body is! Map<String, dynamic>) {
      return shelf.Response(400, body: 'Invalid JSON');
    }
    final LibraryMediaStreamKind? kind = LibraryMediaStreamKind.fromWire(
      body['kind'] as String?,
    );
    final Object? id = body['id'];
    if (kind == null || id is! String || id.isEmpty) {
      return shelf.Response(400, body: 'Missing kind / id');
    }
    final LibraryMediaFileResolver? resolver = _mediaStreams.resolverFor(kind);
    if (resolver == null) {
      return shelf.Response.notFound('Stream kind not offered');
    }
    final File? file = await resolver(id);
    if (file == null) return shelf.Response.notFound('Media not found');
    // BUG-4393：票记签发凭据，取流时对照当前快照（吊销即连带作废）。
    final String? issuer = _requestCredentialFingerprint(request);
    if (issuer == null) return shelf.Response(401);
    final String token = _mediaStreams.issue(
      kind: kind,
      id: id,
      issuer: issuer,
    );
    final Uri url = request.requestedUri.replace(
      path: kLibraryMediaStreamPath,
      queryParameters: <String, String>{'token': token},
    );
    return jsonResponse(<String, dynamic>{
      'url': url.toString(),
      'ticket': token,
    });
  }

  Future<shelf.Response> _serveLibraryMediaStream(shelf.Request request) async {
    _mediaStreams.prune();
    final String? token = request.url.queryParameters['token'];
    if (token == null || token.isEmpty) {
      return shelf.Response(
        401,
        body: 'Missing token',
        headers: <String, String>{'Content-Type': 'text/plain'},
      );
    }
    final LibraryMediaGrant? grant = _mediaStreams[token];
    final LibraryMediaFileResolver? resolver = grant == null
        ? null
        : _mediaStreams.resolverFor(grant.kind);
    if (grant == null || resolver == null) {
      return shelf.Response(
        403,
        body: 'Invalid or expired token',
        headers: <String, String>{'Content-Type': 'text/plain'},
      );
    }
    if (!await _issuerStillValid(grant.issuer)) {
      _mediaStreams.drop(token);
      return shelf.Response(
        403,
        body: 'Token revoked',
        headers: <String, String>{'Content-Type': 'text/plain'},
      );
    }
    // 只认票上的 id，不认 URL 里的任何东西。
    final File? file = await resolver(grant.id);
    if (file == null) return shelf.Response.notFound('Media not found');
    final String etag;
    try {
      etag = await videoFileEtag(file);
    } on FileSystemException {
      return shelf.Response.notFound('Media not found');
    }
    // 播放器的盲 Range（seek）不带 If-Range，照常 206；原样直出，不转码（bit-perfect）。
    return serveFileWithRange(
      file,
      request,
      etag: etag,
      ifRangeRequired: false,
    );
  }
}
