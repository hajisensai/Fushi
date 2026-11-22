// 长程模式（beginLongTask）、上下文压缩、计划清单（plan.update）：
// spec docs/specs/2026-11-22-ai-library-agent-design.md §3.4。
import 'dart:collection';
import 'dart:convert';

import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_model_pricing.dart';
import 'package:test/test.dart';

/// 回放固定回合的 stub 模型；记下每次收到的消息与工具表。
class _Llm implements AgentLlm {
  _Llm(List<AiChatTurn> turns, {this.supportsTools = true})
    : _turns = Queue<AiChatTurn>.of(turns);

  final Queue<AiChatTurn> _turns;
  final List<List<AiChatMessage>> requests = <List<AiChatMessage>>[];
  final List<List<String>> toolNames = <List<String>>[];

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
    toolNames.add(<String>[for (final AiChatToolSpec t in tools) t.name]);
    return _turns.isEmpty
        ? const AiChatTurn(text: 'done', toolCalls: <AiChatToolCall>[])
        : _turns.removeFirst();
  }
}

AiChatToolCall _c(String id, String tool, [Map<String, Object?>? args]) =>
    AiChatToolCall(
      id: id,
      name: agentWireToolName(tool),
      arguments: args ?? <String, Object?>{'n': id},
    );

AiChatTurn _calls(List<AiChatToolCall> calls) =>
    AiChatTurn(text: '', toolCalls: calls);

AiChatTurn _reply(String text) =>
    AiChatTurn(text: text, toolCalls: const <AiChatToolCall>[]);

/// 整库整理技能：进长程模式，装上 map / apply（外加一个不存在的 id）。
class _ReorganizeSkill implements AgentSkill {
  _ReorganizeSkill({this.maxToolCalls});

  final int? maxToolCalls;

  @override
  AgentToolSpec get spec => const AgentToolSpec(
    name: 'skill.library.reorganize',
    description: 'Reorganize the library.',
    parameters: <String, Object?>{'type': 'object'},
  );

  @override
  Future<Object?> run(
    AgentSkillContext context,
    Map<String, Object?> args,
  ) async {
    context.beginLongTask(
      tools: <String>[
        'library.map',
        'library__changes__apply',
        'no.such.tool',
        AgentMetaTool.planUpdate,
      ],
      maxToolCalls: maxToolCalls,
    );
    return const <String, Object?>{'method': 'map, plan, apply, verify'};
  }
}

class _Toolbox implements AgentToolbox, AgentSkillProvider {
  _Toolbox({this.skill, this.resultSize = 50});

  final AgentSkill? skill;
  final int resultSize;
  final List<String> executed = <String>[];

  static const AgentToolSpec map = AgentToolSpec(
    name: 'library.map',
    description: 'Library overview.',
    parameters: <String, Object?>{'type': 'object'},
  );
  static const AgentToolSpec apply = AgentToolSpec(
    name: 'library.changes.apply',
    description: 'Apply a changeset.',
    parameters: <String, Object?>{'type': 'object'},
    risk: AgentToolRisk.write,
    undoable: true,
  );

  @override
  List<AgentToolSpec> residentTools() => const <AgentToolSpec>[];

  @override
  List<AgentToolSpec> searchTools(String query, {int limit = 12}) =>
      const <AgentToolSpec>[];

  @override
  AgentToolSpec? describeTool(String name) => switch (name) {
    'library.map' => map,
    'library.changes.apply' => apply,
    _ => null,
  };

  @override
  Future<AgentToolResult> execute(AgentToolInvocation invocation) async {
    executed.add(invocation.name);
    return AgentToolResult.ok(<String, Object?>{
      'call': invocation.arguments['n'],
      'rows': 'x' * resultSize,
    });
  }

  @override
  Future<AgentUndoResult> undo(String actionId) async =>
      const AgentUndoResult(AgentUndoStatus.done);

  @override
  List<AgentSkill> skills() => <AgentSkill>[?skill];
}

class _Host implements AgentHost {
  @override
  Future<bool> confirm(AgentConfirmRequest request) async => true;

  @override
  Future<String?> askChoice(
    String prompt,
    List<AgentChoiceOption> options,
  ) async => null;
}

AgentSession _session(
  _Llm llm,
  _Toolbox toolbox, {
  AgentLimits limits = const AgentLimits(),
}) => AgentSession(
  id: 's1',
  llm: llm,
  toolbox: toolbox,
  host: _Host(),
  limits: limits,
  clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
);

