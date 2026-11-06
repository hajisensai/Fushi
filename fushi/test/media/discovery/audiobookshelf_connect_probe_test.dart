// connectAudiobookshelfServer 的 /status 预检：填错地址（对面不是 ABS）和只开了
// OpenID 的服务器用一句能照着改的话报出来；没有明确结论（404 / 没有 authMethods）
// 时不拦，照常走登录。用本机回环服务器走真实 HTTP（该函数自己建客户端）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/discovery/audiobookshelf_server_config.dart';
import 'package:fushi/src/media/discovery/discovery_server_probes.dart';

void main() {
  late HttpServer server;
  late List<String> paths;
  late void Function(HttpRequest) handler;

  setUp(() async {
    paths = <String>[];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) {
      paths.add('${request.method} ${request.uri.path}');
      handler(request);
    });
  });
  tearDown(() => server.close(force: true));

  AudiobookshelfServerConfig config() => AudiobookshelfServerConfig(
    id: 'srv',
    name: 'Local',
    serverUrl: Uri.parse('http://127.0.0.1:${server.port}'),
    allowInsecureHttp: true,
  );

  void respond(HttpRequest request, int status, Object body, [String? type]) {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.parse(type ?? 'application/json')
      ..write(body is String ? body : jsonEncode(body));
    request.response.close();
  }

  test('对面不是 ABS（/status 回 HTML）→ 提示地址不对，不尝试登录', () async {
    handler = (HttpRequest request) =>
        respond(request, 200, '<html>hello</html>', 'text/html');
    final AudiobookshelfConnectOutcome outcome =
        await connectAudiobookshelfServer(
          config(),
          username: 'me',
          password: 'pw',
        );
    expect(outcome.ok, isFalse);
    expect(outcome.message, t.discovery_audiobookshelf_not_abs);
    expect(paths, <String>['GET /status']);
  });

  test('只开了 OpenID → 账号密码登录给出改用 API key 的提示', () async {
    handler = (HttpRequest request) => respond(request, 200, <String, Object?>{
      'app': 'audiobookshelf',
      'serverVersion': '2.37.1',
      'isInit': true,
      'authMethods': <String>['openid'],
    });
    final AudiobookshelfConnectOutcome outcome =
        await connectAudiobookshelfServer(
          config(),
          username: 'me',
          password: 'pw',
        );
    expect(outcome.ok, isFalse);
    expect(outcome.message, t.discovery_audiobookshelf_sso_only_hint);
    expect(paths, <String>['GET /status'], reason: '没有去撞限频的 /login');
  });

  test('/status 404（没有结论）→ 不拦，照常去登录', () async {
    handler = (HttpRequest request) {
      if (request.uri.path == '/status') {
        respond(request, 404, 'nope', 'text/plain');
      } else {
        respond(request, 401, <String, Object?>{'error': 'bad'});
      }
    };
    final AudiobookshelfConnectOutcome outcome =
        await connectAudiobookshelfServer(
          config(),
          username: 'me',
          password: 'pw',
        );
    expect(outcome.ok, isFalse);
    expect(paths, contains('POST /login'));
  });

  test('用 API key 时，即使服务器只开 OpenID 也不拦', () async {
    handler = (HttpRequest request) {
      if (request.uri.path == '/status') {
        respond(request, 200, <String, Object?>{
          'app': 'audiobookshelf',
          'authMethods': <String>['openid'],
        });
      } else if (request.uri.path == '/api/me') {
        respond(request, 200, <String, Object?>{
          'id': 'u',
          'username': 'keyuser',
        });
      } else {
        respond(request, 200, <String, Object?>{'libraries': <Object?>[]});
      }
    };
    final AudiobookshelfConnectOutcome outcome =
        await connectAudiobookshelfServer(config(), apiKey: 'api-key');
    expect(outcome.ok, isTrue);
    expect(outcome.username, 'keyuser');
  });
}
