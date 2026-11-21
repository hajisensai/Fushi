import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:test/test.dart';

void main() {
  test('首次确认过的不可逆工具不再要确认卡；没确认过照旧要', () {
    const AgentToolSpec fresh = AgentToolSpec(
      name: 'web.search',
      description: 'd',
      parameters: <String, Object?>{'type': 'object'},
      risk: AgentToolRisk.irreversible,
    );
    expect(fresh.needsConfirmation, isTrue);
    expect(fresh.toJson().containsKey('preapproved'), isFalse);

    const AgentToolSpec granted = AgentToolSpec(
      name: 'web.search',
      description: 'd',
      parameters: <String, Object?>{'type': 'object'},
      risk: AgentToolRisk.irreversible,
      preapproved: true,
    );
    expect(granted.needsConfirmation, isFalse);
    // 远端执行时 spec 走 JSON：长期同意跟着过去，不丢也不凭空出现。
    expect(AgentToolSpec.fromJson(granted.toJson()).needsConfirmation, isFalse);
    expect(AgentToolSpec.fromJson(fresh.toJson()).needsConfirmation, isTrue);
  });
}
