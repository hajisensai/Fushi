import 'dart:collection';
import 'dart:convert';

import 'package:fushi_core/fushi_core.dart' show AiAgentSessionSummary;
import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/agent/agent_session_archive.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_model_pricing.dart';
import 'package:fushi_engine/sync/assistant/agent_assistant_host.dart';
import 'package:fushi_engine/sync/assistant/host_assistant.dart';
import 'package:fushi_engine/sync/assistant/host_assistant_routes.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

/// BUG-4067：互联 host 的远端 AI 助手会话历史——按发起设备存档，已配对设备只能列 /
/// 续接 / 改名 / 删除自己发起的；共享口令认不出设备、看不到任何历史；同一场会话
/// 一个进程里只许一处打开。
class _StubLlm implements AgentLlm {
  _StubLlm(List<String> replies) : _replies = Queue<String>.of(replies);

  final Queue<String> _replies;
  final List<List<AiChatMessage>> seen = <List<AiChatMessage>>[];

  @override
  bool get supportsTools => true;

  @override
  AiModelPricing get pricing => const AiModelPricing();

  @override
  Future<AiChatTurn> chat(
    List<AiChatMessage> messages,
    List<AiChatToolSpec> tools,
  ) async {
    seen.add(List<AiChatMessage>.of(messages));
    if (_replies.isEmpty) throw const AiChatFailure('empty_response');
    return AiChatTurn(
      text: _replies.removeFirst(),
      toolCalls: const <AiChatToolCall>[],
      usage: const AiChatUsage(inputTokens: 1, outputTokens: 1),
    );
  }
}

class _Toolbox implements AgentToolbox {
  @override
  List<AgentToolSpec> residentTools() => const <AgentToolSpec>[];

  @override
  List<AgentToolSpec> searchTools(String query, {int limit = 12}) =>
      const <AgentToolSpec>[];

  @override
  AgentToolSpec? describeTool(String name) => null;

  @override
  Future<AgentToolResult> execute(AgentToolInvocation invocation) async =>
      const AgentToolResult.ok(<String, Object?>{});

  @override
  Future<AgentUndoResult> undo(String actionId) async =>
      const AgentUndoResult(AgentUndoStatus.notUndoable);
}

/// 内存版存档（与 [DatabaseAgentSessionHistory] 同一语义：发起设备首次落库定下）。
class _MemoryHistory implements AgentSessionHistoryStore {
  final Map<String, String> peers = <String, String>{
    'tok-phone': 'phone',
    'tok-tablet': 'tablet',
  };
  final Map<String, AgentArchivedSession> rows =
      <String, AgentArchivedSession>{};
  int clock = 100;

  @override
  Future<String?> peerIdForToken(String peerToken) async => peers[peerToken];

  @override
  Future<void> save(
    AgentSession session, {
    required String originPeerId,
  }) async {
    final AgentArchivedSession? old = rows[session.id];
    rows[session.id] = AgentArchivedSession(
      id: session.id,
      title: old?.title ?? aiAgentSessionTitleOf(session),
      scene: kAiAgentRemoteScene,
      originPeerId: old?.originPeerId ?? originPeerId,
      createdAt: old?.createdAt ?? clock,
      updatedAt: ++clock,
      totalTokens: session.totalTokens,
      // 过一遍 JSON：与库里存的是同一形状。
      payload: Map<String, Object?>.from(
        jsonDecode(jsonEncode(session.toJson())) as Map,
      ),
    );
  }

  @override
  Future<List<AiAgentSessionSummary>> list(String originPeerId) async =>
      <AiAgentSessionSummary>[
        for (final AgentArchivedSession r
            in rows.values.toList()..sort(
              (AgentArchivedSession a, AgentArchivedSession b) =>
                  b.updatedAt.compareTo(a.updatedAt),
            ))
          if (r.originPeerId == originPeerId)
            AiAgentSessionSummary(
              id: r.id,
              title: r.title,
              scene: r.scene,
              profileUid: '',
              totalTokens: r.totalTokens,
              createdAt: r.createdAt,
              updatedAt: r.updatedAt,
              originPeerId: r.originPeerId,
            ),
      ];

  @override
  Future<AgentArchivedSession?> load(String id) async => rows[id];

