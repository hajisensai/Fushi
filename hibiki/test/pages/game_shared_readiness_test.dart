import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/pages/implementations/game_shared.dart';

void main() {
  group('BUG-1452 未选择台词线程时的捕获状态', () {
    test('空闲会话保持空闲', () {
      expect(
        galWorkbenchReadiness(
          state: const GalHookSessionState(),
          hasEngineSource: false,
          selectedTextThreadKey: null,
        ),
        GalWorkbenchReadiness.idle,
      );
    });

    test('引擎和音频源已启动但未选线程时不能宣称正在监听', () {
      expect(
        galWorkbenchReadiness(
          state: const GalHookSessionState(
            phase: GalHookSessionPhase.running,
            audioBackend: GalHookAudioBackend.systemLoopback,
          ),
          hasEngineSource: true,
          selectedTextThreadKey: null,
        ),
        GalWorkbenchReadiness.waitingForThread,
      );
    });

    test('选定线程后才进入正在监听', () {
      expect(
        galWorkbenchReadiness(
          state: const GalHookSessionState(
            phase: GalHookSessionPhase.running,
            audioBackend: GalHookAudioBackend.systemLoopback,
          ),
          hasEngineSource: true,
          selectedTextThreadKey: 'pid:thread:hook',
        ),
        GalWorkbenchReadiness.listening,
      );
    });

    test('无引擎的 WebSocket 会话维持原有无需选线程的监听语义', () {
      expect(
        galWorkbenchReadiness(
          state: const GalHookSessionState(
            phase: GalHookSessionPhase.running,
          ),
          hasEngineSource: false,
          selectedTextThreadKey: null,
        ),
        GalWorkbenchReadiness.listening,
      );
    });
  });

  group('游戏启动后的捕获设置弹窗', () {
    const GalHookSessionState active = GalHookSessionState(
      phase: GalHookSessionPhase.running,
      sessionStartedAt: null,
    );
    final GalHookSessionState launched = active.copyWith(
      sessionStartedAt: DateTime(2026, 8, 2),
    );

    test('发现候选线程且尚未选择时提示', () {
      expect(
        shouldPromptGalCaptureSetup(
          state: launched,
          hasEngineSource: true,
          selectedTextThreadKey: null,
          textThreadCount: 2,
          sessionAlreadyPrompted: false,
        ),
        isTrue,
      );
    });

    test('没有候选、已经选择或本轮已经提示时均不重复弹窗', () {
      bool prompt({
        String? selected,
        int count = 2,
        bool shown = false,
      }) =>
          shouldPromptGalCaptureSetup(
            state: launched,
            hasEngineSource: true,
            selectedTextThreadKey: selected,
            textThreadCount: count,
            sessionAlreadyPrompted: shown,
          );

      expect(prompt(count: 0), isFalse);
      expect(prompt(selected: 'pid:thread:hook'), isFalse);
      expect(prompt(shown: true), isFalse);
    });
  });
}
