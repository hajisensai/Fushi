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
      final List<int> raw = <int>[for (final List<int> c in await request.toList()) ...c];
      final bool isJson = request.headers.contentType?.mimeType == 'application/json';
      final String text = isJson ? utf8.decode(raw) : '';
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

  group('经互联代理的动作', () {
    final Map<List<String>, (String, String)> cases = <List<String>, (String, String)>{
      <String>['books']: ('GET', '/api/admin/host/library/books'),
      <String>['books', 'progress', 'k 1']: ('GET', '/api/admin/host/library/books/k%201/progress'),
      <String>['videos', 'rm', 'v1']: ('DELETE', '/api/admin/host/library/videos/v1'),
      <String>['videos', 'playback', 'v1']: ('GET', '/api/admin/host/library/videos/v1/playback'),
      <String>['audiobooks', 'delay', 'a1']: ('GET', '/api/admin/host/library/audiobooks/a1/delay'),
      <String>['manga', 'manifest', 'm1']: ('GET', '/api/admin/host/library/manga/m1/manifest'),
      <String>['dict']: ('GET', '/api/admin/host/library/dictionaries'),
      <String>['metadata']: ('GET', '/api/admin/host/library/metadata'),
      <String>['activity']: ('GET', '/api/admin/host/library/activity'),
      <String>['tombstones']: ('GET', '/api/admin/host/tombstones'),
      <String>['scrape', 'pending']: ('GET', '/api/admin/scrape/pending'),
      <String>['scrape', 'sweep']: ('POST', '/api/admin/scrape/sweep'),
      <String>['scrape', 'ai-identify', 'book:u1']: ('POST', '/api/admin/scrape/ai-identify'),
      <String>['assistant', 'stop', 's1']: ('DELETE', '/api/admin/host/assistant/sessions/s1'),
      <String>['host', 'get', '/api/library/tags']: ('GET', '/api/admin/host/library/tags'),
    };
    cases.forEach((List<String> args, (String, String) expected) {
      test(args.join(' '), () async {
        expect(await ctl(args), 0, reason: err.toString());
        expect('${admin.seen.single.method} ${admin.seen.single.path}', '${expected.$1} ${expected.$2}');
      });
    });

    test('--set 把读变成写', () async {
      expect(await ctl(<String>['videos', 'position', 'v1', '--set', '{"positionMs":5}']), 0);
      expect(admin.seen.single.method, 'PUT');
      expect(admin.seen.single.body, <String, Object?>{'positionMs': 5});
    });

    test('scrape search / identify 的作品键与 lookup', () async {
      expect(await ctl(<String>['scrape', 'search', 'uid1', '-q', '葬送']), 0);
      expect(admin.seen.last.body, <String, Object?>{
        'key': <String, Object?>{'bookUid': 'uid1'},
        'query': '葬送',
      });
      expect(
        await ctl(<String>[
          'scrape', 'identify', '--collection', 'Frieren', '--collection-type', 'series', //
          '--provider', 'anidb', '--external-id', '17617',
        ]),
        0,
      );
      expect(admin.seen.last.path, '/api/admin/host/library/metadata/scrape');
      expect(admin.seen.last.body, <String, Object?>{
        'key': <String, Object?>{
          'collection': <String, Object?>{'name': 'Frieren', 'collectionType': 'series'},
        },
        'lookup': <String, Object?>{'provider': 'anidb', 'externalId': '17617', 'mediaKind': 'tv'},
      });
    });

    test('scrape 缺参数 = 64 不发请求（合集键缺 collectionType 也算缺）', () async {
      expect(await ctl(<String>['scrape', 'search', 'uid1']), 64);
      expect(await ctl(<String>['scrape', 'identify', 'uid1', '--provider', 'anidb']), 64);
      expect(await ctl(<String>['scrape', 'episode-groups', '--collection', 'X']), 64);
      expect(admin.seen, isEmpty);
    });

    test('顶层列表响应一行一条', () async {
      admin.nextBody = <Object?>[
        <String, Object?>{'id': 'b1', 'title': '本好きの下剋上'},
      ];
      expect(await ctl(<String>['books']), 0);
      expect(out.toString(), contains('b1  本好きの下剋上'));
    });
  });

  group('jobs submit asr', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('fushi_ctl_jobs_'));
    tearDown(() => tmp.delete(recursive: true));

    test('创建 → 上传输入 → 启动，不等则打印 jobId', () async {
      final File audio = File('${tmp.path}/a.mp3')..writeAsBytesSync(<int>[1, 2, 3]);
      admin.nextBody = <String, Object?>{'jobId': 'j9', 'state': 'pending'};
      expect(await ctl(<String>['jobs', 'submit', 'asr', audio.path, '-l', 'en']), 0, reason: '$err');
      expect(admin.seen.map((_Seen s) => '${s.method} ${s.path}').toList(), <String>[
        'POST /api/admin/host/jobs',
        'PUT /api/admin/host/jobs/j9/input/audio',
        'POST /api/admin/host/jobs/j9/start',
      ]);
      expect(admin.seen.first.body, <String, Object?>{
        'kind': 'asr',
        'params': <String, Object?>{'language': 'en', 'input': 'audio'},
      });
      expect(out.toString().trim(), 'j9');
    });

    test('音频不存在 = 66', () async {
      expect(await ctl(<String>['jobs', 'submit', 'asr', '${tmp.path}/none.mp3']), 66);
      expect(admin.seen, isEmpty);
    });

    test('jobs ls / rm 仍走 admin 自己的接口', () async {
      await ctl(<String>['jobs']);
      await ctl(<String>['jobs', 'rm', 'j1']);
      expect(admin.seen.map((_Seen s) => s.path).toList(), <String>['/api/admin/jobs', '/api/admin/jobs/j1']);
    });
  });

  group('upload', () {
    late _FakeUploadServer up;
    late AdminClient upClient;
    late Directory tmp;

    setUp(() async {
      up = await _FakeUploadServer.start();
      upClient = AdminClient(baseUri: up.uri, token: 't');
      tmp = await Directory.systemTemp.createTemp('fushi_ctl_up_');
    });

    tearDown(() async {
      upClient.close();
      await up.close();
      await tmp.delete(recursive: true);
    });

    Future<int> upload(List<String> args) =>
        runCtlAction(upClient, buildCtlParser().parse(args), out: out, err: err, uploadChunkBytes: 4);

    test('分块上传，字节与 Content-Range 正确', () async {
      final File f = File('${tmp.path}/ep01.mkv')..writeAsBytesSync(List<int>.generate(10, (int i) => i));
      expect(await upload(<String>['upload', f.path, '--lib', 'v', '--path', '/Season1/']), 0, reason: '$err');
      expect(up.stored['v:Season1/ep01.mkv'], List<int>.generate(10, (int i) => i));
      expect(up.ranges, <String>['bytes 0-3/10', 'bytes 4-7/10', 'bytes 8-9/10']);
    });

    test('断点续传：从服务端已收字节数接着传', () async {
      final File f = File('${tmp.path}/a.bin')..writeAsBytesSync(List<int>.generate(10, (int i) => i));
      up.stored['v:a.bin'] = <int>[0, 1, 2, 3, 4, 5];
      expect(await upload(<String>['upload', f.path, '--lib', 'v']), 0, reason: '$err');
      expect(up.ranges, <String>['bytes 6-9/10']);
      expect(up.stored['v:a.bin'], List<int>.generate(10, (int i) => i));
    });

    test('空文件发 0-0/0；已完整的文件跳过', () async {
      final File empty = File('${tmp.path}/empty.txt')..writeAsBytesSync(<int>[]);
      final File full = File('${tmp.path}/full.bin')..writeAsBytesSync(<int>[1, 2]);
      up.stored['v:full.bin'] = <int>[1, 2];
      expect(await upload(<String>['upload', empty.path, full.path, '--lib', 'v']), 0, reason: '$err');
      expect(up.ranges, <String>['bytes 0-0/0']);
    });

    test('缺 --lib = 64，文件不存在 = 66，都不发请求', () async {
      expect(await upload(<String>['upload', '${tmp.path}/x']), 64);
      expect(await upload(<String>['upload', '${tmp.path}/missing', '--lib', 'v']), 66);
      expect(up.ranges, isEmpty);
    });
  });

  group('logs --follow', () {
    test('newLogLines 只取窗口滑动后的新行', () {
      expect(newLogLines(<String>[], <String>['a', 'b']), <String>['a', 'b']);
      expect(newLogLines(<String>['a', 'b'], <String>['a', 'b', 'c']), <String>['c']);
      expect(newLogLines(<String>['a', 'b', 'c'], <String>['b', 'c', 'd', 'e']), <String>['d', 'e']);
      expect(newLogLines(<String>['a', 'b'], <String>['a', 'b']), isEmpty);
      expect(newLogLines(<String>['a'], <String>['x', 'y']), <String>['x', 'y']);
    });

    test('轮询时不重复打印旧行', () async {
      final List<Object?> bodies = <Object?>[
        <String, Object?>{
          'lines': <String>['l1', 'l2'],
        },
        <String, Object?>{
          'lines': <String>['l1', 'l2', 'l3'],
        },
        <String, Object?>{
          'lines': <String>['l2', 'l3', 'l4'],
        },
      ];
      int polls = 0;
      admin.nextBody = bodies[0];
      final int code = await runCtlAction(
        client,
        buildCtlParser().parse(<String>['logs', '-f']),
        out: out,
        err: err,
        followInterval: Duration.zero,
        keepFollowing: () {
          polls++;
          if (polls < bodies.length) admin.nextBody = bodies[polls];
          return polls < bodies.length;
        },
      );
      expect(code, 0);
      expect(out.toString().trim().split('\n'), <String>['l1', 'l2', 'l3', 'l4']);
    });
  });

  test('ctl 参数表能独立解析（cli.dart 复用同一份）', () {
    final ArgResults r = buildCtlParser().parse(<String>['downloads', 'add', 'm', '--title', 't']);
    expect(r.rest, <String>['downloads', 'add', 'm']);
    expect(r['title'], 't');
  });
}

