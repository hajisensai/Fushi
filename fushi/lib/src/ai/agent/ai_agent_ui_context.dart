import 'package:fushi_engine/ai/agent/agent_session.dart';

import 'package:fushi/src/floating_ball/floating_ball_config.dart';
import 'package:fushi/src/floating_ball/floating_ball_scene.dart';

/// 悬浮球场景 → AI 助手的界面上下文（spec §6.4）：阅读器 / 漫画 = 当前书和位置，
/// 视频 = 当前作品、集数和播放时间，其它页 = 当前页签。页面经
/// [FloatingBallScene.aiContext] 给出键值，这里只做归一。
AgentUiContext aiAgentUiContextFromScene(FloatingBallSceneSnapshot? scene) {
  final String sceneName = switch (scene?.scope) {
    FloatingBallScope.reader => 'reader',
    FloatingBallScope.manga => 'manga',
    FloatingBallScope.video => 'video',
    FloatingBallScope.system => 'system',
    _ => 'general',
  };
  return aiAgentUiContextFromMap(sceneName, scene?.aiContext);
}

/// 页面键值 → AI 助手的界面上下文（悬浮球与各页顶栏「问 AI」共用这一份归一）。
///
/// [read] 是页面的上下文求值（与 [FloatingBallScene.aiContext] 同形）：`page` /
/// `itemKind` / `itemId` / `itemTitle` / `position` 落进对应字段，其余键原样进
/// [AgentUiContext.extra]。求值抛错（页面正在卸载等）按没有上下文处理——不让一个
/// 按钮因此点不开。
AgentUiContext aiAgentUiContextFromMap(
  String scene,
  Map<String, Object?> Function()? read,
) {
  final Map<String, Object?> raw = <String, Object?>{};
  try {
    raw.addAll(read?.call() ?? const <String, Object?>{});
  } on Object {
    // 页面求值失败：不带上下文也能用。
  }
  String? text(String key) {
    final Object? value = raw.remove(key);
    if (value == null) return null;
    final String s = '$value'.trim();
    return s.isEmpty ? null : s;
  }

  return AgentUiContext(
    scene: scene,
    page: text('page'),
    itemKind: text('itemKind'),
    itemId: text('itemId'),
    itemTitle: text('itemTitle'),
    position: text('position'),
    extra: raw,
  );
}
