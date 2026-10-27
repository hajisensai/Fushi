import 'dart:collection';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/agent/ai_agent_controller.dart';
import 'package:fushi/src/ai/agent/ai_agent_toolbox.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';

class _UnusedRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('测试走注入的 invoker，不碰 ref');
}

class _Settings implements AiSettingsSource {
  _Settings(this.aiProviders);

  @override
  final List<AiProviderConfig> aiProviders;

  @override
  AiFeatureAssignments get aiFeatureAssignments =>
      AiFeatureAssignments(defaultProviderId: aiProviders.firstOrNull?.id);

  @override
  List<WebKnowledgeSite> get aiWebKnowledgeSites => const <WebKnowledgeSite>[];
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

AiChatTurn _call(
  String id,
  Map<String, Object?> args, {
  String callId = 'c1',
}) => AiChatTurn(
  text: '',
  toolCalls: <AiChatToolCall>[
    AiChatToolCall(id: callId, name: agentWireToolName(id), arguments: args),
  ],
);

/// 一份最小的「设置」路由 + 描述：与真实 settings.set 同一撤销形态（读旧值写回）。
OpInvoker _invoker(Map<String, Object?> store, List<String> deleted) {
  final List<CtlRoute> routes = <CtlRoute>[
    CtlRoute.get(
      '/api/admin/settings/:key',
      (CtlCall call) async => <String, Object?>{
        'value': store[call.params['key']],
      },
    ),
    CtlRoute.put('/api/admin/settings/:key', (CtlCall call) async {
      store[call.params['key']!] = call.body['value'];
      return <String, Object?>{'value': store[call.params['key']]};
    }),
    CtlRoute.post('/api/admin/files/:name/delete', (CtlCall call) async {
      if (call.optBool('confirm') != true) {
        throw const CtlFailure.badRequest('需 confirm');
      }
      deleted.add(call.params['name']!);
      return null;
    }),
  ];
  Future<Object?> read(String key) async => store[key];
  return OpInvoker(
    OpCatalog.build(routes, <OpDescription>[
      OpDescription(
        id: 'settings.set',
        method: 'PUT',
        pattern: '/api/admin/settings/:key',
        summary: 'Set a setting.',
        risk: OpRisk.write,
        params: const <OpParam>[
          OpParam.string('key', description: 'k', required: true, inPath: true),
          OpParam.string('value', description: 'v', required: true),
        ],
        undo: OpUndo(
          capture: (CtlCall call) async => <String, Object?>{
            'key': call.params['key'],
            'old': await read(call.params['key']!),
          },
          record: (CtlCall call, Map<String, Object?> before, Object? result) =>
              OpUndoRecord(
                payload: <String, Object?>{
                  ...before,
                  'new': call.body['value'],
                },
                before: '${before['old']}',
                after: '${call.body['value']}',
              ),
          revert: (Map<String, Object?> payload) async {
            final String key = payload['key']! as String;
            if (store[key] != payload['new']) {
              return const OpUndoOutcome.superseded();
            }
            store[key] = payload['old'];
            return const OpUndoOutcome.done();
          },
        ),
      ),
      const OpDescription(
        id: 'files.delete',
        method: 'POST',
        pattern: '/api/admin/files/:name/delete',
        summary: 'Delete a file from disk.',
        risk: OpRisk.irreversible,
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
    ]),
  );
}

void main() {
  late FushiDatabase db;
  late Map<String, Object?> store;
  late List<String> deleted;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    store = <String, Object?>{'subtitle.size': '20'};
    deleted = <String>[];
  });

  tearDown(() => db.close());

  AiAgentController controller(List<AiChatTurn> turns) =>
      AiAgentController.forTesting(
        database: db,
        settings: _Settings(<AiProviderConfig>[
          AiProviderConfig(
            id: 'p1',
            presetId: 'openai',
            name: 'test',
            baseUrl: Uri.parse('https://api.openai.com/v1'),
            apiKeys: const <AiApiKey>[AiApiKey('sk-test')],
            model: 'gpt-test',
            protocol: AiWireProtocol.openAiCompatible,
          ),
        ]),
        opContext: OpContext(ref: _UnusedRef()),
        invoker: _invoker(store, deleted),
        llmFactory: (AiProviderConfig _) => _StubLlm(turns),
        clock: () => DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );

  test('没指派提供商：hasProvider = false，不开会话', () {
    final AiAgentController c = AiAgentController.forTesting(
      database: db,
      settings: _Settings(const <AiProviderConfig>[]),
      opContext: OpContext(ref: _UnusedRef()),
      invoker: _invoker(store, deleted),
      llmFactory: (AiProviderConfig _) => fail('不该建模型'),
    );
    expect(c.hasProvider, isFalse);
    expect(() => c.ensureSession(), throwsStateError);
  });

