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
    shelf.Request routed = request;
    if (method == 'POST' &&
        (reqPath == '/api/game-stream/mine' || reqPath.endsWith('/mine'))) {
      final shelf.Request? rewritten = await _resolveGameStreamMineAudio(
        request,
      );
      if (rewritten == null) {
        return shelf.Response(413, body: 'Game-stream mine body too large');
      }
      routed = rewritten;
    }
    return service.handleRequest(
      routed,
      method,
      reqPath,
      peerIdentity: peerIdentity,
    );
  }

  /// The receiver's popup resolves word audio on the phone: a pinned host
  /// token materialized into a phone-local file, a host token URL, or an
  /// external http(s) source. Only the last is usable on the host as-is, so
  /// the others are resolved again here (token bytes first, then the host's
  /// own audio sources by expression/reading). An unresolvable reference is
  /// dropped instead of letting the host read a path the phone named.
  /// Returns null when the body exceeds the mine size limit.
  Future<shelf.Request?> _resolveGameStreamMineAudio(
    shelf.Request request,
  ) async {
    const int maxBytes = 8 * 1024 * 1024;
    // BytesBuilder 按字节存；List<int>.addAll 每字节占一个 8 字节槽，8 MiB 的体
    // 会吃掉 64 MiB。
    final BytesBuilder bytes = BytesBuilder(copy: false);
    await for (final List<int> chunk in request.read()) {
      if (bytes.length + chunk.length > maxBytes) return null;
      bytes.add(chunk);
    }
    final String raw = utf8.decode(bytes.takeBytes(), allowMalformed: true);
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      decoded = null;
    }
    final Object? fields = decoded is Map ? decoded['fields'] : null;
    final Object? audio = fields is Map ? fields['audio'] : null;
    if (decoded is! Map || fields is! Map || audio is! String) {
      return request.change(body: raw);
    }
    final String? tokenId = remoteAudioTokenIdFromRef(audio);
    final bool usable =
        tokenId == null &&
        (audio.startsWith('https://') ||
            audio.startsWith('http://') ||
            audio.startsWith('data:audio/'));
    if (audio.isEmpty || usable) return request.change(body: raw);
    final String expression = fields['expression']?.toString() ?? '';
    final String reading = fields['reading']?.toString() ?? '';
    String? resolved;
    try {
      if (tokenId != null) {
        resolved = await _lookupRoutes.resolveMineWordAudio(
          tokenId,
          expression: expression,
          reading: reading,
        );
      } else if (expression.trim().isNotEmpty) {
        final RemoteAudioLookup? found = await _remoteLookupService
            ?.lookupAudio(expression: expression, reading: reading);
        if (found != null) resolved = remoteAudioLookupToDataUri(found);
      }
    } catch (error, stack) {
      engineLog.log('GameStream.mineAudio', error, stack);
    }
    final Map<String, dynamic> body = Map<String, dynamic>.from(decoded);
    body['fields'] = <String, dynamic>{
      ...Map<String, dynamic>.from(fields),
      'audio': resolved ?? '',
    };
    return request.change(body: jsonEncode(body));
  }
}
