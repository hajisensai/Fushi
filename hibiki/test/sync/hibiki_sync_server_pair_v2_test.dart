import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/pairing/hibiki_pairing_protocol.dart';
import 'package:http/http.dart' as http;

// TODO-961 M1 §3.6 behavior tests for /api/pair/v2 + /api/pair/v2/confirm.
void main() {
  late Directory tempDir;
  late HibikiSyncServer server;
  String? shownPin;

  Future<void> startServer({
    required bool lanRequiresPin,
    bool approve = true,
  }) async {
    tempDir = Directory.systemTemp.createTempSync('hibiki_pair_v2_test');
    server = HibikiSyncServer(
      syncDataDir: tempDir.path,
      port: 0,
      token: 'super-secret-token',
      allowLan: true,
    )
      ..onPairRequest = ((HibikiPairRequest _) async => approve)
      ..onPairPinGenerated = ((HibikiPairSession s) {
        shownPin = '482913';
        return shownPin!;
      })
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

  test('double confirm PIN ok but host declines yields 403 declined', () async {
    await startServer(lanRequiresPin: true, approve: false);
    const String clientNonce = 'cn-6';
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
    expect(resp.statusCode, 403);
    expect(
        (jsonDecode(resp.body) as Map<String, dynamic>)['reason'], 'declined');
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
