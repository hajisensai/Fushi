import 'dart:collection';
import 'dart:convert';

import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_model_pricing.dart';
import 'package:fushi_engine/sync/assistant/agent_assistant_host.dart';
import 'package:fushi_engine/sync/assistant/host_assistant.dart';
import 'package:test/test.dart';

/// 回放固定回合的 stub 模型。
class _StubLlm implements AgentLlm {
  _StubLlm(List<AiChatTurn> turns) : _turns = Queue<AiChatTurn>.of(turns);

  final Queue<AiChatTurn> _turns;
  int requests = 0;

  @override
  bool get supportsTools => true;

  @override
  AiModelPricing get pricing => const AiModelPricing();

  @override
  Future<AiChatTurn> chat(
    List<AiChatMessage> messages,
    List<AiChatToolSpec> tools,
  ) async {
    requests++;
    if (_turns.isEmpty) throw const AiChatFailure('empty_response');
    return _turns.removeFirst();
  }
}

AiChatTurn _call(String name, Map<String, Object?> args, {String id = 'c1'}) =>
    AiChatTurn(
      text: '',
      toolCalls: <AiChatToolCall>[
        AiChatToolCall(id: id, name: agentWireToolName(name), arguments: args),
      ],
      usage: const AiChatUsage(inputTokens: 10, outputTokens: 5),
    );

AiChatTurn _reply(String text) => AiChatTurn(
  text: text,
  toolCalls: const <AiChatToolCall>[],
  usage: const AiChatUsage(inputTokens: 10, outputTokens: 5),
);

class _Toolbox implements AgentToolbox {
  final Map<String, Object?> settings = <String, Object?>{'size': 20};
  final List<String> executed = <String>[];
  final Map<String, Object?> undoPayload = <String, Object?>{};
  int seq = 0;

  static const AgentToolSpec set = AgentToolSpec(
    name: 'settings.set',
    description: 'Write a setting.',
    parameters: <String, Object?>{'type': 'object'},
    risk: AgentToolRisk.write,
    undoable: true,
  );
  static const AgentToolSpec wipe = AgentToolSpec(
    name: 'library.file.delete',
    description: 'Delete a file.',
    parameters: <String, Object?>{'type': 'object'},
    risk: AgentToolRisk.irreversible,
  );

  @override
  List<AgentToolSpec> residentTools() => const <AgentToolSpec>[set, wipe];

  @override
  List<AgentToolSpec> searchTools(String query, {int limit = 12}) =>
      residentTools();

  @override
  AgentToolSpec? describeTool(String name) =>
      residentTools().where((AgentToolSpec t) => t.name == name).firstOrNull;

  @override
  Future<AgentToolResult> execute(AgentToolInvocation invocation) async {
    executed.add(invocation.name);
    if (invocation.name == set.name) {
      final String id = 'a${++seq}';
      undoPayload[id] = settings['size'];
      settings['size'] = invocation.arguments['value'];
      return AgentToolResult.ok(
        const <String, Object?>{'ok': true},
        actionId: id,
        before: '${undoPayload[id]}',
        after: '${settings['size']}',
      );
    }
    return const AgentToolResult.ok(<String, Object?>{'deleted': true});
  }

  @override
  Future<AgentUndoResult> undo(String actionId) async {
    if (!undoPayload.containsKey(actionId)) {
      return const AgentUndoResult(AgentUndoStatus.notUndoable);
    }
    settings['size'] = undoPayload.remove(actionId);
    return const AgentUndoResult(AgentUndoStatus.done);
  }
}

