// AI 助手控制器接 MCP 工具箱（spec docs/specs/2026-11-05-ai-mcp-client-design.md §4）：
// 每轮 send 前 prepare，会话的工具箱是「操作目录 + MCP」，模型能经 ops.search 找到
// MCP 工具并调用；MCP 调用不进 AI 操作记录（不可撤销，只读工具直接执行）。
import 'dart:collection';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/agent/ai_agent_controller.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_model_pricing.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/ai/mcp_client/mcp_client_config.dart';
import 'package:fushi_engine/ai/mcp_client/mcp_client_toolbox.dart';
import 'package:fushi_engine/ai/mcp_client/mcp_client_transport.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';
import 'package:fushi_engine/ai/web_search.dart';

class _UnusedRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('测试走注入的 invoker，不碰 ref');
}

class _Settings implements AiSettingsSource {
  @override
  final List<AiProviderConfig> aiProviders = <AiProviderConfig>[
    AiProviderConfig(
      id: 'p1',
      presetId: 'openai',
      name: 'test',
      baseUrl: Uri.parse('https://api.openai.com/v1'),
      apiKeys: const <AiApiKey>[AiApiKey('sk-test')],
      model: 'gpt-test',
      protocol: AiWireProtocol.openAiCompatible,
    ),
  ];

  @override
  AiFeatureAssignments get aiFeatureAssignments =>
      AiFeatureAssignments(defaultProviderId: 'p1');

  @override
  List<WebKnowledgeSite> get aiWebKnowledgeSites => const <WebKnowledgeSite>[];

  @override
  WebSearchConfig? get aiWebSearch => null;
}

class _StubLlm implements AgentLlm {
  _StubLlm(List<AiChatTurn> turns) : _turns = Queue<AiChatTurn>.of(turns);

  final Queue<AiChatTurn> _turns;
  final List<List<AiChatMessage>> requests = <List<AiChatMessage>>[];

  @override
  bool get supportsTools => true;

  @override
  AiModelPricing get pricing => const AiModelPricing();

  @override
  Future<AiChatTurn> chat(
    List<AiChatMessage> messages,
    List<AiChatToolSpec> tools,
  ) async {
    requests.add(List<AiChatMessage>.of(messages));
    return _turns.isEmpty
        ? const AiChatTurn(text: 'done', toolCalls: <AiChatToolCall>[])
        : _turns.removeFirst();
  }
}

/// 只说无状态协议的假 MangaBaka。
class _FakeMangaBaka implements McpClientTransport {
  final List<String> calls = <String>[];

  @override
  Future<Map<String, Object?>> request(
    Map<String, Object?> message, {
    Map<String, String> headers = const <String, String>{},
    required Duration timeout,
  }) async {
    final Object? id = message['id'];
    switch (message['method']) {
      case 'initialize':
        return <String, Object?>{
          'id': id,
          'error': <String, Object?>{
            'code': -32022,
            'data': <String, Object?>{
              'supported': <String>['2026-07-28'],
            },
          },
        };
      case 'tools/list':
        return <String, Object?>{
          'id': id,
          'result': <String, Object?>{
            'tools': <Object?>[
              <String, Object?>{
                'name': 'series_search',
                'description': 'Search MangaBaka series by title.',
                'inputSchema': <String, Object?>{'type': 'object'},
                'annotations': <String, Object?>{'readOnlyHint': true},
              },
            ],
          },
        };
      case 'tools/call':
        calls.add('${(message['params']! as Map)['name']}');
        return <String, Object?>{
          'id': id,
          'result': <String, Object?>{
            'content': <Object?>[
              <String, Object?>{
                'type': 'text',
                'text': '{"title":"Yotsuba&!"}',
              },
            ],
          },
        };
    }
    return <String, Object?>{
      'id': id,
      'error': <String, Object?>{'code': -32601},
    };
  }

  @override
  Future<void> notify(
    Map<String, Object?> message, {
    Map<String, String> headers = const <String, String>{},
  }) async {}

  @override
  Future<void> close() async {}
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

void main() {
  late FushiDatabase db;

  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test(
    'send prepares MCP; the model finds and calls a MangaBaka tool; no action-log row',
    () async {
      final _FakeMangaBaka server = _FakeMangaBaka();
      final McpClientToolbox mcp = McpClientToolbox(
        servers: () => const <McpServerConfig>[
          McpServerConfig(
            id: 'mangabaka',
            name: 'MangaBaka',
            url: 'https://api.mangabaka.org/mcp',
          ),
        ],
        connect: (_) async => server,
      );
      final _StubLlm llm = _StubLlm(<AiChatTurn>[
        _call(AgentMetaTool.search, <String, Object?>{
          'query': 'mangabaka series search',
        }),
        _call(AgentMetaTool.describe, <String, Object?>{
          'id': 'mcp__mangabaka__series_search',
        }, callId: 'c2'),
        _call('mcp.mangabaka.series_search', <String, Object?>{
          'q': 'yotsuba',
        }, callId: 'c3'),
      ]);
      final AiAgentController controller = AiAgentController.forTesting(
        database: db,
        settings: _Settings(),
        opContext: OpContext(ref: _UnusedRef()),
        invoker: OpInvoker(
          OpCatalog.build(const <CtlRoute>[], const <OpDescription>[]),
        ),
        llmFactory: (_) => llm,
        mcpToolbox: mcp,
      );
      addTearDown(controller.dispose);

      await controller.send('look up yotsuba on mangabaka');

      expect(mcp.statuses['mangabaka']!.state, McpServerState.connected);
      expect(
        llm.requests.first.first.content,
        contains('MangaBaka (search "mangabaka")'),
      );
      // ops.search 的结果里有 MCP 工具。
      expect(
        llm.requests[1].last.content,
        contains('mcp.mangabaka.series_search'),
      );
      expect(server.calls, <String>['series_search']);
      expect(llm.requests[3].last.content, contains('Yotsuba&!'));
      final AgentEntry entry = controller.session!.entries.lastWhere(
        (AgentEntry e) => e.kind == AgentEntryKind.toolCall,
      );
      expect(entry.toolName, 'mcp.mangabaka.series_search');
      expect(entry.status, AgentEntryStatus.done);
      expect(entry.undoable, isFalse);
      expect(await db.listAiAgentActions(), isEmpty);
    },
  );

  test(
    'without servers the controller still chats and never connects',
    () async {
      int connects = 0;
      final McpClientToolbox mcp = McpClientToolbox(
        servers: () => const <McpServerConfig>[],
        connect: (_) async {
          connects++;
          return _FakeMangaBaka();
        },
      );
      final _StubLlm llm = _StubLlm(const <AiChatTurn>[]);
      final AiAgentController controller = AiAgentController.forTesting(
        database: db,
        settings: _Settings(),
        opContext: OpContext(ref: _UnusedRef()),
        invoker: OpInvoker(
          OpCatalog.build(const <CtlRoute>[], const <OpDescription>[]),
        ),
        llmFactory: (_) => llm,
        mcpToolbox: mcp,
      );
      addTearDown(controller.dispose);
      await controller.send('hi');
      expect(connects, 0);
      expect(llm.requests.single.first.content, agentSystemPrompt(null));
    },
  );
}
