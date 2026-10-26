/// 「问 AI」入口（spec `docs/specs/2026-10-26-ai-operations-agent-design.md`
/// D4 ②③）：各页顶栏按钮与全局快捷键共用的打开方式，最终都落到
/// [openAiAgent]（窄屏半屏面板 / 宽屏侧栏，没指派提供商时只引导去设置）。
///
/// 模块门：阅读器 / 漫画 / 视频页的顶栏入口由调用方渲染前问 `isAiModuleEnabled`
/// （守卫 `test/models/ai_module_gate_guard_test.dart` 按 [openAiAgentForPage] 接线点
/// 反向枚举）；库页按钮 [aiAgentAskHeaderActions] 与快捷键执行面
/// [openAiAgentFromShortcut] 自己判。
library;

import 'dart:async';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/agent/ai_agent_ui_context.dart';
import 'package:fushi/src/floating_ball/floating_ball_scene.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart' show ModuleVisibility;
import 'package:fushi/src/models/module_registry.dart' show isAiModuleEnabled;
import 'package:fushi/src/pages/implementations/ai_agent_page.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// 顶栏「问 AI」按钮的 key（测试 / 焦点驱动定位用）。
const ValueKey<String> kAiAgentAskKey = ValueKey<String>('ai-agent-ask');

/// 「问 AI」的图标（各页顶栏同一枚）。
const IconData kAiAgentAskIcon = FushiIcons.aiAssistant;

/// 「问 AI」的 tooltip / 无障碍名 / 收进「⋯」后的菜单文字。
String get aiAgentAskLabel => t.ai_agent_ask_action;

/// 顶栏「问 AI」：用页面给的上下文打开 AI 浮层。[scene] 是 `reader` / `manga` /
/// `video` / `general`；[read] 与悬浮球的 `FloatingBallScene.aiContext` 同形
/// （阅读器 / 漫画 / 视频页直接传同一个方法，库页只给 `page`）。
void openAiAgentForPage(
  BuildContext context, {
  required String scene,
  Map<String, Object?> Function()? read,
}) {
  unawaited(
    openAiAgent(context, uiContext: aiAgentUiContextFromMap(scene, read)),
  );
}

/// 库页页头（书架 / 视频库 / 游戏库）的「问 AI」：一颗 [FushiIconButton]，
/// `overflowPriority` 低于页头里所有既有动作（它们最低是 5）= 宽度不够时最先
/// 收进「⋯」（页头动作体系 `fushiResolveHeaderActions`，默认平铺、放不下才收）。
/// AI 模块关着时返回空列表——调用方直接 `...` 展开，不用自己再判门。
List<Widget> aiAgentAskHeaderActions(
  BuildContext context, {
  required ModuleVisibility visibility,
  required String page,
}) => <Widget>[
  if (isAiModuleEnabled(visibility))
    FushiIconButton(
      key: kAiAgentAskKey,
      tooltip: aiAgentAskLabel,
      label: aiAgentAskLabel,
      icon: kAiAgentAskIcon,
      overflowPriority: -10,
      onTap: () => openAiAgentForPage(
        context,
        scene: 'general',
        read: () => <String, Object?>{'page': page},
      ),
    ),
];

/// 全局快捷键「呼出 AI 助手」的执行面（`main.dart` 装配进
/// `wrapWithGlobalNavigation`）：按当前悬浮球场景带上下文打开 AI 浮层，返回这次
/// 按键是否被认领。
///
/// - AI 模块关着 → false（按键照常冒泡，不吞键）；
/// - 浮层 / 整页已经开着 → true 但不再开第二层（焦点在输入框里按 Ctrl+J 也会冒泡
///   到 app 根）；
/// - 导航还没起来 → false。
bool openAiAgentFromShortcut(AppModel appModel) {
  if (!isAiModuleEnabled(appModel.moduleVisibility)) return false;
  if (AiAgentConversation.openCount > 0) return true;
  final BuildContext? context = appModel.navigatorKey.currentContext;
  if (context == null) return false;
  unawaited(
    openAiAgent(
      context,
      uiContext: aiAgentUiContextFromScene(
        FloatingBallSceneRegistry.instance.current,
      ),
    ),
  );
  return true;
}
