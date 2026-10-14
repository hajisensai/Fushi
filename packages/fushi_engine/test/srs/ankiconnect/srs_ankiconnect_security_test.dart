import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_endpoint.dart';
import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_media.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

import 'ankiconnect_harness.dart';

class _Conn implements HttpConnectionInfo {
  _Conn(String ip) : remoteAddress = InternetAddress(ip);
  @override
  final InternetAddress remoteAddress;
  @override
  int get remotePort => 50000;
  @override
  int get localPort => 19633;
}

void main() {
  late AcHarness h;
  late SrsAnkiConnectEndpoint endpoint;

  setUp(() async {
    h = await AcHarness.create(
      dns: <String, List<InternetAddress>>{
        'cdn.example.com': <InternetAddress>[InternetAddress('93.184.216.34')],
        'rebind.example.com': <InternetAddress>[InternetAddress('10.1.2.3')],
        'mixed.example.com': <InternetAddress>[
          InternetAddress('93.184.216.34'),
          InternetAddress('192.168.1.1'),
        ],
      },
    );
    endpoint = SrsAnkiConnectEndpoint(handler: h.handler);
  });

  Future<shelf.Response> send(
    Object? body, {
    String method = 'POST',
    String ip = '127.0.0.1',
    Map<String, String> headers = const <String, String>{},
  }) => endpoint.handle(
    shelf.Request(
      method,
      Uri.parse('http://127.0.0.1:19633/'),
      body: body == null ? null : jsonEncode(body),
      headers: <String, String>{'content-type': 'text/plain', ...headers},
      context: <String, Object>{'shelf.io.connection_info': _Conn(ip)},
    ),
  );

  Future<Object?> json(shelf.Response r) async =>
      jsonDecode(await r.readAsString());

  final Map<String, Object?> addNote = <String, Object?>{
    'action': 'addNote',
    'version': 6,
    'params': <String, Object?>{'note': yomitanNote('猫')},
  };

  group('Origin 白名单', () {
    test('网页 Origin（text/plain 简单请求）调 addNote → 403，且没写库', () async {
      final shelf.Response r = await send(
        addNote,
        headers: <String, String>{'origin': 'https://evil.example'},
      );
      expect(r.statusCode, 403);
      expect(r.headers['access-control-allow-origin'], isNull);
      expect(await h.store.hasUserNotes(), isFalse);
    });

    test('被拒的 Origin 调 requestPermission → 200 {permission: denied}', () async {
      final shelf.Response r = await send(
        <String, Object?>{'action': 'requestPermission', 'version': 6},
        headers: <String, String>{'origin': 'https://evil.example'},
      );
      expect(r.statusCode, 200);
      expect(await json(r), <String, Object?>{
        'result': <String, Object?>{'permission': 'denied'},
        'error': null,
      });
      expect(r.headers['access-control-allow-origin'], 'https://evil.example');
    });

    test('浏览器扩展 / localhost Origin 放行并回显 ACAO', () async {
      for (final String o in <String>[
        'chrome-extension://abcdefghijklmnop',
        'moz-extension://1234-5678',
        'safari-web-extension://x',
        'http://localhost',
        'http://127.0.0.1:8080',
      ]) {
        final shelf.Response r = await send(
          <String, Object?>{'action': 'requestPermission', 'version': 6},
          headers: <String, String>{'origin': o},
        );
        expect(r.statusCode, 200, reason: o);
        expect(r.headers['access-control-allow-origin'], o, reason: o);
        expect(((await json(r))! as Map)['result'], <String, Object?>{
          'permission': 'granted',
          'requireApikey': false,
          'version': 6,
        });
      }
      final shelf.Response add = await send(
        addNote,
        headers: <String, String>{'origin': 'chrome-extension://abc'},
      );
      expect(((await json(add))! as Map)['result'], isA<int>());
    });

    test('OPTIONS 预检：白名单内 200 + CORS 头，白名单外 403', () async {
      final shelf.Response ok = await send(
        null,
        method: 'OPTIONS',
        headers: <String, String>{
          'origin': 'chrome-extension://abc',
          'access-control-request-method': 'POST',
          'access-control-request-private-network': 'true',
        },
      );
      expect(ok.statusCode, 200);
      expect(
        ok.headers['access-control-allow-origin'],
        'chrome-extension://abc',
      );
      expect(ok.headers['access-control-allow-methods'], contains('POST'));
      expect(ok.headers['access-control-allow-private-network'], 'true');
      final shelf.Response no = await send(
        null,
        method: 'OPTIONS',
        headers: <String, String>{'origin': 'https://evil.example'},
      );
      expect(no.statusCode, 403);
      expect(no.headers['access-control-allow-origin'], isNull);
    });

    test('srsAnkiOriginAllowed 边界', () {
      const List<String> d = kSrsAnkiDefaultCorsOrigins;
      expect(srsAnkiOriginAllowed('null', d), isFalse);
      expect(srsAnkiOriginAllowed('http://127.0.0.1.evil.com', d), isFalse);
      expect(srsAnkiOriginAllowed('chrome-extension://', d), isFalse);
      expect(srsAnkiOriginAllowed('https://localhost.evil.com', d), isFalse);
      expect(srsAnkiOriginAllowed('https://a.example', <String>['*']), isTrue);
      expect(
        srsAnkiOriginAllowed('chrome-extension://abc', <String>['https://x']),
        isFalse,
        reason: '白名单里没有 http://localhost 时扩展不自动放行（同 AnkiConnect）',
      );
    });
  });

  group('回环 / key', () {
    test('没设 key：非回环来源一律 403（fushiIdentify 例外）', () async {
      final shelf.Response r = await send(addNote, ip: '192.168.1.5');
      expect(r.statusCode, 403);
      expect(await h.store.hasUserNotes(), isFalse);
      final shelf.Response v = await send(<String, Object?>{
        'action': 'version',
        'version': 6,
      }, ip: '10.0.0.2');
      expect(v.statusCode, 403);
      final shelf.Response id = await send(<String, Object?>{
        'action': 'fushiIdentify',
        'version': 6,
      }, ip: '192.168.1.5');
      expect(id.statusCode, 200);
      expect(((await json(id))! as Map)['result'], <String, Object?>{
        'fushi': true,
        'instance': 'inst-123',
      });
      // IPv6 回环与 IPv4 映射回环都算回环。
      expect((await send(addNote, ip: '::1')).statusCode, 200);
      expect(
        (await send(<String, Object?>{
          'action': 'version',
          'version': 6,
        }, ip: '::ffff:127.0.0.1')).statusCode,
        200,
      );
    });

    test('拿不到连接信息时按非回环处理（失败即关闭）', () async {
      final shelf.Response r = await endpoint.handle(
        shelf.Request(
          'POST',
          Uri.parse('http://127.0.0.1:19633/'),
          body: jsonEncode(addNote),
        ),
      );
      expect(r.statusCode, 403);
    });

    test('设了 key：非回环可用，但 key 错 → 错误且不写库；key 对 → 加卡', () async {
      h.apiKey = 'k';
      final shelf.Response bad = await send(<String, Object?>{
        ...addNote,
        'key': 'nope',
      }, ip: '192.168.1.5');
      expect(bad.statusCode, 200);
      expect(await json(bad), <String, Object?>{
        'result': null,
        'error': 'valid api key must be provided',
      });
      expect(await h.store.hasUserNotes(), isFalse);
      final shelf.Response good = await send(<String, Object?>{
        ...addNote,
        'key': 'k',
      }, ip: '192.168.1.5');
      expect(((await json(good))! as Map)['result'], isA<int>());
      // 头部 x-api-key 也认。
      final shelf.Response hdr = await send(
        <String, Object?>{'action': 'deckNames', 'version': 6},
        ip: '192.168.1.5',
        headers: <String, String>{'x-api-key': 'k'},
      );
      expect(((await json(hdr))! as Map)['error'], isNull);
    });

    test('空 body：回 AnkiConnect 探活文本；非 JSON：回 error 形状', () async {
      final shelf.Response r = await send(null, method: 'GET');
      expect(r.statusCode, 200);
      expect(await r.readAsString(), 'AnkiConnect v.6');
      final shelf.Response bad = await endpoint.handle(
        shelf.Request(
          'POST',
          Uri.parse('http://127.0.0.1:19633/'),
          body: 'not json',
          context: <String, Object>{
            'shelf.io.connection_info': _Conn('127.0.0.1'),
          },
        ),
      );
      expect(((await json(bad))! as Map)['error'], isNotNull);
      expect((await send(addNote, method: 'PUT')).statusCode, 405);
    });
  });

  group('storeMediaFile 的 url（打开开关后）', () {
    setUp(() => h.policy = const SrsAnkiMediaPolicy(allowUrl: true));

    Future<Map<String, Object?>> store(String url) => h.call(
      'storeMediaFile',
      <String, Object?>{'filename': 'a.png', 'url': url},
    );

    test('拒绝回环 / 私网 / 链路本地 / 非 http(s)，不发请求', () async {
      for (final String u in <String>[
        'http://127.0.0.1/a.png',
        'http://localhost.localdomain.invalid/a.png',
        'http://10.0.0.5/a.png',
        'http://172.20.1.1/a.png',
        'http://192.168.0.1/a.png',
        'http://169.254.169.254/latest/meta-data',
        'http://[::1]/a.png',
        'http://[fe80::1]/a.png',
        'http://[::ffff:127.0.0.1]/a.png',
        'http://198.18.0.1/a.png',
        'file:///etc/passwd',
        'ftp://cdn.example.com/a.png',
        'http://rebind.example.com/a.png',
        'http://mixed.example.com/a.png',
      ]) {
        final Map<String, Object?> r = await store(u);
        expect(r['result'], isNull, reason: u);
        expect(r['error'], isNotNull, reason: u);
      }
      expect(h.fetched, isEmpty);
      expect(h.media, isEmpty);
    });

    test('公网地址放行，交给宿主按内容存', () async {
      final Map<String, Object?> r = await store(
        'https://cdn.example.com/a.png',
      );
      expect(r, <String, Object?>{'result': 'a.png', 'error': null});
      expect(h.fetched.single.host, 'cdn.example.com');
      expect(h.media['a.png'], <int>[1, 2, 3]);
    });

    test('重定向到私网逐跳重新核验', () async {
      int hops = 0;
      await expectLater(
        srsAnkiDownload(
          Uri.parse('https://cdn.example.com/a.png'),
          resolve: (String host) async => <InternetAddress>[
            InternetAddress('93.184.216.34'),
          ],
          fetch: (Uri u, InternetAddress a) async {
            hops++;
            return SrsAnkiFetchResult.redirect(
              Uri.parse('http://127.0.0.1/secret'),
            );
          },
        ),
        throwsA(isA<SrsAnkiMediaException>()),
      );
      expect(hops, 1);
    });

    test('path 打开开关后才读本机文件', () async {
      final Directory dir = await Directory.systemTemp.createTemp('ac_path');
      addTearDown(() => dir.delete(recursive: true));
      final File f = File('${dir.path}/x.bin')..writeAsBytesSync(<int>[5]);
      expect(
        (await h.call('storeMediaFile', <String, Object?>{
          'filename': 'x.bin',
          'path': f.path,
        }))['error'],
        contains('disabled'),
      );
      h.policy = const SrsAnkiMediaPolicy(allowPath: true);
      expect(
        await h.ok('storeMediaFile', <String, Object?>{
          'filename': 'x.bin',
          'path': f.path,
        }),
        'x.bin',
      );
    });
  });
}
