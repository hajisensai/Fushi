/// 首页「AI 助手」入口条（[HomeDashboardPanel.aiAgent]，spec 2026-10-26 D4 ①）：
/// 一行「AI 助手 · 告诉 AI 要做什么…」，点了打开 AI 浮层（与悬浮球「AI」同一个入口
/// [openAiAgent]）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/ai/agent/ai_agent_controller.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_dashboard_panel.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/ai_agent_page.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// AI 助手条该不该出现在首页（纯函数，判据的唯一实现）。
///
/// - AI 模块关着：恒不显示。
/// - 用户钉了显示 / 隐藏：照办（钉了显示但没指派提供商时照样出，点了引导去设置）。
/// - 自动：给「AI 助手」指派了可用的提供商才出（没配 AI 的人首页不多一栏）。
bool resolveHomeAiAgentPanelVisible({
  required bool moduleEnabled,
  required HomeDashboardPanelMode mode,
  required bool hasProvider,
}) {
  if (!moduleEnabled) return false;
  return switch (mode) {
    HomeDashboardPanelMode.shown => true,
    HomeDashboardPanelMode.hidden => false,
    HomeDashboardPanelMode.auto => hasProvider,
  };
}

/// [resolveHomeAiAgentPanelVisible] 的 Riverpod 装配。
final Provider<bool> homeAiAgentPanelVisibleProvider = Provider<bool>((
  Ref ref,
) {
  final AppModel app = ref.watch(appProvider);
  if (!app.isPreferencesReady) return false;
  return resolveHomeAiAgentPanelVisible(
    moduleEnabled: app.moduleVisibility.isEnabled(ModuleId.ai),
    mode: app.homeDashboardPanelMode(HomeDashboardPanel.aiAgent),
    hasProvider: resolveAiAgentProvider(app.prefsRepo) != null,
  );
});

/// 首页 AI 助手条。显隐由 dashboard 按 [homeAiAgentPanelVisibleProvider] 决定。
class HomeAiAgentPanel extends StatelessWidget {
  const HomeAiAgentPanel({super.key});

  static const double rowHeight = 44;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool apple = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final BorderRadius radius = apple
        ? FushiAppleMetrics.of(context).groupBorderRadius
        : FushiBorderRadius.card;
    final Color fill = apple
        ? appleColorsOf(context).secondaryGroupedBackground
        : tokens.surfaces.group;
    return FushiHoverLift(
      scale: 1.01,
      builder: (BuildContext context, bool hovering) => FushiPressScale(
        child: Material(
          key: const ValueKey<String>('home-ai-agent-panel'),
          color: fill,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: eink
                ? BorderSide(color: tokens.surfaces.outline)
                : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const ValueKey<String>('home-ai-agent-panel-open'),
            onTap: () => openAiAgent(context),
            child: Padding(
              padding: EdgeInsetsDirectional.fromSTEB(
                tokens.spacing.gap + 4,
                tokens.spacing.gap / 2,
                tokens.spacing.gap + 4,
                tokens.spacing.gap / 2,
              ),
              child: SizedBox(
                height: rowHeight,
                child: Row(
                  children: <Widget>[
                    FushiIcon(
                      FushiIcons.aiAssistant,
                      size: 18,
                      color: tokens.type.sectionLabel.color,
                    ),
                    SizedBox(width: tokens.spacing.gap / 2),
                    Text(
                      t.ai_agent_title,
                      maxLines: 1,
                      style: tokens.type.sectionLabel,
                    ),
                    SizedBox(width: tokens.spacing.gap),
                    Expanded(
                      child: Text(
                        t.ai_agent_input_hint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tokens.type.metadata,
                      ),
                    ),
                    FushiIcon(
                      FushiIcons.forward,
                      size: 18,
                      color: tokens.type.metadata.color,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
