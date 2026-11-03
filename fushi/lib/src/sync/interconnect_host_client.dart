import 'dart:async';
import 'dart:convert';

import 'package:fushi/src/sync/interconnect_peer_addresses.dart'
    show interconnectPersistedUrl;
import 'package:fushi/src/sync/interconnect_post_transport.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:http/http.dart' as http;
import 'package:fushi_engine/sync/tls/fushi_pinning_http.dart';

/// A failure talking to the selected host. [message] is the host's
/// machine-readable error code (or a client-side code such as
/// [InterconnectHostError.unreachableCode]); pages map it to localized text.
/// [statusCode] is null when no HTTP response arrived, i.e. the request may or
/// may not have reached the host.
class InterconnectHostError implements Exception {
  const InterconnectHostError(this.message, {this.statusCode});
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

/// A request was refused locally because it would bypass the host's pin.
class InterconnectPinRefused implements Exception {
  const InterconnectPinRefused();
  @override
  String toString() => InterconnectHostError.certificateMismatchCode;
}

/// Requests bound to one paired host (video remote control, SRS remote review),
/// including its credential and pin.
///
/// When [peer] carries a certificate fingerprint, every request must go through
/// a TLS client pinned to exactly that fingerprint. Addresses of the same host
/// with another pin, or plaintext addresses (except this process's own P2P
/// forwarding port, whose identity is the tunnel's node key), are refused
/// before any byte is written, so a learned or manually grouped address can
/// never downgrade the pin.
class InterconnectHostClient {
  InterconnectHostClient({
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

  /// `POST` [body] as JSON to [path] on the first address of the selected host
  /// that answers. A rejection carries the host's `error` / `message` code.
  Future<Map<String, dynamic>> postJson(
    String path, {
    Map<String, dynamic> body = const <String, dynamic>{},
    Duration timeout = const Duration(seconds: 35),
    required String authErrorMessage,
  }) async {
    InterconnectHostError? rejection;
    final int refusalsBefore = _pinRefusals;
    final InterconnectPostOutcome response = await _transport.post(
      path: path,
      body: body,
      timeout: timeout,
      onlyCandidate: peer,
      authErrorMessage: authErrorMessage,
      onRejectedResponse: (int status, Map<String, dynamic>? json) {
        rejection = InterconnectHostError(
          (json?['error'] ?? json?['message'] ?? 'HTTP $status').toString(),
          statusCode: status,
        );
      },
    );
    if (response.json != null) return response.json!;
    if (rejection != null) throw rejection!;
    if (_pinRefusals > refusalsBefore && response.allUnreachable) {
      throw const InterconnectHostError(
        InterconnectHostError.certificateMismatchCode,
      );
    }
    throw const InterconnectHostError(InterconnectHostError.unreachableCode);
  }

  /// Whether the selected host declares [capability] on
  /// `GET /api/capabilities`. Null when no address answered (unknown).
  Future<bool?> declaresCapability(
    String capability, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final http.Response? response = await getFromHost(
      '/api/capabilities',
      timeout: timeout,
    );
    if (response == null) return null;
    try {
      final Object? decoded = jsonDecode(utf8.decode(response.bodyBytes));
      return decoded is Map && decoded[capability] == true;
    } catch (_) {
      return null;
    }
  }

  /// `GET` [path] on the first address of the selected host that answers 200
  /// (same host, credential and pin rules as [postJson]). Null when none did.
  Future<http.Response?> getFromHost(
    String path, {
    required Duration timeout,
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
      final Uri? uri = interconnectEndpointUri(candidate.url, path);
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
        // 404 is the host's answer (e.g. no cover), not a bad address: asking
        // its other addresses would get the same answer, each after a timeout.
        if (response.statusCode == 404) return null;
        if (response.statusCode != 200) continue;
        return response;
      } catch (_) {
        continue;
      } finally {
        if (usePinned || _injected == null) client.close();
      }
    }
    return null;
  }
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
      return Future<http.StreamedResponse>.error(
        const InterconnectPinRefused(),
      );
    }
    return client.send(request);
  }

  @override
  void close() => inner?.close();
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
