/// 「问 AI」快捷键入口（spec `docs/specs/2026-10-26-ai-operations-agent-design.md`
/// D4 ②）：最终落到 [openAiAgent]（窄屏半屏面板 / 宽屏侧栏，没指派提供商时只引导
/// 去设置）。
///
/// 入口只留首页面板、悬浮球与本快捷键（2026-10-29 所有者拍板砍掉书架 / 视频库 /
/// 游戏库 / 阅读器 / 漫画 / 视频页顶栏的「问 AI」按钮）。模块门由
/// [openAiAgentFromShortcut] 自己判。
library;

import 'dart:async';

import 'package:fushi/src/ai/agent/ai_agent_ui_context.dart';
import 'package:fushi/src/floating_ball/floating_ball_scene.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_registry.dart' show isAiModuleEnabled;
import 'package:fushi/src/pages/implementations/ai_agent_page.dart';
import 'package:material_ui/material_ui.dart';

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
