import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/interconnect_dav_tree_listing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// BUG-3703 host 侧：同步根树列举（PROPFIND Depth: infinity）的能力公布与层数边界。

late String _token;

Future<({int status, String body})> _send(
  FushiSyncServer server,
  String method,
  String path, {
  Map<String, String> headers = const <String, String>{},
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
    headers.forEach(req.headers.set);
    final HttpClientResponse res = await req.close();
    return (
      status: res.statusCode,
      body: await res.transform(utf8.decoder).join(),
    );
  } finally {
    client.close(force: true);
  }
}

List<String> _hrefs(String xml) => RegExp(r'<d:href>(.*?)</d:href>')
    .allMatches(xml)
    .map((RegExpMatch m) => Uri.decodeFull(m.group(1)!))
    .toList();

void main() {
  late Directory tmp;
  late FushiSyncServer server;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dav_tree_host_');
    server = FushiSyncServer(
      syncDataDir: tmp.path,
      port: 0,
      token: _token = FushiSyncServer.generateToken(),
    );
    await server.start();
    final String root = p.join(tmp.path, 'sync-data', 'fushi-data');
    File(p.join(root, 'Book A', 'progress_1_6_1000_0.5.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');
    File(p.join(root, 'Re%3Aゼロ', 'statistics_1_6_1000_2.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('[]');
    Directory(p.join(root, 'Empty')).createSync(recursive: true);
    // 第三层：同步根布局里不存在，树列举必须不列。
    File(p.join(root, '__srs__', 'writer', 'deep.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');
    File(p.join(root, 'spill.json')).writeAsStringSync('{}');
  });

  tearDown(() async {
    await server.stop();
    await tmp.delete(recursive: true);
  });

  test('capabilities 公布树列举层数 = 2', () async {
    final r = await _send(server, 'GET', '/api/capabilities');
    expect(r.status, 200);
    expect(
      interconnectDavTreeListingLevels(jsonDecode(r.body)),
      kDavTreeListingMaxLevels,
    );
    expect(kDavTreeListingMaxLevels, 2);
  });

  test('老 host 形状（无 webdav 分组）判为不支持', () {
    expect(interconnectDavTreeListingLevels(<String, Object?>{}), 0);
    expect(interconnectDavTreeListingLevels(null), 0);
    expect(
      interconnectDavTreeListingLevels(<String, Object?>{
        'webdav': <String, Object?>{'treeListingLevels': '2'},
      }),
      0,
    );
  });

  test('Depth: infinity 恰好列到孙层，不再往下', () async {
    final r = await _send(
      server,
      'PROPFIND',
      '/fushi-data/',
      headers: <String, String>{'Depth': 'infinity'},
    );
    expect(r.status, 207);
    expect(
      _hrefs(r.body).toSet(),
      <String>{
        '/fushi-data/',
        '/fushi-data/Book A/',
        '/fushi-data/Book A/progress_1_6_1000_0.5.json',
        '/fushi-data/Re%3Aゼロ/',
        '/fushi-data/Re%3Aゼロ/statistics_1_6_1000_2.json',
        '/fushi-data/Empty/',
        '/fushi-data/__srs__/',
        '/fushi-data/__srs__/writer/',
        '/fushi-data/spill.json',
      },
    );
  });

  test('孙层条目与对该文件夹单独 Depth 1 的回包逐字相同', () async {
    final tree = await _send(
      server,
      'PROPFIND',
      '/fushi-data/',
      headers: <String, String>{'Depth': 'infinity'},
    );
    final single = await _send(
      server,
      'PROPFIND',
      '/fushi-data/${Uri.encodeComponent('Re%3Aゼロ')}/',
      headers: <String, String>{'Depth': '1'},
    );
    final RegExp block = RegExp(r'<d:response>.*?</d:response>', dotAll: true);
    final Set<String> treeBlocks =
        block.allMatches(tree.body).map((RegExpMatch m) => m.group(0)!).toSet();
    for (final RegExpMatch m in block.allMatches(single.body)) {
      expect(treeBlocks, contains(m.group(0)));
    }
  });

  test('Depth 1 / Depth 0 行为不变', () async {
    final d1 = await _send(
      server,
      'PROPFIND',
      '/fushi-data/',
      headers: <String, String>{'Depth': '1'},
    );
    expect(
      _hrefs(d1.body).where((String h) => h.split('/').length > 4),
      isEmpty,
      reason: 'Depth 1 不得带出孙层',
    );
    final d0 = await _send(
      server,
      'PROPFIND',
      '/fushi-data/',
      headers: <String, String>{'Depth': '0'},
    );
    expect(_hrefs(d0.body), <String>['/fushi-data/']);
  });

  test('树列举与其它 WebDAV 请求同一道鉴权', () async {
    final HttpClient client = HttpClient();
    addTearDown(() => client.close(force: true));
    final HttpClientRequest req = await client.openUrl(
      'PROPFIND',
      Uri.parse('http://127.0.0.1:${server.port}/fushi-data/'),
    );
    req.headers.set('Depth', 'infinity');
    final HttpClientResponse res = await req.close();
    await res.drain<void>();
    expect(res.statusCode, 401);
  });
}
