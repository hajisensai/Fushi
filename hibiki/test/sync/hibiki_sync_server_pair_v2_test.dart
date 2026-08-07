import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/hibiki_sync_server.dart';
import 'package:fushi/src/sync/pairing/hibiki_pairing_protocol.dart';
import 'package:http/http.dart' as http;

// TODO-961 M1 §3.6 behavior tests for /api/pair/v2 + /api/pair/v2/confirm.
void main() {
  late Directory tempDir;
  late HibikiSyncServer server;
  String? shownPin;
  // TODO-1296 / BUG-592: record each host-approval invocation's pinRequired so
  // tests can assert *when* (create vs confirm) the PIN-showing approval fires.
  late List<bool> approvalPinRequired;
  // TODO-1330 / BUG-617: how many times the host was told "the client has
  // submitted confirm, drop the lingering PIN dialog" (onPairSessionResolved).
  late int sessionResolvedCount;

  Future<void> startServer({
    required bool lanRequiresPin,
    bool approve = true,
  }) async {
    approvalPinRequired = <bool>[];
    sessionResolvedCount = 0;
    tempDir = Directory.systemTemp.createTempSync('hibiki_pair_v2_test');
    server = HibikiSyncServer(
      syncDataDir: tempDir.path,
      port: 0,
      token: 'super-secret-token',
      allowLan: true,
    )
      ..onPairRequest = ((HibikiPairRequest r) async {
        approvalPinRequired.add(r.pinRequired);
        return approve;
      })
      ..onPairPinGenerated = ((HibikiPairSession s) {
        shownPin = '482913';
        return shownPin!;
      })
      ..onPairSessionResolved = (() => sessionResolvedCount++)
      ..lanRequiresPinProvider = (() async => lanRequiresPin);
    await server.start();
  }

  tearDown(() async {
    await server.stop();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    shownPin = null;
  });

  Uri v2Uri() => Uri.parse('http://127.0.0.1:${server.port}/api/pair/v2');
  Uri confirmUri() =>
      Uri.parse('http://127.0.0.1:${server.port}/api/pair/v2/confirm');

  Future<Map<String, dynamic>> startSession(String clientNonce) async {
    final http.Response resp = await http.post(
      v2Uri(),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{
        'name': 'Galaxy S21',
        'clientNonce': clientNonce,
      }),
    );
    expect(resp.statusCode, 200);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  test('LAN auto-discovery + host allows PIN-free yields pinRequired false',
      () async {
    await startServer(lanRequiresPin: false);
    final Map<String, dynamic> body = await startSession('cn-1');
    expect(body['pinRequired'], isFalse);
    expect(body['sessionId'], isA<String>());
    expect(body['hostNonce'], isA<String>());
    expect(body.containsKey('pin'), isFalse);
    expect(jsonEncode(body).contains('482913'), isFalse);
  });

  test('LAN but host requires PIN yields pinRequired true', () async {
    await startServer(lanRequiresPin: true);
    final Map<String, dynamic> body = await startSession('cn-2');
    expect(body['pinRequired'], isTrue);
  });

  test('PIN-free session confirm without proof yields token', () async {
    await startServer(lanRequiresPin: false);
    final Map<String, dynamic> start = await startSession('cn-3');
    final http.Response resp = await http.post(
      confirmUri(),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(
          <String, String>{'sessionId': start['sessionId'] as String}),
    );
    expect(resp.statusCode, 200);
    final Map<String, dynamic> body =
        jsonDecode(resp.body) as Map<String, dynamic>;
    expect(body['token'], 'super-secret-token');
  });

  test('PIN required correct proof plus host allow yields token', () async {
    await startServer(lanRequiresPin: true);
    const String clientNonce = 'cn-4';
    final Map<String, dynamic> start = await startSession(clientNonce);
    final String pinProof = HibikiPairingProtocol.computePinProof(
      pin: shownPin!,
      clientNonce: clientNonce,
      hostNonce: start['hostNonce'] as String,
    );
    final http.Response resp = await http.post(
      confirmUri(),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{
        'sessionId': start['sessionId'] as String,
        'pinProof': pinProof,
      }),
    );
    expect(resp.statusCode, 200);
    expect((jsonDecode(resp.body) as Map<String, dynamic>)['token'],
        'super-secret-token');
  });

  test('PIN required wrong proof yields 401 pin', () async {
    await startServer(lanRequiresPin: true);
    const String clientNonce = 'cn-5';
    final Map<String, dynamic> start = await startSession(clientNonce);
    final String wrongProof = HibikiPairingProtocol.computePinProof(
      pin: '000000',
      clientNonce: clientNonce,
      hostNonce: start['hostNonce'] as String,
    );
    final http.Response resp = await http.post(
      confirmUri(),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{
        'sessionId': start['sessionId'] as String,
        'pinProof': wrongProof,
      }),
    );
    expect(resp.statusCode, 401);
    expect((jsonDecode(resp.body) as Map<String, dynamic>)['reason'], 'pin');
  });

  test('PIN-required host declines at CREATE yields 403 declined (BUG-592)',
      () async {
    // TODO-1296 / BUG-592: for a PIN-required session the host approval (which
    // shows the PIN) moved to the /api/pair/v2 CREATE step, so a decline now
    // surfaces there — the client never gets a session/hostNonce to even ask for
    // a PIN. This is what makes the PIN visible before the client must type it.
    await startServer(lanRequiresPin: true, approve: false);
    final http.Response resp = await http.post(
      v2Uri(),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{
        'name': 'Galaxy S21',
        'clientNonce': 'cn-6',
      }),
    );
    expect(resp.statusCode, 403);
    expect(
        (jsonDecode(resp.body) as Map<String, dynamic>)['reason'], 'declined');
    // Approval was consulted exactly once, at create, with pinRequired=true
    // (i.e. the host was given the chance to display the PIN).
    expect(approvalPinRequired, <bool>[true]);
  });

  // TODO-1296 / BUG-592 regression: the PIN-showing host approval must fire at
  // CREATE for a PIN-required session, so the host displays the PIN before the
  // client is asked to enter it. Previously it only fired at confirm AFTER
  // pinProof verification — an impossible ordering that hid the PIN forever.
  test('PIN-required approval fires at CREATE not confirm (BUG-592)', () async {
    await startServer(lanRequiresPin: true);
    const String clientNonce = 'cn-create';
    // After CREATE the host has already been asked to approve+show the PIN.
    final Map<String, dynamic> start = await startSession(clientNonce);
    expect(approvalPinRequired, <bool>[true],
        reason: 'host approval (PIN display) must happen during /api/pair/v2');
    // Confirm with the correct proof must NOT trigger a second approval prompt.
    final String pinProof = HibikiPairingProtocol.computePinProof(
      pin: shownPin!,
      clientNonce: clientNonce,
      hostNonce: start['hostNonce'] as String,
    );
    final http.Response resp = await http.post(
      confirmUri(),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{
        'sessionId': start['sessionId'] as String,
        'pinProof': pinProof,
      }),
    );
    expect(resp.statusCode, 200);
    expect((jsonDecode(resp.body) as Map<String, dynamic>)['token'],
        'super-secret-token');
    expect(approvalPinRequired, <bool>[true],
        reason: 'confirm must not re-prompt: approval already done at create');
  });

  // PIN-free (LAN auto-discovery) sessions keep the old behavior: no approval at
  // create (nothing to display), approval fires at confirm.
  test('PIN-free approval fires at CONFIRM not create (BUG-592)', () async {
    await startServer(lanRequiresPin: false);
    final Map<String, dynamic> start = await startSession('cn-free-phase');
    expect(approvalPinRequired, isEmpty,
        reason: 'PIN-free create must not prompt the host (no PIN to show)');
    final http.Response resp = await http.post(
      confirmUri(),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(
          <String, String>{'sessionId': start['sessionId'] as String}),
    );
    expect(resp.statusCode, 200);
    expect(approvalPinRequired, <bool>[false],
        reason: 'PIN-free approval happens at confirm');
  });

  // TODO-1330 / BUG-617: 公网 PIN 时序修复的服务端契约——pinRequired 会话一旦 client
  // 提交 confirm，就通知 host 收起常驻显示 PIN 的弹窗（否则「点允许即关窗」会在 client
  // 输 PIN 前抹掉 PIN）。免 PIN 会话没有常驻弹窗，绝不触发。
  test('pinRequired confirm 触发 onPairSessionResolved 一次（BUG-617）', () async {
    await startServer(lanRequiresPin: true);
    const String clientNonce = 'cn-resolve';
    final Map<String, dynamic> start = await startSession(clientNonce);
    expect(sessionResolvedCount, 0,
        reason: 'CREATE 阶段不算「已解决」——client 还没读到 PIN。');
    final String pinProof = HibikiPairingProtocol.computePinProof(
      pin: shownPin!,
      clientNonce: clientNonce,
      hostNonce: start['hostNonce'] as String,
    );
    final http.Response resp = await http.post(
      confirmUri(),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{
        'sessionId': start['sessionId'] as String,
        'pinProof': pinProof,
      }),
    );
    expect(resp.statusCode, 200);
    expect(sessionResolvedCount, 1,
        reason: 'client 提交 confirm 后必须收起 host 常驻 PIN 弹窗一次。');
  });

  test('pinRequired 错 PIN 的 confirm 也触发 onPairSessionResolved（PIN 已消费）',
      () async {
    await startServer(lanRequiresPin: true);
    const String clientNonce = 'cn-resolve-wrong';
    final Map<String, dynamic> start = await startSession(clientNonce);
    final String wrongProof = HibikiPairingProtocol.computePinProof(
      pin: '000000',
      clientNonce: clientNonce,
      hostNonce: start['hostNonce'] as String,
    );
    final http.Response resp = await http.post(
      confirmUri(),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{
        'sessionId': start['sessionId'] as String,
        'pinProof': wrongProof,
      }),
    );
    expect(resp.statusCode, 401);
    // PIN 已被读到并一次性消费，host 常驻弹窗照样收起（重试走新会话拿新 PIN）。
    expect(sessionResolvedCount, 1);
  });

  test('免 PIN 会话 confirm 不触发 onPairSessionResolved（无常驻弹窗）', () async {
    await startServer(lanRequiresPin: false);
    final Map<String, dynamic> start = await startSession('cn-resolve-free');
    final http.Response resp = await http.post(
      confirmUri(),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(
          <String, String>{'sessionId': start['sessionId'] as String}),
    );
    expect(resp.statusCode, 200);
    expect(sessionResolvedCount, 0, reason: '免 PIN 会话没有常驻 PIN 弹窗，绝不触发收起回调。');
  });

  test('replay same sessionId confirmed twice is rejected', () async {
    await startServer(lanRequiresPin: false);
    final Map<String, dynamic> start = await startSession('cn-7');
    final String sid = start['sessionId'] as String;
    final http.Response first = await http.post(
      confirmUri(),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{'sessionId': sid}),
    );
    expect(first.statusCode, 200);
    final http.Response second = await http.post(
      confirmUri(),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{'sessionId': sid}),
    );
    expect(second.statusCode, 403);
    expect((jsonDecode(second.body) as Map<String, dynamic>)['reason'],
        'declined');
  });

  test('unknown sessionId yields 403', () async {
    await startServer(lanRequiresPin: false);
    final http.Response resp = await http.post(
      confirmUri(),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{'sessionId': 'bogus-session'}),
    );
    expect(resp.statusCode, 403);
  });

  test('pair v2 missing clientNonce yields 400', () async {
    await startServer(lanRequiresPin: false);
    final http.Response resp = await http.post(
      v2Uri(),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{'name': 'x'}),
    );
    expect(resp.statusCode, 400);
  });

  test('no approval UI yields pair v2 403 unavailable', () async {
    tempDir = Directory.systemTemp.createTempSync('hibiki_pair_v2_test');
    server = HibikiSyncServer(
      syncDataDir: tempDir.path,
      port: 0,
      token: 't',
      allowLan: true,
    );
    await server.start();
    final http.Response resp = await http.post(
      v2Uri(),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{'clientNonce': 'cn'}),
    );
    expect(resp.statusCode, 403);
    expect((jsonDecode(resp.body) as Map<String, dynamic>)['reason'],
        'unavailable');
  });

  test('legacy api pair unchanged backward compat', () async {
    await startServer(lanRequiresPin: true);
    final http.Response resp = await http.post(
      Uri.parse('http://127.0.0.1:${server.port}/api/pair'),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{'name': 'legacy'}),
    );
    expect(resp.statusCode, 200);
    expect((jsonDecode(resp.body) as Map<String, dynamic>)['token'],
        'super-secret-token');
  });

  test('GET pair v2 yields 405', () async {
    await startServer(lanRequiresPin: false);
    final http.Response resp = await http.get(v2Uri());
    expect(resp.statusCode, 405);
  });

  test('capabilities exposes pairing v2 plus tls subobject', () async {
    await startServer(lanRequiresPin: false);
    final http.Response resp = await http.get(
      Uri.parse('http://127.0.0.1:${server.port}/api/capabilities'),
      headers: <String, String>{
        'Authorization':
            'Basic ${base64Encode(utf8.encode('hibiki:super-secret-token'))}',
      },
    );
    expect(resp.statusCode, 200);
    final Map<String, dynamic> body =
        jsonDecode(resp.body) as Map<String, dynamic>;
    expect((body['pairing'] as Map)['v2'], isTrue);
    expect((body['tls'] as Map)['enabled'], isFalse);
  });
}
