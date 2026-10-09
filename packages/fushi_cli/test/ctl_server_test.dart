import 'dart:convert';
import 'dart:io';

import 'package:fushi_cli/fushi_cli.dart';
import 'package:test/test.dart';

class FakeHandler implements CtlDesktopHandler {
  bool initialised = true;
  final List<String> opened = <String>[];
  final List<String> lookups = <String>[];
  int quits = 0;
  final Map<String, String> books = <String, String>{'a/1': '猫の本'};

  @override
  List<CtlRoute> get routes => <CtlRoute>[
    CtlRoute.get(
      '/api/admin/library/books',
      (CtlCall call) async => <String, Object?>{
        'books': <Map<String, Object?>>[
          for (final MapEntry<String, String> e in books.entries)
            <String, Object?>{'key': e.key, 'title': e.value},
        ],
      },
    ),
    CtlRoute.delete('/api/admin/library/books/:key', (CtlCall call) async {
      final String key = call.params['key']!;
      if (books.remove(key) == null) throw CtlFailure.notFound('没有这本书：$key');
      return null;
    }),
    CtlRoute.get(
      '/api/admin/ping',
      (CtlCall call) async => <String>['pong', call.query['n'] ?? ''],
      requiresReady: false,
    ),
  ];

  @override
  CtlAppStatus status() => CtlAppStatus(
    pid: 4242,
    platform: 'linux',
    initialised: initialised,
    version: '9.9.9',
  );

  @override
  Future<CtlOpenResult> open(String target) async {
    opened.add(target);
    if (target.endsWith('.mkv'))
      return const CtlOpenResult.accepted(CtlOpenKind.video);
    return const CtlOpenResult.rejected('unsupported');
  }

  @override
  Future<void> lookup(String word) async => lookups.add(word);

  @override
  Future<void> quit() async => quits++;
}

Future<HttpClientResponse> _raw(
  CtlEndpoint endpoint,
  String method,
  String path, {
  String? token,
  Map<String, String> headers = const <String, String>{},
  Object? body,
}) async {
  final HttpClient http = HttpClient();
  final HttpClientRequest request = await http.openUrl(
    method,
    endpoint.baseUri.replace(path: path),
  );
  if (token != null) request.headers.set('authorization', 'Bearer $token');
  headers.forEach(request.headers.set);
  if (body != null) request.write(jsonEncode(body));
  final HttpClientResponse response = await request.close();
  http.close();
  return response;
}