  @override
  Future<bool> rename(String id, String title) async {
    final AgentArchivedSession? r = rows[id];
    if (r == null || title.trim().isEmpty) return false;
    rows[id] = AgentArchivedSession(
      id: r.id,
      title: title.trim(),
      scene: r.scene,
      originPeerId: r.originPeerId,
      createdAt: r.createdAt,
      updatedAt: r.updatedAt,
      totalTokens: r.totalTokens,
      payload: r.payload,
    );
    return true;
  }

  @override
  Future<void> delete(String id) async => rows.remove(id);
}

const HostAssistantCaller _phone = HostAssistantCaller(peerToken: 'tok-phone');
const HostAssistantCaller _tablet = HostAssistantCaller(
  peerToken: 'tok-tablet',
);

Future<void> _until(bool Function() ready) async {
  for (int i = 0; i < 200; i++) {
    if (ready()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('condition never became true');
}

List<String> _texts(HostAssistantSession s) => <String>[
  for (final Object? e in s.snapshot()['entries']! as List)
    '${(e! as Map)['kind']}:${(e as Map)['text'] ?? ''}',
];

void main() {
  late _MemoryHistory history;
  late AgentLiveSessions live;
  late int nextId;
  late _StubLlm llm;

  AgentAssistantHost host({bool withHistory = true}) => AgentAssistantHost(
    blocker: () async => null,
    source: 'test',
    history: withHistory ? history : null,
    live: live,
    newSessionId: () => 'rm${nextId++}',
    open: (String locale) async =>
        AgentSessionParts(llm: llm, toolbox: _Toolbox()),
  );

  Future<HostAssistantSession> talk(
    AgentAssistantHost h,
    HostAssistantCaller caller,
    String text,
  ) async {
    final HostAssistantSession s = await h.open(
      kHostAssistantFeatureAgent,
      locale: 'zh',
      caller: caller,
    );
    await s.act(<String, Object?>{'type': 'text', 'text': text});
    await _until(
      () => s.snapshot()['running'] == false && _texts(s).length > 1,
    );
    return s;
  }

  setUp(() {
    history = _MemoryHistory();
    live = AgentLiveSessions();
    nextId = 1;
    llm = _StubLlm(<String>['a1', 'a2', 'a3', 'a4']);
  });

  test('能力位：有存档才宣告 agentHistory 协议版本；老装配（无存档）不宣告', () async {
    expect(
      (await host().capability())[kHostAssistantAgentHistoryKey],
      kHostAssistantAgentHistoryVersion,
    );
    expect(
      (await host(
        withHistory: false,
      ).capability()).containsKey(kHostAssistantAgentHistoryKey),
      isFalse,
    );
    expect(
      host(withHistory: false).hasHistory(kHostAssistantFeatureAgent),
      isFalse,
    );
  });

  test('按发起设备存档与列出；别的设备看不到，共享口令一律 403', () async {
    final AgentAssistantHost h = host();
    final HostAssistantSession mine = await talk(h, _phone, '手机问的');
    await mine.close();
    final HostAssistantSession anon = await talk(
      h,
      HostAssistantCaller.anonymous,
      '共享口令问的',
    );
    await anon.close();

    expect(history.rows['rm1']!.originPeerId, 'phone');
    expect(history.rows['rm2']!.originPeerId, '', reason: '认不出设备就不归属');
    final List<Map<String, Object?>> listed = await h.listHistory(
      kHostAssistantFeatureAgent,
      _phone,
    );
    expect(listed.map((Map<String, Object?> s) => s['id']), <String>['rm1']);
    expect(listed.single['title'], '手机问的');
    expect(() => jsonEncode(listed), returnsNormally);
    expect(await h.listHistory(kHostAssistantFeatureAgent, _tablet), isEmpty);
    await expectLater(
      () => h.listHistory(
        kHostAssistantFeatureAgent,
        HostAssistantCaller.anonymous,
      ),
      throwsA(isA<HostAssistantPeerRequired>()),
    );
    await expectLater(
      () => h.listHistory(
        kHostAssistantFeatureAgent,
        const HostAssistantCaller(peerToken: 'revoked'),
      ),
      throwsA(isA<HostAssistantPeerRequired>()),
      reason: '已吊销的口令认不出设备',
    );
  });

  test('续接：读回整场对话接着说（模型拿到之前的历史）；别的设备续不了', () async {
    final AgentAssistantHost h = host();
    final HostAssistantSession first = await talk(h, _phone, '第一句');
    await first.close();
    expect(live.contains('rm1'), isFalse, reason: '关了就释放占用');

    await expectLater(
      () => h.resume(
        kHostAssistantFeatureAgent,
        'rm1',
        locale: 'zh',
        caller: _tablet,
      ),
      throwsA(isA<HostAssistantHistoryNotFound>()),
    );
    final HostAssistantSession resumed = await h.resume(
      kHostAssistantFeatureAgent,
      'rm1',
      locale: 'zh',
      caller: _phone,
    );
    expect(resumed.snapshot()['id'], 'rm1');
    expect(_texts(resumed), <String>['user:第一句', 'assistant:a1']);
    await resumed.act(<String, Object?>{'type': 'text', 'text': '第二句'});
    await _until(
      () =>
          resumed.snapshot()['running'] == false && _texts(resumed).length == 4,
    );
    expect(
      llm.seen.last.map((AiChatMessage m) => m.content).join('|'),
      allOf(contains('第一句'), contains('a1'), contains('第二句')),
    );
    await resumed.close();
    expect(
      (history.rows['rm1']!.payload['entries']! as List).length,
      4,
      reason: '续接后的几轮照样存回同一场',
    );
    expect(history.rows['rm1']!.originPeerId, 'phone');
  });

  test('同一场会话只许一处打开：别处占着 → in_use；同一台设备重开 → 接管旧连接', () async {
    final AgentAssistantHost h = host();
    final HostAssistantSessions table = HostAssistantSessions(h);
    final Map<String, Object?> opened = await table.open(
      kHostAssistantFeatureAgent,
      locale: 'zh',
      caller: _phone,
    );
    final String oldTableId = opened['id']! as String;
    await table.act(oldTableId, <String, Object?>{
      'type': 'text',
      'text': 'hi',
    });
    await _until(() => history.rows.containsKey('rm1'));

    // 手机重开 app：旧连接成了遗孤，同一台设备续接同一场 → 接管。
    final Map<String, Object?> again = await table.open(
      kHostAssistantFeatureAgent,
      locale: 'zh',
      caller: _phone,
      resume: 'rm1',
    );
    expect((again['view']! as Map)['id'], 'rm1');
    expect(
      await table.read(oldTableId),
      isNull,
      reason: '被接管的旧连接读到「会话没了」，不对着关掉的会话空转长轮询',
    );
    await table.close(again['id']! as String);

    // host 本机（或别的连接）正开着它：不许再开一份。
    expect(live.claim('rm1'), isTrue);
    await expectLater(
      () => h.resume(
        kHostAssistantFeatureAgent,
        'rm1',
        locale: 'zh',
        caller: _phone,
      ),
      throwsA(
        isA<HostAssistantUnavailable>().having(
          (HostAssistantUnavailable e) => e.reason,
          'reason',
          kHostAssistantReasonInUse,
        ),
      ),
    );
    await expectLater(
      () => h.deleteHistory(kHostAssistantFeatureAgent, 'rm1', _phone),
      throwsA(isA<HostAssistantUnavailable>()),
      reason: '那边收尾时会把它写回来：不删',
    );
    live.release('rm1');
  });

  test('改名 / 删除只认发起设备；删掉开着的那场：关掉且不再写回', () async {
    final AgentAssistantHost h = host();
    final HostAssistantSession s = await talk(h, _phone, '要删的');
    await expectLater(
      () => h.renameHistory(kHostAssistantFeatureAgent, 'rm1', 'x', _tablet),
      throwsA(isA<HostAssistantHistoryNotFound>()),
    );
    await h.renameHistory(kHostAssistantFeatureAgent, 'rm1', ' 新名字 ', _phone);
    expect(history.rows['rm1']!.title, '新名字');
    await expectLater(
      () => h.renameHistory(kHostAssistantFeatureAgent, 'rm1', '  ', _phone),
      throwsArgumentError,
    );
    await expectLater(
      () => h.deleteHistory(kHostAssistantFeatureAgent, 'rm1', _tablet),
      throwsA(isA<HostAssistantHistoryNotFound>()),
    );
    await h.deleteHistory(kHostAssistantFeatureAgent, 'rm1', _phone);
    expect(history.rows, isEmpty);
    expect((s as AgentAssistantHostSession).isClosed, isTrue);
    expect(live.contains('rm1'), isFalse);
    await s.close();
    expect(history.rows, isEmpty, reason: '关闭收尾不把删掉的会话写回');
  });

  group('路由', () {
    Future<shelf.Response> call(
      HostAssistantSessions sessions,
      String method,
      String path, {
      Object? body,
      HostAssistantCaller caller = HostAssistantCaller.anonymous,
    }) => handleHostAssistantRequest(
      sessions,
      shelf.Request(
        method,
        Uri.parse('http://host$path'),
        body: body == null ? null : jsonEncode(body),
      ),
      method,
      Uri.parse(path).path,
      caller: caller,
    );

    test('history：403 / 200 / PATCH / DELETE；resume 未知 404、别人的 404', () async {
      final AgentAssistantHost h = host();
      final HostAssistantSessions sessions = HostAssistantSessions(
        CompositeHostAssistantProvider(<String, HostAssistantProvider>{
          kHostAssistantFeatureAgent: h,
        }),
      );
      await (await talk(h, _phone, '路由里的')).close();

      final shelf.Response anon = await call(
        sessions,
        'GET',
        '/api/assistant/history?feature=agent',
      );
      expect(anon.statusCode, 403);
      expect(jsonDecode(await anon.readAsString()), <String, Object?>{
        'error': 'paired_peer_required',
      });

      final shelf.Response listed = await call(
        sessions,
        'GET',
        '/api/assistant/history?feature=agent',
        caller: _phone,
      );
      expect(listed.statusCode, 200);
      final Map<String, Object?> body = Map<String, Object?>.from(
        jsonDecode(await listed.readAsString()) as Map,
      );
      expect((body['sessions']! as List).single, containsPair('id', 'rm1'));

      expect(
        (await call(
          sessions,
          'GET',
          '/api/assistant/history?feature=videoAcquire',
          caller: _phone,
        )).statusCode,
        anyOf(404, 400),
        reason: '没有历史的 feature 不给历史路由',
      );

      final shelf.Response renamed = await call(
        sessions,
        'PATCH',
        '/api/assistant/history/rm1',
        body: <String, Object?>{'feature': 'agent', 'title': '改过'},
        caller: _phone,
      );
      expect(renamed.statusCode, 200);
      expect(history.rows['rm1']!.title, '改过');

      final shelf.Response resumed = await call(
        sessions,
        'POST',
        '/api/assistant/sessions',
        body: <String, Object?>{
          'feature': 'agent',
          'locale': 'zh',
          'resume': 'rm1',
        },
        caller: _phone,
      );
      expect(resumed.statusCode, 200);
      final Map<String, Object?> envelope = Map<String, Object?>.from(
        jsonDecode(await resumed.readAsString()) as Map,
      );
      expect((envelope['view']! as Map)['id'], 'rm1');
      await sessions.close(envelope['id']! as String);

      expect(
        (await call(
          sessions,
          'POST',
          '/api/assistant/sessions',
          body: <String, Object?>{'feature': 'agent', 'resume': 'rm1'},
          caller: _tablet,
        )).statusCode,
        404,
      );
      expect(
        (await call(
          sessions,
          'POST',
          '/api/assistant/sessions',
          body: <String, Object?>{'feature': 'agent', 'resume': 'nope'},
          caller: _phone,
        )).statusCode,
        404,
      );
      expect(
        (await call(
          sessions,
          'POST',
          '/api/assistant/sessions',
          body: <String, Object?>{'feature': 'agent', 'resume': '../x'},
          caller: _phone,
        )).statusCode,
        400,
      );

      final shelf.Response deleted = await call(
        sessions,
        'DELETE',
        '/api/assistant/history/rm1?feature=agent',
        caller: _phone,
      );
      expect(deleted.statusCode, 200);
      expect(history.rows, isEmpty);
    });

    test('老装配（无存档）：history 404，resume 404，普通开会话照旧', () async {
      final HostAssistantSessions sessions = HostAssistantSessions(
        host(withHistory: false),
      );
      expect(
        (await call(
          sessions,
          'GET',
          '/api/assistant/history?feature=agent',
          caller: _phone,
        )).statusCode,
        404,
      );
      expect(
        (await call(
          sessions,
          'POST',
          '/api/assistant/sessions',
          body: <String, Object?>{'feature': 'agent', 'resume': 'rm1'},
          caller: _phone,
        )).statusCode,
        404,
      );
      final shelf.Response opened = await call(
        sessions,
        'POST',
        '/api/assistant/sessions',
        body: <String, Object?>{'feature': 'agent', 'locale': 'zh'},
      );
      expect(opened.statusCode, 200);
      await sessions.dispose();
    });
  });
}
