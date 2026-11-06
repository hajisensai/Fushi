import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/ai/mcp_client/mcp_client_transport.dart';
import 'package:http/io_client.dart';
import 'package:test/test.dart';

typedef _Handler =
    Future<void> Function(HttpRequest request, Map<String, Object?>? body);

/// 本机回环上的假 MCP server。
class _Server {
  _Server._(this._server, this._handler) {
    _server.listen((HttpRequest request) async {
      final String text = await utf8.decodeStream(request);
      final Object? decoded = text.isEmpty ? null : jsonDecode(text);
      seen.add(request);
      bodies.add(decoded is Map ? Map<String, Object?>.from(decoded) : null);
      await _handler(request, bodies.last);
    });
  }

  static Future<_Server> start(_Handler handler) async => _Server._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    handler,
  );

  final HttpServer _server;
  final _Handler _handler;
  final List<HttpRequest> seen = <HttpRequest>[];
  final List<Map<String, Object?>?> bodies = <Map<String, Object?>?>[];

  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}/mcp');

  Future<void> close() => _server.close(force: true);
}

McpHttpTransport _transport(
  _Server server, {
  Map<String, String> headers = const <String, String>{},
}) => McpHttpTransport(
  endpoint: server.uri,
  client: IOClient(HttpClient()..findProxy = (Uri _) => 'DIRECT'),
  headers: headers,
);

Map<String, Object?> _req(int id, String method) => <String, Object?>{
  'jsonrpc': '2.0',
  'id': id,
  'method': method,
  'params': <String, Object?>{},
};

Future<void> _json(
  HttpRequest request,
  Object? body, {
  int status = 200,
}) async {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
  await request.response.close();
}

