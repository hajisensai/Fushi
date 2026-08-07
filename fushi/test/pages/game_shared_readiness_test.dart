import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/pages/implementations/game_shared.dart';

import '../helpers/source_guard.dart';

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

    test('启动早期与停止阶段即使残留候选也不能弹窗', () {
      for (final GalHookSessionPhase phase in <GalHookSessionPhase>[
        GalHookSessionPhase.resolving,
        GalHookSessionPhase.launching,
        GalHookSessionPhase.attaching,
        GalHookSessionPhase.injecting,
        GalHookSessionPhase.stopping,
      ]) {
        expect(
          shouldPromptGalCaptureSetup(
            state: GalHookSessionState(
              phase: phase,
              sessionStartedAt: DateTime(2026, 8, 2),
            ),
            hasEngineSource: true,
            selectedTextThreadKey: null,
            textThreadCount: 2,
            sessionAlreadyPrompted: false,
          ),
          isFalse,
          reason: '$phase 尚不能安全选择线程',
        );
      }
    });
  });

  group('BUG-1452 消费端接线守卫', () {
    final String texthooker = File(
      'lib/src/pages/implementations/texthooker_page.dart',
    ).readAsStringSync();
    final String homeGame = File(
      'lib/src/pages/implementations/home_game_page.dart',
    ).readAsStringSync();

    test('工作台必须消费 readiness 并以等待卡替代句级音轨', () {
      final String monitor = topLevelFunctionBody(
        texthooker,
        '_buildMonitorBody',
      )!;
      expect(
        containsIdentifierCall(monitor, 'galWorkbenchReadiness'),
        isTrue,
      );
      expect(
        RegExp(
          r'readiness\s*==\s*GalWorkbenchReadiness\.waitingForThread\s*'
          r'\?\s*const\s+_ThreadSelectionRequiredCard\(\)\s*'
          r':\s*_LineTracksCard\s*\(',
        ).hasMatch(maskCommentsAndStrings(monitor)),
        isTrue,
        reason: '未选择线程时不能继续展示“本句音轨”工作区',
      );
    });

    test('自动弹窗必须同时受工作台子页与顶层可见性门控', () {
      final String schedule = topLevelFunctionBody(
        texthooker,
        '_maybeScheduleCaptureSetupDialog',
      )!;
      expect(containsIdentifier(schedule, 'captureSetupEnabled'), isTrue);
      expect(containsIdentifierCall(schedule, 'TickerMode.of'), isTrue);
      final String build = topLevelFunctionBody(texthooker, 'build')!;
      expect(containsIdentifierCall(build, 'TickerMode.of'), isTrue);
      expect(
        containsIdentifierCall(build, '_maybeScheduleCaptureSetupDialog'),
        isTrue,
        reason: '从隐藏顶层 tab 回到工作台时必须补调度',
      );

      final String homeBuild = topLevelFunctionBody(homeGame, 'build')!;
      expect(
        RegExp(
          r'captureSetupEnabled:\s*_section\s*==\s*GameSection\.monitor',
        ).hasMatch(maskCommentsAndStrings(homeBuild)),
        isTrue,
      );
    });

    test('等待状态必须接进会话标题、状态徽章和音轨入口门控', () {
      final String searchable = maskComments(texthooker);
      final int overviewStart = searchable.indexOf(
        'class _SessionOverviewCard',
      );
      expect(overviewStart, greaterThanOrEqualTo(0));
      final String overview = balancedBlockFrom(
        texthooker,
        overviewStart,
        what: '_SessionOverviewCard 类体',
      );
      final String overviewBuild = topLevelFunctionBody(overview, 'build')!;
      expect(
        containsIdentifier(overviewBuild, 'waitingForThread'),
        isTrue,
      );
      expect(
        containsIdentifier(overviewBuild, 'game_session_waiting_thread'),
        isTrue,
      );
      expect(
        containsIdentifier(overviewBuild, 'game_text_thread_unset'),
        isTrue,
      );

      final String toolbar = topLevelFunctionBody(
        texthooker,
        '_buildToolbarActions',
      )!;
      expect(
        RegExp(
          r'state\.isActive\s*&&\s*'
          r'_session\.selectedTextThreadKey\s*!=\s*null',
        ).hasMatch(maskCommentsAndStrings(toolbar)),
        isTrue,
        reason: '会话级音轨入口必须等到台词线程选定后才出现',
      );
    });

    test('游戏库状态带必须消费同一 readiness', () {
      final String library = topLevelFunctionBody(homeGame, '_buildLibrary')!;
      expect(
        containsIdentifierCall(library, 'galWorkbenchReadiness'),
        isTrue,
      );
      expect(
        RegExp(r'readiness:\s*readiness').hasMatch(
          maskCommentsAndStrings(library),
        ),
        isTrue,
      );

      final String searchable = maskComments(homeGame);
      final int stripStart = searchable.indexOf('class _CaptureStatusStrip');
      expect(stripStart, greaterThanOrEqualTo(0));
      final String strip = balancedBlockFrom(
        homeGame,
        stripStart,
        what: '_CaptureStatusStrip 类体',
      );
      expect(
        containsIdentifier(strip, 'GalWorkbenchReadiness.waitingForThread'),
        isTrue,
      );
      expect(
        containsIdentifierCall(strip, '_buildWaitingForThreadDetail'),
        isTrue,
      );
    });
  });
}
