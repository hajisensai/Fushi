import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/sync/assistant/agent_assistant_host.dart';
import 'package:fushi_engine/sync/assistant/host_assistant.dart';
import 'package:fushi_server/src/admin/admin_ops.dart';
import 'package:fushi_server/src/agent_host.dart';
import 'package:fushi_server/src/config/server_ai_config.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

/// 一份最小的「admin API」：设置 / 订阅启停 / 库根 / 扫描，记下每次请求。
class _FakeAdmin {
  final Map<String, Object?> settings = <String, Object?>{
    'subtitleLanguage': 'ja',
    'metadataLocale': 'ja-JP',
    'scanPrune': true,
    'scanScrape': true,
    'tmdbApiKeySet': true,
  };
  final Map<String, bool> subscriptions = <String, bool>{'s1': true};
  final List<Map<String, Object?>> libraries = <Map<String, Object?>>[
    <String, Object?>{'id': 'lib1', 'path': '/media/a', 'kind': 'video'},
  ];
  final List<String> requests = <String>[];
  final List<Map<String, Object?>> bodies = <Map<String, Object?>>[];

  shelf.Response _json(Object body, {int status = 200}) => shelf.Response(
    status,
    body: jsonEncode(body),
    headers: const <String, String>{'Content-Type': 'application/json'},
  );

  Future<shelf.Response> handle(shelf.Request request) async {
    final String path = '/${request.url.path}';
    final String method = request.method;
    requests.add('$method $path');
    final String text = await request.readAsString();
    final Map<String, Object?> body = text.isEmpty
        ? <String, Object?>{}
        : Map<String, Object?>.from(jsonDecode(text) as Map);
    bodies.add(body);
    switch ((method, path)) {
      case ('GET', '/api/admin/settings'):
        return _json(settings);
      case ('PUT', '/api/admin/settings'):
        for (final String key in kServerAgentSettingKeys) {
          if (body.containsKey(key)) settings[key] = body[key];
        }
        return _json(settings);
      case ('GET', '/api/admin/subscriptions'):
        return _json(<String, Object?>{
          'subscriptions': <Object?>[
            for (final MapEntry<String, bool> e in subscriptions.entries)
              <String, Object?>{'subscriptionId': e.key, 'enabled': e.value},
          ],
        });
      case ('POST', _)
          when path.startsWith('/api/admin/subscriptions/') &&
              path.endsWith('/enable'):
        final String id = Uri.decodeComponent(path.split('/')[4]);
        if (!subscriptions.containsKey(id)) {
          return _json(<String, Object?>{'error': 'unknown'}, status: 404);
        }
        subscriptions[id] = body['enabled'] == true;
        return _json(const <String, Object?>{'ok': true});
      case ('GET', '/api/admin/libraries'):
        return _json(<String, Object?>{'libraries': libraries});
      case ('POST', '/api/admin/libraries'):
        libraries.add(<String, Object?>{
          'id': body['id'] ?? 'lib${libraries.length + 1}',
          'path': body['path'],
          'kind': body['kind'] ?? 'video',
        });
        return _json(<String, Object?>{'libraries': libraries});
      case ('DELETE', _) when path.startsWith('/api/admin/libraries/'):
        final String id = Uri.decodeComponent(
          path.substring('/api/admin/libraries/'.length),
        );
        libraries.removeWhere((Map<String, Object?> l) => l['id'] == id);
        return _json(<String, Object?>{'libraries': libraries});
      case ('POST', '/api/admin/scan'):
        return _json(const <String, Object?>{'started': true});
      case ('POST', '/api/admin/downloads'):
        return _json(const <String, Object?>{'jobId': 'j1'});
    }
    return _json(<String, Object?>{
      'error': 'unknown admin route $method $path',
    }, status: 404);
  }
}

class _StubLlm implements AgentLlm {
  _StubLlm(List<AiChatTurn> turns) : _turns = Queue<AiChatTurn>.of(turns);

  final Queue<AiChatTurn> _turns;

  @override
  bool get supportsTools => true;

  @override
  Future<AiChatTurn> chat(
    List<AiChatMessage> messages,
    List<AiChatToolSpec> tools,
  ) async => _turns.isEmpty
      ? const AiChatTurn(text: 'done', toolCalls: <AiChatToolCall>[])
      : _turns.removeFirst();
}

AiChatTurn _call(String id, Map<String, Object?> args) => AiChatTurn(
  text: '',
  toolCalls: <AiChatToolCall>[
    AiChatToolCall(id: 'c1', name: agentWireToolName(id), arguments: args),
  ],
);

