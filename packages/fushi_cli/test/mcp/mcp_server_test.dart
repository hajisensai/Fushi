import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_cli/fushi_cli.dart';
import 'package:test/test.dart';

/// 一份覆盖四种执行方式的小目录：读、可撤销写、装扩展式强制确认、不可逆（带表态
/// 参数），外加两条不该对外的（进程内专有、结果含一次性凭据）。
OpCatalog _catalog(List<String> calls) {
  Future<Object?> record(CtlCall call) async {
    calls.add('${call.method} ${call.path} ${jsonEncode(call.body)}');
    return <String, Object?>{'ok': true};
  }

  final List<CtlRoute> routes = <CtlRoute>[
    CtlRoute.get('/api/admin/things', record),
    CtlRoute.put('/api/admin/things/:id', record),
    CtlRoute.post('/api/admin/ext/install', record),
    CtlRoute.post('/api/admin/files/:name/delete', record),
    CtlRoute.post('/api/admin/peer/ticket', record),
  ];
  return OpCatalog.build(
    routes,
    <OpDescription>[
      const OpDescription(
        id: 'things.list',
        method: 'GET',
        pattern: '/api/admin/things',
        summary: 'List things.',
      ),
      OpDescription(
        id: 'things.rename',
        method: 'PUT',
        pattern: '/api/admin/things/:id',
        summary: 'Rename a thing.',
        risk: OpRisk.write,
        params: const <OpParam>[
          OpParam.string('id', description: 'id', required: true, inPath: true),
          OpParam.string('title', description: 'new title', required: true),
        ],
        undo: OpUndo(
          record: (CtlCall call, Map<String, Object?> before, Object? result) =>
              const OpUndoRecord(payload: <String, Object?>{}),
          revert: (Map<String, Object?> payload) async =>
              const OpUndoOutcome.done(),
        ),
      ),
      OpDescription(
        id: 'online.extension.install',
        method: 'POST',
        pattern: '/api/admin/ext/install',
        summary: 'Install an extension.',
        risk: OpRisk.write,
        confirm: true,
        params: const <OpParam>[
          OpParam.string('pkg', description: 'package', required: true),
          OpParam.userGate('trustSigner', description: 'user trusts signer'),
        ],
        undo: OpUndo(
          record: (CtlCall call, Map<String, Object?> before, Object? result) =>
              const OpUndoRecord(payload: <String, Object?>{}),
          revert: (Map<String, Object?> payload) async =>
              const OpUndoOutcome.done(),
        ),
      ),
      const OpDescription(
        id: 'files.delete',
        method: 'POST',
        pattern: '/api/admin/files/:name/delete',
        summary: 'Delete a file from disk.',
        risk: OpRisk.irreversible,
        longRunning: true,
        params: <OpParam>[
          OpParam.string(
            'name',
            description: 'n',
            required: true,
            inPath: true,
          ),
          OpParam.userGate('confirm', description: 'user confirmed'),
        ],
      ),
      const OpDescription(
        id: 'peer.ticket',
        method: 'POST',
        pattern: '/api/admin/peer/ticket',
        summary: 'Create a one-time pairing ticket.',
        sensitiveResult: true,
      ),
    ],
    extra: <FushiOp>[
      FushiOp(
        id: 'nav.open',
        summary: 'Open a page.',
        inProcessOnly: true,
        route: CtlRoute.post('/inproc/nav/open', record),
      ),
    ],
  );
}

/// 最小宿主：清单 = 目录生成（[mcpToolOf]），执行 = 以模型身份调 [OpInvoker]。
class _CatalogHost implements McpToolHost {
  _CatalogHost(this.catalog);

  final OpCatalog catalog;
  final List<McpCallContext> contexts = <McpCallContext>[];

  @override
  List<McpTool> listTools() => <McpTool>[
    for (final FushiOp op in catalog.available())
      if (mcpExposesOp(op.spec)) mcpToolOf(op.spec),
  ];

