import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/agent/ai_agent_ui_context.dart';
import 'package:fushi/src/floating_ball/floating_ball_config.dart';
import 'package:fushi/src/floating_ball/floating_ball_scene.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';
import 'package:fushi_engine/ai/agent/agent_session.dart';

/// 悬浮球「AI」按钮（spec `docs/specs/2026-10-26-ai-operations-agent-design.md` §6.4）。
void main() {
  const FloatingBallGlobalAction ai = FloatingBallGlobalAction.ai;

  test('四个应用内场景默认放进按钮组，应用外球默认不勾', () {
    expect(FloatingBallGlobalAction.fromStorage('ai'), ai);
    for (final FloatingBallScope scope in <FloatingBallScope>[
      FloatingBallScope.general,
      FloatingBallScope.reader,
      FloatingBallScope.manga,
      FloatingBallScope.video,
    ]) {
      expect(ai.onByDefaultIn(scope), isTrue, reason: scope.name);
      expect(scope.defaultButtons, contains('ai'), reason: scope.name);
    }
    expect(ai.onByDefaultIn(FloatingBallScope.system), isFalse);
    expect(FloatingBallScope.system.defaultButtons, isNot(contains('ai')));
  });

  test('任何场景、任何平台都能放（应用外球也能自己勾上）', () {
    for (final (bool android, bool ios, bool desktop) in <(bool, bool, bool)>[
      (true, false, false),
      (false, true, false),
      (false, false, true),
    ]) {
      expect(ai.availableOn(isAndroid: android, isIOS: ios), isTrue);
      for (final FloatingBallScope scope in FloatingBallScope.values) {
        expect(
          ai.availableIn(
            scope,
            isAndroid: android,
            isIOS: ios,
            isDesktop: desktop,
            lookupModuleEnabled: false,
          ),
          isTrue,
          reason: '$scope android=$android ios=$ios desktop=$desktop',
        );
      }
    }
  });

  test('可以设成 Android 应用外球「点一下直达」', () {
    expect(FloatingBallTapAction.fromStorage('ai'), FloatingBallTapAction.ai);
  });

  test('场景上下文：页面给的键归一成 AgentUiContext，其余进 extra', () {
    final AgentUiContext context = aiAgentUiContextFromScene(
      FloatingBallSceneSnapshot(
        scope: FloatingBallScope.video,
        actions: const <String, ReaderHeaderAction>{},
        hidesBall: false,
        aiContext: () => <String, Object?>{
          'itemKind': 'episode',
          'itemId': 'book-1',
          'itemTitle': '  ぼっち・ざ・ろっく！ 第3話 ',
          'position': '12:30',
          'episode': 3,
          'page': '',
        },
      ),
    );
    expect(context.scene, 'video');
    expect(context.itemId, 'book-1');
    expect(context.itemTitle, 'ぼっち・ざ・ろっく！ 第3話');
    expect(context.page, isNull);
    expect(context.toJson()['episode'], 3);
  });

  test('没有场景 / 页面求值失败：退回 general，不抛', () {
    expect(aiAgentUiContextFromScene(null).scene, 'general');
    final AgentUiContext broken = aiAgentUiContextFromScene(
      FloatingBallSceneSnapshot(
        scope: FloatingBallScope.reader,
        actions: const <String, ReaderHeaderAction>{},
        hidesBall: false,
        aiContext: () => throw StateError('disposed'),
      ),
    );
    expect(broken.scene, 'reader');
    expect(broken.itemId, isNull);
  });
}
