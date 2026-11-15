import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/home_dashboard_panel.dart';
import 'package:fushi/src/models/home_widget_layout.dart';
import 'package:fushi/src/pages/implementations/home_ai_agent_panel.dart';

/// 首页「AI 助手」小组件的可用性判据（spec 2026-11-15「显隐语义」，沿用
/// 2026-10-26 D4 ① 的「模块开着且指派了提供商」）。
void main() {
  test('AI 模块关着：不可用（有提供商也不行）', () {
    expect(
      resolveHomeAiAgentWidgetAvailable(
        moduleEnabled: false,
        hasProvider: true,
      ),
      isFalse,
    );
  });

  test('模块开着：指派了提供商才可用', () {
    expect(
      resolveHomeAiAgentWidgetAvailable(moduleEnabled: true, hasProvider: true),
      isTrue,
    );
    expect(
      resolveHomeAiAgentWidgetAvailable(
        moduleEnabled: true,
        hasProvider: false,
      ),
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
