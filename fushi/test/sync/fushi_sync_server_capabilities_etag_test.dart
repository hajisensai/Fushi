import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/host_update/host_update_protocol.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// 只为让 host 声明 `hostUpdate`（能力表随装配变化）；成员都用不到。
class _NoopUpdater implements HostSelfUpdater {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// BUG-5603 审查后修正 4：`GET /api/capabilities` 带 ETag、认 `If-None-Match`。client 据此不设有效期地复用能力表：
/// 没变回 304 空体，host 改了装配 / 设置下一次请求就拿到新正文。
void main() {
  late Directory tempDir;
  late FushiSyncServer server;
  const String peerToken = 'peer-token-a';

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('fushi_caps_etag_test');
    server = FushiSyncServer(
      syncDataDir: tempDir.path,
      port: 0,
      token: 'shared-token',
      allowLan: true,
    )..pairedPeerTokensProvider = (() async => <String>{peerToken});
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<http.Response> caps({String? ifNoneMatch}) => http.get(
    Uri.parse('http://127.0.0.1:${server.port}/api/capabilities'),
    headers: <String, String>{
      'Authorization':
          'Basic ${base64Encode(utf8.encode('hibiki:$peerToken'))}',
      'If-None-Match': ?ifNoneMatch,
    },
  );

  test('带 ETag；同一个 ETag 的条件请求回 304 空体；装配变了回 200 新正文 + 新 ETag', () async {
    final http.Response first = await caps();
    expect(first.statusCode, 200);
    final String? etag = first.headers['etag'];
    expect(etag, isNotNull);
    expect(etag, matches(RegExp(r'^W/"[0-9a-f]{32}"$')));
    expect(first.headers['cache-control'], 'no-cache');
    expect((jsonDecode(first.body) as Map)['hostUpdate'], isFalse);

    final http.Response same = await caps(ifNoneMatch: etag);
    expect(same.statusCode, 304);
    expect(same.bodyBytes, isEmpty);
    expect(same.headers['etag'], etag);

    expect((await caps(ifNoneMatch: '"stale"')).statusCode, 200);

    server.hostSelfUpdater = _NoopUpdater();
    final http.Response changed = await caps(ifNoneMatch: etag);
    expect(changed.statusCode, 200, reason: 'host 改了能力表：旧 ETag 不再命中');
    expect((jsonDecode(changed.body) as Map)['hostUpdate'], isTrue);
    expect(changed.headers['etag'], isNot(etag));
  });
}
