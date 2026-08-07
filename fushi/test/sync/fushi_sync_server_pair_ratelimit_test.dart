import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_sync_server.dart';
import 'package:fushi/src/sync/pairing/fushi_pairing_protocol.dart';
import 'package:http/http.dart' as http;

// TODO-961 M3: PIN brute-force rate limiting end-to-end over /api/pair/v2/confirm.
// Attack shape: attacker repeatedly opens pair/v2 sessions, confirms each once
// guessing a different PIN. Failures aggregate per source (loopback tests use
// remoteAddress 127.0.0.1); on threshold the source is locked out (429) for a
// backoff window; success and the legitimate single-shot flow are unaffected.
void main() {
  late Directory tempDir;
  late FushiSyncServer server;
  String shownPin = '482913';
  DateTime fakeNow = DateTime.utc(2026, 1, 1, 12, 0, 0);

  Future<void> startServer({bool approve = true}) async {
    tempDir = Directory.systemTemp.createTempSync('hibiki_pair_rl_test');
    server = FushiSyncServer(
      syncDataDir: tempDir.path,
      port: 0,
      token: 'super-secret-token',
      allowLan: true,
      now: () => fakeNow,
    )
      ..onPairRequest = ((FushiPairRequest _) async => approve)
      ..onPairPinGenerated = ((FushiPairSession _) => shownPin)
      ..lanRequiresPinProvider = (() async => true);
    await server.start();
  }

  tearDown(() async {
    await server.stop();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    fakeNow = DateTime.utc(2026, 1, 1, 12, 0, 0);
    shownPin = '482913';
  });

  Uri v2Uri() => Uri.parse('http://127.0.0.1:${server.port}/api/pair/v2');
  Uri confirmUri() =>
      Uri.parse('http://127.0.0.1:${server.port}/api/pair/v2/confirm');

  Future<Map<String, dynamic>> startSession(String clientNonce) async {
    final http.Response resp = await http.post(
      v2Uri(),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{
        'name': 'Attacker',
        'clientNonce': clientNonce,
      }),
    );
    expect(resp.statusCode, 200);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<http.Response> confirmWrongPin(int attempt) async {
    final String clientNonce = 'cn-wrong-$attempt';
    final Map<String, dynamic> start = await startSession(clientNonce);
    final String wrongProof = FushiPairingProtocol.computePinProof(
      pin: '000000',
      clientNonce: clientNonce,
      hostNonce: start['hostNonce'] as String,
    );
    return http.post(
      confirmUri(),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{
        'sessionId': start['sessionId'] as String,
        'pinProof': wrongProof,
      }),
    );
  }

  Future<http.Response> confirmCorrectPin(String tag) async {
    final String clientNonce = 'cn-ok-$tag';
    final Map<String, dynamic> start = await startSession(clientNonce);
    final String proof = FushiPairingProtocol.computePinProof(
      pin: shownPin,
      clientNonce: clientNonce,
      hostNonce: start['hostNonce'] as String,
    );
    return http.post(
      confirmUri(),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{
        'sessionId': start['sessionId'] as String,
        'pinProof': proof,
      }),
    );
  }

  test('threshold failures lock out: 401 pin then 429 rate_limited', () async {
    await startServer();
    for (int i = 1; i <= 4; i++) {
      final http.Response r = await confirmWrongPin(i);
      expect(r.statusCode, 401, reason: 'attempt $i should be 401 pin');
      expect((jsonDecode(r.body) as Map<String, dynamic>)['reason'], 'pin');
    }
    final http.Response fifth = await confirmWrongPin(5);
    expect(fifth.statusCode, 429, reason: '5th attempt hits threshold');
    expect((jsonDecode(fifth.body) as Map<String, dynamic>)['reason'],
        'rate_limited');
  });

  test('within lockout window confirm is 429 even with correct PIN', () async {
    await startServer();
    for (int i = 1; i <= 5; i++) {
      await confirmWrongPin(i);
    }
    final http.Response r = await confirmCorrectPin('during-lockout');
    expect(r.statusCode, 429);
    expect(
        (jsonDecode(r.body) as Map<String, dynamic>)['reason'], 'rate_limited');
  });

  test('after backoff window correct PIN pairs again', () async {
    await startServer();
    for (int i = 1; i <= 5; i++) {
      await confirmWrongPin(i);
    }
    fakeNow = fakeNow.add(const Duration(minutes: 16));
    final http.Response r = await confirmCorrectPin('after-lockout');
    expect(r.statusCode, 200, reason: 'recovers after backoff');
    expect((jsonDecode(r.body) as Map<String, dynamic>)['token'],
        'super-secret-token');
  });

  test('success clears count: later failures start fresh', () async {
    await startServer();
    for (int i = 1; i <= 4; i++) {
      final http.Response r = await confirmWrongPin(i);
      expect(r.statusCode, 401);
    }
    final http.Response ok = await confirmCorrectPin('reset');
    expect(ok.statusCode, 200);
    for (int i = 5; i <= 8; i++) {
      final http.Response r = await confirmWrongPin(i);
      expect(r.statusCode, 401,
          reason: 'attempt ${i - 4} after reset stays 401');
    }
  });

  test('legitimate single-shot flow zero regression', () async {
    await startServer();
    final http.Response r = await confirmCorrectPin('single');
    expect(r.statusCode, 200);
    expect((jsonDecode(r.body) as Map<String, dynamic>)['token'],
        'super-secret-token');
  });

  test('PIN-free sessions are never rate limited', () async {
    tempDir = Directory.systemTemp.createTempSync('hibiki_pair_rl_free_test');
    server = FushiSyncServer(
      syncDataDir: tempDir.path,
      port: 0,
      token: 'super-secret-token',
      allowLan: true,
      now: () => fakeNow,
    )
      ..onPairRequest = ((FushiPairRequest _) async => true)
      ..onPairPinGenerated = ((FushiPairSession _) => shownPin)
      ..lanRequiresPinProvider = (() async => false);
    await server.start();
    for (int i = 0; i < 10; i++) {
      final Map<String, dynamic> start = await startSession('cn-free-$i');
      final http.Response r = await http.post(
        confirmUri(),
        headers: <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(
            <String, String>{'sessionId': start['sessionId'] as String}),
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
    expect(server.pinRateLimitTrackedSourceCount, 0,
        reason: 'cooled record should be reclaimed');
  });
}
