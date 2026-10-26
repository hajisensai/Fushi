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
  final Map<String, Object?> raw = <String, Object?>{};
  try {
    raw.addAll(scene?.aiContext?.call() ?? const <String, Object?>{});
  } on Object {
    // 页面求值失败（正在卸载等）：不带上下文也能用，不让一个按钮点不开。
  }
  String? text(String key) {
    final Object? value = raw.remove(key);
    if (value == null) return null;
    final String s = '$value'.trim();
    return s.isEmpty ? null : s;
  }

  return AgentUiContext(
    scene: sceneName,
    page: text('page'),
    itemKind: text('itemKind'),
    itemId: text('itemId'),
    itemTitle: text('itemTitle'),
    position: text('position'),
    extra: raw,
  );
}
