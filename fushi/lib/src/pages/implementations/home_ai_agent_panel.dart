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
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';

/// AI 助手组件此刻可不可用（纯函数，判据的唯一实现）：只看 AI 模块门。
///
/// 未指派提供商**不算**不可用（fushi/CLAUDE.md §13：入口可见，点击引导去设置）——
/// 组件照常渲染，点了走 [openAiAgent]，由它提示并引导去「设置 › AI」，不发请求。
bool resolveHomeAiAgentWidgetAvailable({required bool moduleEnabled}) =>
    moduleEnabled;

/// [resolveHomeAiAgentWidgetAvailable] 的 Riverpod 装配。
final Provider<bool> homeAiAgentWidgetAvailableProvider = Provider<bool>((
  Ref ref,
) {
  final AppModel app = ref.watch(appProvider);
  if (!app.isPreferencesReady) return false;
  return resolveHomeAiAgentWidgetAvailable(
    moduleEnabled: app.moduleVisibility.isEnabled(ModuleId.ai),
  );
});

/// 旧可选面板「自动」档的判据（迁移首个布局 / 恢复默认时决定默认模板放不放 AI
/// 助手）：模块开着且给「AI 助手」指派了可用的提供商。只影响默认放不放，不影响
/// 已放上的组件显不显示。
bool resolveHomeAiAgentAutoDefault({
  required bool moduleEnabled,
  required bool hasProvider,
}) => moduleEnabled && hasProvider;

/// [resolveHomeAiAgentAutoDefault] 的 Riverpod 装配。
final Provider<bool> homeAiAgentAutoDefaultProvider = Provider<bool>((Ref ref) {
  final AppModel app = ref.watch(appProvider);
  if (!app.isPreferencesReady) return false;
  return resolveHomeAiAgentAutoDefault(
    moduleEnabled: app.moduleVisibility.isEnabled(ModuleId.ai),
    hasProvider: resolveAiAgentProvider(app.prefsRepo) != null,
  );
});

/// 首页 AI 助手小组件（1×1…3×2，提示文字按格子高度放几行）。可不可用由首页按
/// [homeAiAgentWidgetAvailableProvider] 决定。
class HomeAiAgentPanel extends StatelessWidget {
  const HomeAiAgentPanel({super.key, this.poster = false});

  /// true = 海报色块外观。
  final bool poster;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final bool dense = homeWidgetIsDense(c.maxHeight);
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
              final FushiTypography type = context.fushiType;
              final TextStyle hintStyle =
                  (dense ? type.bodyMedium : type.bodyLarge).copyWith(
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                    color: style.accent,
                  );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                spacing: 6,
                children: <Widget>[
                  Expanded(
                    child: LayoutBuilder(
                      builder: (BuildContext context, BoxConstraints box) =>
                          Align(
                            alignment: AlignmentDirectional.bottomStart,
                            child: Text(
                              t.ai_agent_input_hint,
                              // 格子越高放越多行；按行高算，不溢出。
                              maxLines: homeWidgetLinesFor(
                                box.maxHeight,
                                homeWidgetLineHeight(context, hintStyle),
                                max: 6,
                              ),
                              overflow: TextOverflow.ellipsis,
                              style: hintStyle,
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
      },
    );
  }
}
