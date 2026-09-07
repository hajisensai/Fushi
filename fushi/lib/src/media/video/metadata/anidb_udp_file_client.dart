import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A registered AniDB client identity and the user's website credentials.
/// Never include this object or wire packets in logs.
class AnidbUdpConfig {
  const AnidbUdpConfig({
    required this.username,
    required this.password,
    required this.clientName,
    required this.clientVersion,
    this.host = 'api.anidb.net',
    this.port = 9000,
    this.localPort = 19000,
    this.timeout = const Duration(seconds: 15),
  });
  final String username, password, clientName, host;
  final int clientVersion, port, localPort;
  final Duration timeout;
  bool get isAvailable =>
      RegExp(r'^[a-z]{4,16}$').hasMatch(clientName) &&
      clientVersion > 0 &&
      RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(username) &&
      password.isNotEmpty &&
      host.isNotEmpty &&
      port > 0 &&
      port <= 65535 &&
      localPort > 1024 &&
      localPort <= 65535 &&
      timeout > Duration.zero;
}

enum AnidbUdpFailure {
  unavailable,
  invalidInput,
  authentication,
  clientOutdated,
  clientBanned,
  banned,
  session,
  accessDenied,
  maintenance,
  server,
  timeout,
  network,
  malformedResponse,
  closed,
}

class AnidbUdpException implements Exception {
  const AnidbUdpException(this.reason, {this.code});
  final AnidbUdpFailure reason;
  final int? code;
  @override
  String toString() => 'AnidbUdpException(${reason.name}, code: $code)';
}

class AnidbFileIdentity {
  const AnidbFileIdentity({
    required this.fileId,
    required this.animeId,
    required this.episodeId,
    required this.episodeNumber,
    required this.romajiTitle,
    required this.kanjiTitle,
    required this.englishTitle,
    required this.episodeTitle,
    required this.episodeRomajiTitle,
    required this.episodeKanjiTitle,
  });
  final int fileId, animeId, episodeId;
  final String episodeNumber,
      romajiTitle,
      kanjiTitle,
      englishTitle,
      episodeTitle,
      episodeRomajiTitle,
      episodeKanjiTitle;
}

/// Request/response transport; implementations must discard other peers/tags.
abstract interface class AnidbUdpTransport {
  Future<String> exchange(String packet, String tag, Duration timeout);
  Future<void> send(String packet);
  void cancelPending();
  Future<void> close();
}

typedef AnidbUdpTransportFactory = Future<AnidbUdpTransport> Function(
    AnidbUdpConfig config);

/// One persistent socket/session, with serialized commands and no automatic
/// retries. Keep a client for a scan batch, then await [close]. Cache successful
/// identities durably in the caller; this client also deduplicates within a batch.
/// Protocol: https://wiki.anidb.net/UDP_API_Definition (FILE masks, AUTH, flooding).
class AnidbUdpFileClient {
  AnidbUdpFileClient({
    required this.config,
    AnidbUdpTransportFactory? transportFactory,
  }) : _factory = transportFactory ?? AnidbDatagramTransport.connect;
  final AnidbUdpConfig config;
  final AnidbUdpTransportFactory _factory;
  AnidbUdpTransport? _transport;
  String? _session;
  AnidbUdpException? _terminalFailure;
  bool _closed = false;
  Future<void>? _closing;
  bool clientUpdateAvailable = false;
  Future<void> _tail = Future<void>.value();
  int _tag = 0;
  final Map<String, AnidbFileIdentity?> _cache = {};
  static Future<void> _sendTail = Future<void>.value();
  static final Stopwatch _clock = Stopwatch()..start();
  static int _nextSendMs = 0;
  static int _blockedUntilMs = 0;

