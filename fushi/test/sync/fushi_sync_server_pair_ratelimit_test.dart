import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/pairing/fushi_pairing_protocol.dart';
import 'package:shelf/shelf.dart' as shelf;

/// 进程内请求的 TCP 对端（[FushiSyncServer.handleInProcess] 没有真连接）。
class _FakeConnectionInfo implements HttpConnectionInfo {
  _FakeConnectionInfo(String address)
    : remoteAddress = InternetAddress(address);

  @override
  final InternetAddress remoteAddress;

  @override
  int get remotePort => 40000;

  @override
  int get localPort => 8765;
}

/// 本组用例的来源：无转发头的局域网对端，来源键可信（`ip:192.168.1.20`）。回环对端
/// 的来源键不可信（经本机反代 / 穿透进来的所有人共用），不进按来源的限速，见
/// fushi_sync_server_pair_bruteforce_test.dart 例 9。
const String _peer = '192.168.1.20';

// TODO-961 M3: PIN brute-force rate limiting end-to-end over /api/pair/v2/confirm.
// Attack shape: attacker repeatedly opens pair/v2 sessions, confirms each once
// guessing a different PIN. Failures aggregate per source (here the LAN peer
// 192.168.1.20); on threshold the source is locked out (429) for a backoff
// window; success and the legitimate single-shot flow are unaffected.
void main() {
  late Directory tempDir;
  late FushiSyncServer server;
  String shownPin = '482913';
  DateTime fakeNow = DateTime.utc(2026, 1, 1, 12, 0, 0);

  Future<void> startServer({bool approve = true}) async {
    tempDir = Directory.systemTemp.createTempSync('fushi_pair_rl_test');
    server =
        FushiSyncServer(
            syncDataDir: tempDir.path,
            port: 0,
            token: 'super-secret-token',
            allowLan: true,
            now: () => fakeNow,
          )
          ..onPairRequest = ((FushiPairRequest _) async => approve)
          ..onPairPinGenerated = ((FushiPairSession _) => shownPin)
          ..lanRequiresPinProvider = (() async => true);
  }

  tearDown(() async {
    await server.stop();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    fakeNow = DateTime.utc(2026, 1, 1, 12, 0, 0);
    shownPin = '482913';
  });

  Future<({int statusCode, String body})> post(
    String path,
    Map<String, Object?> body,
  ) async {
    final shelf.Response resp = await server.handleInProcess(
      shelf.Request(
        'POST',
        Uri.parse('http://fushi.test$path'),
        headers: <String, String>{'content-type': 'application/json'},
        body: jsonEncode(body),
        context: <String, Object>{
          'shelf.io.connection_info': _FakeConnectionInfo(_peer),
        },
      ),
    );
    return (statusCode: resp.statusCode, body: await resp.readAsString());
  }

  Future<Map<String, dynamic>> startSession(String clientNonce) async {
    final ({int statusCode, String body}) resp = await post(
      '/api/pair/v2',
      <String, String>{'name': 'Attacker', 'clientNonce': clientNonce},
    );
    expect(resp.statusCode, 200);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<({int statusCode, String body})> confirmWith(
    Map<String, dynamic> start,
    String clientNonce,
    String pin,
  ) {
    return post('/api/pair/v2/confirm', <String, String>{
      'sessionId': start['sessionId'] as String,
      'pinProof': FushiPairingProtocol.computePinProof(
        pin: pin,
        clientNonce: clientNonce,
        hostNonce: start['hostNonce'] as String,
      ),
    });
  }

  Future<({int statusCode, String body})> confirmWrongPin(int attempt) async {
    final String clientNonce = 'cn-wrong-$attempt';
    final Map<String, dynamic> start = await startSession(clientNonce);
    return confirmWith(start, clientNonce, '000000');
  }

  Future<({int statusCode, String body})> confirmCorrectPin(String tag) async {
    final String clientNonce = 'cn-ok-$tag';
    final Map<String, dynamic> start = await startSession(clientNonce);
    return confirmWith(start, clientNonce, shownPin);
  }

  test('threshold failures lock out: 401 pin then 429 rate_limited', () async {
    await startServer();
    for (int i = 1; i <= 4; i++) {
      final ({int statusCode, String body}) r = await confirmWrongPin(i);
      expect(r.statusCode, 401, reason: 'attempt $i should be 401 pin');
      expect((jsonDecode(r.body) as Map<String, dynamic>)['reason'], 'pin');
    }
    final ({int statusCode, String body}) fifth = await confirmWrongPin(5);
    expect(fifth.statusCode, 429, reason: '5th attempt hits threshold');
    expect(
      (jsonDecode(fifth.body) as Map<String, dynamic>)['reason'],
      'rate_limited',
    );
  });

  test(
    'within lockout window pair/v2 itself is 429 (no session, no PIN shown)',
    () async {
      // BUG-4390：锁定中的来源连会话都开不出来——不生成 PIN、不弹审批，自然也没有
      // 「拿正确 PIN 来 confirm」的机会。
      await startServer();
      for (int i = 1; i <= 5; i++) {
        await confirmWrongPin(i);
      }
      final ({int statusCode, String body}) r = await post(
        '/api/pair/v2',
        <String, String>{
          'name': 'Attacker',
          'clientNonce': 'cn-during-lockout',
        },
      );
      expect(r.statusCode, 429);
      expect(
        (jsonDecode(r.body) as Map<String, dynamic>)['reason'],
        'rate_limited',
      );
    },
  );

  test(
    'session opened before lockout: correct PIN confirm is still 429',
    () async {
      // 评审 tests-2：锁定之前就开好的会话，锁定后只靠 confirm 里比对 PIN 之前的
      // 锁定预检拦住。没有这道预检，猜对的会照常拿到 token，锁定期间仍在回答
      // 「是否猜中」。
      await startServer();
      const String earlyNonce = 'cn-opened-before-lockout';
      final Map<String, dynamic> early = await startSession(earlyNonce);
      for (int i = 1; i <= 5; i++) {
        await confirmWrongPin(i);
      }
      final ({int statusCode, String body}) r = await confirmWith(
        early,
        earlyNonce,
        shownPin,
      );
      expect(r.statusCode, 429, reason: '锁定中的来源拿正确 PIN 也不放行');
      expect(
        (jsonDecode(r.body) as Map<String, dynamic>)['reason'],
        'rate_limited',
      );
    },
  );

  test('after backoff window correct PIN pairs again', () async {
    await startServer();
    for (int i = 1; i <= 5; i++) {
      await confirmWrongPin(i);
    }
    fakeNow = fakeNow.add(const Duration(minutes: 16));
    final ({int statusCode, String body}) r = await confirmCorrectPin(
      'after-lockout',
    );
    expect(r.statusCode, 200, reason: 'recovers after backoff');
    expect(
      (jsonDecode(r.body) as Map<String, dynamic>)['token'],
      'super-secret-token',
    );
  });

  test('success clears count: later failures start fresh', () async {
    await startServer();
    for (int i = 1; i <= 4; i++) {
      final ({int statusCode, String body}) r = await confirmWrongPin(i);
      expect(r.statusCode, 401);
    }
    final ({int statusCode, String body}) ok = await confirmCorrectPin('reset');
    expect(ok.statusCode, 200);
    for (int i = 5; i <= 8; i++) {
      final ({int statusCode, String body}) r = await confirmWrongPin(i);
      expect(
        r.statusCode,
        401,
        reason: 'attempt ${i - 4} after reset stays 401',
      );
    }
  });

  test('legitimate single-shot flow zero regression', () async {
    await startServer();
    final ({int statusCode, String body}) r = await confirmCorrectPin('single');
    expect(r.statusCode, 200);
    expect(
      (jsonDecode(r.body) as Map<String, dynamic>)['token'],
      'super-secret-token',
    );
  });

  test('PIN-free sessions are never rate limited', () async {
    tempDir = Directory.systemTemp.createTempSync('fushi_pair_rl_free_test');
    server =
        FushiSyncServer(
            syncDataDir: tempDir.path,
            port: 0,
            token: 'super-secret-token',
            allowLan: true,
            now: () => fakeNow,
          )
          ..onPairRequest = ((FushiPairRequest _) async => true)
          ..onPairPinGenerated = ((FushiPairSession _) => shownPin)
          ..lanRequiresPinProvider = (() async => false);
    for (int i = 0; i < 10; i++) {
      final Map<String, dynamic> start = await startSession('cn-free-$i');
      final ({int statusCode, String body}) r = await post(
        '/api/pair/v2/confirm',
        <String, String>{'sessionId': start['sessionId'] as String},
      );
      expect(r.statusCode, 200, reason: 'free confirm $i should succeed');
    }
  });

  test('rate-limit records are pruned, not leaked', () async {
    await startServer();
    await confirmWrongPin(1);
    expect(server.pinRateLimitTrackedSourceCount, 1);
    fakeNow = fakeNow.add(const Duration(minutes: 6));
    await startSession('cn-prune-trigger');
    expect(
      server.pinRateLimitTrackedSourceCount,
      0,
      reason: 'cooled record should be reclaimed',
    );
  });
}
