import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:test/test.dart';

// 复习同步的互联长轮询令牌（`/api/srs/changes`）：只有客户端写进新 head（PUT）才推进。删旧 head 不带任何新数据，
// 以前也推进，等于每轮多唤醒一次全部设备（反馈：iPhone 连着 Windows host 时复习同步一轮接一轮不停）。

late String _token;

Future<int> _send(
  FushiSyncServer server,
  String method,
  String path, {
  List<int>? body,
}) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.port}$path'),
    );
    req.headers.set(
      'Authorization',
      'Basic ${base64Encode(utf8.encode('hibiki:$_token'))}',
    );
    if (body != null) req.add(body);
    final HttpClientResponse res = await req.close();
    await res.drain<void>();
    return res.statusCode;
  } finally {
    client.close(force: true);
  }
}

void main() {
  late Directory tmp;
  late FushiSyncServer server;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('srs_change_feed_host_');
    server = FushiSyncServer(
      syncDataDir: tmp.path,
      port: 0,
      token: _token = FushiSyncServer.generateToken(),
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    await tmp.delete(recursive: true);
  });

  test('PUT 新 head 推进令牌，DELETE 旧 head 不推进', () async {
    const String dir = '/fushi-data/fushi-srs/p/v2/devices/d';
    for (final String seg in <String>[
      '/fushi-data/fushi-srs',
      '/fushi-data/fushi-srs/p',
      '/fushi-data/fushi-srs/p/v2',
      '/fushi-data/fushi-srs/p/v2/devices',
      dir,
    ]) {
      await _send(server, 'MKCOL', seg);
    }
    final int t0 = server.srsChanges.token;
    expect(
      await _send(server, 'PUT', '$dir/head-1-aaaa.bin', body: <int>[1]),
      inInclusiveRange(200, 299),
    );
    final int t1 = server.srsChanges.token;
    expect(t1, isNot(t0));
    expect(
      await _send(server, 'DELETE', '$dir/head-1-aaaa.bin'),
      inInclusiveRange(200, 299),
    );
    expect(server.srsChanges.token, t1);
  });
}