  Future<T> _serialize<T>(Future<T> Function() action) {
    final Future<T> result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<AnidbFileIdentity?> lookup({
    required int size,
    required String ed2k,
  }) =>
      _serialize(() async {
        if (_closed) throw const AnidbUdpException(AnidbUdpFailure.closed);
        if (!config.isAvailable) {
          throw const AnidbUdpException(AnidbUdpFailure.unavailable);
        }
        if (_terminalFailure != null) throw _terminalFailure!;
        if (size <= 0 || !RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(ed2k)) {
          throw const AnidbUdpException(AnidbUdpFailure.invalidInput);
        }
        final String key = '$size:${ed2k.toLowerCase()}';
        if (_cache.containsKey(key)) return _cache[key];
        if (_cache.length >= 2048) _cache.remove(_cache.keys.first);
        if (_session == null) {
          final _Reply auth = await _request('AUTH', {
            'user': config.username,
            'pass': config.password,
            'protover': '3',
            'client': config.clientName,
            'clientver': '${config.clientVersion}',
            'enc': 'UTF-8',
            'comp': '0',
          });
          if (auth.code != 200 && auth.code != 201) _fail(auth.code);
          final RegExpMatch? sessionMatch = RegExp(
            r'^([a-zA-Z0-9]{4,8}) LOGIN ACCEPTED(?: - NEW VERSION AVAILABLE)?$',
          ).firstMatch(auth.message);
          if (sessionMatch == null) {
            throw const AnidbUdpException(AnidbUdpFailure.malformedResponse);
          }
          _session = sessionMatch[1]!;
          clientUpdateAvailable = auth.code == 201;
        }
        // fmask byte1 bits6/5 = aid/eid. fid is always first.
        // amask byte2 bits7/6/5 = anime titles; byte3 bits7..4 = epno/titles.
        final _Reply file = await _request('FILE', {
          'size': '$size',
          'ed2k': ed2k.toLowerCase(),
          'fmask': '6000000000',
          'amask': '00e0f000',
          's': _session!,
        });
        if (file.code == 320) {
          _cache[key] = null;
          return null;
        }
        if (file.code != 220) _fail(file.code);
        final List<String> fields = file.data.split('|');
        if (fields.length < 10) {
          throw const AnidbUdpException(AnidbUdpFailure.malformedResponse);
        }
        final List<int?> ids = fields.take(3).map(int.tryParse).toList();
        if (ids.any((int? id) => id == null || id <= 0) ||
            !RegExp(r'^(?:[SCTPO])?\d+$').hasMatch(fields[6])) {
          throw const AnidbUdpException(AnidbUdpFailure.malformedResponse);
        }
        final AnidbFileIdentity identity = AnidbFileIdentity(
          fileId: ids[0]!,
          animeId: ids[1]!,
          episodeId: ids[2]!,
          romajiTitle: fields[3],
          kanjiTitle: fields[4],
          englishTitle: fields[5],
          episodeNumber: fields[6],
          episodeTitle: fields[7],
          episodeRomajiTitle: fields[8],
          episodeKanjiTitle: fields[9],
        );
        _cache[key] = identity;
        return identity;
      });

  Future<_Reply> _request(String command, Map<String, String> values,
      {bool responseRequired = true}) async {
    final String tag = 'f${++_tag}';
    final String packet = '$command ${({
      ...values,
      'tag': tag
    }).entries.map((MapEntry<String, String> entry) => '${entry.key}=${_escape(entry.value)}').join('&')}';
    if (utf8.encode(packet).length > 1400) {
      throw const AnidbUdpException(AnidbUdpFailure.invalidInput);
    }
    try {
      _transport ??= await _factory(config);
      if (_closed && command != 'LOGOUT') {
        throw const AnidbUdpException(AnidbUdpFailure.closed);
      }
      // Shared across all clients in the app isolate. Four seconds even for
      // short batches satisfies both AniDB's short and long term limits.
      // In-memory test transports have no network and need no flood delay.
      if (_transport is AnidbDatagramTransport) {
        final Future<void> turn = _sendTail.then((_) async {
          if (_closed && command != 'LOGOUT') {
            throw const AnidbUdpException(AnidbUdpFailure.closed);
          }
          if (_clock.elapsedMilliseconds < _blockedUntilMs) {
            throw const AnidbUdpException(AnidbUdpFailure.maintenance);
          }
          final int delay = _nextSendMs - _clock.elapsedMilliseconds;
          if (delay > 0) {
            await Future<void>.delayed(Duration(milliseconds: delay));
          }
          if (_closed && command != 'LOGOUT') {
            throw const AnidbUdpException(AnidbUdpFailure.closed);
          }
          if (_clock.elapsedMilliseconds < _blockedUntilMs) {
            throw const AnidbUdpException(AnidbUdpFailure.maintenance);
          }
          _nextSendMs = _clock.elapsedMilliseconds + 4000;
        });
        _sendTail = turn.then<void>(
          (_) {},
          onError: (Object _, StackTrace __) {},
        );
        await turn;
      }
      if (_closed && command != 'LOGOUT') {
        throw const AnidbUdpException(AnidbUdpFailure.closed);
      }
      if (!responseRequired) {
        await _transport!.send(packet);
        // No response was requested; this is not a successful server reply.
        return const _Reply(0, '', '');
      }
      return _Reply.parse(
        await _transport!.exchange(packet, tag, config.timeout),
        tag,
      );
    } on AnidbUdpException catch (error) {
      if (error.reason == AnidbUdpFailure.network) _session = null;
      rethrow;
    } on TimeoutException {
      if (_transport is AnidbDatagramTransport) {
        _blockedUntilMs = _clock.elapsedMilliseconds + 30 * 60 * 1000;
      }
      _session = null;
      throw const AnidbUdpException(AnidbUdpFailure.timeout);
    } catch (_) {
      _session = null;
      throw const AnidbUdpException(AnidbUdpFailure.network);
    }
  }

  Never _fail(int code) {
    final AnidbUdpFailure reason = switch (code) {
      500 => AnidbUdpFailure.authentication,
      503 => AnidbUdpFailure.clientOutdated,
      504 => AnidbUdpFailure.clientBanned,
      555 => AnidbUdpFailure.banned,
      501 || 506 => AnidbUdpFailure.session,
      502 || 505 => AnidbUdpFailure.accessDenied,
      601 => AnidbUdpFailure.maintenance,
      _ => AnidbUdpFailure.server,
    };
    if (code == 501 || code == 506) _session = null;
    if (_transport is AnidbDatagramTransport &&
        (code == 601 || code == 555 || code == 504)) {
      _blockedUntilMs = _clock.elapsedMilliseconds + 30 * 60 * 1000;
    }
    if (code == 500 || code == 503 || code == 504 || code == 555) {
      // Stop a queued scan from repeatedly authenticating bad credentials.
      // A new client after changing configuration may try again.
      _terminalFailure = AnidbUdpException(reason, code: code);
    }
    throw AnidbUdpException(reason, code: code);
  }

  /// Cancels the pending receive immediately, sends a best-effort LOGOUT at the
  /// next permitted send slot, then releases the fixed local port. Does not wait
  /// for LOGOUT acknowledgement. Callers must await this before opening a batch.
  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    _transport?.cancelPending();
    final Future<void> closing = _closing = _serialize(() async {
      try {
        if (_session != null) {
          await _request('LOGOUT', {'s': _session!}, responseRequired: false);
        }
      } on AnidbUdpException {
        // Best-effort logout; never keep the local socket open after failure.
      } finally {
        _session = null;
        await _transport?.close();
        _transport = null;
      }
    });
    if (_transport is AnidbDatagramTransport) {
      AnidbDatagramTransport._registerClosing(config.localPort, closing);
    }
    return closing;
  }
}