  @override
  Future<McpToolResult> callTool(
    String name,
    Map<String, Object?> arguments,
    McpCallContext context,
  ) async {
    contexts.add(context);
    final FushiOp? op = catalog[mcpOpIdOf(name)];
    if (op == null || !mcpExposesOp(op.spec)) throw McpUnknownTool(name);
    try {
      final OpInvocation result = await OpInvoker(
        catalog,
      ).invoke(op.id, arguments, caller: OpCaller.model);
      return McpToolResult.ok(result.result);
    } on CtlFailure catch (failure) {
      return McpToolResult.error(failure.code, failure.message);
    }
  }
}

/// 每次调用都挂起，直到测试放行或调用被取消；放行时只执行没被取消的。
class _BlockingHost implements McpToolHost {
  final List<McpCallContext> contexts = <McpCallContext>[];
  final List<String> executed = <String>[];
  final Completer<void> release = Completer<void>();

  @override
  List<McpTool> listTools() => const <McpTool>[];

  @override
  Future<McpToolResult> callTool(
    String name,
    Map<String, Object?> arguments,
    McpCallContext context,
  ) async {
    contexts.add(context);
    await Future.any(<Future<void>>[
      release.future,
      context.cancellation.whenCancelled,
    ]);
    if (context.cancellation.isCancelled) {
      return const McpToolResult.error('cancelled');
    }
    executed.add(name);
    return const McpToolResult.ok(null);
  }
}

Map<String, Object?> _cancelled(Object? requestId) => <String, Object?>{
  'jsonrpc': '2.0',
  'method': 'notifications/cancelled',
  'params': <String, Object?>{'requestId': requestId, 'reason': 'timeout'},
};

Map<String, Object?> _req(int id, String method, [Object? params]) =>
    <String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    };