void main() {
  group('McpHttpTransport', () {
    test(
      'posts JSON with Accept for both kinds, custom and per-request headers',
      () async {
        final _Server server = await _Server.start((
          HttpRequest r,
          Map<String, Object?>? body,
        ) async {
          await _json(r, <String, Object?>{
            'jsonrpc': '2.0',
            'id': body!['id'],
            'result': <String, Object?>{'ok': 1},
          });
        });
        addTearDown(server.close);
        final McpHttpTransport transport = _transport(
          server,
          headers: <String, String>{'Authorization': 'Bearer t'},
        );
        final Map<String, Object?> reply = await transport.request(
          _req(7, 'tools/list'),
          headers: <String, String>{'Mcp-Method': 'tools/list'},
          timeout: const Duration(seconds: 5),
        );
        expect(reply['result'], <String, Object?>{'ok': 1});
        final HttpHeaders headers = server.seen.single.headers;
        expect(headers.value('accept'), 'application/json, text/event-stream');
        expect(headers.value('authorization'), 'Bearer t');
        expect(headers.value('mcp-method'), 'tools/list');
        expect(server.bodies.single!['method'], 'tools/list');
        await transport.close();
      },
    );

    test(
      'SSE replies: returns the matching event without waiting for the stream to end',
      () async {
        final Completer<void> release = Completer<void>();
        final _Server server = await _Server.start((
          HttpRequest r,
          Map<String, Object?>? body,
        ) async {
          // dart:io 的 HttpResponse 默认缓冲输出，flush 也不一定把小块推出去；
          // 真实 SSE server 会逐事件推送，这里关缓冲模拟它。
          r.response
            ..bufferOutput = false
            ..headers.contentType = ContentType('text', 'event-stream');
          r.response
            ..write(
              'event: message\ndata: {"jsonrpc":"2.0","method":"notifications/progress"}\n\n',
            )
            ..write('data: {"jsonrpc":"2.0","id":99,"result":{}}\n\n')
            ..write(
              'data: {"jsonrpc":"2.0",\ndata: "id":${body!['id']},"result":{"tools":[]}}\n\n',
            );
          await r.response.flush();
          // 故意不关流：客户端拿到应答就该返回。
          await release.future;
          await r.response.close();
        });
        addTearDown(() async {
          release.complete();
          await server.close();
        });
        final McpHttpTransport transport = _transport(server);
        final Map<String, Object?> reply = await transport.request(
          _req(3, 'tools/list'),
          timeout: const Duration(seconds: 5),
        );
        expect(reply['id'], 3);
        expect(reply['result'], <String, Object?>{'tools': <Object?>[]});
      },
    );

    test(
      'remembers Mcp-Session-Id and sends it back; DELETEs it on close',
      () async {
        final _Server server = await _Server.start((
          HttpRequest r,
          Map<String, Object?>? body,
        ) async {
          if (r.method == 'DELETE') {
            r.response.statusCode = 200;
            await r.response.close();
            return;
          }
          r.response.headers.set('Mcp-Session-Id', 'sess-1');
          await _json(r, <String, Object?>{
            'jsonrpc': '2.0',
            'id': body!['id'],
            'result': <String, Object?>{},
          });
        });
        addTearDown(server.close);
        final McpHttpTransport transport = _transport(server);
        await transport.request(
          _req(1, 'initialize'),
          timeout: const Duration(seconds: 5),
        );
        expect(transport.sessionId, 'sess-1');
        await transport.request(
          _req(2, 'tools/list'),
          timeout: const Duration(seconds: 5),
        );
        expect(server.seen[1].headers.value('mcp-session-id'), 'sess-1');
        await transport.close();
        expect(server.seen.last.method, 'DELETE');
        expect(server.seen.last.headers.value('mcp-session-id'), 'sess-1');
      },
    );

    test(
      'a JSON-RPC error body on HTTP 400 is returned as the reply (MangaBaka style)',
      () async {
        final _Server server = await _Server.start((
          HttpRequest r,
          Map<String, Object?>? body,
        ) async {
          await _json(r, <String, Object?>{
            'jsonrpc': '2.0',
            'id': body!['id'],
            'error': <String, Object?>{
              'code': -32022,
              'data': <String, Object?>{
                'supported': <String>['2026-07-28'],
              },
            },
          }, status: 400);
        });
        addTearDown(server.close);
        final Map<String, Object?> reply = await _transport(
          server,
        ).request(_req(1, 'initialize'), timeout: const Duration(seconds: 5));
        expect((reply['error']! as Map)['code'], -32022);
      },
    );

    test('non-JSON-RPC failures map to short codes', () async {
      final _Server server = await _Server.start((
        HttpRequest r,
        Map<String, Object?>? body,
      ) async {
        r.response
          ..statusCode = 500
          ..write('<html>oops</html>');
        await r.response.close();
      });
      addTearDown(server.close);
      await expectLater(
        _transport(
          server,
        ).request(_req(1, 'tools/list'), timeout: const Duration(seconds: 5)),
        throwsA(
          isA<McpClientException>().having(
            (McpClientException e) => e.message,
            'message',
            'HTTP 500',
          ),
        ),
      );
    });

    test('404 with a session means the session expired', () async {
      int calls = 0;
      final _Server server = await _Server.start((
        HttpRequest r,
        Map<String, Object?>? body,
      ) async {
        calls++;
        if (calls == 1) {
          r.response.headers.set('Mcp-Session-Id', 's');
          await _json(r, <String, Object?>{
            'jsonrpc': '2.0',
            'id': body!['id'],
            'result': <String, Object?>{},
          });
          return;
        }
        r.response.statusCode = 404;
        await r.response.close();
      });
      addTearDown(server.close);
      final McpHttpTransport transport = _transport(server);
      await transport.request(
        _req(1, 'initialize'),
        timeout: const Duration(seconds: 5),
      );
      await expectLater(
        transport.request(
          _req(2, 'tools/list'),
          timeout: const Duration(seconds: 5),
        ),
        throwsA(
          isA<McpClientException>().having(
            (McpClientException e) => e.code,
            'code',
            'session_expired',
          ),
        ),
      );
      expect(transport.sessionId, isNull);
    });

    test('unreachable endpoint is connect_failed', () async {
      final HttpServer probe = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final int port = probe.port;
      await probe.close(force: true);
      final McpHttpTransport transport = McpHttpTransport(
        endpoint: Uri.parse('http://127.0.0.1:$port/mcp'),
        client: IOClient(HttpClient()..findProxy = (Uri _) => 'DIRECT'),
      );
      await expectLater(
        transport.request(
          _req(1, 'initialize'),
          timeout: const Duration(seconds: 5),
        ),
        throwsA(
          isA<McpClientException>().having(
            (McpClientException e) => e.code,
            'code',
            'connect_failed',
          ),
        ),
      );
    });
  });

  group('McpStdioTransport', () {
    test(
      'matches replies by id, answers server pings, rejects other server requests',
      () async {
        final _FakeProcess process = _FakeProcess();
        final McpStdioTransport transport = McpStdioTransport(process);
        final Future<Map<String, Object?>> pending = transport.request(
          _req(5, 'tools/list'),
          timeout: const Duration(seconds: 5),
        );
        await pumpEventQueue();
        expect(
          jsonDecode(process.written.single),
          containsPair('method', 'tools/list'),
        );
        process
          ..emit('not json at all')
          ..emit(
            '{"jsonrpc":"2.0","method":"notifications/message","params":{}}',
          )
          ..emit('{"jsonrpc":"2.0","id":"srv-1","method":"ping"}')
          ..emit(
            '{"jsonrpc":"2.0","id":"srv-2","method":"sampling/createMessage"}',
          )
          ..emit('{"jsonrpc":"2.0","id":5,"result":{"tools":[]}}');
        expect((await pending)['result'], <String, Object?>{
          'tools': <Object?>[],
        });
        final List<Map<String, Object?>> replies = <Map<String, Object?>>[
          for (final String line in process.written.skip(1))
            Map<String, Object?>.from(jsonDecode(line) as Map),
        ];
        expect(replies[0], <String, Object?>{
          'jsonrpc': '2.0',
          'id': 'srv-1',
          'result': <String, Object?>{},
        });
        expect((replies[1]['error']! as Map)['code'], -32601);
        await transport.close();
        expect(process.killed, isTrue);
      },
    );

    test('process exit fails pending requests with the stderr tail', () async {
      final _FakeProcess process = _FakeProcess();
      final McpStdioTransport transport = McpStdioTransport(process);
      final Future<Map<String, Object?>> pending = transport.request(
        _req(1, 'initialize'),
        timeout: const Duration(seconds: 5),
      );
      process.emitStderr('Error: missing API_KEY');
      await pumpEventQueue();
      process.exit(1);
      await expectLater(
        pending,
        throwsA(
          isA<McpClientException>()
              .having(
                (McpClientException e) => e.code,
                'code',
                'process_exited',
              )
              .having(
                (McpClientException e) => e.message,
                'message',
                contains('missing API_KEY'),
              ),
        ),
      );
      await expectLater(
        transport.request(
          _req(2, 'tools/list'),
          timeout: const Duration(seconds: 5),
        ),
        throwsA(isA<McpClientException>()),
      );
    });

    test('times out when the program never answers', () async {
      final McpStdioTransport transport = McpStdioTransport(_FakeProcess());
      await expectLater(
        transport.request(
          _req(1, 'initialize'),
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(
          isA<McpClientException>().having(
            (McpClientException e) => e.code,
            'code',
            'timeout',
          ),
        ),
      );
    });
  });
}

class _FakeProcess implements McpStdioProcess {
  final StreamController<String> _out = StreamController<String>();
  final StreamController<String> _err = StreamController<String>();
  final Completer<int> _exit = Completer<int>();
  final List<String> written = <String>[];
  bool killed = false;

  void emit(String line) => _out.add(line);
  void emitStderr(String line) => _err.add(line);
  void exit(int code) => _exit.complete(code);

  @override
  void writeLine(String line) => written.add(line);

  @override
  Stream<String> get stdoutLines => _out.stream;

  @override
  Stream<String> get stderrLines => _err.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  void kill() {
    killed = true;
    if (!_exit.isCompleted) _exit.complete(-1);
  }
}
