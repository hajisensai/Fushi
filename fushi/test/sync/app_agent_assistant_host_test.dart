/// 手机经互联把整场「AI 助手」会话交给电脑（`/api/assistant` feature `agent`，spec
/// `docs/specs/2026-10-26-ai-operations-agent-design.md` §6.5）。
///
/// 真 [FushiSyncServer] 挂 app 的 agent host 装配（[createAgentAssistantHostWith]：
/// stub 模型 + 一份最小的假操作目录 + 内存库），用真 [InterconnectAssistantClient]
/// 与 [RemoteAiAgentSession] 走一遍：能力位三态 → 开会话 → 手机说一句话 → 写操作在
/// **电脑**上执行并记进**电脑**的 `ai_agent_actions` → 手机点撤销 → 电脑写回；
/// 不可逆操作的确认卡片由手机作答；电脑停机 → 断线提示只插一次、放开输入。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/agent/ai_agent_assistant_host.dart';
import 'package:fushi/src/ai/agent/remote_ai_agent_session.dart';
import 'package:fushi/src/sync/interconnect_assistant_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
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
import 'package:fushi_engine/sync/assistant/agent_assistant_host.dart';
import 'package:fushi_engine/sync/assistant/host_assistant.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:path/path.dart' as p;

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

final AiProviderConfig _provider = AiProviderConfig(
  id: 'p1',
  presetId: 'openai',
  name: 'test',
  baseUrl: Uri.parse('https://api.openai.com/v1'),
  apiKeys: const <AiApiKey>[AiApiKey('sk-test')],
  model: 'gpt-test',
  protocol: AiWireProtocol.openAiCompatible,
);

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
    return _turns.isEmpty
        ? const AiChatTurn(text: 'done', toolCalls: <AiChatToolCall>[])
        : _turns.removeFirst();
  }
}

AiChatTurn _call(String id, Map<String, Object?> args) => AiChatTurn(
  text: '',
  toolCalls: <AiChatToolCall>[
    AiChatToolCall(id: 'c1', name: agentWireToolName(id), arguments: args),
  ],
);

