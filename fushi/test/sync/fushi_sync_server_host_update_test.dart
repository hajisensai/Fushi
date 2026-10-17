import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/host_update/host_update_protocol.dart';
import 'package:http/http.dart' as http;

/// 反馈 Pp8XPyve0N：`/api/host/update` 的鉴权 / 开关 / 平台门 / 信任区 / nonce 行为。
class _FakeUpdater implements HostSelfUpdater {
  _FakeUpdater();

  @override
  bool platformSupported = true;
  bool allowed = true;
  int starts = 0;
  bool refreshed = false;
  HostUpdateDenial? startRejection;

  HostUpdateStatus get _base => HostUpdateStatus(
    currentVersion: '2.10.0',
    platform: 'windows',
    supported: platformSupported,
    remoteUpdateAllowed: allowed,
    latestVersion: '2.11.0',
  );

  @override
  Future<bool> isRemoteUpdateAllowed() async => allowed;

  @override
  Future<HostUpdateStatus> status({bool refresh = false}) async {
    refreshed = refreshed || refresh;
    return _base;
  }

  @override
  Future<HostUpdateStatus> startUpdate() async {
    final HostUpdateDenial? rejection = startRejection;
    if (rejection != null) throw HostUpdateRejected(rejection);
    starts++;
    return _base.copyWith(phase: HostUpdatePhase.downloading, progress: 0);
  }
}

