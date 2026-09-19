import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

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
    // Shoko `AniDBSocketHandler` 收发各 30 s；AniDB 高峰期 FILE 常要十几秒才
    // 回，15 s 会把慢应答误判成丢包（BUG-2592）。
    this.timeout = const Duration(seconds: 30),
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

  /// 连续无应答后的本地退避窗口内，报文未发出（不是服务端拒绝）。
  backoff,
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
    @visibleForTesting bool sharedRateGate = false,
    this.idleLogout = const Duration(minutes: 5),
  })  : _factory = transportFactory ?? AnidbDatagramTransport.connect,
        // 进程级节流 / 退避 / 封禁只对真实 UDP 传输生效；内存传输默认不走
        // （没有网络也就没有 flood），测试要验退避时显式打开。
        _gated = sharedRateGate || transportFactory == null;
  final AnidbUdpConfig config;
  final AnidbUdpTransportFactory _factory;
  final bool _gated;

  /// 多久没有业务请求就主动 LOGOUT（Shoko `AniDBUDPConnectionHandler` 5 min）。
  /// 客户端与刮削协调器同寿命，一批扫完后会话不该一直挂着占 AniDB 的连接；
  /// 下一批第一条请求自动重新 AUTH。
  final Duration idleLogout;
  Timer? _idleTimer;
  AnidbUdpTransport? _transport;
  String? _session;
  AnidbUdpException? _terminalFailure;
  bool _closed = false;
  Future<void>? _closing;
  bool clientUpdateAvailable = false;
  Future<void> _tail = Future<void>.value();
  int _tag = 0;
  final Map<String, AnidbFileIdentity?> _cache = {};

  /// 320 未收录只在批次尺度内去重：客户端与协调器同寿命，永久缓存会让 AniDB
  /// 后来收录的文件在本进程里再也查不到；持久层另有 7 天复查期。
  final Map<String, int> _missAt = {};
  static const int _missCacheMs = 60 * 60 * 1000;
  static Future<void> _sendTail = Future<void>.value();
  static final Stopwatch _clock = Stopwatch()..start();
  static int _nextSendMs = 0;
  static int _blockedUntilMs = 0;

  /// 测试用：把进程级节流 / 退避 / 封禁状态归零，并可换成假时钟（毫秒）与
  /// 假睡眠（节流等待）。
  @visibleForTesting
  static void resetSharedState({
    int Function()? clockMs,
    Future<void> Function(Duration)? sleep,
  }) {
    _sendTail = Future<void>.value();
    _nextSendMs = 0;
    _blockedUntilMs = 0;
    _blockedReason = AnidbUdpFailure.maintenance;
    _timeoutStreak = 0;
    _lastSendMs = -1;
    _activeSinceMs = -1;
    _clockOverride = clockMs;
    _sleepOverride = sleep;
  }

  static int Function()? _clockOverride;
  static Future<void> Function(Duration)? _sleepOverride;
  static int get _nowMs => _clockOverride?.call() ?? _clock.elapsedMilliseconds;
  static Future<void> _sleep(Duration duration) =>
      (_sleepOverride ?? Future<void>.delayed)(duration);

  /// 当前退避 / 封禁还剩多久；不在窗口内为 [Duration.zero]。报告文案用。
  static Duration get sharedBlockRemaining {
    final int remaining = _blockedUntilMs - _nowMs;
    return remaining > 0 ? Duration(milliseconds: remaining) : Duration.zero;
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    _idleTimer?.cancel();
    final Future<T> result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _tail = _tail.then((_) => _armIdleLogout());
    return result;
  }

  /// 最近一条请求结束后起一个空闲计时；到点且仍有会话就在下一个发送槽发
  /// LOGOUT 并清会话（不等应答）。任何新请求进队列都会先取消它。
  void _armIdleLogout() {
    _idleTimer?.cancel();
    if (_closed || _session == null) return;
    _idleTimer = Timer(idleLogout, () {
      _idleTimer = null;
      if (_closed || _session == null) return;
      final String session = _session!;
      _session = null;
      _tail = _tail.then((_) async {
        try {
          await _request('LOGOUT', {'s': session}, responseRequired: false);
        } on AnidbUdpException {
          // 尽力而为；会话在服务端 35 分钟后也会自己过期。
        }
      });
    });
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
        if (_cache.containsKey(key)) {
          final AnidbFileIdentity? cached = _cache[key];
          if (cached != null || _nowMs - (_missAt[key] ?? 0) < _missCacheMs) {
            return cached;
          }
          _cache.remove(key);
          _missAt.remove(key);
        }
        if (_cache.length >= 2048) {
          _missAt.remove(_cache.keys.first);
          _cache.remove(_cache.keys.first);
        }
        await _ensureSession();
        _Reply file = await _requestFile(size, ed2k);
        if (file.code == 501 || file.code == 506 || file.code == 505) {
          // The virtual connection expires after 35 idle minutes (wiki
          // UDP_API_Definition), and this client lives as long as the scrape
          // coordinator, so the first FILE of a later batch routinely lands on
          // a dead session. Re-authenticate once and resend; a second
          // rejection is a real session failure (BUG-2586). 505 follows Shoko
          // (`UDPRequest.ParseResponse`: ILLEGAL INPUT OR ACCESS DENIED ⇒
          // invalid session ⇒ log in again and resend).
          _session = null;
          await _ensureSession();
          file = await _requestFile(size, ed2k);
        }
        if (file.code == 320) {
          _cache[key] = null;
          _missAt[key] = _nowMs;
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

  // fmask byte1 bits6/5 = aid/eid. fid is always first.
  // amask byte2 bits7/6/5 = anime titles; byte3 bits7..4 = epno/titles.
  Future<_Reply> _requestFile(int size, String ed2k) => _request('FILE', {
        'size': '$size',
        'ed2k': ed2k.toLowerCase(),
        'fmask': '6000000000',
        'amask': '00e0f000',
        's': _session!,
      });

  /// Settings "test login": AUTH only, no FILE query. The caller must still
  /// await [close] so the session is released with a LOGOUT. Same flood/ban
  /// bookkeeping as a scan batch; a bad password is terminal for this client.
  Future<void> verifyLogin() => _serialize(() async {
        if (_closed) throw const AnidbUdpException(AnidbUdpFailure.closed);
        if (!config.isAvailable) {
          throw const AnidbUdpException(AnidbUdpFailure.unavailable);
        }
        if (_terminalFailure != null) throw _terminalFailure!;
        await _ensureSession();
      });

  Future<void> _ensureSession() async {
    if (_session != null) return;
    final Map<String, String> values = <String, String>{
      'user': config.username,
      'pass': config.password,
      'protover': '3',
      'client': config.clientName,
      'clientver': '${config.clientVersion}',
      'enc': 'UTF-8',
      'comp': '0',
    };
    _Reply auth;
    try {
      // 第一轮登录超时不进退避：Shoko `LoginWithFallbacks` 对登录超时先
      // `ForceReconnection`（重建 socket）再登一次，本地端口状态坏掉时这一步
      // 才是真正的修复。
      auth = await _request('AUTH', values, backoffOnTimeout: false);
    } on AnidbUdpException catch (error) {
      if (error.reason != AnidbUdpFailure.timeout) rethrow;
      final AnidbUdpTransport? stale = _transport;
      _transport = null;
      await stale?.close();
      auth = await _request('AUTH', values);
    }
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

  /// Shoko parity for a silent server (`AniDBUDPConnectionHandler.SendInternal`
  /// + `ConnectionHandler.IsBanned`): a request that gets no reply is resent
  /// once with the same tag, and if that is also silent the request fails with
  /// [AnidbUdpFailure.timeout] — it is **not** a ban. Shoko only treats
  /// `555 BANNED` (and an all-zero reply) as a ban, for `BanTimerResetLength`
  /// = 1.5 h; every other reply code clears the ban flag. Server-side "try
  /// again later" codes (600/601/602/604) start a 300 s backoff.
  ///
  /// Our previous rule "two silent datagrams ⇒ banned 90 min" turned every
  /// transient loss into a process-wide freeze: one FILE timing out mid-sweep
  /// made all remaining files of all works report "限流或维护" (BUG-2592).
  /// Instead consecutive timeouts back off exponentially (Shoko's queue
  /// `RetryPolicy`: 30 s × 2ⁿ) so a genuinely silent server is still probed
  /// only every few minutes, while a single lost datagram costs one file.
  static const Duration _serverBan = Duration(minutes: 90);
  static const Duration _serverBackoff = Duration(minutes: 5);
  static const Duration _timeoutBackoffBase = Duration(seconds: 30);
  static const Duration _timeoutBackoffMax = Duration(minutes: 10);
  static AnidbUdpFailure _blockedReason = AnidbUdpFailure.maintenance;
  static int _timeoutStreak = 0;

  /// Shoko `UDPRateLimiter`：`BaseRateInSeconds` 2、`SlowRateMultiplier` 3、
  /// `SlowRatePeriodMultiplier` 5、`ResetPeriodMultiplier` 60。
  static const int _shortDelayMs = 2000;
  static const int _longDelayMs = 6000;
  static const int _shortPeriodMs = 10000;
  static const int _resetPeriodMs = 120000;
  static int _lastSendMs = -1;
  static int _activeSinceMs = -1;

  /// 本包发出后到下一包的最小间隔：按「活跃时长」在短/长间隔间切换。
  static int _rateLimitDelayMs() {
    final int now = _nowMs;
    if (_lastSendMs < 0 || now - _lastSendMs > _resetPeriodMs) {
      _activeSinceMs = now;
    }
    _lastSendMs = now;
    return now - _activeSinceMs > _shortPeriodMs ? _longDelayMs : _shortDelayMs;
  }

  static void _block(AnidbUdpFailure reason, Duration duration) {
    _blockedUntilMs = _nowMs + duration.inMilliseconds;
    _blockedReason = reason;
  }

  /// 连续第 n 次双超时 → 退避 30 s × 2ⁿ⁻¹，封顶 10 分钟。
  static void _backoffAfterTimeout() {
    _timeoutStreak++;
    final int factor = 1 << (_timeoutStreak - 1).clamp(0, 30);
    final int ms = (_timeoutBackoffBase.inMilliseconds * factor)
        .clamp(0, _timeoutBackoffMax.inMilliseconds);
    _block(AnidbUdpFailure.backoff, Duration(milliseconds: ms));
  }

  /// 收到任何一条 AniDB 应答：链路是通的，清掉超时退避（Shoko：任何响应码都
  /// 把 `IsBanned` 写回 false）。真 ban（555/504）不由这里清——它们在收到应答
  /// 时才写入，且之后不再发包。
  static void _noteReply() {
    _timeoutStreak = 0;
    if (_blockedReason == AnidbUdpFailure.backoff) _blockedUntilMs = 0;
  }

  Future<_Reply> _request(String command, Map<String, String> values,
      {bool responseRequired = true, bool backoffOnTimeout = true}) async {
    final String tag = 'f${++_tag}';
    final String packet = '$command ${({
      ...values,
      'tag': tag
    }).entries.map((MapEntry<String, String> entry) => '${entry.key}=${_escape(entry.value)}').join('&')}';
    if (utf8.encode(packet).length > 1400) {
      throw const AnidbUdpException(AnidbUdpFailure.invalidInput);
    }
    for (int attempt = 0;; attempt++) {
      try {
        return await _exchangeOnce(command, packet, tag,
            responseRequired: responseRequired);
      } on AnidbUdpException catch (error) {
        if (error.reason == AnidbUdpFailure.network) _session = null;
        rethrow;
      } on TimeoutException {
        // Same tag on purpose: a late reply to the first datagram still
        // answers this command.
        if (attempt == 0 && responseRequired) continue;
        if (_gated && backoffOnTimeout) _backoffAfterTimeout();
        _session = null;
        throw const AnidbUdpException(AnidbUdpFailure.timeout);
      } catch (_) {
        _session = null;
        throw const AnidbUdpException(AnidbUdpFailure.network);
      }
    }
  }

  Future<_Reply> _exchangeOnce(String command, String packet, String tag,
      {required bool responseRequired}) async {
    _transport ??= await _factory(config);
    if (_closed && command != 'LOGOUT') {
      throw const AnidbUdpException(AnidbUdpFailure.closed);
    }
    // Shared across all clients in the app isolate（Shoko `UDPRateLimiter`）：
    // 基准 2 s 一包；连续活跃超过 10 s 后放慢到 6 s；空闲超过 120 s 重置回
    // 短间隔。AniDB 的"长期不超过四秒一包"由 6 s 段兜住。
    // In-memory test transports have no network and need no flood delay.
    if (_gated) {
      final Future<void> turn = _sendTail.then((_) async {
        if (_closed && command != 'LOGOUT') {
          throw const AnidbUdpException(AnidbUdpFailure.closed);
        }
        if (_nowMs < _blockedUntilMs) {
          throw AnidbUdpException(_blockedReason);
        }
        final int delay = _nextSendMs - _nowMs;
        if (delay > 0) await _sleep(Duration(milliseconds: delay));
        if (_closed && command != 'LOGOUT') {
          throw const AnidbUdpException(AnidbUdpFailure.closed);
        }
        if (_nowMs < _blockedUntilMs) {
          throw AnidbUdpException(_blockedReason);
        }
        _nextSendMs = _nowMs + _rateLimitDelayMs();
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
    final String raw = await _transport!.exchange(packet, tag, config.timeout);
    if (_gated) _noteReply();
    return _Reply.parse(raw, tag);
  }

  Never _fail(int code) {
    final AnidbUdpFailure reason = switch (code) {
      500 => AnidbUdpFailure.authentication,
      503 => AnidbUdpFailure.clientOutdated,
      504 => AnidbUdpFailure.clientBanned,
      555 => AnidbUdpFailure.banned,
      501 || 505 || 506 || 598 => AnidbUdpFailure.session,
      502 => AnidbUdpFailure.accessDenied,
      600 || 601 || 602 || 604 => AnidbUdpFailure.maintenance,
      _ => AnidbUdpFailure.server,
    };
    // Shoko：505 ⇒ IsInvalidSession，506/598 ⇒ ClearSession，ban ⇒ 清会话。
    if (reason == AnidbUdpFailure.session || code == 555 || code == 504) {
      _session = null;
    }
    if (_gated) {
      if (code == 555 || code == 504) {
        _block(reason, _serverBan);
      } else if (reason == AnidbUdpFailure.maintenance) {
        // Shoko `UDPRequest.ParseResponse`：600/601/602/604 → 300 s backoff。
        _block(reason, _serverBackoff);
      }
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
    _idleTimer?.cancel();
    _idleTimer = null;
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