/// 让排进微任务 / 事件队列的后台 loop 跑起来，直到 [ready] 成立。
Future<void> _until(bool Function() ready) async {
  for (int i = 0; i < 200; i++) {
    if (ready()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('condition never became true');
}

({AgentAssistantHost host, _Toolbox toolbox, List<int> released}) _host(
  _StubLlm llm, {
  String? blocked,
  List<String>? persisted,
}) {
  final _Toolbox toolbox = _Toolbox();
  final List<int> released = <int>[];
  final AgentAssistantHost host = AgentAssistantHost(
    blocker: () async => blocked,
    source: 'test',
    toolCount: () => 2,
    persist: persisted == null
        ? null
        : (AgentSession s) async => persisted.add(s.id),
    newSessionId: () => 'rmtest',
    open: (String locale) async => AgentSessionParts(
      llm: llm,
      toolbox: toolbox,
      release: () => released.add(1),
    ),
  );
  return (host: host, toolbox: toolbox, released: released);
}

Map<String, Object?> _pending(HostAssistantSession s) =>
    Map<String, Object?>.from(s.snapshot()['pending']! as Map);

List<Map<String, Object?>> _entries(HostAssistantSession s) =>
    <Map<String, Object?>>[
      for (final Object? e in s.snapshot()['entries']! as List)
        Map<String, Object?>.from(e! as Map),
    ];

void main() {
  group('AgentAssistantHost', () {
    test('能力位：能开时报 feature 与工具来源 / 数量；开不了报短码', () async {
      final Map<String, Object?> ok = await _host(
        _StubLlm(<AiChatTurn>[]),
      ).host.capability();
      expect(ok['supported'], isTrue);
      expect(ok['features'], <String>[kHostAssistantFeatureAgent]);
      expect(ok[kHostAssistantAgentToolsKey], <String, Object?>{
        'source': 'test',
        'count': 2,
      });
      final Map<String, Object?> blocked = await _host(
        _StubLlm(<AiChatTurn>[]),
        blocked: 'no_provider',
      ).host.capability();
      expect(blocked['supported'], isFalse);
      expect(blocked['features'], isEmpty);
      expect(blocked['reason'], 'no_provider');
      expect(blocked.containsKey(kHostAssistantAgentToolsKey), isFalse);
    });

    test(
      '未知 feature 抛 ArgumentError；被门挡住抛 HostAssistantUnavailable 且不开会话',
      () async {
        final _StubLlm llm = _StubLlm(<AiChatTurn>[]);
        final AgentAssistantHost ok = _host(llm).host;
        await expectLater(
          ok.open('videoAcquire', locale: 'zh'),
          throwsA(isA<ArgumentError>()),
        );
        final AgentAssistantHost blocked = _host(
          llm,
          blocked: 'no_provider',
        ).host;
        await expectLater(
          blocked.open(kHostAssistantFeatureAgent, locale: 'zh'),
          throwsA(
            isA<HostAssistantUnavailable>().having(
              (HostAssistantUnavailable e) => e.reason,
              'reason',
              'no_provider',
            ),
          ),
        );
        expect(llm.requests, 0);
      },
    );

    test('一句话 → 写操作直接执行；快照与语言无关、可 JSON 编码；undo 动作回推 lastUndo', () async {
      final _StubLlm llm = _StubLlm(<AiChatTurn>[
        _call('settings.set', <String, Object?>{'value': 30}),
        _reply('done'),
      ]);
      final List<String> persisted = <String>[];
      final ({AgentAssistantHost host, _Toolbox toolbox, List<int> released})
      parts = _host(llm, persisted: persisted);
      final HostAssistantSession session = await parts.host.open(
        kHostAssistantFeatureAgent,
        locale: 'zh',
      );
      final int before = session.revision;
      await session.act(<String, Object?>{
        'type': 'text',
        'text': 'bigger subtitles',
        'context': <String, Object?>{'scene': 'video', 'itemTitle': 'X'},
      });
      await _until(
        () =>
            session.snapshot()['running'] == false &&
            _entries(
              session,
            ).any((Map<String, Object?> e) => e['kind'] == 'assistant'),
      );
      expect(session.revision, greaterThan(before));
      expect(parts.toolbox.settings['size'], 30);
      final Map<String, Object?> snap = session.snapshot();
      expect(() => jsonEncode(snap), returnsNormally);
      expect(snap['tokens'], 30);
      expect(snap['undoable'], 1);
      expect(snap['tools'], <String, Object?>{'source': 'test', 'count': 2});
      expect(snap.containsKey('pending'), isFalse);
      final Map<String, Object?> tool = _entries(
        session,
      ).firstWhere((Map<String, Object?> e) => e['kind'] == 'toolCall');
      expect(tool['toolName'], 'settings.set');
      expect(tool['status'], 'done');
      expect(tool['before'], '20');
      expect(tool['after'], '30');
      // 上下文随话注入（条目里不带，进的是发给模型的历史）。
      expect(persisted, isNotEmpty);

      await session.act(<String, Object?>{
        'type': 'undo',
        'entryId': tool['id'],
      });
      await _until(() => session.snapshot().containsKey('lastUndo'));
      final Map<String, Object?> lastUndo = Map<String, Object?>.from(
        session.snapshot()['lastUndo']! as Map,
      );
      expect(lastUndo['seq'], 1);
      expect(lastUndo['results'], <Object?>[
        <String, Object?>{'entryId': tool['id'], 'status': 'done'},
      ]);
      expect(parts.toolbox.settings['size'], 20);
      expect(
        _entries(session).firstWhere(
          (Map<String, Object?> e) => e['id'] == tool['id'],
        )['status'],
        'undone',
      );
      await session.close();
      expect(parts.released, <int>[1]);
    });

    test('不可逆操作：快照报 pending confirm；客户端同意后才执行', () async {
      final _StubLlm llm = _StubLlm(<AiChatTurn>[
        _call('library.file.delete', <String, Object?>{'path': '/a'}),
        _reply('deleted'),
      ]);
      final ({AgentAssistantHost host, _Toolbox toolbox, List<int> released})
      parts = _host(llm);
      final HostAssistantSession session = await parts.host.open(
        kHostAssistantFeatureAgent,
        locale: 'zh',
      );
      await session.act(<String, Object?>{'type': 'text', 'text': 'delete a'});
      await _until(() => session.snapshot().containsKey('pending'));
      final Map<String, Object?> pending = _pending(session);
      expect(pending['kind'], kAgentPendingConfirm);
      final Map<String, Object?> card = _entries(
        session,
      ).firstWhere((Map<String, Object?> e) => e['id'] == pending['entryId']);
      expect(card['kind'], 'confirm');
      expect(card['status'], 'pending');
      expect(parts.toolbox.executed, isEmpty);
      // 没有待答候选卡片时的 answerChoice 原样忽略。
      await session.act(<String, Object?>{
        'type': 'answerChoice',
        'choice': 'x',
      });
      await session.act(<String, Object?>{
        'type': 'answerConfirm',
        'approve': true,
      });
      await _until(() => session.snapshot()['running'] == false);
      expect(parts.toolbox.executed, <String>['library.file.delete']);
      expect(session.snapshot().containsKey('pending'), isFalse);
      await session.close();
    });

    test('待答确认时关闭会话：按拒绝收尾，不执行、不再发模型请求', () async {
      final _StubLlm llm = _StubLlm(<AiChatTurn>[
        _call('library.file.delete', <String, Object?>{'path': '/a'}),
        _reply('should never be requested'),
      ]);
      final ({AgentAssistantHost host, _Toolbox toolbox, List<int> released})
      parts = _host(llm);
      final AgentAssistantHostSession session =
          await parts.host.open(kHostAssistantFeatureAgent, locale: 'zh')
              as AgentAssistantHostSession;
      await session.act(<String, Object?>{'type': 'text', 'text': 'delete a'});
      await _until(() => session.snapshot().containsKey('pending'));
      await session.close();
      await _until(() => !session.session.running);
      expect(parts.toolbox.executed, isEmpty);
      expect(llm.requests, 1);
      final AgentEntry card = session.session.entries.firstWhere(
        (AgentEntry e) => e.kind == AgentEntryKind.confirm,
      );
      expect(card.status, AgentEntryStatus.declined);
      await expectLater(
        session.act(<String, Object?>{'type': 'cancel'}),
        throwsA(isA<StateError>()),
      );
    });

    test('cancel 动作：待答确认按拒绝收尾，loop 停下', () async {
      final _StubLlm llm = _StubLlm(<AiChatTurn>[
        _call('library.file.delete', <String, Object?>{'path': '/a'}),
        _reply('should never be requested'),
      ]);
      final ({AgentAssistantHost host, _Toolbox toolbox, List<int> released})
      parts = _host(llm);
      final HostAssistantSession session = await parts.host.open(
        kHostAssistantFeatureAgent,
        locale: 'zh',
      );
      await session.act(<String, Object?>{'type': 'text', 'text': 'delete a'});
      await _until(() => session.snapshot().containsKey('pending'));
      await session.act(<String, Object?>{'type': 'cancel'});
      await _until(() => session.snapshot()['running'] == false);
      expect(parts.toolbox.executed, isEmpty);
      expect(llm.requests, 1);
      expect(
        _entries(session).any(
          (Map<String, Object?> e) =>
              e['kind'] == 'notice' &&
              e['errorCode'] == AgentStopCode.cancelled,
        ),
        isTrue,
      );
      await session.close();
    });

    test('候选卡片：pending choice；只认候选里的 id，选中后续跑', () async {
      final _StubLlm llm = _StubLlm(<AiChatTurn>[
        _call('ui.ask_choice', <String, Object?>{
          'prompt': 'Which?',
          'options': <Object?>[
            <String, Object?>{'id': 'a', 'label': 'A'},
            <String, Object?>{'id': 'b', 'label': 'B'},
          ],
        }),
        _reply('picked'),
      ]);
      final HostAssistantSession session = await _host(
        llm,
      ).host.open(kHostAssistantFeatureAgent, locale: 'zh');
      await session.act(<String, Object?>{'type': 'text', 'text': 'pick'});
      await _until(() => session.snapshot().containsKey('pending'));
      expect(_pending(session)['kind'], kAgentPendingChoice);
      await expectLater(
        session.act(<String, Object?>{'type': 'answerChoice', 'choice': 'zzz'}),
        throwsA(isA<ArgumentError>()),
      );
      await session.act(<String, Object?>{
        'type': 'answerChoice',
        'choice': 'b',
      });
      await _until(() => session.snapshot()['running'] == false);
      final Map<String, Object?> card = _entries(
        session,
      ).firstWhere((Map<String, Object?> e) => e['kind'] == 'choice');
      expect(card['selected'], 'b');
      expect(llm.requests, 2);
      await session.close();
    });

    test('动作形状不对一律 ArgumentError（路由 400）', () async {
      final HostAssistantSession session = await _host(
        _StubLlm(<AiChatTurn>[]),
      ).host.open(kHostAssistantFeatureAgent, locale: 'zh');
      for (final Map<String, Object?> bad in <Map<String, Object?>>[
        <String, Object?>{'type': 'text', 'text': '  '},
        <String, Object?>{'type': 'text', 'text': 'x', 'context': 'nope'},
        <String, Object?>{'type': 'answerConfirm'},
        <String, Object?>{'type': 'answerChoice', 'choice': 3},
        <String, Object?>{'type': 'undo'},
        <String, Object?>{'type': 'bogus'},
      ]) {
        await expectLater(
          session.act(bad),
          throwsA(isA<ArgumentError>()),
          reason: '$bad',
        );
      }
      await session.close();
    });

    test('经 HostAssistantSessions：开会话 → 长轮询拿到新快照 → 关闭后 404', () async {
      final _StubLlm llm = _StubLlm(<AiChatTurn>[_reply('hi')]);
      final HostAssistantSessions sessions = HostAssistantSessions(
        CompositeHostAssistantProvider(<String, HostAssistantProvider>{
          kHostAssistantFeatureAgent: _host(llm).host,
        }),
      );
      final Map<String, Object?> first = await sessions.open(
        kHostAssistantFeatureAgent,
        locale: 'zh',
      );
      final String id = first['id']! as String;
      final int rev = first['revision']! as int;
      await sessions.act(id, <String, Object?>{
        'type': 'text',
        'text': 'hello',
      });
      final Map<String, Object?>? later = await sessions.read(
        id,
        after: rev,
        wait: const Duration(seconds: 2),
      );
      expect(later!['revision'] as int, greaterThan(rev));
      expect(jsonEncode(later), contains('"kind":"user"'));
      expect(await sessions.close(id), isTrue);
      expect(await sessions.read(id), isNull);
    });
  });

  group('CompositeHostAssistantProvider', () {
    test('features 取并集；开不了的按 feature 报 reasons；额外字段并入', () async {
      final CompositeHostAssistantProvider composite =
          CompositeHostAssistantProvider(<String, HostAssistantProvider>{
            kHostAssistantFeatureVideoAcquire: _FakeProvider(
              const <String, Object?>{
                'supported': true,
                'features': <String>[kHostAssistantFeatureVideoAcquire],
              },
            ),
            kHostAssistantFeatureAgent: _host(
              _StubLlm(<AiChatTurn>[]),
              blocked: 'no_provider',
            ).host,
          });
      final Map<String, Object?> cap = await composite.capability();
      expect(cap['supported'], isTrue);
      expect(cap['features'], <String>[kHostAssistantFeatureVideoAcquire]);
      expect(cap.containsKey('reason'), isFalse);
      expect(cap[kHostAssistantReasonsKey], <String, String>{
        kHostAssistantFeatureAgent: 'no_provider',
      });
    });

    test('全部开不了：顶层 reason 取第一个 feature 的（老客户端只认它）', () async {
      final CompositeHostAssistantProvider composite =
          CompositeHostAssistantProvider(<String, HostAssistantProvider>{
            kHostAssistantFeatureVideoAcquire: _FakeProvider(
              const <String, Object?>{
                'supported': false,
                'features': <String>[],
                'reason': 'not_ready',
              },
            ),
            kHostAssistantFeatureAgent: _host(
              _StubLlm(<AiChatTurn>[]),
              blocked: 'no_provider',
            ).host,
          });
      final Map<String, Object?> cap = await composite.capability();
      expect(cap['supported'], isFalse);
      expect(cap['features'], isEmpty);
      expect(cap['reason'], 'not_ready');
    });

    test('两者都能开时都报；open 按 feature 分派，未知 feature 抛 ArgumentError', () async {
      final _FakeProvider video = _FakeProvider(const <String, Object?>{
        'supported': true,
        'features': <String>[kHostAssistantFeatureVideoAcquire],
      });
      final CompositeHostAssistantProvider composite =
          CompositeHostAssistantProvider(<String, HostAssistantProvider>{
            kHostAssistantFeatureVideoAcquire: video,
            kHostAssistantFeatureAgent: _host(_StubLlm(<AiChatTurn>[])).host,
          });
      final Map<String, Object?> cap = await composite.capability();
      expect(cap['features'], <String>[
        kHostAssistantFeatureVideoAcquire,
        kHostAssistantFeatureAgent,
      ]);
      expect(cap[kHostAssistantAgentToolsKey], isNotNull);
      await composite.open(kHostAssistantFeatureVideoAcquire, locale: 'zh');
      expect(video.opened, <String>[kHostAssistantFeatureVideoAcquire]);
      final HostAssistantSession agent = await composite.open(
        kHostAssistantFeatureAgent,
        locale: 'zh',
      );
      expect(agent, isA<AgentAssistantHostSession>());
      await agent.close();
      expect(
        () => composite.open('nope', locale: 'zh'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}

class _FakeProvider implements HostAssistantProvider {
  _FakeProvider(this._capability);

  final Map<String, Object?> _capability;
  final List<String> opened = <String>[];

  @override
  Future<Map<String, Object?>> capability() async => _capability;

  @override
  Future<HostAssistantSession> open(
    String feature, {
    required String locale,
  }) async {
    opened.add(feature);
    return _NoopSession();
  }
}

class _NoopSession implements HostAssistantSession {
  @override
  int get revision => 0;

  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  Map<String, Object?> snapshot() => const <String, Object?>{};

  @override
  Future<void> act(Map<String, Object?> action) async {}

  @override
  Future<void> close() async {}
}