void main() {
  group('服务端操作描述（与 app 侧护轮同口径）', () {
    final _FakeAdmin admin = _FakeAdmin();
    final ({List<CtlRoute> routes, List<OpDescription> descriptions}) ops =
        buildServerAdminOps(() => admin.handle);
    final OpCatalog catalog = OpCatalog.build(ops.routes, ops.descriptions);
    final String adminSource = File(
      'lib/src/admin/admin_api.dart',
    ).readAsStringSync();

    test('id 唯一、点分小写、不含 __、server. 前缀、说明非空', () {
      final RegExp shape = RegExp(r'^[a-z][a-z0-9]*(\.[a-z][a-z0-9-]*)+$');
      expect(catalog.ops.length, ops.descriptions.length);
      for (final FushiOp op in catalog.ops) {
        expect(shape.hasMatch(op.id), isTrue, reason: op.id);
        expect(op.id.contains('__'), isFalse, reason: op.id);
        expect(op.id, startsWith('server.'));
        expect(op.summary.trim(), isNotEmpty, reason: op.id);
      }
    });

    test('非 read 必须可撤销或标 irreversible；irreversible 不声明撤销且带 confirm 表态参数', () {
      for (final FushiOp op in catalog.ops) {
        if (op.risk == OpRisk.read) {
          expect(op.undo, isNull, reason: '${op.id}：read 不该声明撤销');
          expect(
            op.params.where((OpParam p) => p.userGate),
            isEmpty,
            reason: op.id,
          );
          continue;
        }
        expect(
          op.undo != null || op.risk == OpRisk.irreversible,
          isTrue,
          reason: '${op.id}：AI 写操作必须可回滚（fushi/CLAUDE.md §13）',
        );
        if (op.risk == OpRisk.irreversible) {
          expect(op.undo, isNull, reason: '${op.id}：能撤销就该是 write');
          expect(
            op.params.any(
              (OpParam p) => p.userGate && p.name == kServerOpConfirmGate,
            ),
            isTrue,
            reason: '${op.id}：不可逆操作要带表态参数',
          );
        }
      }
    });

    test('inPath 参数与模式的 :段一致；每条路由在 admin_api.dart 里真有处理分支', () {
      for (final FushiOp op in catalog.ops) {
        final List<String> parts = op.route.pattern.split('/');
        final Set<String> segments = <String>{
          for (final String seg in parts)
            if (seg.startsWith(':')) seg.substring(1),
        };
        expect(
          <String>{
            for (final OpParam p in op.params)
              if (p.inPath) p.name,
          },
          segments,
          reason: op.id,
        );
        // 防漂移：模式里 :段前后的字面量都要在 admin API 源码里出现。
        final int at = parts.indexWhere((String s) => s.startsWith(':'));
        if (at < 0) {
          expect(
            adminSource,
            contains("('${op.route.method}', '${op.route.pattern}')"),
            reason: op.id,
          );
        } else {
          final String prefix = '${parts.sublist(0, at).join('/')}/';
          expect(adminSource, contains("'$prefix'"), reason: op.id);
          if (at < parts.length - 1) {
            expect(
              adminSource,
              contains("'/${parts.sublist(at + 1).join('/')}'"),
              reason: op.id,
            );
          }
        }
      }
    });

    test('凭据 / 配对 / 监听类路由不进目录', () {
      for (final FushiOp op in catalog.ops) {
        for (final String banned in <String>[
          '/pairing',
          '/anki/login',
          '/anki/logout',
          '/resource-indexers',
          '/upload',
          '/host/',
          '/profiles',
          '/logs',
        ]) {
          expect(op.route.pattern.contains(banned), isFalse, reason: op.id);
        }
        for (final OpParam p in op.params) {
          expect(
            RegExp(
              r'(api_?key|token|secret|password|port|bind|tls)',
              caseSensitive: false,
            ).hasMatch(p.name),
            isFalse,
            reason: '${op.id}.${p.name}',
          );
        }
      }
    });

    test('不可逆操作：模型调不带表态 → 422 且不碰 admin API；运行时注入后才转发（表态参数不过线）', () async {
      final OpInvoker invoker = OpInvoker(catalog);
      admin.requests.clear();
      await expectLater(
        invoker.invoke(
          'server.scan',
          const <String, Object?>{},
          caller: OpCaller.model,
        ),
        throwsA(
          isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 422),
        ),
      );
      // 模型自己在参数里塞 confirm：未知参数 400。
      await expectLater(
        invoker.invoke('server.scan', const <String, Object?>{
          'confirm': true,
        }, caller: OpCaller.model),
        throwsA(
          isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 400),
        ),
      );
      expect(admin.requests, isEmpty);
      await invoker.invoke(
        'server.scan',
        const <String, Object?>{},
        caller: OpCaller.model,
        grantedGates: const <String>{kServerOpConfirmGate},
      );
      expect(admin.requests, <String>['POST /api/admin/scan']);
      expect(admin.bodies.last.containsKey(kServerOpConfirmGate), isFalse);
    });
  });

  group('磁力链接里的地址参数（tr= 等）', () {
    const String btih = 'urn:btih:0123456789abcdef0123456789abcdef01234567';

    test('判据：tr / ws / xs / as / x.pe（含编号写法、编码写法）都算；纯 DHT 不算', () {
      expect(magnetHasAddressParams('magnet:?xt=$btih&dn=a'), isFalse);
      for (final String extra in <String>[
        'tr=udp%3A%2F%2Fevil%3A1337%2Fannounce%3Fd%3Dsecret',
        'tr.1=http://t.example/announce',
        'ws=https://seed.example/file',
        'xs=https://x.example/a.torrent',
        'as=https://x.example/a.torrent',
        'x.pe=203.0.113.5:6881',
        'TR=http://t.example/announce',
        '%74r=http://t.example/announce',
      ]) {
        expect(
          magnetHasAddressParams('magnet:?xt=$btih&$extra'),
          isTrue,
          reason: extra,
        );
      }
    });

    test('模型给带 tracker 的磁力：直接执行的那条拒绝、不碰 admin API；先确认的那条确认后才转发', () async {
      final _FakeAdmin admin = _FakeAdmin();
      final OpCatalog catalog = buildServerAdminOpCatalog(() => admin.handle);
      final OpInvoker invoker = OpInvoker(catalog);
      const String withTracker =
          'magnet:?xt=$btih&tr=udp://evil.example:1337/announce?d=secret';
      final Map<String, Object?> args = <String, Object?>{
        'magnet': withTracker,
        'title': 'Work',
      };
      expect(catalog['server.download.add']!.spec.needsConfirmation, isFalse);
      final FushiOpSpec confirmed =
          catalog['server.download.add-with-trackers']!.spec;
      expect(confirmed.needsConfirmation, isTrue);
      expect(confirmed.undoable, isTrue);

      await expectLater(
        invoker.invoke('server.download.add', args, caller: OpCaller.model),
        throwsA(
          isA<CtlFailure>().having(
            (CtlFailure f) => f.message,
            'message',
            contains('server.download.add-with-trackers'),
          ),
        ),
      );
      // 模型自己塞表态参数：未知参数 400。
      await expectLater(
        invoker.invoke('server.download.add-with-trackers', <String, Object?>{
          ...args,
          kServerOpTrustMagnetAddressesGate: true,
        }, caller: OpCaller.model),
        throwsA(
          isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 400),
        ),
      );
      // 没经确认（运行时没注入）：同样拒。
      await expectLater(
        invoker.invoke(
          'server.download.add-with-trackers',
          args,
          caller: OpCaller.model,
        ),
        throwsA(isA<CtlFailure>()),
      );
      expect(admin.requests, isEmpty);

      await invoker.invoke(
        'server.download.add-with-trackers',
        args,
        caller: OpCaller.model,
        grantedGates: const <String>{kServerOpTrustMagnetAddressesGate},
      );
      expect(admin.requests, <String>['POST /api/admin/downloads']);
      expect(admin.bodies.last['magnet'], withTracker);
      expect(
        admin.bodies.last.containsKey(kServerOpTrustMagnetAddressesGate),
        isFalse,
      );

      // 纯 DHT 的磁力直接执行。
      await invoker.invoke('server.download.add', <String, Object?>{
        'magnet': 'magnet:?xt=$btih',
        'title': 'Work',
      }, caller: OpCaller.model);
      expect(admin.requests, hasLength(2));
    });
  });

  group('ServerAgentToolbox', () {
    late FushiDatabase db;
    late _FakeAdmin admin;
    late ServerAgentToolbox toolbox;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      admin = _FakeAdmin();
      toolbox = ServerAgentToolbox(
        invoker: OpInvoker(buildServerAdminOpCatalog(() => admin.handle)),
        db: db,
      );
    });

    tearDown(() => db.close());

    test('设置写：直接执行 → 记进服务端库 → 撤销写回；执行后被手改 → superseded 保留手改', () async {
      final AgentToolResult result = await toolbox.execute(
        const AgentToolInvocation(
          sessionId: 'rm1',
          name: 'server.settings.set',
          arguments: <String, Object?>{'subtitleLanguage': 'en'},
        ),
      );
      expect(result.isError, isFalse);
      expect(admin.settings['subtitleLanguage'], 'en');
      final List<AiAgentActionRow> rows = await db.listAiAgentActions();
      expect(rows.single.opId, 'server.settings.set');
      expect(rows.single.confirmation, 'auto');
      expect(result.actionId, '${rows.single.id}');
      expect(
        (await toolbox.undo(result.actionId!)).status,
        AgentUndoStatus.done,
      );
      expect(admin.settings['subtitleLanguage'], 'ja');
      // 已撤过：再撤不重复写回。
      expect(
        (await toolbox.undo(result.actionId!)).status,
        AgentUndoStatus.done,
      );

      final AgentToolResult second = await toolbox.execute(
        const AgentToolInvocation(
          sessionId: 'rm1',
          name: 'server.settings.set',
          arguments: <String, Object?>{'scanPrune': false},
        ),
      );
      admin.settings['scanPrune'] = true; // 管理员在 WebUI 里又改了
      expect(
        (await toolbox.undo(second.actionId!)).status,
        AgentUndoStatus.superseded,
      );
      expect(admin.settings['scanPrune'], isTrue);
    });

    test('订阅启停 / 库根增删：执行 → 撤销回到原状', () async {
      final AgentToolResult pause = await toolbox.execute(
        const AgentToolInvocation(
          sessionId: 'rm1',
          name: 'server.subscription.enable',
          arguments: <String, Object?>{'id': 's1', 'enabled': false},
        ),
      );
      expect(admin.subscriptions['s1'], isFalse);
      expect(
        (await toolbox.undo(pause.actionId!)).status,
        AgentUndoStatus.done,
      );
      expect(admin.subscriptions['s1'], isTrue);

      final AgentToolResult add = await toolbox.execute(
        const AgentToolInvocation(
          sessionId: 'rm1',
          name: 'server.library.add',
          arguments: <String, Object?>{'path': '/media/new', 'kind': 'book'},
        ),
      );
      expect(admin.libraries, hasLength(2));
      expect((await toolbox.undo(add.actionId!)).status, AgentUndoStatus.done);
      expect(
        admin.libraries.map((Map<String, Object?> l) => l['id']),
        <Object?>['lib1'],
      );

      final AgentToolResult remove = await toolbox.execute(
        const AgentToolInvocation(
          sessionId: 'rm1',
          name: 'server.library.remove',
          arguments: <String, Object?>{'id': 'lib1'},
        ),
      );
      expect(admin.libraries, isEmpty);
      expect(
        (await toolbox.undo(remove.actionId!)).status,
        AgentUndoStatus.done,
      );
      expect(admin.libraries.single, <String, Object?>{
        'id': 'lib1',
        'path': '/media/a',
        'kind': 'video',
      });
    });

    test('不可逆操作没经用户确认：拒绝执行；admin API 报错原样回成短码', () async {
      final AgentToolResult refused = await toolbox.execute(
        const AgentToolInvocation(
          sessionId: 'rm1',
          name: 'server.scan',
          arguments: <String, Object?>{},
        ),
      );
      expect(refused.errorCode, 'confirmation_required');
      expect(admin.requests, isEmpty);
      final AgentToolResult missing = await toolbox.execute(
        const AgentToolInvocation(
          sessionId: 'rm1',
          name: 'server.subscription.enable',
          arguments: <String, Object?>{'id': 'nope', 'enabled': true},
        ),
      );
      expect(missing.errorCode, 'not_found');
    });
  });

  group('createServerAgentAssistantHost', () {
    late FushiDatabase db;
    late _FakeAdmin admin;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      admin = _FakeAdmin();
    });

    tearDown(() => db.close());

    ServerConfig config(ServerAiConfig? ai) => ServerConfig.defaults(
      dataDir: Directory.systemTemp.path,
    ).copyWith(ai: ai);
    const ServerAiConfig ai = ServerAiConfig(
      preset: 'custom',
      baseUrl: 'https://ai.example.com/v1',
      model: 'm',
      apiKey: 'sk-test',
      agentForPeers: true,
    );

    test('没打开 agent_for_peers：报 disabled，不开会话（默认关）', () async {
      final AgentAssistantHost host = createServerAgentAssistantHost(
        config: () => config(ai.copyWith(agentForPeers: false)),
        db: db,
        dispatch: () => admin.handle,
        llmFactory: (AiProviderConfig _) => fail('不该建模型'),
      );
      expect((await host.capability())['reason'], 'disabled');
      await expectLater(
        host.open(kHostAssistantFeatureAgent, locale: 'zh'),
        throwsA(isA<HostAssistantUnavailable>()),
      );
      expect(const ServerAiConfig(preset: 'openai').agentForPeers, isFalse);
      expect(
        ServerAiConfig.fromYaml(<String, Object?>{
          'preset': 'openai',
          'agent_for_peers': true,
        })!.agentForPeers,
        isTrue,
      );
    });

    test('配置 `ai:` 段指派给 AI 助手；没配 → no_provider 且不建模型', () async {
      expect(
        ServerAiSettings(
          () => ai,
        ).aiFeatureAssignments.providerIdFor(AiFeature.agent),
        kServerAiProviderId,
      );
      bool built = false;
      final AgentAssistantHost host = createServerAgentAssistantHost(
        config: () => config(null),
        db: db,
        dispatch: () => admin.handle,
        llmFactory: (AiProviderConfig _) {
          built = true;
          return _StubLlm(<AiChatTurn>[]);
        },
      );
      final Map<String, Object?> cap = await host.capability();
      expect(cap['supported'], isFalse);
      expect(cap['reason'], 'no_provider');
      await expectLater(
        host.open(kHostAssistantFeatureAgent, locale: 'zh'),
        throwsA(isA<HostAssistantUnavailable>()),
      );
      expect(built, isFalse);
    });

    test('admin API 还没接上 → not_ready；接上后宣告 agent + 服务端工具数', () async {
      AdminDispatch? dispatch;
      final AgentAssistantHost host = createServerAgentAssistantHost(
        config: () => config(ai),
        db: db,
        dispatch: () => dispatch,
        llmFactory: (AiProviderConfig _) => _StubLlm(<AiChatTurn>[]),
      );
      expect((await host.capability())['reason'], 'not_ready');
      dispatch = admin.handle;
      final Map<String, Object?> cap = await host.capability();
      expect(cap['features'], <String>[kHostAssistantFeatureAgent]);
      final Map<String, Object?> tools = Map<String, Object?>.from(
        cap[kHostAssistantAgentToolsKey]! as Map,
      );
      expect(tools['source'], 'server');
      expect(
        tools['count'],
        buildServerAdminOpCatalog(() => admin.handle).ops.length,
      );
    });

    test('经 HostAssistantSessions：一句话 → 服务端操作执行 + 记账 → 撤销动作写回', () async {
      final HostAssistantSessions sessions = HostAssistantSessions(
        createServerAgentAssistantHost(
          config: () => config(ai),
          db: db,
          dispatch: () => admin.handle,
          llmFactory: (AiProviderConfig _) => _StubLlm(<AiChatTurn>[
            _call('server.settings.set', <String, Object?>{
              'subtitleLanguage': 'zh',
            }),
          ]),
        ),
      );
      final Map<String, Object?> first = await sessions.open(
        kHostAssistantFeatureAgent,
        locale: 'zh',
      );
      final String id = first['id']! as String;
      await sessions.act(id, <String, Object?>{
        'type': 'text',
        'text': '字幕语言改中文',
      });
      Map<String, Object?> view = <String, Object?>{};
      for (int i = 0; i < 200; i++) {
        view = Map<String, Object?>.from(
          (await sessions.read(id))!['view']! as Map,
        );
        if (view['running'] == false &&
            (view['entries']! as List).length >= 3) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(admin.settings['subtitleLanguage'], 'zh');
      final Map<String, Object?> tool = <Map<String, Object?>>[
        for (final Object? e in view['entries']! as List)
          Map<String, Object?>.from(e! as Map),
      ].firstWhere((Map<String, Object?> e) => e['kind'] == 'toolCall');
      expect(tool['status'], 'done');
      expect(
        (await db.listAiAgentActions()).single.sessionId,
        startsWith('rm'),
      );

      await sessions.act(id, <String, Object?>{
        'type': 'undo',
        'entryId': tool['id'],
      });
      for (
        int i = 0;
        i < 200 && admin.settings['subtitleLanguage'] != 'ja';
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(admin.settings['subtitleLanguage'], 'ja');
      await sessions.dispose();
    });
  });
}
