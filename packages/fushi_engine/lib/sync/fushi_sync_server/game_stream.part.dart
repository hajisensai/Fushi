part of '../fushi_sync_server.dart';

extension _FushiSyncServerGameStream on FushiSyncServer {
  Future<shelf.Response> _handleGameStream(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    final FushiRemoteGameStreamService? service = _gameStreamService;
    if (service == null) {
      return shelf.Response.notFound('Game stream off');
    }
    // HTTPS is not optional here. WebRTC's DTLS-SRTP confidentiality rests
    // entirely on the integrity of the signalling channel: over plaintext HTTP
    // an on-path attacker swaps the `a=fingerprint` in the answer and becomes
    // the real peer -- game video, loopback audio, and input injection into the
    // host's game window. The repo already forces HTTPS for the far weaker
    // service-config and profile-transfer endpoints (`sync_state.part.dart`);
    // TLS here is the root of the trust chain, not a hardening nicety. Existing
    // LAN hosts default to plaintext (`applyFirstHostingTlsDefault` only opts in
    // brand-new devices), so this gate is what those users actually hit.
    if (_securityContext == null) {
      return shelf.Response.forbidden('HTTPS required for game stream');
    }
    final String authorization = request.headers['authorization'] ?? '';
    // Control access requires a currently paired device credential; legacy
    // shared WebDAV passwords do not identify the sole authorised controller.
    if (!await _validatePeerAuth(authorization)) return shelf.Response(403);
    // `_validatePeerAuth` only succeeds once it has decoded a password, but that
    // is a cross-file invariant; decode explicitly rather than assert non-null.
    // NOTE: this digest is a deterministic hash of a live credential -- never log it.
    final String? peerPassword = _basicPassword(authorization);
    if (peerPassword == null) return shelf.Response(403);
    final String peerIdentity = sha256
        .convert(utf8.encode(peerPassword))
        .toString();
    return service.handleRequest(
      request,
      method,
      reqPath,
      peerIdentity: peerIdentity,
    );
  }
}
