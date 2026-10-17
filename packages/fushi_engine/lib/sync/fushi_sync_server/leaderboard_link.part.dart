part of '../fushi_sync_server.dart';

/// 「跟随已配对设备自动登录 Fushi 账户」端点（协议与门见
/// `interconnect_leaderboard_link.dart` 文件头）。
extension _FushiSyncServerLeaderboardLink on FushiSyncServer {
  /// 本 host 是否在 `/api/capabilities` 声明 [kInterconnectLeaderboardLinkCapability]：
  /// 装配了能力且走 HTTPS（明文下端点一律拒，声明了也用不了）。
  bool get _leaderboardLinkAvailable =>
      _securityContext != null && leaderboardLinkHost != null;

  /// POST [kInterconnectLeaderboardLinkPath] {pubkey, time, proof}。
  Future<shelf.Response> _handleInterconnectLeaderboardLink(
    shelf.Request request,
    String method,
  ) async {
    if (method != 'POST') return shelf.Response(405);
    if (_securityContext == null) {
      return _leaderboardLinkError(403, 'https_required');
    }
    final String? authorization = request.headers['authorization'];
    if (!await _validatePeerAuth(authorization)) {
      return _leaderboardLinkError(403, 'paired_peer_required');
    }
    final InterconnectLeaderboardLinkHost? host = leaderboardLinkHost;
    if (host == null) {
      return shelf.Response.notFound('Leaderboard device link capability off');
    }
    if (!await host.isInterconnectLeaderboardLinkEnabled()) {
      return _leaderboardLinkError(
        403,
        InterconnectLeaderboardLinkError.disabled,
      );
    }
    // 只认 host 主人标记过「我的设备」的 peer（_validatePeerAuth 已保证凭据是 per-peer token）。
    if (!await host.isOwnerDevicePeer(_basicPassword(authorization!)!)) {
      return _leaderboardLinkError(
        403,
        InterconnectLeaderboardLinkError.notOwnerDevice,
      );
    }
    final BytesBuilder bytes = BytesBuilder(copy: false);
    await for (final List<int> chunk in request.read()) {
      bytes.add(chunk);
      if (bytes.length > kInterconnectLeaderboardLinkMaxBody) {
        return shelf.Response(413);
      }
    }
    final LeaderboardDeviceLinkRequest link;
    try {
      final Object? decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      link = LeaderboardDeviceLinkRequest.fromJson(decoded);
    } on FormatException {
      return _leaderboardLinkError(
        400,
        InterconnectLeaderboardLinkError.badRequest,
      );
    }
    // 本地预检持有证明：伪造请求不必消耗服务端的限流额度。
    if (!link.verifyProof()) {
      return _leaderboardLinkError(
        400,
        InterconnectLeaderboardLinkError.badRequest,
      );
    }
    try {
      final InterconnectLeaderboardLinkResult result = await host
          .linkLeaderboardDevice(link);
      return jsonResponse(result.toJson());
    } on InterconnectLeaderboardLinkException catch (e) {
      return _leaderboardLinkError(e.status, e.code);
    }
  }
}

shelf.Response _leaderboardLinkError(int status, String code) => shelf.Response(
  status,
  body: jsonEncode(<String, String>{'error': code}),
  headers: const <String, String>{
    'content-type': 'application/json',
    'Cache-Control': 'no-store',
  },
);