void main() {
  late List<String> calls;
  late _CatalogHost host;
  late McpServer server;

  setUp(() {
    calls = <String>[];
    host = _CatalogHost(_catalog(calls));
    server = McpServer(
      host: host,
      serverName: 'fushi',
      serverVersion: () => '1.2.3',
      instructions: 'hi',
    );
  });

  group('工具清单由目录描述生成', () {
    test('名字 = id 点换 __，可逆；进程内专有与含一次性凭据的不对外', () async {
      final McpReply reply = await server.handle(_req(1, 'tools/list'));
      final Map<String, Object?> body = reply.body! as Map<String, Object?>;
      final List<Object?> tools =
          (body['result']! as Map<String, Object?>)['tools']! as List<Object?>;
      final Map<String, Map<String, Object?>> byName =
          <String, Map<String, Object?>>{
            for (final Object? t in tools)
              (t! as Map<String, Object?>)['name']! as String:
                  t as Map<String, Object?>,
          };
      expect(byName.keys.toSet(), <String>{
        'things__list',
        'things__rename',
        'online__extension__install',
        'files__delete',
      });
      for (final String name in byName.keys) {
        expect(mcpToolNameOf(mcpOpIdOf(name)), name);
      }
    });

    test('参数 schema 不含用户表态参数；说明 = 目录说明 + 执行方式', () {
      final Map<String, McpTool> tools = <String, McpTool>{
        for (final McpTool t in host.listTools()) t.name: t,
      };
      final McpTool install = tools['online__extension__install']!;
      final Map<String, Object?> props =
          install.inputSchema['properties']! as Map<String, Object?>;
      expect(props.keys, <String>['pkg']);
      expect(install.inputSchema['required'], <String>['pkg']);
      expect(install.description, startsWith('Install an extension.'));
      expect(install.description, contains('must approve it in the Fushi app'));

      final McpTool delete = tools['files__delete']!;
      expect(
        (delete.inputSchema['properties']! as Map<String, Object?>).keys,
        <String>['name'],
      );
      expect(delete.description, contains('Cannot be undone'));
      expect(delete.description, contains('background job'));
      expect(delete.toJson()['annotations'], <String, Object?>{
        'title': 'files.delete',
        'readOnlyHint': false,
        'destructiveHint': true,
      });

      expect(tools['things__list']!.toJson()['annotations'], <String, Object?>{
        'title': 'things.list',
        'readOnlyHint': true,
      });
      expect(tools['things__rename']!.description, contains('undo_action'));
      expect(
        (tools['things__rename']!.toJson()['annotations']!
            as Map<String, Object?>)['destructiveHint'],
        isFalse,
      );
    });
  });

  group('协议', () {
    test('initialize：协商版本、开会话、记住客户端身份', () async {
      final McpReply reply = await server.handle(
        _req(1, 'initialize', <String, Object?>{
          'protocolVersion': '2025-03-26',
          'capabilities': <String, Object?>{},
          'clientInfo': <String, Object?>{
            'name': 'claude-ai',
            'version': '0.1',
          },
        }),
      );
      final Map<String, Object?> result =
          (reply.body! as Map<String, Object?>)['result']!
              as Map<String, Object?>;
      expect(result['protocolVersion'], '2025-03-26');
      expect(result['serverInfo'], <String, Object?>{
        'name': 'fushi',
        'version': '1.2.3',
      });
      expect(result['instructions'], 'hi');
      expect(reply.sessionId, isNotNull);

      await server.handle(
        _req(2, 'tools/call', <String, Object?>{
          'name': 'things__list',
          'arguments': <String, Object?>{},
        }),
        sessionId: reply.sessionId,
      );
      expect(host.contexts.single.sessionId, reply.sessionId);
      expect(host.contexts.single.client.label, 'claude-ai 0.1');
    });

    test('不认识的版本回最新；未知会话按匿名客户端照常处理', () async {
      final McpReply reply = await server.handle(
        _req(1, 'initialize', <String, Object?>{
          'protocolVersion': '1999-01-01',
        }),
      );
      expect(
        ((reply.body! as Map<String, Object?>)['result']!
            as Map<String, Object?>)['protocolVersion'],
        kMcpSupportedProtocolVersions.first,
      );
      await server.handle(
        _req(2, 'tools/call', <String, Object?>{'name': 'things__list'}),
        sessionId: 'stale-after-restart',
      );
      expect(host.contexts.single.sessionId, 'anonymous');
      expect(host.contexts.single.client.name, McpClientInfo.unknown.name);
    });

    test('通知不回；ping 回空对象；未知方法 -32601', () async {
      expect(
        (await server.handle(<String, Object?>{
          'jsonrpc': '2.0',
          'method': 'notifications/initialized',
        })).body,
        isNull,
      );
      expect((await server.handle(_req(3, 'ping'))).body, <String, Object?>{
        'jsonrpc': '2.0',
        'id': 3,
        'result': <String, Object?>{},
      });
      final Map<String, Object?> missing =
          (await server.handle(_req(4, 'resources/list'))).body!
              as Map<String, Object?>;
      expect(
        (missing['error']! as Map<String, Object?>)['code'],
        kJsonRpcMethodNotFound,
      );
    });

    test('tools/call：未知工具 -32602；进程内专有工具按未知处理', () async {
      for (final String name in <String>[
        'nope__x',
        'nav__open',
        'peer__ticket',
      ]) {
        final Map<String, Object?> body =
            (await server.handle(
                  _req(5, 'tools/call', <String, Object?>{'name': name}),
                )).body!
                as Map<String, Object?>;
        expect(
          (body['error']! as Map<String, Object?>)['code'],
          kJsonRpcInvalidParams,
          reason: name,
        );
      }
      expect(calls, isEmpty);
    });

    test('外部调用方填表态参数一律 400（模型身份），不执行', () async {
      final Map<String, Object?> body =
          (await server.handle(
                _req(6, 'tools/call', <String, Object?>{
                  'name': 'files__delete',
                  'arguments': <String, Object?>{'name': 'a', 'confirm': true},
                }),
              )).body!
              as Map<String, Object?>;
      final Map<String, Object?> result =
          body['result']! as Map<String, Object?>;
      expect(result['isError'], isTrue);
      expect(
        jsonDecode(
          ((result['content']! as List<Object?>).single!
                  as Map<String, Object?>)['text']!
              as String,
        ),
        containsPair('error', 'bad_request'),
      );
      expect(calls, isEmpty);
    });

    test('成功结果：text + structuredContent', () async {
      final Map<String, Object?> body =
          (await server.handle(
                _req(7, 'tools/call', <String, Object?>{
                  'name': 'things__rename',
                  'arguments': <String, Object?>{'id': 'a', 'title': 'b'},
                }),
              )).body!
              as Map<String, Object?>;
      final Map<String, Object?> result =
          body['result']! as Map<String, Object?>;
      expect(result['isError'], isFalse);
      expect(result['structuredContent'], <String, Object?>{'ok': true});
      expect(calls.single, 'PUT /api/admin/things/a {"title":"b"}');
    });

    test('批量（2025-03-26 及更早）：逐条应答，通知不回', () async {
      final McpReply reply = await server.handle(<Object?>[
        _req(1, 'ping'),
        <String, Object?>{'jsonrpc': '2.0', 'method': 'notifications/x'},
        _req(2, 'ping'),
      ]);
      expect((reply.body! as List<Object?>).length, 2);
    });
  });

  group('取消（notifications/cancelled）', () {
    late _BlockingHost blocking;
    late McpServer cancellable;

    setUp(() {
      blocking = _BlockingHost();
      cancellable = McpServer(
        host: blocking,
        serverName: 'fushi',
        serverVersion: () => '1.2.3',
      );
    });

    Future<McpReply> call(Object? id, {String? session}) =>
        cancellable.handle(<String, Object?>{
          'jsonrpc': '2.0',
          'id': id,
          'method': 'tools/call',
          'params': <String, Object?>{'name': 'things__rename'},
        }, sessionId: session);

    test('取消在途调用：宿主拿到取消信号、不执行，被取消的请求不再应答', () async {
      final Future<McpReply> pending = call(9, session: 'S');
      await pumpEventQueue();
      expect(blocking.contexts.single.cancellation.isCancelled, isFalse);
      final McpReply ack = await cancellable.handle(
        _cancelled(9),
        sessionId: 'S',
      );
      expect(ack.body, isNull);
      expect(blocking.contexts.single.cancellation.isCancelled, isTrue);
      expect((await pending).body, isNull);
      expect(blocking.executed, isEmpty);
    });

    test('只取消同一会话、同一 id 的请求（1 与 "1" 是两个）', () async {
      final Future<McpReply> a = call(1, session: 'S');
      final Future<McpReply> b = call('1', session: 'S');
      final Future<McpReply> c = call(1, session: 'T');
      await pumpEventQueue();
      await cancellable.handle(_cancelled(1), sessionId: 'T');
      await cancellable.handle(_cancelled(1), sessionId: 'other');
      await cancellable.handle(_cancelled(404), sessionId: 'S');
      blocking.release.complete();
      expect((await c).body, isNull, reason: 'T 会话的 1 被取消');
      expect((await a).body, isNotNull);
      expect((await b).body, isNotNull);
      expect(blocking.executed, hasLength(2));
    });

    test('调用结束后再来的取消通知静默忽略；同 id 可再次使用', () async {
      blocking.release.complete();
      expect((await call(5, session: 'S')).body, isNotNull);
      expect(
        (await cancellable.handle(_cancelled(5), sessionId: 'S')).body,
        isNull,
      );
      expect((await call(5, session: 'S')).body, isNotNull);
      expect(blocking.executed, hasLength(2));
    });

    test('没带会话 id 的调用用没带会话 id 的取消通知取消', () async {
      final Future<McpReply> pending = call(3);
      await pumpEventQueue();
      await cancellable.handle(_cancelled(3), sessionId: 'S');
      expect(blocking.contexts.single.cancellation.isCancelled, isFalse);
      await cancellable.handle(_cancelled(3));
      expect((await pending).body, isNull);
      expect(blocking.contexts.single.sessionId, kMcpAnonymousSessionId);
    });

    test('DELETE /mcp 结束会话：它在途的调用一并取消', () async {
      final Future<McpReply> pending = call(7, session: 'S');
      final Future<McpReply> other = call(7, session: 'T');
      await pumpEventQueue();
      cancellable.endSession('S');
      expect((await pending).body, isNull);
      blocking.release.complete();
      expect((await other).body, isNotNull);
      expect(blocking.executed, hasLength(1));
    });
  });

  group('HTTP：挂在控制通道 /mcp，用配对令牌鉴权', () {
    late Directory dir;
    late CtlServer ctl;
    late CtlEndpoint endpoint;
    late McpAccess Function(String?) access;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('fushi_mcp_http_');
      access = (String? token) =>
          token == 'pair-token' ? McpAccess.allowed : McpAccess.unauthorized;
      ctl = CtlServer(
        handler: _NoopHandler(),
        stateDir: dir.path,
        token: 'ctl-token',
        mcp: McpHttpEndpoint(
          server: server,
          authorize: (String? token) => access(token),
        ),
      );
      endpoint = await ctl.start();
    });

    tearDown(() async {
      await ctl.stop();
      await dir.delete(recursive: true);
    });

    Future<(int, Map<String, String>, String)> post(
      Object? body, {
      String? token,
      Map<String, String> headers = const <String, String>{},
      String method = 'POST',
    }) async {
      final HttpClient http = HttpClient();
      try {
        final HttpClientRequest request = await http.openUrl(
          method,
          endpoint.baseUri.replace(path: '/mcp'),
        );
        if (token != null) {
          request.headers.set('authorization', 'Bearer $token');
        }
        headers.forEach(request.headers.set);
        if (body != null) request.write(jsonEncode(body));
        final HttpClientResponse response = await request.close();
        final Map<String, String> out = <String, String>{};
        response.headers.forEach(
          (String name, List<String> values) => out[name] = values.join(','),
        );
        return (response.statusCode, out, await utf8.decodeStream(response));
      } finally {
        http.close();
      }
    }

    test('没带令牌 / 令牌不对 / 拿控制通道 token 冒充：401，不执行', () async {
      for (final String? token in <String?>[null, 'wrong', 'ctl-token']) {
        final (int status, _, String text) = await post(
          _req(1, 'tools/call', <String, Object?>{
            'name': 'things__rename',
            'arguments': <String, Object?>{'id': 'a', 'title': 'b'},
          }),
          token: token,
        );
        expect(status, 401, reason: '$token');
        expect(jsonDecode(text), containsPair('error', 'unauthorized'));
      }
      expect(calls, isEmpty);
    });

    test('开关关着 / 没生成令牌：403 并说明去哪打开', () async {
      access = (String? _) => McpAccess.disabled;
      final (int s1, _, String t1) = await post(
        _req(1, 'tools/list'),
        token: 'pair-token',
      );
      expect(s1, 403);
      expect(jsonDecode(t1), containsPair('error', 'mcp_disabled'));
      access = (String? _) => McpAccess.notPaired;
      final (int s2, _, String t2) = await post(
        _req(1, 'tools/list'),
        token: 'pair-token',
      );
      expect(s2, 403);
      expect(jsonDecode(t2), containsPair('error', 'mcp_not_paired'));
    });

    test('带 Origin（网页 fetch）一律 403', () async {
      final (int status, _, _) = await post(
        _req(1, 'tools/list'),
        token: 'pair-token',
        headers: const <String, String>{'origin': 'https://evil.example'},
      );
      expect(status, 403);
    });

    test('initialize 回 Mcp-Session-Id；通知 202；GET 405；DELETE 204', () async {
      final (int s1, Map<String, String> h1, String t1) = await post(
        _req(1, 'initialize', <String, Object?>{
          'protocolVersion': '2025-06-18',
          'clientInfo': <String, Object?>{'name': 'test'},
        }),
        token: 'pair-token',
      );
      expect(s1, 200);
      expect(h1['mcp-session-id'], isNotEmpty);
      expect(jsonDecode(t1), containsPair('id', 1));

      final (int s2, _, String t2) = await post(
        <String, Object?>{
          'jsonrpc': '2.0',
          'method': 'notifications/initialized',
        },
        token: 'pair-token',
        headers: <String, String>{'mcp-session-id': h1['mcp-session-id']!},
      );
      expect((s2, t2), (202, ''));

      final (int s3, _, _) = await post(
        null,
        token: 'pair-token',
        method: 'GET',
      );
      expect(s3, 405);
      final (int s4, _, _) = await post(
        null,
        token: 'pair-token',
        method: 'DELETE',
        headers: <String, String>{'mcp-session-id': h1['mcp-session-id']!},
      );
      expect(s4, 204);
    });

    test('坏 JSON：400 + JSON-RPC parse error', () async {
      final HttpClient http = HttpClient();
      final HttpClientRequest request = await http.postUrl(
        endpoint.baseUri.replace(path: '/mcp'),
      );
      request.headers.set('authorization', 'Bearer pair-token');
      request.write('{not json');
      final HttpClientResponse response = await request.close();
      final Map<String, Object?> body =
          jsonDecode(await utf8.decodeStream(response)) as Map<String, Object?>;
      http.close();
      expect(response.statusCode, 400);
      expect(
        (body['error']! as Map<String, Object?>)['code'],
        kJsonRpcParseError,
      );
    });

    test('配对令牌进不了控制通道其它路由（那里只认控制通道 token）', () async {
      final HttpClient http = HttpClient();
      final HttpClientRequest request = await http.getUrl(
        endpoint.baseUri.replace(path: kCtlStatusPath),
      );
      request.headers.set('authorization', 'Bearer pair-token');
      final HttpClientResponse response = await request.close();
      await response.drain<void>();
      http.close();
      expect(response.statusCode, 401);
    });

    group('fushi_cli mcp 的 stdio 桥', () {
      Future<List<Map<String, Object?>>> bridge(
        List<Object?> messages, {
        String token = 'pair-token',
        bool appRunning = true,
      }) async {
        final StringBuffer out = StringBuffer();
        final StringBuffer log = StringBuffer();
        final McpStdioBridge b = McpStdioBridge(
          token: token,
          endpoint: () async => appRunning ? endpoint : null,
          output: out,
          log: log,
        );
        final StreamController<List<int>> input = StreamController<List<int>>();
        final Future<int> done = b.run(input.stream);
        // 一条一条发：与真客户端一样，等 initialize 的应答（会话 id）再发后续。
        for (final Object? m in messages) {
          input.add(utf8.encode('${jsonEncode(m)}\n'));
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        await input.close();
        expect(await done, 0);
        return <Map<String, Object?>>[
          for (final String line in const LineSplitter().convert('$out'))
            jsonDecode(line) as Map<String, Object?>,
        ];
      }

      test('initialize → initialized → tools/call：会话 id 由桥带上', () async {
        final List<Map<String, Object?>> replies = await bridge(<Object?>[
          _req(1, 'initialize', <String, Object?>{
            'protocolVersion': '2025-06-18',
            'clientInfo': <String, Object?>{'name': 'Claude Desktop'},
          }),
          <String, Object?>{
            'jsonrpc': '2.0',
            'method': 'notifications/initialized',
          },
          _req(2, 'tools/call', <String, Object?>{'name': 'things__list'}),
        ]);
        expect(replies.map((Map<String, Object?> r) => r['id']), <int>[1, 2]);
        expect(host.contexts.single.client.name, 'Claude Desktop');
        expect(host.contexts.single.sessionId, isNot('anonymous'));
      });

      test('令牌不对：每个请求回 JSON-RPC 错误，原因照搬', () async {
        final List<Map<String, Object?>> replies = await bridge(<Object?>[
          _req(1, 'tools/list'),
        ], token: 'wrong');
        final Map<String, Object?> error =
            replies.single['error']! as Map<String, Object?>;
        expect(error['code'], kMcpBridgeRejected);
        expect(error['message'], contains('pairing token'));
      });

      test('app 没在运行：回「Fushi is not running」', () async {
        final List<Map<String, Object?>> replies = await bridge(<Object?>[
          _req(1, 'initialize'),
        ], appRunning: false);
        final Map<String, Object?> error =
            replies.single['error']! as Map<String, Object?>;
        expect(error['code'], kMcpBridgeAppUnavailable);
        expect(error['message'], contains('not running'));
      });
    });
  });
}

class _NoopHandler implements CtlDesktopHandler {
  @override
  List<CtlRoute> get routes => const <CtlRoute>[];

  @override
  CtlAppStatus status() =>
      const CtlAppStatus(pid: 1, platform: 'linux', initialised: true);

  @override
  Future<CtlOpenResult> open(String target) async =>
      const CtlOpenResult.rejected('no');

  @override
  Future<void> lookup(String word) async {}

  @override
  Future<void> quit() async {}
}
