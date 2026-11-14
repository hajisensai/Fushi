import 'dart:convert';

import 'package:fushi/src/sync/interconnect_host_channel.dart';
import 'package:fushi/src/sync/interconnect_post_transport.dart'
    show kInterconnectConnectTimeout;
import 'package:fushi/src/sync/sync_backend.dart'
    show SyncAuthError, SyncAuthFailureKind;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:http/http.dart' as http;
import 'package:fushi_engine/sync/tls/fushi_pinning_http.dart';

export 'package:fushi/src/sync/interconnect_host_channel.dart'
    show InterconnectPinRefused;

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

/// Requests bound to one paired host (video remote control, SRS remote review),
/// including its credential and pin.
///
/// 传输一律走共享 [InterconnectHostChannel]（选路、per-peer 凭据、钉扎闸、整段
/// 超时、client 生命周期都在那里），这里只把通道的结局映射成本类的错误形状。
///
/// 会话绑定：通道带上 [peer] 的 token 与指纹（[InterconnectHostBinding]）。吊销
/// 或重新配对（凭据变了、地址改归另一台 host）都让会话失效，绝不换到另一个媒体库。
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
       _injectedPinned = pinnedClientFactory;
  final FushiClientUrl peer;
  final SyncRepository _repository;

  /// 注入的明文 client：通道借用、不关它。null → 通道自建并在
  /// [cancelPending] 时关掉。
  final http.Client? _injected;

  /// 注入的钉扎工厂。null → 通道用默认钉扎 client（能识别真正的证书不符）。
  final http.Client Function(String expectedFingerprint)? _injectedPinned;

  late InterconnectHostChannel _channel = _newChannel();

  InterconnectHostChannel _newChannel() => InterconnectHostChannel(
    repo: _repository,
    host: InterconnectHostRef.ofRow(peer),
    binding: (token: peer.token, fingerprint: peer.fingerprintSha256),
    plainClient: _injected,
    pinnedClientFactory: _injectedPinned,
  );

  static http.Client _defaultPinnedClient(String expectedFingerprint) =>
      createPinnedHttpPackageClient(
        expectedFingerprint: expectedFingerprint,
        connectionTimeout: kInterconnectConnectTimeout,
      );

  String? get _expectedPin {
    final String? pin = peer.fingerprintSha256;
    return pin == null || pin.isEmpty ? null : pin;
  }

  /// Wraps a plaintext client so it refuses non-tunnel requests to a pinned
  /// host (companion clients bound to the same host, e.g. dictionary lookup).
  http.Client guardPlaintext(http.Client inner) => _PinGuardClient(
    inner,
    (Uri uri) => interconnectPlaintextAllowed(uri, pin: _expectedPin),
  );

  /// Pinned-client factory that only builds clients for the peer's own pin.
  http.Client Function(String expectedFingerprint) guardPinnedFactory(
    http.Client Function(String expectedFingerprint) inner,
  ) => (String pin) {
    final String? expected = _expectedPin;
    if (expected != null && !fingerprintEquals(pin, expected)) {
      return _PinGuardClient(null, (_) => false);
    }
    return inner(pin);
  };

  /// Pinned-client factory bound to this peer's pin, for a companion client
  /// (dictionary lookup) bound to the same host.
  http.Client Function(String expectedFingerprint) get pinnedClientFactory =>
      guardPinnedFactory(_injectedPinned ?? _defaultPinnedClient);

  /// 关掉通道建的全部 client，在途请求立即收尾；之后的请求走一条新通道。
  void cancelPending() {
    _channel.close();
    _channel = _newChannel();
  }

  int _sequence = 0;
  String requestId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';

  /// `POST` [body] as JSON to [path] on the selected host (one attempt: a
  /// non-idempotent request is never re-sent to another address once it may
  /// have been delivered). A rejection carries the host's `error` / `message`
  /// code.
  Future<Map<String, dynamic>> postJson(
    String path, {
    Map<String, dynamic> body = const <String, dynamic>{},
    Duration timeout = const Duration(seconds: 35),
    required String authErrorMessage,
  }) async {
    final InterconnectChannelResponse response;
    try {
      response = await _channel.send(
        'POST',
        path,
        body: InterconnectRequestBody.json(body),
        timeout: timeout,
      );
    } on InterconnectChannelException catch (e) {
      throw switch (e.kind) {
        InterconnectChannelFailure.authRejected => SyncAuthError(
          authErrorMessage,
          kind: SyncAuthFailureKind.pairingRejected,
        ),
        InterconnectChannelFailure.certificateMismatch =>
          const InterconnectHostError(
            InterconnectHostError.certificateMismatchCode,
          ),
        // 没有候选、谁都没回答、调用方已 cancelPending：都是「没连上」。
        InterconnectChannelFailure.notPaired ||
        InterconnectChannelFailure.unreachable ||
        InterconnectChannelFailure.cancelled => const InterconnectHostError(
          InterconnectHostError.unreachableCode,
        ),
      };
    }
    final int status = response.statusCode;
    final Map<String, dynamic>? json = response.jsonObject;
    if (status >= 200 && status < 300 && json != null) return json;
    throw InterconnectHostError(
      json?['error']?.toString() ??
          json?['message']?.toString() ??
          'HTTP $status',
      statusCode: status,
    );
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

  /// `GET` [path] on the selected host (same routing, credential and pin rules
  /// as [postJson]). Null when the host answered anything but 200 (404 = the
  /// host has no such resource) or no address answered.
  Future<http.Response?> getFromHost(
    String path, {
    required Duration timeout,
  }) async {
    final InterconnectChannelResponse response;
    try {
      response = await _channel.send('GET', path, timeout: timeout);
    } on InterconnectChannelException {
      return null;
    }
    if (response.statusCode != 200) return null;
    return http.Response.bytes(
      response.bodyBytes,
      response.statusCode,
      headers: response.headers,
    );
  }
}

/// Refuses requests [allowed] rejects; the refusal surfaces as a transport
/// failure, so nothing reaches the network.
class _PinGuardClient extends http.BaseClient {
  _PinGuardClient(this.inner, this.allowed);
  final http.Client? inner;
  final bool Function(Uri uri) allowed;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final http.Client? client = inner;
    if (client == null || !allowed(request.url)) {
      return Future<http.StreamedResponse>.error(
        const InterconnectPinRefused(),
      );
    }
    return client.send(request);
  }

  @override
  void close() => inner?.close();
}