// AniDB specifies HTML entities, NOT URI percent/form-url encoding.
String _escape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .replaceAll('\n', '<br />');

class _Reply {
  const _Reply(this.code, this.message, this.data);
  final int code;
  final String message, data;
  static _Reply parse(String text, String tag) {
    final List<String> lines = text.trimRight().split('\n');
    final String header = lines.first;
    final String bare =
        header.startsWith('$tag ') ? header.substring(tag.length + 1) : header;
    final RegExpMatch? match = RegExp(r'^(\d{3}) (.*)$').firstMatch(bare);
    if (match == null ||
        (!header.startsWith('$tag ') && !bare.startsWith('6'))) {
      throw const AnidbUdpException(AnidbUdpFailure.malformedResponse);
    }
    final String data = lines.length > 1 ? lines[1] : '';
    return _Reply(
      int.parse(match[1]!),
      match[2]!,
      (data.startsWith('$tag ') ? data.substring(tag.length + 1) : data)
          .replaceAll('<br />', '\n'),
    );
  }
}

/// Fixed local port, source endpoint verification, and one outstanding request.
class AnidbDatagramTransport implements AnidbUdpTransport {
  AnidbDatagramTransport._(this._socket, this._remote, this._port);
  final RawDatagramSocket _socket;
  final InternetAddress _remote;
  final int _port;
  StreamSubscription<RawSocketEvent>? _subscription;
  Completer<String>? _pending;
  String? _expectedTag;
  static final Map<int, Future<void>> _closingByPort = {};