void main() {
  late Directory tempDir;
  late FushiSyncServer server;
  late _FakeUpdater updater;
  const String peerToken = 'peer-token-a';
  const String otherPeerToken = 'peer-token-b';

  Future<void> startServer({bool wireUpdater = true}) async {
    tempDir = Directory.systemTemp.createTempSync('fushi_host_update_test');
    updater = _FakeUpdater();
    server =
        FushiSyncServer(
            syncDataDir: tempDir.path,
            port: 0,
            token: 'shared-token',
            allowLan: true,
          )
          ..pairedPeerTokensProvider = (() async => <String>{
            peerToken,
            otherPeerToken,
          });
    if (wireUpdater) server.hostSelfUpdater = updater;
    await server.start();
  }

  tearDown(() async {
    await server.stop();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Map<String, String> auth(String token) => <String, String>{
    'Authorization': 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
  };

  Uri uri({int? port, bool refresh = false}) => Uri.parse(
    'http://127.0.0.1:${port ?? server.port}$kHostUpdatePath'
    '${refresh ? '?refresh=1' : ''}',
  );

  Future<http.Response> getStatus(
    String token, {
    int? port,
    bool refresh = false,
  }) => http.get(
    uri(port: port, refresh: refresh),
    headers: auth(token),
  );

  Future<String> issueNonce(String token, {int? port}) async {
    final http.Response resp = await getStatus(token, port: port);
    expect(resp.statusCode, 200);
    final HostUpdateStatus status = HostUpdateStatus.fromJson(
      (jsonDecode(resp.body) as Map).cast<String, Object?>(),
    );
    return status.nonce!;
  }

  Future<http.Response> trigger(String token, String? nonce, {int? port}) =>
      http.post(
        uri(port: port),
        headers: <String, String>{
          ...auth(token),
          'Content-Type': 'application/json',
        },
        body: jsonEncode(<String, Object?>{'nonce': nonce}),
      );

  HostUpdateDenial? denialOf(http.Response resp) =>
      parseHostUpdateDenialBody(resp.body);

  test(
    'host without updater answers 404 and advertises no capability',
    () async {
      await startServer(wireUpdater: false);
      expect((await getStatus(peerToken)).statusCode, 404);
      final http.Response caps = await http.get(
        Uri.parse('http://127.0.0.1:${server.port}/api/capabilities'),
        headers: auth(peerToken),
      );
      expect((jsonDecode(caps.body) as Map)['hostUpdate'], isFalse);
    },
  );

  test(
    'GET returns version, refresh flag and a nonce for a paired peer',
    () async {
      await startServer();
      final http.Response resp = await getStatus(peerToken, refresh: true);
      expect(resp.statusCode, 200);
      final HostUpdateStatus status = HostUpdateStatus.fromJson(
        (jsonDecode(resp.body) as Map).cast<String, Object?>(),
      );
      expect(status.currentVersion, '2.10.0');
      expect(status.latestVersion, '2.11.0');
      expect(status.nonce, isNotEmpty);
      expect(updater.refreshed, isTrue);
    },
  );

  test(
    'shared server token is refused (paired-device token required)',
    () async {
      await startServer();
      final http.Response resp = await getStatus('shared-token');
      expect(resp.statusCode, 403);
      expect(denialOf(resp), HostUpdateDenial.peerTokenRequired);
      expect((await getStatus('bogus')).statusCode, 401);
    },
  );

  test('valid nonce triggers exactly once; replay is refused', () async {
    await startServer();
    final String nonce = await issueNonce(peerToken);
    final http.Response first = await trigger(peerToken, nonce);
    expect(first.statusCode, 200);
    expect(updater.starts, 1);
    final http.Response replay = await trigger(peerToken, nonce);
    expect(replay.statusCode, 400);
    expect(denialOf(replay), HostUpdateDenial.invalidNonce);
    expect(updater.starts, 1);
  });

  test('missing nonce or a nonce issued to another peer is refused', () async {
    await startServer();
    expect(
      denialOf(await trigger(peerToken, null)),
      HostUpdateDenial.invalidNonce,
    );
    final String foreign = await issueNonce(otherPeerToken);
    expect(
      denialOf(await trigger(peerToken, foreign)),
      HostUpdateDenial.invalidNonce,
    );
    expect(updater.starts, 0);
  });

  test('non-JSON body is refused even with a valid nonce', () async {
    await startServer();
    final String nonce = await issueNonce(peerToken);
    final http.Response resp = await http.post(
      uri(),
      headers: <String, String>{
        ...auth(peerToken),
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: 'nonce=$nonce',
    );
    expect(denialOf(resp), HostUpdateDenial.invalidNonce);
    expect(updater.starts, 0);
  });

  test('host switch off refuses with remote_update_disabled', () async {
    await startServer();
    updater.allowed = false;
    final String nonce = await issueNonce(peerToken);
    final http.Response resp = await trigger(peerToken, nonce);
    expect(resp.statusCode, 403);
    expect(denialOf(resp), HostUpdateDenial.disabled);
    expect(updater.starts, 0);
  });

  test('platform gate refuses with platform_unsupported', () async {
    await startServer();
    updater.platformSupported = false;
    final String nonce = await issueNonce(peerToken);
    final http.Response resp = await trigger(peerToken, nonce);
    expect(resp.statusCode, 403);
    expect(denialOf(resp), HostUpdateDenial.unsupported);
  });

  test('P2P tunnel zone may read status but not trigger', () async {
    await startServer();
    final int p2pPort = await server.startP2pListener();
    final String nonce = await issueNonce(peerToken, port: p2pPort);
    final http.Response resp = await trigger(peerToken, nonce, port: p2pPort);
    expect(resp.statusCode, 403);
    expect(denialOf(resp), HostUpdateDenial.zone);
    expect(updater.starts, 0);
  });

  test('updater rejection (busy) is reported as 409', () async {
    await startServer();
    updater.startRejection = HostUpdateDenial.busy;
    final String nonce = await issueNonce(peerToken);
    final http.Response resp = await trigger(peerToken, nonce);
    expect(resp.statusCode, 409);
    expect(denialOf(resp), HostUpdateDenial.busy);
  });

  group('HostUpdateNonceStore', () {
    test('expired nonces are refused', () {
      DateTime now = DateTime(2026, 10, 13, 12);
      final HostUpdateNonceStore store = HostUpdateNonceStore(now: () => now);
      final String nonce = store.issue('peer');
      now = now.add(const Duration(minutes: 3));
      expect(store.consume(nonce, 'peer'), isFalse);
    });

    test('capacity evicts the oldest nonce', () {
      final HostUpdateNonceStore store = HostUpdateNonceStore(capacity: 2);
      final String oldest = store.issue('peer');
      store.issue('peer');
      final String newest = store.issue('peer');
      expect(store.consume(oldest, 'peer'), isFalse);
      expect(store.consume(newest, 'peer'), isTrue);
    });
  });
}
