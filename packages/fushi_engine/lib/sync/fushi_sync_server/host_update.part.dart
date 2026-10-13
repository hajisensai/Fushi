part of '../fushi_sync_server.dart';

/// 远程更新域（反馈 Pp8XPyve0N）：`GET/POST /api/host/update`。
///
/// 门禁顺序（每一道拒绝都带 `{"error": code}`，client 据此说清原因）：
///   1. 装配方没接 [FushiSyncServer.hostSelfUpdater] → 404（老 host / 无头服务端）；
///   2. 必须是已配对 peer 的专属 token（共享 token 不收）→ 403 peer_token_required；
///   3. GET：回状态 + 给这个 peer 签一个一次性 nonce；
///   4. POST：平台门 → 用户开关 → 信任区（P2P / 公网拒）→ nonce 核销 → 交给
///      [HostSelfUpdater.startUpdate]。
/// 触发与拒绝都写一条诊断日志。
extension _FushiSyncServerHostUpdate on FushiSyncServer {
  Future<shelf.Response> _handleHostUpdate(
    shelf.Request request,
    String method,
  ) async {
    if (method != 'GET' && method != 'POST') return shelf.Response(405);
    final HostSelfUpdater? updater = hostSelfUpdater;
    if (updater == null) return shelf.Response.notFound('Host update off');
    final String? authorization = request.headers['authorization'];
    if (!await _validatePeerAuth(authorization)) {
      return _hostUpdateDenied(request, HostUpdateDenial.peerTokenRequired);
    }
    // _validatePeerAuth 通过 ⇒ 能解出密码。
    final String peerKey = hostUpdatePeerKey(_basicPassword(authorization!)!);
    if (method == 'GET') {
      final bool refresh = request.url.queryParameters['refresh'] == '1';
      final HostUpdateStatus status = await updater.status(refresh: refresh);
      return _hostUpdateJson(
        status.copyWith(nonce: _hostUpdateNonces.issue(peerKey)),
      );
    }
    final HostUpdateDenial? gate = await _hostUpdateTriggerGate(
      request,
      updater,
      peerKey,
    );
    if (gate != null) return _hostUpdateDenied(request, gate);
    try {
      final HostUpdateStatus status = await updater.startUpdate();
      engineLog.logDiagnostic(
        'HostUpdate',
        'remote update started by ${_remoteAddress(request) ?? '?'} '
            '(${status.currentVersion} -> ${status.latestVersion})',
      );
      return _hostUpdateJson(status);
    } on HostUpdateRejected catch (e) {
      return _hostUpdateDenied(request, e.denial);
    }
  }

  /// POST 的门：返回第一个不满足的条件，全过返回 null。nonce 放最后核销——前面的
  /// 拒绝不该白白烧掉 client 手里那张票。
  Future<HostUpdateDenial?> _hostUpdateTriggerGate(
    shelf.Request request,
    HostSelfUpdater updater,
    String peerKey,
  ) async {
    if (!updater.platformSupported) return HostUpdateDenial.unsupported;
    if (!await updater.isRemoteUpdateAllowed()) {
      return HostUpdateDenial.disabled;
    }
    if (!_isLanPeerRequest(request, _remoteAddress(request))) {
      return HostUpdateDenial.zone;
    }
    final String? nonce = await _readHostUpdateNonce(request);
    if (!_hostUpdateNonces.consume(nonce, peerKey)) {
      return HostUpdateDenial.invalidNonce;
    }
    return null;
  }

  /// 只收 `application/json` 正文里的 `nonce`：浏览器跨站发 JSON 必经 CORS 预检，
  /// 表单 / 简单请求带不进来。
  Future<String?> _readHostUpdateNonce(shelf.Request request) async {
    if (request.mimeType != 'application/json') return null;
    try {
      final Object? decoded = jsonDecode(await request.readAsString());
      if (decoded is! Map) return null;
      final Object? nonce = decoded['nonce'];
      return nonce is String ? nonce : null;
    } on FormatException {
      return null;
    }
  }

  shelf.Response _hostUpdateDenied(
    shelf.Request request,
    HostUpdateDenial denial,
  ) {
    engineLog.logDiagnostic(
      'HostUpdate',
      'denied ${request.method} from ${_remoteAddress(request) ?? '?'}: '
          '${denial.code}',
    );
    return shelf.Response(
      denial.httpStatus,
      body: hostUpdateDenialBody(denial),
      headers: const <String, String>{
        'Content-Type': 'application/json; charset=utf-8',
        'Cache-Control': 'no-store',
      },
    );
  }

  shelf.Response _hostUpdateJson(HostUpdateStatus status) => shelf.Response.ok(
    jsonEncode(status.toJson()),
    headers: const <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
    },
  );
}