  static void _registerClosing(int port, Future<void> closing) {
    // A failed best-effort logout must not prevent a new owner using the port
    // after the socket has been released. The caller still receives its error.
    final Future<void> released =
        closing.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _closingByPort[port] = released;
    unawaited(released.then((_) {
      if (identical(_closingByPort[port], released)) {
        _closingByPort.remove(port);
      }
    }));
  }

  static Future<AnidbUdpTransport> connect(AnidbUdpConfig config) async {
    final List<InternetAddress> addresses = await InternetAddress.lookup(
      config.host,
      type: InternetAddressType.IPv4,
    ).timeout(config.timeout);
    // A coordinator may dispose without awaiting close and its successor may
    // immediately start a scan. Wait only for a known closing owner, never for
    // an active client or by changing to another (AniDB rate-sensitive) port.
    await _closingByPort[config.localPort];
    final RawDatagramSocket socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      config.localPort,
      reuseAddress: false,
    );
    final AnidbDatagramTransport transport = AnidbDatagramTransport._(
      socket,
      addresses.first,
      config.port,
    );
    transport._subscription = socket.listen(
      transport._onEvent,
      onError: (Object _) => transport._failPending(),
      onDone: transport._failPending,
    );
    return transport;
  }

  void _failPending() {
    final Completer<String>? pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const AnidbUdpException(AnidbUdpFailure.network));
    }
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    Datagram? datagram;
    while ((datagram = _socket.receive()) != null) {
      final Datagram received = datagram!;
      if (received.address.address != _remote.address ||
          received.port != _port) {
        continue;
      }
      final Completer<String>? pending = _pending;
      if (pending == null || pending.isCompleted) continue;
      String text;
      try {
        text = utf8.decode(received.data);
      } on FormatException {
        continue;
      }
      if (!text.startsWith('$_expectedTag ') &&
          !RegExp(r'^6\d\d ').hasMatch(text)) {
        continue;
      }
      pending.complete(text);
    }
  }

  @override
  Future<String> exchange(String packet, String tag, Duration timeout) async {
    if (_pending != null) throw StateError('AniDB request already pending');
    final Completer<String> pending = Completer<String>();
    _pending = pending;
    _expectedTag = tag;
    try {
      _sendDatagram(packet);
      return await pending.future.timeout(timeout);
    } finally {
      _pending = null;
      _expectedTag = null;
    }
  }

  @override
  Future<void> send(String packet) async {
    _sendDatagram(packet);
  }

  void _sendDatagram(String packet) {
    final List<int> bytes = utf8.encode(packet);
    if (_socket.send(bytes, _remote, _port) != bytes.length) {
      throw const AnidbUdpException(AnidbUdpFailure.network);
    }
  }

  @override
  void cancelPending() {
    final Completer<String>? pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const AnidbUdpException(AnidbUdpFailure.closed));
    }
  }

  @override
  Future<void> close() async {
    _failPending();
    _socket.close();
    await _subscription?.cancel();
  }
}
