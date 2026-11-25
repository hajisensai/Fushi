import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/home_dashboard_panel.dart';
import 'package:fushi/src/models/home_widget_layout.dart';
import 'package:fushi/src/pages/implementations/home_ai_agent_panel.dart';

/// 首页「AI 助手」小组件：可用性只看模块门（fushi/CLAUDE.md §13：未指派提供商时
/// 入口可见、点击引导去设置）；旧「自动」档判据（指派了提供商）只决定默认模板放不放。
void main() {
  test('可用性只看 AI 模块门，与有没有提供商无关', () {
    expect(resolveHomeAiAgentWidgetAvailable(moduleEnabled: false), isFalse);
    expect(resolveHomeAiAgentWidgetAvailable(moduleEnabled: true), isTrue);
  });

  test('默认模板放不放：模块开着且指派了提供商', () {
    expect(
      resolveHomeAiAgentAutoDefault(moduleEnabled: true, hasProvider: true),
      isTrue,
    );
    expect(
      resolveHomeAiAgentAutoDefault(moduleEnabled: true, hasProvider: false),
      isFalse,
    );
    expect(
      resolveHomeAiAgentAutoDefault(moduleEnabled: false, hasProvider: true),
      isFalse,
    );
  });

  test('组件 id 冻结；旧面板 id 冻结、旧显示档仍能读出（迁移用）', () {
    expect(HomeWidgetKind.aiAgent.id, 'ai_agent');
    expect(HomeDashboardPanel.aiAgent.id, 'ai_agent');
    expect(
      decodeHomeDashboardPanelModes('{"ai_agent":"hidden"}'),
      <HomeDashboardPanel, HomeDashboardPanelMode>{
        HomeDashboardPanel.aiAgent: HomeDashboardPanelMode.hidden,
      },
    );
  });
}
