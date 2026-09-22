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
    final String authorization = request.headers['authorization'] ?? '';
    // Control access requires a currently paired device credential; legacy
    // shared WebDAV passwords do not identify the sole authorised controller.
    if (!await _validatePeerAuth(authorization)) return shelf.Response(403);
    final String peerIdentity = sha256
        .convert(utf8.encode(_basicPassword(authorization)!))
        .toString();
    return service.handleRequest(
      request,
      method,
      reqPath,
      peerIdentity: peerIdentity,
    );
  }
}
