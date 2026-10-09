/// `media-server plex` 契约：PIN 登录落凭据（0600、不进偏好表）、账号 resources 选服务器 +
/// 按优先级探测连接、浏览三层、`--url` 直连取环境变量 token、401 / 未登录 / 用法错误的
/// 退出码。plex.tv 与 PMS 都由 `MockClient` 扮演，不连网。
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/commands/media_server_commands.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late File configFile;
  late ServerPaths paths;
  late StringBuffer out;
  late StringBuffer err;
  late List<String> seen;
  late int pinChecks;
  late bool lanReachable;
  late int pmsStatus;

  http.Response jsonResponse(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: <String, String>{'content-type': 'application/json'});

  Future<http.Response> handler(http.Request req) async {
    final Uri u = req.url;
    seen.add('${req.method} ${u.host}${u.path} token=${req.headers['X-Plex-Token'] ?? '-'}');
    if (u.host == 'plex.tv' && u.path == '/api/v2/pins' && req.method == 'POST') {
      return jsonResponse(<String, Object?>{'id': 7, 'code': 'ABCD', 'expiresAt': '2099-01-01T00:00:00Z'});
    }
    if (u.host == 'plex.tv' && u.path == '/api/v2/pins/7') {
      pinChecks++;
      return jsonResponse(<String, Object?>{
        'id': 7,
        'code': 'ABCD',
        'authToken': pinChecks >= 2 ? 'acct-token' : null,
        'expiresAt': '2099-01-01T00:00:00Z',
      });
    }
    if (u.host == 'plex.tv' && u.path == '/api/v2/user') {
      return jsonResponse(<String, Object?>{'id': 1, 'username': 'neko'});
    }
    if (u.host == 'clients.plex.tv' && u.path == '/api/v2/resources') {
      if (req.headers['X-Plex-Token'] != 'acct-token') return http.Response('', 401);
      return jsonResponse(<Object?>[
        <String, Object?>{'name': 'Phone', 'provides': 'player', 'clientIdentifier': 'p1'},
        <String, Object?>{
          'name': 'Home',
          'provides': 'server',
          'clientIdentifier': 'mid1',
          'accessToken': 'srv-token',
          'owned': true,
          'connections': <Object?>[
            <String, Object?>{'uri': 'https://relay.plex.direct:8443', 'relay': true},
            <String, Object?>{'uri': 'http://10.0.0.9:32400', 'local': true},
          ],
        },
      ]);
    }
    // PMS
    if (u.host == '10.0.0.9' && !lanReachable) throw http.ClientException('connection refused');
    if (pmsStatus != 200) return http.Response('', pmsStatus);
    if (u.path == '/identity') {
      return jsonResponse(<String, Object?>{
        'MediaContainer': <String, Object?>{'machineIdentifier': 'mid1'},
      });
    }
    if (u.path == '/library/sections') {
      return jsonResponse(<String, Object?>{
        'MediaContainer': <String, Object?>{
          'Directory': <Object?>[
            <String, Object?>{'key': '1', 'title': 'Anime', 'type': 'show'},
          ],
        },
      });
    }
    if (u.path == '/library/sections/1/all') {
      expect(u.queryParameters['X-Plex-Container-Start'], '0');
      return jsonResponse(<String, Object?>{
        'MediaContainer': <String, Object?>{
          'totalSize': 1,
          'Metadata': <Object?>[
            <String, Object?>{'ratingKey': '100', 'type': 'show', 'title': 'ぼっち・ざ・ろっく！', 'year': 2022},
          ],
        },
      });
    }
    if (u.path == '/library/metadata/100/children') {
      return jsonResponse(<String, Object?>{
        'MediaContainer': <String, Object?>{
          'Metadata': <Object?>[
            <String, Object?>{'ratingKey': '101', 'type': 'season', 'title': 'Season 1', 'index': 1},
          ],
        },
      });
    }
    return http.Response('', 404);
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_plex_cli_');
    configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
    final String dataDir = p.join(tmp.path, 'data');
    await ServerConfig.defaults(dataDir: dataDir).save(configFile);
    paths = ServerPaths(dataDir);
    out = StringBuffer();
    err = StringBuffer();
    seen = <String>[];
    pinChecks = 0;
    lanReachable = true;
    pmsStatus = 200;
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<int> plex(List<String> args, {Map<String, String> env = const <String, String>{}}) {
    final MediaServerModule module = MediaServerModule(
      out: out,
      err: err,
      env: env,
      httpClient: () => MockClient(handler),
      delay: (Duration _) async {},
    );
    final ArgParser parser = ArgParser();
    module.register(parser);
    return module.run(
      'media-server',
      parser.parse(<String>['media-server', ...args]).command!,
      CliContext(configFile: configFile, verbose: false),
    );
  }

  Future<void> login() async {
    expect(await plex(<String>['plex', 'login']), 0, reason: err.toString());
    out.clear();
    seen.clear();
  }

  test('login：打印授权链接、轮询拿 token、凭据落盘 0600', () async {
    expect(await plex(<String>['plex', 'login']), 0, reason: err.toString());
    expect(out.toString(), contains('https://app.plex.tv/auth#?'));
    expect(out.toString(), contains('code=ABCD'));
    expect(out.toString(), contains('已登录 Plex: neko'));
    expect(pinChecks, 2);
    final File f = PlexCredentialStore.under(paths.support).file;
    final Map<String, Object?> saved = jsonDecode(await f.readAsString()) as Map<String, Object?>;
    expect(saved['accountToken'], 'acct-token');
    expect(saved['username'], 'neko');
    expect(saved['clientIdentifier'], startsWith('fushi-server-'));
    if (!Platform.isWindows) expect((await f.stat()).modeString(), 'rw-------');

    out.clear();
    expect(await plex(<String>['plex', 'status', '--json']), 0);
    expect(jsonDecode(out.toString()), containsPair('signedIn', true));
  });

  test('clientIdentifier 每安装稳定，logout 只清 token', () async {
    await login();
    final PlexCredentialStore store = PlexCredentialStore.under(paths.support);
    final String id = (await store.loadOrCreate()).clientIdentifier;
    expect(await plex(<String>['plex', 'logout']), 0);
    final PlexAccountCredential after = await store.loadOrCreate();
    expect(after.signedIn, isFalse);
    expect(after.clientIdentifier, id);
  });

  test('servers：只列 server 资源，连接按 局域网 → relay 排序', () async {
    await login();
    expect(await plex(<String>['plex', 'servers', '--json']), 0, reason: err.toString());
    final List<Object?> servers = jsonDecode(out.toString()) as List<Object?>;
    expect(servers, hasLength(1));
    final Map<String, Object?> s = servers.single! as Map<String, Object?>;
    expect(s['id'], 'mid1');
    expect((s['connections']! as List<Object?>).map((Object? c) => (c! as Map<String, Object?>)['uri']), <String>[
      'http://10.0.0.9:32400',
      'https://relay.plex.direct:8443',
    ]);
  });

  test('ls：媒体库 → 库内条目 → 子级，用服务器自己的 accessToken', () async {
    await login();
    expect(await plex(<String>['plex', 'ls', '--json']), 0, reason: err.toString());
    final Map<String, Object?> root = jsonDecode(out.toString()) as Map<String, Object?>;
    expect(root['server'], 'http://10.0.0.9:32400');
    expect(root['sections'], <Object?>[
      <String, Object?>{'key': '1', 'title': 'Anime', 'type': 'show'},
    ]);
    expect(seen.where((String s) => s.contains('/library/')), everyElement(endsWith('token=srv-token')));

    out.clear();
    expect(await plex(<String>['plex', 'ls', '--section', '1', '--json']), 0, reason: err.toString());
    final Map<String, Object?> items = jsonDecode(out.toString()) as Map<String, Object?>;
    expect(items['totalSize'], 1);
    expect(((items['items']! as List<Object?>).single! as Map<String, Object?>)['ratingKey'], '100');

    out.clear();
    expect(await plex(<String>['plex', 'ls', '100', '--server', 'home']), 0, reason: err.toString());
    expect(out.toString(), contains('101  [season] #1 Season 1'));
  });

  test('局域网连接不通时退到 relay', () async {
    await login();
    lanReachable = false;
    expect(await plex(<String>['plex', 'ls', '--json']), 0, reason: err.toString());
    expect((jsonDecode(out.toString()) as Map<String, Object?>)['server'], 'https://relay.plex.direct:8443');
  });

  test('--url 直连：token 取环境变量', () async {
    expect(
      await plex(
        <String>['plex', 'ls', '--url', '10.0.0.9:32400', '--json'],
        env: <String, String>{kPlexTokenEnv: 'env-token'},
      ),
      0,
      reason: err.toString(),
    );
    expect(seen.single, 'GET 10.0.0.9/library/sections token=env-token');
  });

  test('未登录 / 没 token = 69；PMS 401 = 69；连不上 = 69', () async {
    expect(await plex(<String>['plex', 'servers']), 69);
    expect(await plex(<String>['plex', 'ls']), 69);
    expect(await plex(<String>['plex', 'ls', '--url', 'http://10.0.0.9:32400']), 69);
    pmsStatus = 401;
    expect(
      await plex(<String>['plex', 'ls', '--url', 'http://10.0.0.9:32400'], env: <String, String>{kPlexTokenEnv: 't'}),
      69,
    );
    pmsStatus = 200;
    lanReachable = false;
    expect(
      await plex(<String>['plex', 'ls', '--url', 'http://10.0.0.9:32400'], env: <String, String>{kPlexTokenEnv: 't'}),
      69,
    );
  });

  test('找不到服务器 = 66；条目 404 = 66', () async {
    await login();
    expect(await plex(<String>['plex', 'ls', '--server', 'nas']), 66);
    expect(await plex(<String>['plex', 'ls', '999']), 66);
  });

  test('用法错误 = 64', () async {
    expect(await plex(<String>[]), 64);
    expect(await plex(<String>['plex']), 64);
    expect(await plex(<String>['plex', 'ls', 'a', 'b']), 64);
    expect(await plex(<String>['plex', 'login', '--timeout', '0']), 64);
    expect(await plex(<String>['plex', 'ls', '--section', '1', '100']), 64);
  });
}