  test('可撤销写：直接执行 → 记进操作记录 → 撤销写回；存档可恢复', () async {
    final AiAgentController c = controller(<AiChatTurn>[
      _call('settings.set', <String, Object?>{
        'key': 'subtitle.size',
        'value': '28',
      }),
    ]);
    await c.send('把字幕调大');
    expect(store['subtitle.size'], '28');

    final List<AiAgentActionRow> actions = await db.listAiAgentActions();
    expect(actions, hasLength(1));
    expect(actions.single.opId, 'settings.set');
    expect(actions.single.confirmation, 'auto');
    expect(actions.single.undoPayloadJson, isNotNull);
    expect((actions.single.beforeText, actions.single.afterText), ('20', '28'));

    final AgentEntry entry = c.session!.entries.firstWhere(
      (AgentEntry e) => e.kind == AgentEntryKind.toolCall,
    );
    expect(entry.actionId, '${actions.single.id}');
    final AgentUndoResult undo = await c.undoEntry(entry.id);
    expect(undo.status, AgentUndoStatus.done);
    expect(store['subtitle.size'], '20');
    final AiAgentActionRow after = (await db.getAiAgentAction(
      actions.single.id,
    ))!;
    expect(after.undoneAt, isNotNull);
    expect(after.undoStatus, 'done');
    // 再撤一次：已撤过，不重复写回。
    expect((await c.toolbox.undo('${after.id}')).status, AgentUndoStatus.done);

    final String sessionId = c.session!.id;
    expect((await db.getAiAgentSession(sessionId))!.title, '把字幕调大');
    await c.newSession();
    expect(c.session, isNull);
    expect(await c.resume(sessionId), isTrue);
    expect(
      c.session!.entries
          .firstWhere((AgentEntry e) => e.kind == AgentEntryKind.toolCall)
          .status,
      AgentEntryStatus.undone,
    );
  });

  test('执行后被手动改过：撤销报 superseded，保留用户的值', () async {
    final AiAgentController c = controller(<AiChatTurn>[
      _call('settings.set', <String, Object?>{
        'key': 'subtitle.size',
        'value': '28',
      }),
    ]);
    await c.send('调大');
    store['subtitle.size'] = '32';
    final AgentEntry entry = c.session!.entries.firstWhere(
      (AgentEntry e) => e.kind == AgentEntryKind.toolCall,
    );
    expect((await c.undoEntry(entry.id)).status, AgentUndoStatus.superseded);
    expect(store['subtitle.size'], '32');
  });

  test('不可逆：等用户在卡片上点；同意才注入表态参数，记账为 user 确认', () async {
    final AiAgentController c = controller(<AiChatTurn>[
      _call('files.delete', <String, Object?>{'name': 'a.epub'}),
    ]);
    final Future<void> turn = c.send('删掉 a.epub');
    await pumpEventQueue();
    expect(c.host.awaitingConfirm, isTrue);
    expect(deleted, isEmpty);
    c.host.answerConfirm(true);
    await turn;
    expect(deleted, <String>['a.epub']);
    final AiAgentActionRow row = (await db.listAiAgentActions()).single;
    expect(row.confirmation, 'user');
    expect(row.undoPayloadJson, isNull);
  });

  test('取消会话：待答的确认卡片按拒绝收尾，不替用户同意', () async {
    final AiAgentController c = controller(<AiChatTurn>[
      _call('files.delete', <String, Object?>{'name': 'b.epub'}),
    ]);
    final Future<void> turn = c.send('删掉 b.epub');
    await pumpEventQueue();
    c.cancel();
    await turn;
    expect(deleted, isEmpty);
  });

  test('参数里的凭据在记账前抹掉（递归），设置键名这类普通 key 不误伤', () {
    expect(
      redactAiAgentArgs(<String, Object?>{
        'key': 'subtitle.size',
        'apiKey': 'sk-1',
        'nested': <String, Object?>{'token': 't', 'value': 3},
        'password': 'p',
      }),
      <String, Object?>{
        'key': 'subtitle.size',
        'apiKey': '<redacted>',
        'nested': <String, Object?>{'token': '<redacted>', 'value': 3},
        'password': '<redacted>',
      },
    );
  });

  test('结果交给模型前抹掉凭据：键名像凭据的、标题像凭据的条目值', () {
    expect(
      redactAiAgentResult(<String, Object?>{
        'providers': <Object?>[
          <String, Object?>{'name': 'x', 'apiKey': 'sk-1', 'model': 'm'},
        ],
        'preferences': <Object?>[
          <String, Object?>{'key': 'pwd', 'title': '密码', 'value': 'hunter2'},
          <String, Object?>{
            'key': 'quality',
            'title': 'Quality',
            'value': 'hd',
          },
        ],
      }),
      <String, Object?>{
        'providers': <Object?>[
          <String, Object?>{'name': 'x', 'apiKey': '<redacted>', 'model': 'm'},
        ],
        'preferences': <Object?>[
          <String, Object?>{'key': 'pwd', 'title': '密码', 'value': '<redacted>'},
          <String, Object?>{
            'key': 'quality',
            'title': 'Quality',
            'value': 'hd',
          },
        ],
      },
    );
  });
}
