/// 首页「AI 助手」小组件（[HomeWidgetKind.aiAgent]，spec 2026-10-26 D4 ①；首页小组件
/// 网格 2026-11-15）：「AI 助手 · 告诉 AI 要做什么…」，点了打开 AI 浮层（与悬浮球「AI」
/// 同一个入口 [openAiAgent]）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/ai/agent/ai_agent_controller.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_widget_layout.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/ai_agent_page.dart';
import 'package:fushi/src/pages/implementations/home_widget_frame.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';

/// AI 助手组件此刻可不可用（纯函数，判据的唯一实现）：AI 模块开着，且给「AI 助手」
/// 指派了可用的提供商（spec 2026-11-15「显隐语义」：未指派提供商算不可用——组件整块
/// 不渲染、也不出现在添加面板里，布局里仍保留它，配好提供商就回来）。
///
/// 旧可选面板「自动」档的判据（指派了提供商）与之相同，迁移首个布局时直接用它。
bool resolveHomeAiAgentWidgetAvailable({
  required bool moduleEnabled,
  required bool hasProvider,
}) => moduleEnabled && hasProvider;

/// [resolveHomeAiAgentWidgetAvailable] 的 Riverpod 装配。
final Provider<bool> homeAiAgentWidgetAvailableProvider = Provider<bool>((
  Ref ref,
) {
  final AppModel app = ref.watch(appProvider);
  if (!app.isPreferencesReady) return false;
  return resolveHomeAiAgentWidgetAvailable(
    moduleEnabled: app.moduleVisibility.isEnabled(ModuleId.ai),
    hasProvider: resolveAiAgentProvider(app.prefsRepo) != null,
  );
});

/// 首页 AI 助手小组件（1×1 · 2×1）。可不可用由首页按
/// [homeAiAgentWidgetAvailableProvider] 决定。
class HomeAiAgentPanel extends StatelessWidget {
  const HomeAiAgentPanel({
    super.key,
    required this.size,
    this.poster = false,
    this.dense = false,
  });

  /// 格子尺寸档。
  final HomeWidgetSize size;

  /// true = 海报色块外观。
  final bool poster;

  /// 格子很矮（窄网格一行高）。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return HomeWidgetFrame(
      key: const ValueKey<String>('home-ai-agent-panel'),
      tapKey: const ValueKey<String>('home-ai-agent-panel-open'),
      title: t.ai_agent_title,
      icon: FushiIcons.aiAssistant,
      hueKey: HomeWidgetKind.aiAgent.id,
      poster: poster,
      dense: dense,
      onTap: () => openAiAgent(context),
      child: Builder(
        builder: (BuildContext context) {
          final HomeWidgetStyle style = HomeWidgetStyle.of(context);
          final TextStyle base =
              Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            spacing: 6,
            children: <Widget>[
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.bottomStart,
                  child: Text(
                    t.ai_agent_input_hint,
                    maxLines: dense ? 2 : 3,
                    overflow: TextOverflow.ellipsis,
                    style: base.copyWith(
                      fontSize: dense ? 14 : 16,
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                      color: style.accent,
                    ),
                  ),
                ),
              ),
              FushiIcon(FushiIcons.forward, size: 20, color: style.accent),
            ],
          );
        },
      ),
    );
  }
}
