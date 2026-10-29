import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_music/fushi_music.dart';
import 'package:test/test.dart';

import 'plugin_host_test.dart'
    show buildPlugin, fakePublicResolve, manifest, noRedirectProbe;

/// HTTP 请求 / 响应体走二进制区：宿主拿到的请求体是 Uint8List（不是 base64 串），交回的响应体
/// 原样（含非 UTF-8 字节）到达插件；同一实例连续多步复用同一个后台 isolate。
void main() {
  late Directory root;
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];

  const String js = r'''
module.exports = {
  async search(a) {
    const r = await fushi.http.request({ url: 'https://api.example.com/p', method: 'POST',
      bodyBytes: new Uint8Array([0, 1, 2, 255]), responseType: 'bytes' });
    return { items: [], hasMore: false, total: Array.from(r.bytes).reduce((x, y) => x * 256 + y, 0) };
  },
  async album() { return null; },
  async stream() { return null; },
  async lyrics() { return null; },
};
''';

  setUp(() {
    requests.clear();
    root = Directory.systemTemp.createTempSync('fmp-bytes-');
  });
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('请求体以字节交给宿主，响应体原样交回插件', () async {
    final MusicPluginManager m = MusicPluginManager(
      rootDir: root,
      httpClientFactory: HttpClient.new,
      resolver: fakePublicResolve,
      mediaProbe: noRedirectProbe,
      log: (_, _, _) {},
      httpPerformer: (Map<String, Object?> args) async {
        requests.add(args);
        return <String, Object?>{
          'status': 200,
          'url': args['url'],
          'headers': <String, String>{},
          'setCookies': const <String>[],
          'body': Uint8List.fromList(<int>[0xff, 0x00, 0x80]),
        };
      },
    );
    addTearDown(m.dispose);
    final Uint8List zip = buildPlugin(manifest(), <String, String>{
      'main.js': js,
    });
    await m.install(zip, (await m.inspect(zip)).digest);
    final MusicPluginInstance inst = await m.instance('moe.test.fake');
    for (int i = 0; i < 3; i++) {
      final Object? r = await inst.invoke('search', <String, Object?>{
        'query': 'x',
        'page': 1,
        'type': 'song',
      });
      expect((r! as Map<Object?, Object?>)['total'], 0xff0080);
    }
    expect(requests, hasLength(3));
    for (final Map<String, Object?> a in requests) {
      expect(a['body'], isA<Uint8List>());
      expect(a['body'], <int>[0, 1, 2, 255]);
      expect(a.containsKey('bodyBase64'), isFalse);
    }
  });
}
