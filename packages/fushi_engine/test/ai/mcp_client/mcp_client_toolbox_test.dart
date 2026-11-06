import 'dart:collection';

import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_model_pricing.dart';
import 'package:fushi_engine/ai/mcp_client/mcp_client_config.dart';
import 'package:fushi_engine/ai/mcp_client/mcp_client_toolbox.dart';
import 'package:fushi_engine/ai/mcp_client/mcp_client_transport.dart';
import 'package:test/test.dart';

/// 一个只会无状态协议的假 server（同 MangaBaka），按工具名回固定结果。
class _FakeServer implements McpClientTransport {
  _FakeServer(
    this.tools, {
    this.results = const <String, Map<String, Object?>>{},
  });

  final List<Map<String, Object?>> tools;
  final Map<String, Map<String, Object?>> results;
  final List<String> calls = <String>[];
  bool closed = false;
  bool failCalls = false;

  @override
  Future<Map<String, Object?>> request(
    Map<String, Object?> message, {
    Map<String, String> headers = const <String, String>{},
    required Duration timeout,
  }) async {
    final Object? id = message['id'];
    final Map<Object?, Object?> params =
        message['params']! as Map<Object?, Object?>;
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
          'result': <String, Object?>{'tools': tools},
        };
      case 'tools/call':
        if (failCalls) {
          throw const McpClientException('session_expired', 'gone');
        }
        final String name = params['name']! as String;
        calls.add(name);
        return <String, Object?>{
          'id': id,
          'result':
              results[name] ??
              <String, Object?>{
                'content': <Object?>[
                  <String, Object?>{'type': 'text', 'text': 'ok:$name'},
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
  Future<void> close() async => closed = true;
}

Map<String, Object?> _tool(
  String name, {
  String description = '',
  bool readOnly = true,
  bool? destructive,
}) => <String, Object?>{
  'name': name,
  'description': description,
  'inputSchema': <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'q': <String, Object?>{'type': 'string'},
    },
  },
  'annotations': <String, Object?>{
    'readOnlyHint': readOnly,
    if (destructive != null) 'destructiveHint': destructive,
  },
};

List<Map<String, Object?>> _mangabakaTools() => <Map<String, Object?>>[
  _tool(
    'series_search',
    description:
        'Search the MangaBaka catalog of manga, manhwa and light novels by title.',
  ),
  _tool('series_get', description: 'Get a MangaBaka series by id.'),
  _tool('tags_find', description: 'Find MangaBaka tags by name.'),
];

const McpServerConfig _mangabaka = McpServerConfig(
  id: 'mangabaka',
  name: 'MangaBaka',
  url: 'https://api.mangabaka.org/mcp',
);

void main() {
  late List<McpServerConfig> configs;
  late Map<String, _FakeServer> servers;
  late int connects;

  McpClientToolbox toolbox({bool Function(McpServerConfig)? isSupported}) =>
      McpClientToolbox(
        servers: () => configs,
        connect: (McpServerConfig c) async {
          connects++;
          final _FakeServer? server = servers[c.id];
          if (server == null) {
            throw const McpClientException('connect_failed', 'refused');
          }
          return server;
        },
        isSupported: isSupported,
      );

  setUp(() {
    configs = <McpServerConfig>[_mangabaka];
    servers = <String, _FakeServer>{
      'mangabaka': _FakeServer(_mangabakaTools()),
    };
    connects = 0;
  });

  group('tool ids', () {
    test('mcp.<server>.<tool> and wire-safe', () {
      expect(
        mcpToolIdFor('mangabaka', 'series_search'),
        'mcp.mangabaka.series_search',
      );
      expect(
        agentWireToolName(mcpToolIdFor('mangabaka', 'series_search')),
        'mcp__mangabaka__series_search',
      );
    });

    test('every id survives the wire round trip, even with odd names', () {
      for (final String name in <String>[
        'a.b',
        'a__b',
        'a___b',
        'weird name/с кириллицей',
        'x' * 100,
        'trail_',
      ]) {
        final String id = mcpToolIdFor('srv', name);
        final String wire = agentWireToolName(id);
        expect(agentToolIdFromWire(wire), id, reason: name);
        expect(
          RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(wire),
          isTrue,
          reason: wire,
        );
        expect(id, startsWith('mcp.srv.'));
      }
    });
  });

  test(
    'prepare connects enabled servers; nothing is resident; statuses report tools',
    () async {
      final McpClientToolbox box = toolbox();
      await box.prepare();
      expect(box.residentTools(), isEmpty);
      expect(box.toolIds, hasLength(3));
      final McpServerStatus status = box.statuses['mangabaka']!;
      expect(status.state, McpServerState.connected);
      expect(status.toolCount, 3);
      expect(status.protocolVersion, '2026-07-28');
    },
  );

  test(
    'disabled, unsupported and incomplete servers are never connected',
    () async {
      configs = <McpServerConfig>[
        _mangabaka.copyWith(enabled: false),
        const McpServerConfig(
          id: 'local',
          name: 'Local',
          transport: McpTransportKind.stdio,
          command: 'x',
        ),
        const McpServerConfig(id: 'empty', name: 'Empty'),
      ];
      final McpClientToolbox box = toolbox(
        isSupported: (McpServerConfig c) =>
            c.transport == McpTransportKind.http,
      );
      await box.prepare();
      expect(connects, 0);
      expect(box.statuses['mangabaka']!.state, McpServerState.disabled);
      expect(box.statuses['local']!.state, McpServerState.unsupported);
      expect(box.statuses['empty']!.state, McpServerState.incomplete);
      expect(box.promptNote(), isNull);
    },
  );

  test(
    'a failing server does not break the others and is retried next prepare',
    () async {
      configs = <McpServerConfig>[
        _mangabaka,
        const McpServerConfig(
          id: 'down',
          name: 'Down',
          url: 'https://down/mcp',
        ),
      ];
      final McpClientToolbox box = toolbox();
      await box.prepare();
      expect(box.statuses['down']!.state, McpServerState.failed);
      expect(box.statuses['down']!.errorCode, 'connect_failed');
      expect(box.toolIds, hasLength(3));
      expect(
        box.promptNote(),
        contains('- Down: unavailable (connect_failed)'),
      );
      connects = 0;
      await box.prepare();
      // 健康的不重连，失败的重试。
      expect(connects, 1);
    },
  );

  test(
    'changing connection settings reconnects; toggling tools does not',
    () async {
      final McpClientToolbox box = toolbox();
      await box.prepare();
      expect(connects, 1);
      configs = <McpServerConfig>[
        _mangabaka.copyWith(disabledTools: <String>{'tags_find'}),
      ];
      await box.prepare();
      expect(connects, 1);
      expect(box.toolIds, isNot(contains('mcp.mangabaka.tags_find')));
      final _FakeServer old = servers['mangabaka']!;
      servers['mangabaka'] = _FakeServer(_mangabakaTools());
      configs = <McpServerConfig>[
        _mangabaka.copyWith(url: 'https://other/mcp'),
      ];
      await box.prepare();
      expect(connects, 2);
      expect(old.closed, isTrue);
      configs = const <McpServerConfig>[];
      await box.prepare();
      expect(servers['mangabaka']!.closed, isTrue);
      expect(box.toolIds, isEmpty);
    },
  );

  test(
    'search ranks name hits; compact description; describe gives the full schema',
    () async {
      final McpClientToolbox box = toolbox();
      await box.prepare();
      final List<AgentToolSpec> hits = box.searchTools(
        'mangabaka search series',
      );
      expect(hits.first.name, 'mcp.mangabaka.series_search');
      expect(
        hits.map((AgentToolSpec s) => s.name),
        contains('mcp.mangabaka.tags_find'),
      );
      expect(hits.first.description, startsWith('[MCP: MangaBaka] '));
      expect(box.searchTools('zzz unrelated'), isEmpty);
      expect(box.searchTools(''), isEmpty);

      final AgentToolSpec spec = box.describeTool('mcp.mangabaka.series_get')!;
      expect(spec.parameters['properties'], isA<Map<Object?, Object?>>());
      expect(spec.risk, AgentToolRisk.read);
      expect(spec.needsConfirmation, isFalse);
      expect(box.describeTool('mcp.mangabaka.nope'), isNull);
    },
  );

  test(
    'non-read-only tools and confirmEveryCall servers need confirmation',
    () async {
      servers['mangabaka'] = _FakeServer(<Map<String, Object?>>[
        _tool('read_it'),
        _tool('write_soft', readOnly: false, destructive: false),
        _tool('write_hard', readOnly: false),
      ]);
      final McpClientToolbox box = toolbox();
      await box.prepare();
      expect(
        box.describeTool('mcp.mangabaka.read_it')!.needsConfirmation,
        isFalse,
      );
      final AgentToolSpec soft = box.describeTool('mcp.mangabaka.write_soft')!;
      expect(soft.risk, AgentToolRisk.write);
      expect(soft.needsConfirmation, isTrue);
      expect(
        box.describeTool('mcp.mangabaka.write_hard')!.risk,
        AgentToolRisk.irreversible,
      );

      configs = <McpServerConfig>[_mangabaka.copyWith(confirmEveryCall: true)];
      await box.prepare();
      expect(
        box.describeTool('mcp.mangabaka.read_it')!.needsConfirmation,
        isTrue,
      );
    },
  );

  test(
    'execute calls the server; refuses unconfirmed writes; maps errors',
    () async {
      servers['mangabaka'] = _FakeServer(
        <Map<String, Object?>>[
          _tool('read_it'),
          _tool('write_it', readOnly: false),
          _tool('broken'),
          _tool('big'),
        ],
        results: <String, Map<String, Object?>>{
          'broken': <String, Object?>{
            'isError': true,
            'content': <Object?>[
              <String, Object?>{'type': 'text', 'text': 'bad id'},
            ],
          },
          'big': <String, Object?>{
            'content': <Object?>[
              <String, Object?>{
                'type': 'text',
                'text': 'x' * (kMcpToolResultMaxChars + 50),
              },
            ],
          },
        },
      );
      final McpClientToolbox box = toolbox();
      await box.prepare();

      AgentToolInvocation inv(String tool, {bool confirmed = false}) =>
          AgentToolInvocation(
            sessionId: 's',
            name: 'mcp.mangabaka.$tool',
            arguments: const <String, Object?>{'q': 'x'},
            confirmed: confirmed,
          );

      final AgentToolResult ok = await box.execute(inv('read_it'));
      expect(ok.isError, isFalse);
      expect(ok.data, 'ok:read_it');
      expect(ok.actionId, isNull);

      expect(
        (await box.execute(inv('write_it'))).errorCode,
        'confirmation_required',
      );
      expect(servers['mangabaka']!.calls, isNot(contains('write_it')));
      expect(
        (await box.execute(inv('write_it', confirmed: true))).isError,
        isFalse,
      );

      final AgentToolResult broken = await box.execute(inv('broken'));
      expect(broken.errorCode, 'mcp_tool_error');
      expect(broken.errorMessage, 'bad id');

      final AgentToolResult big = await box.execute(inv('big'));
      expect(
        (big.data! as String).length,
        lessThan(kMcpToolResultMaxChars + 100),
      );
      expect(big.data, contains('truncated 50 characters'));

      expect((await box.execute(inv('missing'))).errorCode, 'unknown_tool');
      expect((await box.undo('anything')).status, AgentUndoStatus.notUndoable);
    },
  );

  test(
    'a broken connection during a call is reported and reconnected next turn',
    () async {
      final McpClientToolbox box = toolbox();
      await box.prepare();
      servers['mangabaka']!.failCalls = true;
      final AgentToolResult result = await box.execute(
        const AgentToolInvocation(
          sessionId: 's',
          name: 'mcp.mangabaka.series_get',
          arguments: <String, Object?>{},
        ),
      );
      expect(result.errorCode, 'mcp_unavailable');
      expect(box.statuses['mangabaka']!.state, McpServerState.failed);
      servers['mangabaka'] = _FakeServer(_mangabakaTools());
      await box.prepare();
      expect(box.statuses['mangabaka']!.state, McpServerState.connected);
    },
  );

  test('prompt note lists servers and tool names, not descriptions', () async {
    final McpClientToolbox box = toolbox();
    await box.prepare();
    final String note = box.promptNote()!;
    expect(
      note,
      contains(
        '- MangaBaka (search "mangabaka"): series_search, series_get, tags_find',
      ),
    );
    expect(note, contains('untrusted'));
    expect(note, isNot(contains('light novels')));
  });

  test('close disconnects everything', () async {
    final McpClientToolbox box = toolbox();
    await box.prepare();
    await box.close();
    expect(servers['mangabaka']!.closed, isTrue);
    expect(box.toolIds, isEmpty);
    await box.prepare();
    expect(connects, 1);
  });

  test('probeMcpServer reports tools without keeping the connection', () async {
    final McpProbeResult result = await probeMcpServer(
      _mangabaka,
      (McpServerConfig c) async => servers[c.id]!,
    );
    expect(result.status.state, McpServerState.connected);
    expect(result.tools.map((t) => t.name), contains('series_search'));
    expect(servers['mangabaka']!.closed, isTrue);
    final McpProbeResult failed = await probeMcpServer(
      _mangabaka,
      (McpServerConfig c) async =>
          throw const McpClientException('connect_failed', 'nope'),
    );
    expect(failed.status.errorCode, 'connect_failed');
    expect(
      (await probeMcpServer(
        const McpServerConfig(id: 'e', name: 'E'),
        (_) async => servers['mangabaka']!,
      )).status.state,
      McpServerState.incomplete,
    );
  });

  group('ComposedAgentToolbox', () {
    test(
      'routes MCP ids to the MCP box and everything else to the primary',
      () async {
        final McpClientToolbox mcp = toolbox();
        await mcp.prepare();
        final _Primary primary = _Primary();
        final ComposedAgentToolbox composed = ComposedAgentToolbox(
          primary,
          <AgentToolbox>[mcp],
        );
        expect(
          composed.residentTools().map((AgentToolSpec s) => s.name),
          <String>['settings.get'],
        );
        expect(composed.describeTool('settings.get'), isNotNull);
        expect(composed.describeTool('mcp.mangabaka.series_get'), isNotNull);
        await composed.execute(
          const AgentToolInvocation(
            sessionId: 's',
            name: 'settings.get',
            arguments: <String, Object?>{},
          ),
        );
        expect(primary.executed, <String>['settings.get']);
        await composed.execute(
          const AgentToolInvocation(
            sessionId: 's',
            name: 'mcp.mangabaka.series_get',
            arguments: <String, Object?>{},
          ),
        );
        expect(servers['mangabaka']!.calls, <String>['series_get']);
        expect(composed.skills(), isEmpty);
        expect(composed.promptNote(), contains('MangaBaka'));
      },
    );

    test(
      'search puts MCP hits first but leaves room for catalog results',
      () async {
        final McpClientToolbox mcp = toolbox();
        await mcp.prepare();
        final ComposedAgentToolbox composed = ComposedAgentToolbox(
          _Primary(catalogHits: 10),
          <AgentToolbox>[mcp],
        );
        final List<String> names = <String>[
          for (final AgentToolSpec s in composed.searchTools(
            'mangabaka series tags',
            limit: 4,
          ))
            s.name,
        ];
        expect(names, hasLength(4));
        expect(names.take(2).every((String n) => n.startsWith('mcp.')), isTrue);
        expect(
          names.skip(2).every((String n) => n.startsWith('catalog.')),
          isTrue,
        );
        // 主目录没结果时名额全给 MCP。
        final ComposedAgentToolbox sparse = ComposedAgentToolbox(
          _Primary(),
          <AgentToolbox>[mcp],
        );
        expect(
          sparse.searchTools('mangabaka series tags', limit: 4),
          hasLength(3),
        );
      },
    );
  });

  group('AgentSession integration', () {
    test(
      'note reaches the system prompt; read-only MCP tool runs without a card',
      () async {
        final McpClientToolbox mcp = toolbox();
        await mcp.prepare();
        final _StubLlm llm = _StubLlm(<AiChatTurn>[
          _call('mcp.mangabaka.series_search', <String, Object?>{
            'q': 'yotsuba',
          }),
          _reply('Found it.'),
        ]);
        final _Host host = _Host();
        final AgentSession session = AgentSession(
          id: 's1',
          llm: llm,
          toolbox: ComposedAgentToolbox(_Primary(), <AgentToolbox>[mcp]),
          host: host,
        );
        await session.send('find yotsuba on mangabaka');
        final AiChatMessage system = llm.requests.first.first;
        expect(system.content, contains('External tools from MCP servers'));
        expect(system.content, contains('series_search'));
        expect(host.confirmed, isEmpty);
        expect(servers['mangabaka']!.calls, <String>['series_search']);
        final AiChatMessage toolResult = llm.requests[1].last;
        expect(
          toolResult.content,
          contains('<untrusted_data source="mcp.mangabaka.series_search">'),
        );
        expect(toolResult.content, contains('ok:series_search'));
      },
    );

    test(
      'a write MCP tool shows the confirmation card; declining does not call it',
      () async {
        servers['mangabaka'] = _FakeServer(<Map<String, Object?>>[
          _tool('add_to_list', readOnly: false),
        ]);
        final McpClientToolbox mcp = toolbox();
        await mcp.prepare();
        final _Host host = _Host(approve: false);
        final AgentSession session = AgentSession(
          id: 's2',
          llm: _StubLlm(<AiChatTurn>[
            _call('mcp.mangabaka.add_to_list', const <String, Object?>{}),
            _reply('Okay.'),
          ]),
          toolbox: ComposedAgentToolbox(_Primary(), <AgentToolbox>[mcp]),
          host: host,
        );
        await session.send('add it');
        expect(host.confirmed, <String>['mcp.mangabaka.add_to_list']);
        expect(servers['mangabaka']!.calls, isEmpty);
      },
    );

    test('without MCP servers the system prompt is unchanged', () async {
      configs = const <McpServerConfig>[];
      final McpClientToolbox mcp = toolbox();
      await mcp.prepare();
      final _StubLlm llm = _StubLlm(<AiChatTurn>[_reply('hi')]);
      await AgentSession(
        id: 's3',
        llm: llm,
        toolbox: ComposedAgentToolbox(_Primary(), <AgentToolbox>[mcp]),
        host: _Host(),
      ).send('hello');
      expect(llm.requests.first.first.content, agentSystemPrompt(null));
    });

    test('JSON fallback protocol also carries the note', () async {
      final McpClientToolbox mcp = toolbox();
      await mcp.prepare();
      final _StubLlm llm = _StubLlm(<AiChatTurn>[
        _reply('{"reply":"hi"}'),
      ], supportsTools: false);
      await AgentSession(
        id: 's4',
        llm: llm,
        toolbox: ComposedAgentToolbox(_Primary(), <AgentToolbox>[mcp]),
        host: _Host(),
      ).send('hello');
      expect(
        llm.requests.first.first.content,
        contains('MangaBaka (search "mangabaka")'),
      );
    });
  });
}

class _Primary implements AgentToolbox {
  _Primary({this.catalogHits = 0});

