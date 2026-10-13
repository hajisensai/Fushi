import 'dart:async';
import 'dart:convert';

import 'package:fushi/src/sync/interconnect_peer_addresses.dart'
    show interconnectPersistedUrl;
import 'package:fushi/src/sync/interconnect_post_transport.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:http/http.dart' as http;
import 'package:fushi_engine/sync/tls/fushi_pinning_http.dart';

/// A video remote failure. [message] is the host's machine-readable error code
/// (or a client-side code such as [VideoRemoteError.unreachableCode]); the page
/// maps it to localized text. [statusCode] is null when no HTTP response
/// arrived, i.e. the request may or may not have reached the host.
class VideoRemoteError implements Exception {
  const VideoRemoteError(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  /// No candidate address of the selected host produced an HTTP response.
  static const String unreachableCode = 'unreachable';

  /// Every reachable address presented a certificate other than the pinned one
  /// (or was plaintext while the host is pinned); nothing was sent.
  static const String certificateMismatchCode = 'certificate_mismatch';
  @override
  String toString() => message;
}

/// All operations are bound to one paired host, including its credential and pin.
///
/// When [peer] carries a certificate fingerprint, every request must go through
/// a TLS client pinned to exactly that fingerprint. Addresses of the same host
/// with another pin, or plaintext addresses (except this process's own P2P
/// forwarding port, whose identity is the tunnel's node key), are refused
/// before any byte is written, so a learned or manually grouped address can
/// never downgrade the pin.
class VideoRemoteClient {
  VideoRemoteClient({
    required SyncRepository repository,
    required this.peer,
    http.Client? httpClient,
    http.Client Function(String expectedFingerprint)? pinnedClientFactory,
  }) : _repository = repository,
       _injected = httpClient,
       _pinnedFactory = pinnedClientFactory ?? _defaultPinnedClient;
  final FushiClientUrl peer;
  final SyncRepository _repository;
  final http.Client? _injected;
  final http.Client Function(String expectedFingerprint) _pinnedFactory;
  final List<http.Client> _clients = <http.Client>[];
  final Map<String, http.Client> _pinned = <String, http.Client>{};
  InterconnectPostTransport? _current;
  int _pinRefusals = 0;

  static http.Client _defaultPinnedClient(String expectedFingerprint) =>
      createPinnedHttpPackageClient(
        expectedFingerprint: expectedFingerprint,
        connectionTimeout: kInterconnectConnectTimeout,
      );

  String? get _expectedPin {
    final String? pin = peer.fingerprintSha256;
    return pin == null || pin.isEmpty ? null : pin;
  }

  /// Wraps a plaintext client so it refuses non-tunnel requests to a pinned host.
  http.Client guardPlaintext(http.Client inner) =>
      _PinGuardClient(inner, _plaintextAllowed, () => _pinRefusals++);

  /// Pinned-client factory that only builds clients for the peer's own pin.
  http.Client Function(String expectedFingerprint) guardPinnedFactory(
    http.Client Function(String expectedFingerprint) inner,
  ) => (String pin) {
    final String? expected = _expectedPin;
    if (expected != null && !fingerprintEquals(pin, expected)) {
      return _PinGuardClient(null, (_) => false, () => _pinRefusals++);
    }
    return inner(pin);
  };

  /// The factory used for this client's own transport, also suitable for a
  /// companion client (dictionary lookup) bound to the same host.
  http.Client Function(String expectedFingerprint) get pinnedClientFactory =>
      guardPinnedFactory(_pinnedFactory);

  bool _plaintextAllowed(Uri uri) {
    if (_expectedPin == null) return true;
    // The P2P forwarding port is loopback plaintext; the tunnel itself
    // authenticates the host node key learned through the pinned channel.
    return interconnectPersistedUrl(uri.origin).startsWith('p2p://');
  }

  InterconnectPostTransport get _transport =>
      _current ??= InterconnectPostTransport(
        repo: _repository,
        httpClient: _own(guardPlaintext(_injected ?? http.Client())),
        pinnedClientFactory: (String pin) => _BorrowedRemoteClient(
          _pinned.putIfAbsent(pin, () => _own(pinnedClientFactory(pin))),
        ),
      );
  http.Client _own(http.Client client) {
    late final _OwnedRemoteClient owned;
    owned = _OwnedRemoteClient(client, () => _clients.remove(owned));
    _clients.add(owned);
    return owned;
  }

  void cancelPending() {
    for (final http.Client client in List<http.Client>.from(_clients)) {
      client.close();
    }
    _clients.clear();
    _pinned.clear();
    _current = null;
  }

  int _sequence = 0;
  String requestId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
  Future<Map<String, dynamic>> call(
    String operation, [
    Map<String, dynamic> body = const <String, dynamic>{},
  ]) async {
    VideoRemoteError? rejection;
    final int refusalsBefore = _pinRefusals;
    final InterconnectPostOutcome response = await _transport.post(
      path: '/api/video-remote/$operation',
      body: body,
      timeout: const Duration(seconds: 35),
      onlyCandidate: peer,
      authErrorMessage: 'Video remote authentication rejected',
      onRejectedResponse: (int status, Map<String, dynamic>? json) {
        rejection = VideoRemoteError(
          (json?['error'] ?? json?['message'] ?? 'HTTP $status').toString(),
          statusCode: status,
        );
      },
    );
    if (response.json != null) return response.json!;
    if (rejection != null) throw rejection!;
    if (_pinRefusals > refusalsBefore && response.allUnreachable) {
      throw const VideoRemoteError(VideoRemoteError.certificateMismatchCode);
    }
    throw const VideoRemoteError(VideoRemoteError.unreachableCode);
  }