/// 与 `ai_agent_controller_test.dart` 同形的最小目录：可撤销的设置写 + 不可逆删文件。
OpInvoker _invoker(Map<String, Object?> store, List<String> deleted) {
  final List<CtlRoute> routes = <CtlRoute>[
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
            'old': store[call.params['key']],
          },
          record: (CtlCall call, Map<String, Object?> before, Object? _) =>
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
  late Directory tmp;
  late FushiDatabase hostDb;
  late FushiDatabase phoneDb;
  late SyncRepository repo;
  late Map<String, Object?> store;
  late List<String> deleted;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fushi-app-agent-host-');
    hostDb = FushiDatabase.forTesting(NativeDatabase.memory());
    phoneDb = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = SyncRepository(phoneDb);
    store = <String, Object?>{'subtitle.size': '20'};
    deleted = <String>[];
  });

  tearDown(() async {
    await hostDb.close();
    await phoneDb.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  AgentAssistantHost agentHost({
    List<AiChatTurn> turns = const <AiChatTurn>[],
    bool aiEnabled = true,
    bool allowPeers = true,
    List<AiProviderConfig>? providers,
    bool ready = true,
    void Function()? onLlm,
  }) => createAgentAssistantHostWith(
    aiModuleEnabled: () => aiEnabled,
    allowPeers: () => allowPeers,
    settings: _Settings(providers ?? <AiProviderConfig>[_provider]),
    database: hostDb,
    invoker: () => ready ? _invoker(store, deleted) : null,
    llmFactory: (AiProviderConfig _) {
      onLlm?.call();
      return _StubLlm(turns);
    },
    clock: () => DateTime.fromMillisecondsSinceEpoch(1700000000000),
  );

  Future<(FushiSyncServer, String)> startHost(
    HostAssistantProvider host,
  ) async {
    final FushiSyncServer server = FushiSyncServer(
      syncDataDir: p.join(tmp.path, 'sync'),
      port: 0,
      token: 'tok',
      assistant: host,
    );
    await server.start();
    addTearDown(server.stop);
    final String url = 'http://127.0.0.1:${server.port}';
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: url, deviceName: 'PC'),
    ]);
    await repo.setFushiClientToken('tok');
    return (server, url);
  }

  InterconnectAssistantClient client() =>
      InterconnectAssistantClient(repo: repo);

  Future<void> until(
    RemoteAiAgentSession session,
    bool Function() ready,
  ) async {
    if (ready()) return;
    final Completer<void> done = Completer<void>();
    void check() {
      if (ready() && !done.isCompleted) done.complete();
    }

    session.addListener(check);
    try {
      await done.future.timeout(const Duration(seconds: 10));
    } finally {
      session.removeListener(check);
    }
  }

  test('能力位：就绪 → 宣告 agent + 工具数；没指派 / 关了 AI / 没允许配对设备 / 未初始化 → '
      '按 feature 报短码，不建模型', () async {
    final (_, String url) = await startHost(agentHost());
    final HostAssistantTarget ready = (await client().probeUrl(url))!;
    expect(ready.supports(kHostAssistantFeatureAgent), isTrue);

    bool llmBuilt = false;
    for (final (AgentAssistantHost host, String reason)
        in <(AgentAssistantHost, String)>[
          (
            agentHost(
              providers: const <AiProviderConfig>[],
              onLlm: () => llmBuilt = true,
            ),
            'no_provider',
          ),
          (agentHost(aiEnabled: false), 'disabled'),
          // 与服务端 ai.agent_for_peers 同一判据：用户没打开就不对配对设备开放。
          (
            agentHost(allowPeers: false, onLlm: () => llmBuilt = true),
            'disabled',
          ),
          (agentHost(ready: false), 'not_ready'),
        ]) {
      final FushiSyncServer server = FushiSyncServer(
        syncDataDir: p.join(tmp.path, 'sync-${identityHashCode(host)}'),
        port: 0,
        token: 'tok',
        assistant: CompositeHostAssistantProvider(
          <String, HostAssistantProvider>{kHostAssistantFeatureAgent: host},
        ),
      );
      await server.start();
      addTearDown(server.stop);
      final String u = 'http://127.0.0.1:${server.port}';
      await repo.setFushiClientUrls(<FushiClientUrl>[
        FushiClientUrl(url: u, deviceName: 'PC'),
      ]);
      final HostAssistantTarget target = (await client().probeUrl(u))!;
      expect(target.supports(kHostAssistantFeatureAgent), isFalse);
      expect(target.reasonFor(kHostAssistantFeatureAgent), reason);
      // 直接开会话同样被门挡住：409 + 同一个短码。
      await expectLater(
        RemoteAiAgentSession.open(
          client: client(),
          target: target,
          locale: 'zh',
        ),
        throwsA(
          isA<HostAssistantException>()
              .having((HostAssistantException e) => e.code, 'code', 'http_409')
              .having((HostAssistantException e) => e.detail, 'detail', reason),
        ),
      );
    }
    expect(llmBuilt, isFalse);
  });

  test('一句话 → 写操作在电脑上执行并记进电脑的操作记录 → 手机撤销 → 电脑写回', () async {
    final (_, String url) = await startHost(
      agentHost(
        turns: <AiChatTurn>[
          _call('settings.set', <String, Object?>{
            'key': 'subtitle.size',
            'value': '28',
          }),
        ],
      ),
    );
    final InterconnectAssistantClient c = client();
    final HostAssistantTarget target = (await c.probeUrl(url))!;
    final RemoteAiAgentSession session = await RemoteAiAgentSession.open(
      client: c,
      target: target,
      locale: 'zh-CN',
      longPollWait: const Duration(seconds: 2),
    );
    addTearDown(session.dispose);
    expect(session.executorLabel, 'PC');

    await session.send(
      '把字幕调大',
      context: const AgentUiContext(scene: 'video', itemTitle: 'X'),
    );
    await until(
      session,
      () =>
          !session.running &&
          session.entries.any(
            (AgentEntry e) => e.kind == AgentEntryKind.assistant,
          ),
    );
    expect(store['subtitle.size'], '28');
    final AgentEntry tool = session.entries.firstWhere(
      (AgentEntry e) => e.kind == AgentEntryKind.toolCall,
    );
    expect(tool.status, AgentEntryStatus.done);
    expect((tool.before, tool.after), ('20', '28'));
    expect(session.undoableCount, 1);

    final List<AiAgentActionRow> actions = await hostDb.listAiAgentActions();
    expect(actions, hasLength(1));
    expect(actions.single.opId, 'settings.set');
    expect(actions.single.sessionId, startsWith('rm'));
    final AiAgentSessionRow? saved = await hostDb.getAiAgentSession(
      actions.single.sessionId,
    );
    expect(saved?.scene, kAiAgentRemoteScene);
    expect(saved?.title, '把字幕调大');
    // 手机本机库里什么都没有：记账与撤销都在电脑上。
    expect(await phoneDb.listAiAgentActions(), isEmpty);

    final AgentUndoResult undo = await session.undoEntry(tool.id);
    expect(undo.status, AgentUndoStatus.done);
    expect(store['subtitle.size'], '20');
    await until(
      session,
      () =>
          session.entries
              .firstWhere((AgentEntry e) => e.id == tool.id)
              .status ==
          AgentEntryStatus.undone,
    );
    expect(
      (await hostDb.getAiAgentAction(actions.single.id))!.undoStatus,
      'done',
    );
  });

  test('不可逆操作：确认卡片由手机作答，同意后才在电脑上执行', () async {
    final (_, String url) = await startHost(
      agentHost(
        turns: <AiChatTurn>[
          _call('files.delete', <String, Object?>{'name': 'a.mkv'}),
        ],
      ),
    );
    final InterconnectAssistantClient c = client();
    final RemoteAiAgentSession session = await RemoteAiAgentSession.open(
      client: c,
      target: (await c.probeUrl(url))!,
      locale: 'zh-CN',
      longPollWait: const Duration(seconds: 2),
    );
    addTearDown(session.dispose);
    await session.send('删掉 a.mkv');
    await until(session, () => session.awaitingConfirm);
    final AgentEntry card = session.entries.lastWhere(
      (AgentEntry e) => e.kind == AgentEntryKind.confirm,
    );
    expect(card.status, AgentEntryStatus.pending);
    expect(deleted, isEmpty);
    session.answerConfirm(true);
    await until(
      session,
      () => !session.running && !session.awaitingConfirm && deleted.isNotEmpty,
    );
    expect(deleted, <String>['a.mkv']);
  });

  test('电脑停机：断线提示只插一次、放开输入与待答卡片', () async {
    final (FushiSyncServer server, String url) = await startHost(agentHost());
    final InterconnectAssistantClient c = client();
    final RemoteAiAgentSession session = await RemoteAiAgentSession.open(
      client: c,
      target: (await c.probeUrl(url))!,
      locale: 'zh-CN',
      retryDelay: const Duration(milliseconds: 50),
      longPollWait: const Duration(seconds: 1),
    );
    addTearDown(session.dispose);
    await server.stop();
    await until(
      session,
      () => session.entries.any(
        (AgentEntry e) => e.errorCode == kAiAgentRemoteUnavailableCode,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      session.entries
          .where((AgentEntry e) => e.errorCode == kAiAgentRemoteUnavailableCode)
          .length,
      1,
    );
    expect(session.running, isFalse);
    expect(session.awaitingConfirm, isFalse);
  });
}