void main() {
  late Directory dir;
  late FakeHandler handler;
  late CtlServer server;
  late CtlEndpoint endpoint;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fushi_ctl_server_');
    handler = FakeHandler();
    server = CtlServer(
      handler: handler,
      stateDir: dir.path,
      appVersion: '9.9.9',
    );
    endpoint = await server.start();
  });

  tearDown(() async {
    await server.stop();
    await dir.delete(recursive: true);
  });

  test('启动后写发现文件，停止后删掉', () async {
    final CtlEndpoint? onDisk = await readCtlEndpoint(dir.path);
    expect(onDisk?.port, endpoint.port);
    expect(onDisk?.token, endpoint.token);
    expect(onDisk?.pid, pid);
    await server.stop();
    expect(await readCtlEndpoint(dir.path), isNull);
  });

  test('停止时不删别的实例接管后的发现文件', () async {
    await writeCtlEndpoint(
      dir.path,
      CtlEndpoint(port: 1, token: 'other', pid: pid + 1, startedAt: 0),
    );
    await server.stop();
    expect((await readCtlEndpoint(dir.path))?.token, 'other');
  });

  test('没 token / token 错 → 401', () async {
    expect((await _raw(endpoint, 'GET', kCtlStatusPath)).statusCode, 401);
    expect(
      (await _raw(endpoint, 'GET', kCtlStatusPath, token: 'nope')).statusCode,
      401,
    );
  });

  test('带 Origin（网页里的 fetch）→ 403，即使 token 正确', () async {
    final HttpClientResponse response = await _raw(
      endpoint,
      'GET',
      kCtlStatusPath,
      token: endpoint.token,
      headers: <String, String>{'origin': 'https://evil.example'},
    );
    expect(response.statusCode, 403);
  });

  test('status / open / lookup / quit 走通', () async {
    final CtlClient client = CtlClient(endpoint);
    addTearDown(client.close);
    final CtlAppStatus status = await client.status();
    expect(status.pid, 4242);
    expect(status.initialised, isTrue);
    expect(await client.open('/v/a.mkv'), CtlOpenKind.video);
    await client.lookup('猫');
    await client.quit();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(handler.opened, <String>['/v/a.mkv']);
    expect(handler.lookups, <String>['猫']);
    expect(handler.quits, 1);
  });

  test('环境里配了 HTTP 代理时 CLI 仍直连，token 不进代理', () async {
    final HttpServer proxy = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => proxy.close(force: true));
    final List<String> proxied = <String>[];
    proxy.listen((HttpRequest request) {
      proxied.add('${request.method} ${request.uri}');
      request.response
        ..statusCode = HttpStatus.badGateway
        ..close();
    });
    final CtlAppStatus status = await HttpOverrides.runZoned(
      () async {
        final CtlClient client = CtlClient(endpoint);
        try {
          return await client.status();
        } finally {
          client.close();
        }
      },
      findProxyFromEnvironment: (Uri uri, Map<String, String>? environment) =>
          'PROXY 127.0.0.1:${proxy.port}',
    );
    expect(status.initialised, isTrue);
    expect(proxied, isEmpty);
  });

  test('app 拒绝的目标 → 422 rejected', () async {
    final CtlClient client = CtlClient(endpoint);
    addTearDown(client.close);
    await expectLater(
      client.open('/v/a.txt'),
      throwsA(
        isA<CtlException>()
            .having((CtlException e) => e.code, 'code', kCtlErrorRejected)
            .having((CtlException e) => e.message, 'message', 'unsupported'),
      ),
    );
  });

  test('未初始化完 → 409 not_ready，且不调用 handler', () async {
    handler.initialised = false;
    final CtlClient client = CtlClient(endpoint);
    addTearDown(client.close);
    await expectLater(
      client.lookup('猫'),
      throwsA(
        isA<CtlException>().having(
          (CtlException e) => e.isNotReady,
          'isNotReady',
          isTrue,
        ),
      ),
    );
    expect(handler.lookups, isEmpty);
  });

  test('缺字段 → 400', () async {
    final HttpClientResponse response = await _raw(
      endpoint,
      'POST',
      kCtlOpenPath,
      token: endpoint.token,
      body: <String, Object?>{'nope': 1},
    );
    expect(response.statusCode, 400);
  });

  test('注册路由：路径参数解码、CtlFailure 映射、List 应答', () async {
    final CtlClient client = CtlClient(endpoint);
    addTearDown(client.close);
    expect(
      await client.call(
        'GET',
        '/api/admin/ping',
        query: <String, String>{'n': '1'},
      ),
      <Object?>['pong', '1'],
    );
    expect(
      await client.call(
        'DELETE',
        '/api/admin/library/books/${Uri.encodeComponent('a/1')}',
      ),
      <String, Object?>{'ok': true},
    );
    expect(handler.books, isEmpty);
    await expectLater(
      client.call('DELETE', '/api/admin/library/books/zzz'),
      throwsA(
        isA<CtlException>()
            .having((CtlException e) => e.statusCode, 'status', 404)
            .having((CtlException e) => e.message, 'message', contains('zzz')),
      ),
    );
    await expectLater(
      client.call('POST', '/api/admin/library/books'),
      throwsA(
        isA<CtlException>().having(
          (CtlException e) => e.statusCode,
          'status',
          405,
        ),
      ),
    );
    await expectLater(
      client.call('GET', '/api/admin/nope'),
      throwsA(
        isA<CtlException>().having(
          (CtlException e) => e.statusCode,
          'status',
          404,
        ),
      ),
    );
  });

  test('注册路由：未就绪回 409，requiresReady:false 的照常服务', () async {
    handler.initialised = false;
    final CtlClient client = CtlClient(endpoint);
    addTearDown(client.close);
    await expectLater(
      client.call('GET', '/api/admin/library/books'),
      throwsA(
        isA<CtlException>().having(
          (CtlException e) => e.isNotReady,
          'notReady',
          isTrue,
        ),
      ),
    );
    expect(await client.call('GET', '/api/admin/ping'), <Object?>['pong', '']);
  });

  test('坏的发现文件按「未运行」处理', () async {
    await ctlEndpointFile(dir.path).writeAsString('{"port":"x"}');
    expect(await readCtlEndpoint(dir.path), isNull);
  });
}