List<AgentEntry> _notices(AgentSession s, String code) => <AgentEntry>[
  for (final AgentEntry e in s.entries)
    if (e.kind == AgentEntryKind.notice && e.errorCode == code) e,
];

/// 原生协议的一段历史：每条工具结果 [size] 字。
List<AiChatMessage> _nativeHistory(int results, int size) => <AiChatMessage>[
  const AiChatMessage.user('reorganize my library'),
  for (int i = 0; i < results; i++) ...<AiChatMessage>[
    AiChatMessage.assistantToolCalls('', <AiChatToolCall>[
      _c('c$i', 'library.map'),
    ]),
    AiChatMessage.toolResult(
      toolCallId: 'c$i',
      toolName: 'library__map',
      content: wrapAgentUntrusted('library.map', '$i:${'y' * size}'),
      isError: i == 1,
    ),
  ],
];

void main() {
  group('长程模式 beginLongTask', () {
    test('技能装上工具（等同 describe 过）并把本轮上限提到 longTaskMaxToolCalls', () async {
      final _Toolbox toolbox = _Toolbox(skill: _ReorganizeSkill());
      final _Llm llm = _Llm(<AiChatTurn>[
        _calls(<AiChatToolCall>[_c('s', 'skill.library.reorganize')]),
        _calls(<AiChatToolCall>[
          for (int i = 0; i < 30; i++) _c('m$i', 'library.map'),
        ]),
        _reply('reorganized'),
      ]);
      final AgentSession session = _session(
        llm,
        toolbox,
        limits: const AgentLimits(
          maxToolCallsPerTurn: 5,
          longTaskMaxToolCalls: 40,
        ),
      );
      await session.send('重新整理整个库');
      expect(_notices(session, AgentStopCode.toolLimit), isEmpty);
      expect(toolbox.executed, hasLength(30));
      expect(session.entries.last.text, 'reorganized');
      // 第二次请求起工具表里就有这两个工具；不存在的 id 与元工具被忽略。
      expect(
        llm.toolNames[1],
        containsAll(<String>['library__map', 'library__changes__apply']),
      );
      expect(llm.toolNames[1], isNot(contains('no__such__tool')));
      expect(
        llm.toolNames[1].where((String n) => n == 'plan__update'),
        hasLength(1),
      );
      // 装进来的工具随存档走。
      expect(
        session.toJson()['loadedTools'],
        containsAll(<String>['library.map', 'library.changes.apply']),
      );
    });

    test('maxToolCalls 显式给值：用它；超了照样停下，没跑的调用也回结果', () async {
      final _Toolbox toolbox = _Toolbox(
        skill: _ReorganizeSkill(maxToolCalls: 8),
      );
      final _Llm llm = _Llm(<AiChatTurn>[
        _calls(<AiChatToolCall>[_c('s', 'skill.library.reorganize')]),
        _calls(<AiChatToolCall>[
          for (int i = 0; i < 10; i++) _c('m$i', 'library.map'),
        ]),
      ]);
      final AgentSession session = _session(
        llm,
        toolbox,
        limits: const AgentLimits(maxToolCallsPerTurn: 3),
      );
      await session.send('整理');
      // 技能本身算 1 次，之后还能再跑 7 次。
      expect(toolbox.executed, hasLength(7));
      expect(_notices(session, AgentStopCode.toolLimit), hasLength(1));
      final List<AiChatMessage> history = <AiChatMessage>[
        for (final Object? m in session.toJson()['history']! as List<Object?>)
          agentMessageFromJson(Map<String, Object?>.from(m! as Map))!,
      ];
      expect(
        history.where((AiChatMessage m) => m.role == 'tool'),
        hasLength(11),
      );
    });

    test('只升不降：比默认低的 maxToolCalls 不把上限调低', () async {
      final _Toolbox toolbox = _Toolbox(
        skill: _ReorganizeSkill(maxToolCalls: 1),
      );
      final _Llm llm = _Llm(<AiChatTurn>[
        _calls(<AiChatToolCall>[_c('s', 'skill.library.reorganize')]),
        _calls(<AiChatToolCall>[
          for (int i = 0; i < 4; i++) _c('m$i', 'library.map'),
        ]),
        _reply('ok'),
      ]);
      final AgentSession session = _session(
        llm,
        toolbox,
        limits: const AgentLimits(maxToolCallsPerTurn: 5),
      );
      await session.send('整理');
      expect(toolbox.executed, hasLength(4));
      expect(_notices(session, AgentStopCode.toolLimit), isEmpty);
    });

    test('下一轮恢复默认上限；已装的工具留在本场', () async {
      final _Toolbox toolbox = _Toolbox(skill: _ReorganizeSkill());
      final _Llm llm = _Llm(<AiChatTurn>[
        _calls(<AiChatToolCall>[_c('s', 'skill.library.reorganize')]),
        _calls(<AiChatToolCall>[
          for (int i = 0; i < 5; i++) _c('a$i', 'library.map'),
        ]),
        _reply('first'),
        _calls(<AiChatToolCall>[
          for (int i = 0; i < 5; i++) _c('b$i', 'library.map'),
        ]),
      ]);
      final AgentSession session = _session(
        llm,
        toolbox,
        limits: const AgentLimits(maxToolCallsPerTurn: 3),
      );
      await session.send('整理');
      expect(_notices(session, AgentStopCode.toolLimit), isEmpty);
      await session.send('再来');
      expect(_notices(session, AgentStopCode.toolLimit), hasLength(1));
      expect(toolbox.executed, hasLength(5 + 3));
      expect(llm.toolNames.last, contains('library__map'));
    });

    test('连错熔断照旧生效', () async {
      final _Toolbox toolbox = _Toolbox(skill: _ReorganizeSkill());
      final _Llm llm = _Llm(<AiChatTurn>[
        _calls(<AiChatToolCall>[_c('s', 'skill.library.reorganize')]),
        _calls(<AiChatToolCall>[
          _c('p1', AgentMetaTool.planUpdate, <String, Object?>{'items': 1}),
        ]),
        _calls(<AiChatToolCall>[
          _c('p2', AgentMetaTool.planUpdate, <String, Object?>{'items': 1}),
        ]),
      ]);
      final AgentSession session = _session(llm, toolbox);
      await session.send('整理');
      expect(_notices(session, AgentStopCode.repeatedFailure), hasLength(1));
    });
  });

  group('上下文压缩', () {
    test('没超预算不动', () {
      final List<AiChatMessage> history = _nativeHistory(4, 100);
      final List<String> before = <String>[
        for (final AiChatMessage m in history) m.content,
      ];
      expect(
        compactAgentHistory(history, charBudget: 100000, keepRecent: 2),
        0,
      );
      expect(<String>[
        for (final AiChatMessage m in history) m.content,
      ], before);
    });

    test('原生协议：从最早起换占位，压到 60% 以下；最近 N 条与配对不动', () {
      final List<AiChatMessage> history = _nativeHistory(10, 2000);
      final List<AiChatMessage> original = List<AiChatMessage>.of(history);
      final int budget = agentHistoryChars(history) - 1;
      final int elided = compactAgentHistory(
        history,
        charBudget: budget,
        keepRecent: 3,
      );
      expect(elided, greaterThan(0));
      expect(
        agentHistoryChars(history),
        lessThanOrEqualTo((budget * kAgentCompactTargetRatio).floor()),
      );
      final List<int> toolIdx = <int>[
        for (int i = 0; i < history.length; i++)
          if (history[i].role == 'tool') i,
      ];
      expect(toolIdx, hasLength(10));
      for (int k = 0; k < toolIdx.length; k++) {
        final AiChatMessage now = history[toolIdx[k]];
        final AiChatMessage was = original[toolIdx[k]];
        // 配对字段原样保留，且紧跟同 id 的 tool_use。
        expect(now.toolCallId, was.toolCallId);
        expect(now.toolName, was.toolName);
        expect(now.isError, was.isError);
        expect(history[toolIdx[k] - 1].toolCalls.single.id, now.toolCallId);
        if (k < elided) {
          expect(now.content, startsWith('[Earlier result of library.map'));
          expect(now.content, contains('${was.content.length} chars'));
          expect(now.content, contains('library__map again'));
          expect(
            now.content,
            contains('<untrusted_data source="library.map">'),
          );
          // 头部摘录保留。
          expect(now.content, contains('$k:${'y' * 300}'));
          expect(now.content.length, lessThan(800));
        } else {
          expect(now.content, was.content);
        }
      }
      // 最近 3 条一定完整。
      for (final int i in toolIdx.skip(7)) {
        expect(history[i].content, original[i].content);
      }
      // 只动工具结果。
      for (int i = 0; i < history.length; i++) {
        if (history[i].role != 'tool') {
          expect(identical(history[i], original[i]), isTrue);
        }
      }
    });

    test('确定且幂等：再压一次不重复包装', () {
      final List<AiChatMessage> a = _nativeHistory(10, 2000);
      final List<AiChatMessage> b = _nativeHistory(10, 2000);
      compactAgentHistory(a, charBudget: 5000, keepRecent: 2);
      compactAgentHistory(b, charBudget: 5000, keepRecent: 2);
      expect(
        <String>[for (final AiChatMessage m in a) m.content],
        <String>[for (final AiChatMessage m in b) m.content],
      );
      final List<String> once = <String>[
        for (final AiChatMessage m in a) m.content,
      ];
      expect(compactAgentHistory(a, charBudget: 5000, keepRecent: 2), 0);
      expect(<String>[for (final AiChatMessage m in a) m.content], once);
    });

    test('降级协议：Result of 结果换占位、保留头；用户自己说的话不动', () {
      final String bigUser = 'Result of nothing: ${'u' * 5000}';
      final List<AiChatMessage> history = <AiChatMessage>[
        AiChatMessage.user(bigUser),
        for (int i = 0; i < 4; i++) ...<AiChatMessage>[
          const AiChatMessage.assistant('{"tool": "library__map", "args": {}}'),
          AiChatMessage.user(
            'Result of library__map:\n'
            '${wrapAgentUntrusted('library.map', 'r$i:${'z' * 3000}')}',
          ),
        ],
      ];
      compactAgentHistory(history, charBudget: 10000, keepRecent: 1);
      expect(history.first.content, bigUser);
      for (final int i in <int>[2, 4, 6]) {
        expect(
          history[i].content,
          startsWith('Result of library__map:\n[Earlier result of library.map'),
        );
        expect(history[i].role, 'user');
      }
      expect(history[8].content, contains('z' * 3000));
    });

    test('会话里每次请求前压缩；压过的历史随存档往返', () async {
      final _Toolbox toolbox = _Toolbox(resultSize: 3000);
      final _Llm llm = _Llm(<AiChatTurn>[
        for (int i = 0; i < 6; i++)
          _calls(<AiChatToolCall>[_c('m$i', 'library.map')]),
        _reply('ok'),
      ]);
      final AgentSession session = AgentSession(
        id: 's1',
        llm: llm,
        toolbox: toolbox,
        host: _Host(),
        limits: const AgentLimits(
          historyCharBudget: 8000,
          keepRecentToolResults: 2,
        ),
        loadedTools: <String>{'library.map'},
      );
      await session.send('看看库');
      final List<AiChatMessage> last = llm.requests.last;
      final List<AiChatMessage> results = <AiChatMessage>[
        for (final AiChatMessage m in last)
          if (m.role == 'tool') m,
      ];
      expect(results, hasLength(6));
      expect(
        results.first.content,
        startsWith('[Earlier result of library.map'),
      );
      expect(results.last.content, contains('x' * 3000));
      expect(results[4].content, contains('x' * 3000));
      final Map<String, Object?> json = session.toJson();
      expect(jsonEncode(json), contains('[Earlier result of library.map'));
      final AgentSession restored = AgentSession.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, Object?>,
        llm: _Llm(const <AiChatTurn>[]),
        toolbox: toolbox,
        host: _Host(),
      );
      expect(
        jsonEncode(restored.toJson()['history']),
        jsonEncode(json['history']),
      );
    });
  });

  group('计划清单 plan.update', () {
    Map<String, Object?> plan(List<(String, String)> items) =>
        <String, Object?>{
          'items': <Object?>[
            for (final (String text, String status) in items)
              <String, Object?>{'text': text, 'status': status},
          ],
        };

    test('校验：非数组 / 空文本 / 未知状态 / 超 50 项都报错；空清单合法', () {
      expect(parseAgentPlanArgs(const <String, Object?>{}).$2, isNotNull);
      expect(
        parseAgentPlanArgs(plan(<(String, String)>[(' ', 'pending')])).$2,
        contains('text'),
      );
      expect(
        parseAgentPlanArgs(plan(<(String, String)>[('a', 'doing')])).$2,
        contains('status'),
      );
      expect(
        parseAgentPlanArgs(<String, Object?>{
          'items': <Object?>['a'],
        }).$2,
        contains('object'),
      );
      expect(
        parseAgentPlanArgs(
          plan(<(String, String)>[
            for (int i = 0; i <= kAgentPlanMaxItems; i++) ('t$i', 'pending'),
          ]),
        ).$2,
        contains('$kAgentPlanMaxItems'),
      );
      expect(
        parseAgentPlanArgs(const <String, Object?>{'items': <Object?>[]}).$1,
        isEmpty,
      );
    });

    test('存进会话、显示成清单记录；同一轮再更新改同一条；存档往返', () async {
      final _Toolbox toolbox = _Toolbox();
      final _Llm llm = _Llm(<AiChatTurn>[
        _calls(<AiChatToolCall>[
          _c(
            'p1',
            AgentMetaTool.planUpdate,
            plan(<(String, String)>[('看全貌', 'active'), ('整理书', 'pending')]),
          ),
        ]),
        _calls(<AiChatToolCall>[
          _c(
            'p2',
            AgentMetaTool.planUpdate,
            plan(<(String, String)>[
              ('看全貌', 'done'),
              ('整理书', 'active'),
              ('自查', 'pending'),
            ]),
          ),
        ]),
        _calls(<AiChatToolCall>[
          _c(
            'p3',
            AgentMetaTool.planUpdate,
            plan(<(String, String)>[('坏的', 'bogus')]),
          ),
        ]),
        _reply('在整理'),
      ]);
      final AgentSession session = _session(llm, toolbox);
      await session.send('整理');
      expect(llm.toolNames.first, contains('plan__update'));
      expect(session.plan, const <AgentPlanItem>[
        AgentPlanItem(text: '看全貌', status: AgentPlanStatus.done),
        AgentPlanItem(text: '整理书', status: AgentPlanStatus.active),
        AgentPlanItem(text: '自查'),
      ]);
      final List<AgentEntry> planEntries = <AgentEntry>[
        for (final AgentEntry e in session.entries)
          if (e.toolName == AgentMetaTool.planUpdate) e,
      ];
      expect(planEntries, hasLength(1));
      expect(planEntries.single.kind, AgentEntryKind.toolCall);
      expect(planEntries.single.status, AgentEntryStatus.done);
      expect(planEntries.single.text, '[x] 看全貌\n[>] 整理书\n[ ] 自查');
      expect(planEntries.single.resultPreview, planEntries.single.text);
      // 坏参数回错误结果，清单不变。
      final AiChatMessage bad = llm.requests.last.lastWhere(
        (AiChatMessage m) => m.role == 'tool',
      );
      expect(bad.isError, isTrue);
      expect(bad.content, contains('invalid_plan'));
      expect(toolbox.executed, isEmpty);

      final Map<String, Object?> json =
          jsonDecode(jsonEncode(session.toJson())) as Map<String, Object?>;
      final AgentSession restored = AgentSession.fromJson(
        json,
        llm: _Llm(const <AiChatTurn>[]),
        toolbox: toolbox,
        host: _Host(),
      );
      expect(restored.plan, session.plan);
      expect(
        restored.entries
            .firstWhere(
              (AgentEntry e) => e.toolName == AgentMetaTool.planUpdate,
            )
            .text,
        '[x] 看全貌\n[>] 整理书\n[ ] 自查',
      );
    });

    test('新一轮的更新另起一条记录', () async {
      final _Llm llm = _Llm(<AiChatTurn>[
        _calls(<AiChatToolCall>[
          _c(
            'p1',
            AgentMetaTool.planUpdate,
            plan(<(String, String)>[('a', 'active')]),
          ),
        ]),
        _reply('1'),
        _calls(<AiChatToolCall>[
          _c(
            'p2',
            AgentMetaTool.planUpdate,
            plan(<(String, String)>[('a', 'done')]),
          ),
        ]),
        _reply('2'),
      ]);
      final AgentSession session = _session(llm, _Toolbox());
      await session.send('一');
      await session.send('二');
      expect(
        <String>[
          for (final AgentEntry e in session.entries)
            if (e.toolName == AgentMetaTool.planUpdate) e.text,
        ],
        <String>['[>] a', '[x] a'],
      );
    });

    test('降级协议：系统提示带 plan__update 完整 schema，JSON 动作同一管线', () async {
      final _Llm llm = _Llm(<AiChatTurn>[
        _reply(
          jsonEncode(<String, Object?>{
            'tool': 'plan__update',
            'args': plan(<(String, String)>[('a', 'active')]),
          }),
        ),
        _reply('{"reply": "ok"}'),
      ], supportsTools: false);
      final AgentSession session = _session(llm, _Toolbox());
      await session.send('整理');
      final String system = llm.requests.first.first.content;
      expect(system, contains('- plan__update: '));
      expect(system, contains('"enum":["pending","active","done"]'));
      expect(agentSystemPrompt(null), contains('plan__update'));
      expect(session.plan, const <AgentPlanItem>[
        AgentPlanItem(text: 'a', status: AgentPlanStatus.active),
      ]);
      expect(
        llm.requests.last.last.content,
        startsWith('Result of plan__update:\n<untrusted_data'),
      );
    });
  });
}
