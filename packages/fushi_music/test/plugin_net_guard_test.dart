import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_music/fushi_music.dart';
import 'package:test/test.dart';

import 'plugin_host_test.dart' show buildPlugin, manifest, testVaultKey;

/// 插件出站网络守卫：私网判据覆盖内嵌 IPv4 的 IPv6 形态；解析失败不放行；连接钉在核对过的 IP
/// 上（DNS rebinding 换不了地址）；媒体地址逐跳核对重定向、请求头走白名单。
void main() {
  group('isMusicPluginPrivateAddress', () {
    test('内嵌 IPv4 的 IPv6 形态按内嵌地址判', () {
      for (final String a in <String>[
        '64:ff9b::a00:1', // NAT64 → 10.0.0.1
        '64:ff9b::7f00:1', // NAT64 → 127.0.0.1
        '64:ff9b:1::1', // 本地 NAT64 前缀整段
        '2002:c0a8:101::1', // 6to4 → 192.168.1.1
        '2002:7f00:1::1', // 6to4 → 127.0.0.1
        '::a9fe:a9fe', // IPv4-compatible → 169.254.169.254
        '::ffff:a00:1', // IPv4-mapped → 10.0.0.1
        '192.0.0.8',
        '0.0.0.0',
        '255.255.255.255',
        'fec0::1',
        'ff02::1',
      ]) {
        expect(
          isMusicPluginPrivateAddress(InternetAddress(a)),
          isTrue,
          reason: a,
        );
      }
      for (final String a in <String>[
        '64:ff9b::808:808', // NAT64 → 8.8.8.8
        '2002:808:808::1', // 6to4 → 8.8.8.8
        '93.184.216.34',
      ]) {
        expect(
          isMusicPluginPrivateAddress(InternetAddress(a)),
          isFalse,
          reason: a,
        );
      }
    });

    test('198.18/15 解析结果不拦（fake-ip 代理把所有域名都解析到这一段）', () {
      expect(
        isMusicPluginPrivateAddress(InternetAddress('198.18.0.7')),
        isFalse,
      );
    });
  });

  group('resolveMusicPluginPublicAddress', () {
    Future<Object?> err(Future<Object?> f) =>
        f.then<Object?>((_) => null, onError: (Object e) => e);

    test('DNS 失败不放行', () async {
      final Object? e = await err(
        resolveMusicPluginPublicAddress(
          'x.example.com',
          resolve: (String h) async => throw const SocketException('nx'),
        ),
      );
      expect(e, isA<MusicPluginHttpException>());
    });

    test('解析不到地址不放行', () async {
      final Object? e = await err(
        resolveMusicPluginPublicAddress(
          'x.example.com',
          resolve: (String h) async => <InternetAddress>[],
        ),
      );
      expect(e, isA<MusicPluginHttpException>());
    });

    test('任一地址落私网就拒绝', () async {
      final Object? e = await err(
        resolveMusicPluginPublicAddress(
          'x.example.com',
          resolve: (String h) async => <InternetAddress>[
            InternetAddress('93.184.216.34'),
            InternetAddress('10.0.0.1'),
          ],
        ),
      );
      expect(e, isA<MusicPluginHttpException>());
    });

    test('IP 字面量不走 DNS、直接核对', () async {
      final Object? e = await err(
        resolveMusicPluginPublicAddress(
          '127.0.0.1',
          resolve: (String h) async => fail('不该解析 IP 字面量'),
        ),
      );
      expect(e, isA<MusicPluginHttpException>());
    });
  });

  group('MusicPluginGuardedHttp', () {
    // 不吃环境变量里的代理：这组测试验证直连路径。
    HttpClient direct() => HttpClient()..findProxy = (Uri u) => 'DIRECT';
    late HttpServer server;
    final List<String?> hosts = <String?>[];

    setUp(() async {
      hosts.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest r) async {
        hosts.add(r.headers.value(HttpHeaders.hostHeader));
        if (r.uri.path == '/hop') {
          r.response
            ..statusCode = HttpStatus.found
            ..headers.set(HttpHeaders.locationHeader, '/final');
        } else {
          r.response.write('ok');
        }
        await r.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    test('连接钉在核对时的 IP 上：之后 DNS 再变也连不到别处', () async {
      int lookups = 0;
      final MusicPluginGuardedHttp net = MusicPluginGuardedHttp(
        direct(),
        // 第一次解析给回环（测试放行），之后换成不可达地址：模拟 DNS rebinding。
        resolve: (String h) async => <InternetAddress>[
          if (lookups++ == 0)
            InternetAddress.loopbackIPv4
          else
            InternetAddress('203.0.113.1'),
        ],
        isBlocked: (InternetAddress a) => false,
      );
      addTearDown(() => net.close(force: true));
      final Uri uri = Uri.parse('http://pinned.test:${server.port}/x');
      await net.pin(uri);
      final HttpClientResponse res = await (await net.client.getUrl(
        uri,
      )).close();
      await res.drain<void>();
      expect(res.statusCode, 200);
      expect(lookups, 1, reason: '建连不再解析');
      expect(hosts.single, 'pinned.test:${server.port}', reason: 'Host 保留原主机名');
    });

    test('没核对过的主机不建连', () async {
      final MusicPluginGuardedHttp net = MusicPluginGuardedHttp(
        direct(),
        resolve: (String h) async => <InternetAddress>[
          InternetAddress.loopbackIPv4,
        ],
        isBlocked: (InternetAddress a) => false,
      );
      addTearDown(() => net.close(force: true));
      await expectLater(() async {
        final HttpClientRequest r = await net.client.getUrl(
          Uri.parse('http://unpinned.test:${server.port}/'),
        );
        await r.close();
      }(), throwsA(isA<SocketException>()));
      expect(hosts, isEmpty);
    });

    test('走代理时没核对过的主机同样不建连', () async {
      final MusicPluginGuardedHttp net = MusicPluginGuardedHttp(
        HttpClient()..findProxy = (Uri u) => 'PROXY 127.0.0.1:${server.port}',
        resolve: (String h) async => <InternetAddress>[
          InternetAddress.loopbackIPv4,
        ],
        isBlocked: (InternetAddress a) => false,
      );
      addTearDown(() => net.close(force: true));
      await expectLater(() async {
        final HttpClientRequest r = await net.client.getUrl(
          Uri.parse('http://unpinned.test/'),
        );
        await r.close();
      }(), throwsA(isA<SocketException>()));
      expect(hosts, isEmpty);
    });

    test('缺省判据下回环目标在核对时就被拒，不建连', () async {
      final MusicPluginGuardedHttp net = MusicPluginGuardedHttp(
        direct(),
        resolve: (String h) async => <InternetAddress>[
          InternetAddress.loopbackIPv4,
        ],
      );
      addTearDown(() => net.close(force: true));
      await expectLater(
        net.pin(Uri.parse('http://evil.test:${server.port}/')),
        throwsA(isA<MusicPluginHttpException>()),
      );
      expect(hosts, isEmpty);
    });

    test('probeRedirect 只报单跳 Location，不自动跟随', () async {
      final MusicPluginGuardedHttp net = MusicPluginGuardedHttp(
        direct(),
        resolve: (String h) async => <InternetAddress>[
          InternetAddress.loopbackIPv4,
        ],
        isBlocked: (InternetAddress a) => false,
      );
      addTearDown(() => net.close(force: true));
      final String base = 'http://media.test:${server.port}';
      expect(
        await net.probeRedirect(Uri.parse('$base/hop'), <String, String>{}),
        '/final',
      );
      expect(
        await net.probeRedirect(Uri.parse('$base/final'), <String, String>{}),
        isNull,
      );
      expect(hosts.length, 2);
    });
  });

  group('checkMusicPluginMediaHeaders', () {
    test('白名单内的头放行，名字大小写不敏感', () {
      expect(
        checkMusicPluginMediaHeaders(<String, String>{
          'Referer': 'https://y.example.com/',
          'User-Agent': 'x',
        }),
        hasLength(2),
      );
    });

    test('白名单外的头、换行注入、过多都报错', () {
      expect(
        () => checkMusicPluginMediaHeaders(<String, String>{'Host': 'evil'}),
        throwsA(isA<MusicPluginHttpException>()),
      );
      expect(
        () => checkMusicPluginMediaHeaders(<String, String>{
          'Referer': 'a\r\nX-Evil: 1',
        }),
        throwsA(isA<MusicPluginHttpException>()),
      );
      expect(
        () => checkMusicPluginMediaHeaders(<String, String>{
          for (int i = 0; i < 17; i++) 'cookie$i': 'x',
        }),
        throwsA(isA<MusicPluginHttpException>()),
      );
    });
  });

  group('媒体地址（插件 stream）', () {
    late Directory root;

    const String js = r'''
module.exports = {
  async search() { return { items: [], hasMore: false, total: 0 }; },
  async album() { return null; },
  async stream(a) {
    if (a.id === 'hdr') return { url: 'https://m1.cdn.example.com/h.mp3', headers: { 'X-Forwarded-For': '1' } };
    return { url: 'https://m1.cdn.example.com/' + a.id + '.mp3', headers: { Referer: 'https://api.example.com/' } };
  },
  async lyrics() { return null; },
};
''';

    setUp(() => root = Directory.systemTemp.createTempSync('fmp-net-'));
    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    Future<(MusicPluginManager, MusicPluginSource)> open(
      Map<String, String?> redirects,
    ) async {
      final MusicPluginManager m = MusicPluginManager(
        rootDir: root,
        vaultKey: testVaultKey,
        httpClientFactory: HttpClient.new,
        log: (_, _, _) {},
        resolver: (String h) async => <InternetAddress>[
          InternetAddress('93.184.216.34'),
        ],
        mediaProbe: (Uri uri, Map<String, String> headers) async {
          expect(headers.keys, everyElement(isIn(<String>['Referer'])));
          return redirects[uri.toString()];
        },
      );
      final Uint8List buildZip = buildPlugin(manifest(), <String, String>{
        'main.js': js,
      });
      await m.install(buildZip, (await m.inspect(buildZip)).digest);
      final MusicPluginSource src = m.source('moe.test.fake');
      return (m, src);
    }

    test('授权内的重定向逐跳跟随，播放器拿到最终地址', () async {
      final (
        MusicPluginManager m,
        MusicPluginSource src,
      ) = await open(<String, String?>{
        'https://m1.cdn.example.com/a.mp3': 'https://m2.cdn.example.com/b.mp3',
      });
      addTearDown(m.dispose);
      final MusicPluginStream s = await src.stream('a');
      expect(s.url, 'https://m2.cdn.example.com/b.mp3');
      expect(s.headers, <String, String>{
        'Referer': 'https://api.example.com/',
      });
    });

    test('重定向到授权外的地址就拒绝', () async {
      final (MusicPluginManager m, MusicPluginSource src) = await open(
        <String, String?>{
          'https://m1.cdn.example.com/a.mp3': 'http://127.0.0.1/admin',
        },
      );
      addTearDown(m.dispose);
      await expectLater(src.stream('a'), throwsA(isA<MusicPluginException>()));
    });

    test('白名单外的请求头报错，不交给播放器', () async {
      final (MusicPluginManager m, MusicPluginSource src) = await open(
        <String, String?>{},
      );
      addTearDown(m.dispose);
      await expectLater(
        src.stream('hdr'),
        throwsA(
          isA<MusicPluginException>().having(
            (MusicPluginException e) => e.message,
            'message',
            contains('X-Forwarded-For'),
          ),
        ),
      );
    });
  });
}
