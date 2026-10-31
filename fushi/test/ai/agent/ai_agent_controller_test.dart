import 'dart:collection';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/agent/ai_agent_controller.dart';
import 'package:fushi/src/ai/agent/ai_agent_session_archive.dart';
import 'package:fushi/src/ai/agent/ai_agent_toolbox.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_model_pricing.dart';
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
  AiModelPricing get pricing => const AiModelPricing();

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

  AiAgentController controller(
    List<AiChatTurn> turns, {
    DateTime Function()? clock,
  }) => AiAgentController.forTesting(
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
    clock: clock ?? () => DateTime.fromMillisecondsSinceEpoch(1700000000000),
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

  group('多会话（反馈 uILXKiYRhl）', () {
    late int now;
    DateTime tick() => DateTime.fromMillisecondsSinceEpoch(now += 1000);

    setUp(() => now = 1700000000000);

    List<String> ids(List<AiAgentSessionSummary> list) =>
        list.map((AiAgentSessionSummary s) => s.id).toList();

    test('新建 / 列表 / 切换续接 / 重命名不被重存冲掉 / 删当前会话', () async {
      final AiAgentController c = controller(const <AiChatTurn>[], clock: tick);
      addTearDown(c.dispose);
      int revisions = 0;
      c.sessionsRevision.addListener(() => revisions++);
      expect(c.sessionLibrary, same(c));
      expect(c.currentSessionUnsaved, isTrue);

      await c.send('第一场：把字幕调大');
      final String first = c.currentSessionId!;
      expect(c.currentSessionUnsaved, isFalse);
      await c.newSession();
      expect(c.currentSessionId, isNull);
      expect(c.currentSessionUnsaved, isTrue);
      await c.send('第二场');
      final String second = c.currentSessionId!;
      expect(second, isNot(first));
      expect(ids(await c.listSessions()), <String>[second, first]);
      expect(revisions, greaterThan(0));

      // 切回第一场：条目原样恢复，能接着说。
      expect(await c.switchToSession(first), isTrue);
      expect(c.currentSessionId, first);
      expect(
        c.entries
            .where((AgentEntry e) => e.kind == AgentEntryKind.user)
            .map((AgentEntry e) => e.text),
        <String>['第一场：把字幕调大'],
      );
      // 切到的就是当前这场：什么都不做。
      expect(await c.switchToSession(first), isTrue);
      expect(await c.switchToSession('missing'), isFalse);
      expect(c.currentSessionId, first, reason: '切换失败不动当前会话');

      // 重命名后再说一句：标题保持用户改的，updatedAt 前移到列表最前。
      await c.renameSession(first, '  字幕设置  ');
      await c.renameSession(first, '   ');
      await c.send('再大一点');
      final AiAgentSessionRow row = (await db.getAiAgentSession(first))!;
      expect(row.title, '字幕设置');
      expect(
        (await c.listSessions()).first,
        isA<AiAgentSessionSummary>()
            .having((AiAgentSessionSummary s) => s.id, 'id', first)
            .having((AiAgentSessionSummary s) => s.title, 'title', '字幕设置'),
      );

      // 删当前这场：换成新对话，存档没了，另一场还在。
      await c.deleteSession(first);
      expect(c.currentSessionId, isNull);
      expect(await db.getAiAgentSession(first), isNull);
      expect(ids(await c.listSessions()), <String>[second]);
    });

    test('互联 host 替远端跑的会话（remote 场景）不进本机会话列表，操作记录页照列', () async {
      final AiAgentController c = controller(const <AiChatTurn>[], clock: tick);
      addTearDown(c.dispose);
      await c.send('本机的会话');
      final String local = c.currentSessionId!;
      // 与 host 的远端会话同一个写入口、同一个 Profile 归属，只是场景不同。
      await db.saveAiAgentSessionSnapshot(
        id: 'remote-1',
        title: '对端的会话',
        scene: kAiAgentRemoteScene,
        payloadJson: '{}',
        totalTokens: 0,
        createdAt: 1,
        updatedAt: now + 60000,
      );
      expect(ids(await c.listSessions()), <String>[local]);
      expect(ids(await db.listAiAgentSessionSummaries()), <String>[
        'remote-1',
        local,
      ], reason: '操作记录页按全部会话配标题，远端会话照列');
      expect(
        await db.listAiAgentSessionSummaries(
          excludeScenes: kAiAgentLocalLibraryExcludedScenes,
          limit: 1,
        ),
        hasLength(1),
        reason: 'limit 按过滤后的行计，远端会话不挤占名额',
      );
    });

    test('删掉正在跑的会话：收尾存档不把它写回，操作记录保留', () async {
      final AiAgentController c = controller(<AiChatTurn>[
        _call('settings.set', <String, Object?>{
          'key': 'subtitle.size',
          'value': '28',
        }),
        const AiChatTurn(text: '好的', toolCalls: <AiChatToolCall>[]),
        _call('files.delete', <String, Object?>{'name': 'c.epub'}),
      ], clock: tick);
      addTearDown(c.dispose);
      await c.send('调大字幕');
      final String id = c.currentSessionId!;
      expect(await db.getAiAgentSession(id), isNotNull);

      final Future<void> turn = c.send('删掉 c.epub');
      await pumpEventQueue();
      expect(c.host.awaitingConfirm, isTrue);
      await c.deleteSession(id);
      await turn;
      expect(deleted, isEmpty, reason: '删会话按取消收尾，不替用户同意');
      expect(await db.getAiAgentSession(id), isNull);
      expect(
        (await db.listAiAgentActions()).map((AiAgentActionRow r) => r.opId),
        contains('settings.set'),
        reason: '操作记录不随会话删除，仍可在「AI 操作记录」里撤销',
      );
    });

    test('会话按 Profile 归属：列表只列当前 Profile 的；切过 Profile 再打开换新对话', () async {
      final int a = await db.insertProfile(
        ProfilesCompanion.insert(
          name: 'A',
          uid: const Value<String?>('uid-a'),
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      final int b = await db.insertProfile(
        ProfilesCompanion.insert(
          name: 'B',
          uid: const Value<String?>('uid-b'),
          createdAt: 2,
          updatedAt: 2,
        ),
      );
      await db.setPref(kActiveProfileIdPrefKey, '$a');
      final AiAgentController c = controller(const <AiChatTurn>[], clock: tick);
      addTearDown(c.dispose);

      await c.send('A 的会话');
      final String sessionA = c.currentSessionId!;
      expect((await db.getAiAgentSession(sessionA))!.profileUid, 'uid-a');

      await db.setPref(kActiveProfileIdPrefKey, '$b');
      expect(await c.listSessions(), isEmpty);
      await c.syncWithActiveProfile();
      expect(c.currentSessionId, isNull, reason: '手上这场属于 A，换成新对话');
      await c.send('B 的会话');
      final String sessionB = c.currentSessionId!;
      expect(ids(await c.listSessions()), <String>[sessionB]);
      // 同一 Profile 下再打开：不换。
      await c.syncWithActiveProfile();
      expect(c.currentSessionId, sessionB);

      await db.setPref(kActiveProfileIdPrefKey, '$a');
      expect(ids(await c.listSessions()), <String>[sessionA]);
      // 续接 A 的会话后在 A 里接着说：归属仍是 A。
      expect(await c.switchToSession(sessionA), isTrue);
      await c.send('接着说');
      expect((await db.getAiAgentSession(sessionA))!.profileUid, 'uid-a');
    });
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
