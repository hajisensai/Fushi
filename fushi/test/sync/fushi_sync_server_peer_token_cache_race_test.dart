import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// BUG：吊销已配对设备时若恰逢 per-peer token 集合在飞加载，旧集合被写回缓存，
/// 被吊销的 token 一直有效到下一次 invalidate。
///
/// 真 [FushiSyncServer]（port 0、loopback），用 Basic 打 `GET /api/capabilities`
/// 探测某个 token 是否被受理。
void main() {
  late Directory tempDir;
  FushiSyncServer? server;

  Future<FushiSyncServer> startServer(
    Future<Set<String>> Function() provider,
  ) async {
    tempDir = Directory.systemTemp.createTempSync('fushi_peer_token_race');
    final FushiSyncServer s = FushiSyncServer(
      syncDataDir: tempDir.path,
      port: 0,
      token: 'shared-token',
    )..pairedPeerTokensProvider = provider;
    await s.start();
    server = s;
    return s;
  }

  tearDown(() async {
    await server?.stop();
    server = null;
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<int> authProbe(FushiSyncServer s, String token) async {
    final http.Response resp = await http.get(
      Uri.parse('http://127.0.0.1:${s.port}/api/capabilities'),
      headers: <String, String>{
        'Authorization': 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
      },
    );
    return resp.statusCode;
  }

  Future<void> waitFor(bool Function() condition) async {
    final Stopwatch sw = Stopwatch()..start();
    while (!condition()) {
      if (sw.elapsed > const Duration(seconds: 10)) {
        fail('condition not reached within 10s');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test(
    'invalidate during an in-flight load discards the stale token set',
    () async {
      const String peer = 'peer-token-P';
      final Completer<Set<String>> first = Completer<Set<String>>();
      int calls = 0;
      final FushiSyncServer s = await startServer(() {
        calls++;
        if (calls == 1) return first.future;
        // 吊销之后的库：P 已删除。
        return Future<Set<String>>.value(<String>{});
      });

      final Future<int> requestA = authProbe(s, peer);
      await waitFor(() => calls == 1);
      // 吊销：先删库（之后的 provider 返回空集），再 invalidate——此时加载 A 仍在飞。
      s.invalidatePeerTokenCache();
      first.complete(<String>{peer});
      await requestA;

      expect(await authProbe(s, peer), 401);
      expect(calls, 2);
    },
  );

  test('a failed load is not cached; the next request reloads', () async {
    const String peer = 'peer-token-P';
    int calls = 0;
    final FushiSyncServer s = await startServer(() async {
      calls++;
      if (calls == 1) throw StateError('db read failed');
      return <String>{peer};
    });

    expect(await authProbe(s, peer), isNot(200));
    expect(await authProbe(s, peer), 200);
    expect(calls, 2);
  });
}
