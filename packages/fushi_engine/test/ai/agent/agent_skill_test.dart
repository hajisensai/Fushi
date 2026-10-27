import 'dart:collection';

import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:test/test.dart';

class _Llm implements AgentLlm {
  _Llm(List<AiChatTurn> turns) : _turns = Queue<AiChatTurn>.of(turns);

  final Queue<AiChatTurn> _turns;
  final List<List<AiChatToolSpec>> toolLists = <List<AiChatToolSpec>>[];

  @override
  bool get supportsTools => true;

  @override
  Future<AiChatTurn> chat(
    List<AiChatMessage> messages,
    List<AiChatToolSpec> tools,
  ) async {
    toolLists.add(tools);
    return _turns.isEmpty
        ? const AiChatTurn(text: 'ok', toolCalls: <AiChatToolCall>[])
        : _turns.removeFirst();
  }
}

/// 两步配方：先调一个可撤销写，再出候选卡，用户选中的那一项直接认领（不可逆，
/// 卡片即确认）；用户取消则不认领。
class _Skill implements AgentSkill {
  @override
  AgentToolSpec get spec => const AgentToolSpec(
    name: 'skill.demo',
    description: 'Demo skill.',
    parameters: <String, Object?>{'type': 'object'},
    risk: AgentToolRisk.write,
  );

  @override
  Future<Object?> run(
    AgentSkillContext context,
    Map<String, Object?> args,
  ) async {
    if (args['bad'] == true) throw const AgentSkillFailure('bad_args', 'nope');
    final AgentToolResult a = await context.call('x.set', <String, Object?>{
      'v': 1,
    });
    final String? picked = await context.askChoice(
      'which?',
      const <AgentChoiceOption>[
        AgentChoiceOption(id: 'p', label: 'P'),
        AgentChoiceOption(id: 'q', label: 'Q'),
      ],
    );
    AgentToolResult? claimed;
    if (picked != null) {
      claimed = await context.call('x.claim', <String, Object?>{
        'id': picked,
      }, userChoseThisStep: true);
    }
    return <String, Object?>{
      'set': !a.isError,
      'picked': picked,
      'claimed': claimed != null && !claimed.isError,
    };
  }
}

class _Box implements AgentToolbox, AgentSkillProvider {
  final List<String> executed = <String>[];

  static const AgentToolSpec set = AgentToolSpec(
    name: 'x.set',
    description: 'set',
    parameters: <String, Object?>{'type': 'object'},
    risk: AgentToolRisk.write,
    undoable: true,
  );
  static const AgentToolSpec claim = AgentToolSpec(
    name: 'x.claim',
    description: 'claim',
    parameters: <String, Object?>{'type': 'object'},
    risk: AgentToolRisk.irreversible,
  );

  @override
  List<AgentSkill> skills() => <AgentSkill>[_Skill()];

  @override
  List<AgentToolSpec> residentTools() => const <AgentToolSpec>[];

  @override
  List<AgentToolSpec> searchTools(String query, {int limit = 12}) =>
      const <AgentToolSpec>[];

  @override
  AgentToolSpec? describeTool(String name) => switch (name) {
    'x.set' => set,
    'x.claim' => claim,
    _ => null,
  };

  @override
  Future<AgentToolResult> execute(AgentToolInvocation invocation) async {
    executed.add('${invocation.name}${invocation.confirmed ? '!' : ''}');
    return const AgentToolResult.ok(<String, Object?>{
      'ok': true,
    }, actionId: 'a1');
  }

  @override
  Future<AgentUndoResult> undo(String actionId) async =>
      const AgentUndoResult(AgentUndoStatus.done);
}

class _Host implements AgentHost {
  _Host(this.pick);

  final String? pick;
  int confirms = 0;

  @override
  Future<bool> confirm(AgentConfirmRequest request) async {
    confirms++;
    return true;
  }

  @override
  Future<String?> askChoice(
    String prompt,
    List<AgentChoiceOption> options,
  ) async => pick;
}

AgentSession _session(_Llm llm, _Box box, _Host host) =>
    AgentSession(id: 's', llm: llm, toolbox: box, host: host);

AiChatTurn _skill(Map<String, Object?> args) => AiChatTurn(
  text: '',
  toolCalls: <AiChatToolCall>[
    AiChatToolCall(
      id: 'c1',
      name: agentWireToolName('skill.demo'),
      arguments: args,
    ),
  ],
);

void main() {
  test('技能常驻在工具表里', () async {
    final _Llm llm = _Llm(const <AiChatTurn>[]);
    await _session(llm, _Box(), _Host(null)).send('x');
    expect(
      llm.toolLists.single.map((AiChatToolSpec t) => t.name),
      contains('skill__demo'),
    );
  });

  test('步骤各自成条目、照常记账；用户在卡片上点选的那一步不再追加确认卡', () async {
    final _Box box = _Box();
    final _Host host = _Host('q');
    final AgentSession session = _session(
      _Llm(<AiChatTurn>[_skill(const <String, Object?>{})]),
      box,
      host,
    );
    await session.send('做吧');
    expect(box.executed, <String>['x.set', 'x.claim!']);
    expect(host.confirms, 0);
    final List<AgentEntry> calls = session.entries
        .where((AgentEntry e) => e.kind == AgentEntryKind.toolCall)
        .toList();
    expect(calls.map((AgentEntry e) => e.toolName), <String>[
      'skill.demo',
      'x.set',
      'x.claim',
    ]);
    expect(calls.first.status, AgentEntryStatus.done);
    expect(calls.first.resultPreview, contains('"claimed":true'));
    expect(calls[1].canUndo, isTrue);
    expect(
      session.entries.where((AgentEntry e) => e.kind == AgentEntryKind.confirm),
      isEmpty,
    );
  });

  test('用户取消候选卡：不执行那一步', () async {
    final _Box box = _Box();
    final AgentSession session = _session(
      _Llm(<AiChatTurn>[_skill(const <String, Object?>{})]),
      box,
      _Host(null),
    );
    await session.send('做吧');
    expect(box.executed, <String>['x.set']);
  });

  test('技能整体失败：汇总条目标失败，错误回给模型', () async {
    final AgentSession session = _session(
      _Llm(<AiChatTurn>[
        _skill(const <String, Object?>{'bad': true}),
      ]),
      _Box(),
      _Host(null),
    );
    await session.send('x');
    final AgentEntry entry = session.entries.firstWhere(
      (AgentEntry e) => e.toolName == 'skill.demo',
    );
    expect(
      (entry.status, entry.errorCode),
      (AgentEntryStatus.failed, 'bad_args'),
    );
  });
}