  final int catalogHits;
  final List<String> executed = <String>[];

  static const AgentToolSpec settingsGet = AgentToolSpec(
    name: 'settings.get',
    description: 'Read a setting.',
    parameters: <String, Object?>{'type': 'object'},
  );

  @override
  List<AgentToolSpec> residentTools() => const <AgentToolSpec>[settingsGet];

  @override
  List<AgentToolSpec> searchTools(String query, {int limit = 12}) =>
      <AgentToolSpec>[
        for (int i = 0; i < catalogHits && i < limit; i++)
          AgentToolSpec(
            name: 'catalog.op$i',
            description: 'op',
            parameters: const <String, Object?>{'type': 'object'},
          ),
      ];

  @override
  AgentToolSpec? describeTool(String name) =>
      name == settingsGet.name ? settingsGet : null;

  @override
  Future<AgentToolResult> execute(AgentToolInvocation invocation) async {
    executed.add(invocation.name);
    return const AgentToolResult.ok(<String, Object?>{'value': 1});
  }

  @override
  Future<AgentUndoResult> undo(String actionId) async =>
      const AgentUndoResult(AgentUndoStatus.done);
}

class _StubLlm implements AgentLlm {
  _StubLlm(List<AiChatTurn> turns, {this.supportsTools = true})
    : _turns = Queue<AiChatTurn>.of(turns);

