/// `fushi_server ctl` 的契约：动词 → admin API 请求的映射、Bearer 鉴权、
/// 输出与退出码，以及主 CLI 入口确实把 `ctl` 接到了运行中的服务上。
///
/// 用一个假的 admin HTTP 服务记录收到的请求，不起真 host（ctl 本来就只发 HTTP）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:fushi_server/src/cli.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/ctl/admin_client.dart';
import 'package:fushi_server/src/ctl/ctl_commands.dart';
import 'package:test/test.dart';

class _Seen {
  _Seen(this.method, this.path, this.query, this.auth, this.body);

  final String method;
  final String path;
  final Map<String, String> query;
  final String? auth;
  final Object? body;
}

class _FakeAdmin {
  _FakeAdmin._(this._server);

  static Future<_FakeAdmin> start() async {
    final _FakeAdmin admin = _FakeAdmin._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    admin._listen();
    return admin;
  }

  final HttpServer _server;
  final List<_Seen> seen = <_Seen>[];

  /// 下一次请求回什么；缺省 `{"ok": true}`。
  int nextStatus = 200;
  Object? nextBody = const <String, Object?>{'ok': true};

  int get port => _server.port;
  Uri get uri => Uri.parse('http://127.0.0.1:$port');

  void _listen() {
    _server.listen((HttpRequest request) async {
      final String text = await utf8.decoder.bind(request).join();
      seen.add(
        _Seen(
          request.method,
          request.uri.path,
          request.uri.queryParameters,
          request.headers.value(HttpHeaders.authorizationHeader),
          text.isEmpty ? null : jsonDecode(text),
        ),
      );
      request.response
        ..statusCode = nextStatus
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(nextBody));
      await request.response.close();
    });
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  late _FakeAdmin admin;
  late AdminClient client;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() async {
    admin = await _FakeAdmin.start();
    client = AdminClient(baseUri: admin.uri, token: 'secret-token=');
    out = StringBuffer();
    err = StringBuffer();
  });

  tearDown(() async {
    client.close();
    await admin.close();
  });

  String? secret;
  Future<int> ctl(List<String> args) =>
      runCtlAction(client, buildCtlParser().parse(args), out: out, err: err, readSecret: (String _) => secret);

  group('动词 → 请求', () {
    final Map<List<String>, (String, String)> cases = <List<String>, (String, String)>{
      <String>['status']: ('GET', '/api/admin/status'),
      <String>['logs']: ('GET', '/api/admin/logs'),
      <String>['pairing']: ('GET', '/api/admin/pairing'),
      <String>['pairing', 'revoke', 'peer 1']: ('DELETE', '/api/admin/pairing/peers/peer%201'),
      <String>['libraries', 'ls']: ('GET', '/api/admin/libraries'),
      <String>['jobs', 'rm', 'j1']: ('DELETE', '/api/admin/jobs/j1'),
      <String>['downloads']: ('GET', '/api/admin/downloads'),
      <String>['downloads', 'cancel', 'd1']: ('POST', '/api/admin/downloads/d1/cancel'),
      <String>['downloads', 'retry', 'd1']: ('POST', '/api/admin/downloads/d1/retry'),
      <String>['downloads', 'rm', 'd1']: ('DELETE', '/api/admin/downloads/d1'),
      <String>['subscriptions', 'check']: ('POST', '/api/admin/subscriptions/check'),
      <String>['subscriptions', 'check', 's1']: ('POST', '/api/admin/subscriptions/s1/check'),
      <String>['subscriptions', 'rm', 's1']: ('DELETE', '/api/admin/subscriptions/s1'),
      <String>['models']: ('GET', '/api/admin/models'),
      <String>['settings']: ('GET', '/api/admin/settings'),
      <String>['resource-indexers', 'get']: ('GET', '/api/admin/resource-indexers'),
      <String>['anki', 'sync']: ('POST', '/api/admin/anki/sync'),
      <String>['profiles', 'share', '3']: ('POST', '/api/admin/profiles/3/share'),
      <String>['p2p']: ('GET', '/api/admin/p2p'),
    };
    cases.forEach((List<String> args, (String, String) expected) {
      test(args.join(' '), () async {
        expect(await ctl(args), 0, reason: err.toString());
        expect(admin.seen, hasLength(1));
        expect(admin.seen.single.method, expected.$1);
        // Uri.path 保留百分号编码：id 里的空格必须编码成 %20 而不是拆路径。
        expect(admin.seen.single.path, expected.$2);
        expect(admin.seen.single.auth, 'Bearer secret-token=');
      });
    });

    test('libraries add 带上 kind / id', () async {
      expect(await ctl(<String>['libraries', 'add', '/srv/books', '--kind', 'book', '--id', 'b1']), 0);
      expect(admin.seen.single.body, <String, Object?>{'path': '/srv/books', 'kind': 'book', 'id': 'b1'});
    });

    test('libraries rm --purge 走 query', () async {
      expect(await ctl(<String>['libraries', 'rm', 'lib1', '--purge']), 0);
      expect(admin.seen.single.query, <String, String>{'purge': 'true'});
    });

    test('scan 的 prune 三态：不给就不发，给了按值发', () async {
      await ctl(<String>['scan']);
      await ctl(<String>['scan', '--no-prune']);
      await ctl(<String>['scan', '--prune']);
      expect(admin.seen.map((_Seen s) => s.body).toList(), <Object?>[
        <String, Object?>{},
        <String, Object?>{'prune': false},
        <String, Object?>{'prune': true},
      ]);
    });

    test('downloads add 要求 --title', () async {
      expect(await ctl(<String>['downloads', 'add', 'magnet:?xt=x']), 64);
      expect(admin.seen, isEmpty);
      expect(await ctl(<String>['downloads', 'add', 'magnet:?xt=x', '--title', 'T', '--media-kind', 'tv']), 0);
      expect(admin.seen.single.body, <String, Object?>{'magnet': 'magnet:?xt=x', 'title': 'T', 'mediaKind': 'tv'});
    });

    test('subscriptions enable / disable', () async {
      await ctl(<String>['subscriptions', 'enable', 's1']);
      await ctl(<String>['subscriptions', 'disable', 's1']);
      expect(admin.seen.map((_Seen s) => s.path).toSet(), <String>{'/api/admin/subscriptions/s1/enable'});
      expect(admin.seen.map((_Seen s) => s.body).toList(), <Object?>[
        <String, Object?>{'enabled': true},
        <String, Object?>{'enabled': false},
      ]);
    });

    test('settings set 传 JSON 对象；非法 JSON 不发请求', () async {
      expect(await ctl(<String>['settings', 'set', '{"deviceName":"nas"}']), 0);
      expect(admin.seen.single.method, 'PUT');
      expect(admin.seen.single.body, <String, Object?>{'deviceName': 'nas'});
      expect(await ctl(<String>['settings', 'set', '[1]']), 64);
      expect(await ctl(<String>['settings', 'set', '{oops']), 64);
      expect(admin.seen, hasLength(1));
    });

    test('raw 只放行 /api/admin/ 下的路径', () async {
      expect(await ctl(<String>['raw', 'get', '/api/admin/jobs?x=1']), 0);
      expect(admin.seen.single.method, 'GET');
      expect(admin.seen.single.path, '/api/admin/jobs');
      expect(admin.seen.single.query, <String, String>{'x': '1'});
      expect(await ctl(<String>['raw', 'GET', '/api/sync/books']), 64);
      expect(admin.seen, hasLength(1));
    });

    test('短别名与规范名走同一个接口', () async {
      await ctl(<String>['lib']);
      await ctl(<String>['dl', 'rm', 'd1']);
      await ctl(<String>['sub']);
      await ctl(<String>['pair', 'revoke', 'p1']);
      await ctl(<String>['indexers']);
      await ctl(<String>['config', 'get']);
      await ctl(<String>['profile', 'rm', '2']);
      expect(admin.seen.map((_Seen s) => '${s.method} ${s.path}').toList(), <String>[
        'GET /api/admin/libraries',
        'DELETE /api/admin/downloads/d1',
        'GET /api/admin/subscriptions',
        'DELETE /api/admin/pairing/peers/p1',
        'GET /api/admin/resource-indexers',
        'GET /api/admin/settings',
        'DELETE /api/admin/profiles/2',
      ]);
    });

    test('anki login 的密码只经 readSecret，不经 argv', () async {
      secret = null;
      expect(await ctl(<String>['anki', 'login', '--user', 'me']), 64);
      expect(admin.seen, isEmpty, reason: '没有密码不得发请求');
      secret = 'pw';
      expect(await ctl(<String>['anki', 'login', '--user', 'me', '--endpoint', 'https://sync.local']), 0);
      expect(admin.seen.single.path, '/api/admin/anki/login');
      expect(admin.seen.single.body, <String, Object?>{
        'username': 'me',
        'password': 'pw',
        'endpoint': 'https://sync.local',
      });
    });

    test('anki logout / landing / config', () async {
      await ctl(<String>['anki', 'logout', '--discard-unsynced']);
      await ctl(<String>['anki', 'landing', 'off']);
      await ctl(<String>['anki', 'config', '{"deck":"Mining"}']);
      expect(admin.seen.map((_Seen s) => '${s.method} ${s.path}').toList(), <String>[
        'POST /api/admin/anki/logout',
        'POST /api/admin/anki/landing',
        'PUT /api/admin/anki/settings',
      ]);
      expect(admin.seen.map((_Seen s) => s.body).toList(), <Object?>[
        <String, Object?>{'discardUnsynced': true},
        <String, Object?>{'enabled': false},
        <String, Object?>{'deck': 'Mining'},
      ]);
      expect(await ctl(<String>['anki', 'landing', 'maybe']), 64);
    });

    test('未知动作 / 空动作 = 用法错误，不发请求', () async {
      expect(await ctl(<String>[]), 64);
      expect(await ctl(<String>['nope']), 64);
      expect(await ctl(<String>['jobs', 'rm']), 64);
      expect(admin.seen, isEmpty);
    });
  });

  group('输出与退出码', () {
    test('列表渲染成一行一条', () async {
      admin.nextBody = <String, Object?>{
        'libraries': <Object?>[
          <String, Object?>{'id': 'lib1', 'kind': 'video', 'path': '/srv/video'},
        ],
      };
      expect(await ctl(<String>['libraries']), 0);
      expect(out.toString(), contains('lib1  [video]  /srv/video'));
    });

    test('布尔状态渲染成词', () async {
      admin.nextBody = <String, Object?>{
        'asr': <Object?>[
          <String, Object?>{'tag': 'ja', 'name': '日本語', 'ready': false},
        ],
        'ocrModels': <Object?>[
          <String, Object?>{'key': 'manga_ocr', 'name': 'manga-ocr', 'ready': true},
        ],
      };
      expect(await ctl(<String>['models']), 0);
      expect(out.toString(), contains('ja  [missing]  日本語'));
      expect(out.toString(), contains('manga_ocr  [ready]  manga-ocr'));
    });

    test('--json 原样输出', () async {
      admin.nextBody = <String, Object?>{'deviceName': 'nas', 'videos': 3};
      expect(await ctl(<String>['status', '--json']), 0);
      expect(jsonDecode(out.toString()), <String, Object?>{'deviceName': 'nas', 'videos': 3});
    });

    test('ok:false → 1', () async {
      admin.nextBody = <String, Object?>{'ok': false};
      expect(await ctl(<String>['pairing', 'revoke', 'ghost']), 1);
    });

    test('4xx 透出服务端 error，401 → 77', () async {
      admin
        ..nextStatus = 400
        ..nextBody = <String, Object?>{'error': 'magnet and title required'};
      expect(await ctl(<String>['downloads', 'add', 'm', '--title', 't']), 1);
      expect(err.toString(), contains('magnet and title required'));
      admin.nextStatus = 401;
      expect(await ctl(<String>['status']), 77);
      admin.nextStatus = 409;
      expect(await ctl(<String>['anki', 'logout']), 75);
    });

    test('连不上 → 69', () async {
      await admin.close();
      expect(await ctl(<String>['status']), 69);
      expect(err.toString(), contains('连不上'));
    });
  });

  group('AdminClient.fromConfig', () {
    ServerConfig config({String bind = '0.0.0.0', int port = 38780, bool tls = false, String? token = 't'}) =>
        ServerConfig.defaults(
          dataDir: Directory.systemTemp.path,
        ).copyWith(adminBind: bind, adminPort: port, tls: tls, adminToken: token);

    test('通配 bind 换成回环地址', () async {
      final AdminClient c = await AdminClient.fromConfig(config());
      expect(c.baseUri.toString(), 'http://127.0.0.1:38780');
      c.close();
      expect(adminLoopbackHost('::'), '::1');
      expect(adminLoopbackHost('192.168.1.5'), '192.168.1.5');
    });

    test('--url / --token 覆盖配置', () async {
      final AdminClient c = await AdminClient.fromConfig(config(), url: 'http://nas:9000', token: 'override');
      expect(c.baseUri.toString(), 'http://nas:9000');
      expect(c.token, 'override');
      c.close();
    });

    test('admin 端口关闭 / 无 token / tls 无证书时明确报错', () async {
      await expectLater(AdminClient.fromConfig(config(port: 0)), throwsA(isA<AdminApiException>()));
      await expectLater(AdminClient.fromConfig(config(token: null)), throwsA(isA<AdminApiException>()));
      final Directory empty = await Directory.systemTemp.createTemp('fushi_ctl_');
      addTearDown(() => empty.delete(recursive: true));
      await expectLater(
        AdminClient.fromConfig(ServerConfig.defaults(dataDir: empty.path).copyWith(tls: true, adminToken: 't')),
        throwsA(isA<AdminApiException>().having((AdminApiException e) => e.message, 'message', contains('TLS 证书'))),
      );
    });
  });

  test('主 CLI 入口把 ctl 接到配置里的 admin 端口', () async {
    final Directory dir = await Directory.systemTemp.createTemp('fushi_ctl_cli_');
    addTearDown(() => dir.delete(recursive: true));
    final File configFile = File('${dir.path}/fushi_server.yaml');
    await ServerConfig.defaults(
      dataDir: '${dir.path}/data',
    ).copyWith(adminBind: '127.0.0.1', adminPort: admin.port, adminToken: 'cfg-token', tls: false).save(configFile);
    admin.nextBody = <String, Object?>{'jobs': <Object?>[]};
    expect(await runFushiServerCli(<String>['-c', configFile.path, 'ctl', 'jobs']), 0);
    expect(admin.seen.single.path, '/api/admin/jobs');
    expect(admin.seen.single.auth, 'Bearer cfg-token');
    // 不经 _withRuntime：ctl 不得建数据目录 / 开数据库。
    expect(Directory('${dir.path}/data').existsSync(), isFalse);
  });

  test('ctl 参数表能独立解析（cli.dart 复用同一份）', () {
    final ArgResults r = buildCtlParser().parse(<String>['downloads', 'add', 'm', '--title', 't']);
    expect(r.rest, <String>['downloads', 'add', 'm']);
    expect(r['title'], 't');
  });
}