/// 按 README「上传协议」实现的最小假上传端：追加到内存，校验 Content-Range 起点。
class _FakeUploadServer {
  _FakeUploadServer._(this._server);

  static Future<_FakeUploadServer> start() async {
    final _FakeUploadServer s = _FakeUploadServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    s._server.listen(s._handle);
    return s;
  }

  final HttpServer _server;
  final Map<String, List<int>> stored = <String, List<int>>{};
  final List<String> ranges = <String>[];

  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> _handle(HttpRequest request) async {
    final String key = '${request.uri.queryParameters['library']}:${request.uri.queryParameters['path']}';
    final List<int> have = stored.putIfAbsent(key, () => <int>[]);
    Map<String, Object?> body;
    int status = 200;
    if (request.method == 'GET') {
      body = <String, Object?>{'received': have.length};
    } else {
      final String range = request.headers.value('content-range') ?? '';
      ranges.add(range);
      final RegExpMatch m = RegExp(r'bytes (\d+)-(\d+)/(\d+)').firstMatch(range)!;
      final int start = int.parse(m.group(1)!);
      final int total = int.parse(m.group(3)!);
      final List<int> chunk = <int>[for (final List<int> c in await request.toList()) ...c];
      if (start != have.length) {
        status = 409;
        body = <String, Object?>{'error': 'offset mismatch'};
      } else {
        have.addAll(chunk);
        body = <String, Object?>{'received': have.length, 'complete': have.length >= total};
      }
    }
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await request.response.close();
  }

  Future<void> close() => _server.close(force: true);
}
