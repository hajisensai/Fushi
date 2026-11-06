import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/home_dashboard_panel.dart';
import 'package:fushi/src/pages/implementations/home_ai_agent_panel.dart';

/// 首页「AI 助手」条的显隐判据（spec 2026-10-26 D4 ①）。
void main() {
  test('AI 模块关着：恒不显示（钉了显示也不出）', () {
    for (final HomeDashboardPanelMode mode in HomeDashboardPanelMode.values) {
      expect(
        resolveHomeAiAgentPanelVisible(
          moduleEnabled: false,
          mode: mode,
          hasProvider: true,
        ),
        isFalse,
      );
    }
  });

  test('自动：指派了提供商才出；钉了显示 / 隐藏照办', () {
    bool visible(HomeDashboardPanelMode mode, bool hasProvider) =>
        resolveHomeAiAgentPanelVisible(
          moduleEnabled: true,
          mode: mode,
          hasProvider: hasProvider,
        );
    expect(visible(HomeDashboardPanelMode.auto, true), isTrue);
    expect(visible(HomeDashboardPanelMode.auto, false), isFalse);
    expect(visible(HomeDashboardPanelMode.shown, false), isTrue);
    expect(visible(HomeDashboardPanelMode.hidden, true), isFalse);
  });

  test('面板 id 冻结、能往返持久化', () {
    expect(HomeDashboardPanel.aiAgent.id, 'ai_agent');
    final String json = encodeHomeDashboardPanelModes(
      <HomeDashboardPanel, HomeDashboardPanelMode>{
        HomeDashboardPanel.aiAgent: HomeDashboardPanelMode.hidden,
      },
    );
    expect(json, '{"ai_agent":"hidden"}');
    expect(
      decodeHomeDashboardPanelModes(json),
      <HomeDashboardPanel, HomeDashboardPanelMode>{
        HomeDashboardPanel.aiAgent: HomeDashboardPanelMode.hidden,
      },
    );
  });
}