  Future<Map<String, dynamic>> snapshot() => call('snapshot');
  Future<Map<String, dynamic>> events(int revision) => call(
    'events',
    <String, dynamic>{'afterRevision': revision, 'waitMs': 25000},
  );
  Future<Map<String, dynamic>> disconnect() =>
      call('disconnect', <String, dynamic>{'requestId': requestId()});

  /// Whether the selected host declares `videoRemoteControlV1` on
  /// `GET /api/capabilities`. Null when no address answered (unknown).
  Future<bool?> supportsVideoRemote({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final String? fallbackToken = await _repository.getFushiClientToken();
    final List<FushiClientUrl> candidates =
        (await _repository.getFushiClientUrls()).where((FushiClientUrl u) {
          if (!u.enabled) return false;
          final bool sameHost = peer.hostId != null
              ? u.hostId == peer.hostId
              : u.url == peer.url &&
                    u.fingerprintSha256 == peer.fingerprintSha256;
          return sameHost &&
              interconnectTokenFor(u, fallbackToken) == peer.token;
        }).toList();
    for (final FushiClientUrl candidate in candidates) {
      final Uri? uri = interconnectEndpointUri(
        candidate.url,
        '/api/capabilities',
      );
      final String? token = interconnectTokenFor(candidate, fallbackToken);
      if (uri == null || token == null) continue;
      final String? pin = candidate.fingerprintSha256;
      final bool usePinned =
          uri.isScheme('https') && pin != null && pin.isNotEmpty;
      final http.Client client = usePinned
          ? pinnedClientFactory(pin)
          : guardPlaintext(_injected ?? http.Client());
      try {
        final http.Response response = await client
            .get(
              uri,
              headers: <String, String>{
                'Authorization':
                    'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
              },
            )
            .timeout(timeout);
        if (response.statusCode != 200) continue;
        final Object? decoded = jsonDecode(utf8.decode(response.bodyBytes));
        return decoded is Map && decoded['videoRemoteControlV1'] == true;
      } catch (_) {
        continue;
      } finally {
        if (usePinned || _injected == null) client.close();
      }
    }
    return null;
  }

  final Map<String, _SubtitleChunks> _subtitleCache =
      <String, _SubtitleChunks>{};

  /// Cached subtitle pages keyed by (sessionId, subtitleVersion). A version is
  /// immutable on the host, so loaded chunks are reused across reconnects and
  /// track flips; an interrupted load resumes from the first missing chunk.
  /// Returns null when [active] turns false before the list is complete.
  Future<List<Map<String, dynamic>>?> subtitles({
    required String sessionId,
    required int subtitleVersion,
    required int expectedTotal,
    required bool Function() active,
    int chunkSize = 200,
  }) async {
    final String key = '$sessionId|$subtitleVersion';
    final _SubtitleChunks cache =
        _subtitleCache.remove(key) ?? _SubtitleChunks(expectedTotal);
    // Keep the most recently used versions last; evict the oldest beyond 3.
    _subtitleCache[key] = cache;
    while (_subtitleCache.length > 3) {
      _subtitleCache.remove(_subtitleCache.keys.first);
    }
    int offset = 0;
    while (offset < cache.total) {
      List<Map<String, dynamic>>? chunk = cache.chunks[offset];
      if (chunk == null) {
        if (!active()) return null;
        final Map<String, dynamic> page =
            await call('subtitles', <String, dynamic>{
              'sessionId': sessionId,
              'subtitleVersion': subtitleVersion,
              'offset': offset,
              'limit': chunkSize,
            });
        chunk = <Map<String, dynamic>>[
          for (final dynamic e in page['cues'] as List? ?? <dynamic>[])
            Map<String, dynamic>.from(e as Map),
        ];
        cache.total = (page['total'] as num?)?.toInt() ?? cache.total;
        if (chunk.isEmpty) {
          cache.total = offset;
          break;
        }
        cache.chunks[offset] = chunk;
      }
      offset += chunk.length;
    }
    final List<Map<String, dynamic>> cues = <Map<String, dynamic>>[];
    while (cues.length < cache.total) {
      final List<Map<String, dynamic>>? chunk = cache.chunks[cues.length];
      if (chunk == null) break;
      cues.addAll(chunk);
    }
    return cues;
  }
}

class _SubtitleChunks {
  _SubtitleChunks(this.total);
  int total;
  final Map<int, List<Map<String, dynamic>>> chunks =
      <int, List<Map<String, dynamic>>>{};
}

/// Refuses requests [allowed] rejects; the refusal surfaces as a transport
/// failure, so nothing reaches the network.
class _PinGuardClient extends http.BaseClient {
  _PinGuardClient(this.inner, this.allowed, this.onRefused);
  final http.Client? inner;
  final bool Function(Uri uri) allowed;
  final void Function() onRefused;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final http.Client? client = inner;
    if (client == null || !allowed(request.url)) {
      onRefused();
      return Future<http.StreamedResponse>.error(const VideoRemotePinRefused());
    }
    return client.send(request);
  }

  @override
  void close() => inner?.close();
}

/// A request was refused locally because it would bypass the host's pin.
class VideoRemotePinRefused implements Exception {
  const VideoRemotePinRefused();
  @override
  String toString() => VideoRemoteError.certificateMismatchCode;
}

class _BorrowedRemoteClient extends http.BaseClient {
  _BorrowedRemoteClient(this.inner);
  final http.Client inner;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      inner.send(request);
  @override
  void close() {}
}

class _OwnedRemoteClient extends http.BaseClient {
  _OwnedRemoteClient(this.inner, this.onClosed);
  final http.Client inner;
  final void Function() onClosed;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      inner.send(request);
  @override
  void close() {
    inner.close();
    onClosed();
  }
}