  final Queue<AiChatTurn> _turns;
  final List<List<AiChatMessage>> requests = <List<AiChatMessage>>[];

  @override
  final bool supportsTools;

  @override
  AiModelPricing get pricing => const AiModelPricing();

  @override
  Future<AiChatTurn> chat(
    List<AiChatMessage> messages,
    List<AiChatToolSpec> tools,
  ) async {
    requests.add(List<AiChatMessage>.of(messages));
    if (_turns.isEmpty) throw const AiChatFailure('empty_response');
    return _turns.removeFirst();
  }
}

class _Host implements AgentHost {
  _Host({this.approve = true});

  final bool approve;
  final List<String> confirmed = <String>[];

  @override
  Future<bool> confirm(AgentConfirmRequest request) async {
    confirmed.add(request.tool.name);
    return approve;
  }

  @override
  Future<String?> askChoice(
    String prompt,
    List<AgentChoiceOption> options,
  ) async => null;
}

AiChatTurn _call(String name, Map<String, Object?> args) => AiChatTurn(
  text: '',
  toolCalls: <AiChatToolCall>[
    AiChatToolCall(id: 'c1', name: agentWireToolName(name), arguments: args),
  ],
  usage: const AiChatUsage(inputTokens: 1, outputTokens: 1),
);

AiChatTurn _reply(String text) => AiChatTurn(
  text: text,
  toolCalls: const <AiChatToolCall>[],
  usage: const AiChatUsage(inputTokens: 1, outputTokens: 1),
);
