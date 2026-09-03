// Magpie 窗口超分的**会话生命周期对称性**（PR#430 审查修复）。
//
// 审查判定的三条 FAIL 是同一个根因：开挂在 `_setState` 的状态跃迁上、关挂在
// `stopCapture` / `close` 的方法调用点上，两边判据不同源。本文件按「同一个判据驱动
// 开与关」的修法逐条咬住：
//   1. 正常退出不留孤儿（退出链登记 + close 收干净）
//   2. `stopCapture` 的 idle 早退分支也不会漏关
//   3. 第二局起仍能拉起（keepBinding: true 保留 boundWindow 不再让开边沿消失）

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/magpie_upscaling.dart';
import 'package:fushi/src/mining/magpie_upscaling_service.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/startup/exit_flush_registry.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/sync/texthooker_ws_client.dart';

const ExternalWindowInfo kWindow = ExternalWindowInfo(
  hwnd: 4242,
  pid: 777,
  title: 'Sakura',
);

const ExternalWindowInfo kOtherWindow = ExternalWindowInfo(
  hwnd: 9999,
  pid: 778,
  title: 'Another',
);

/// 只记调用、不碰任何真实 Magpie 的替身。继承而不是新造接口：会话侧的注入点签名
/// 就是 [MagpieUpscalingService]，替身与生产同型才谈得上「咬住的是真实契约」。
class _RecordingMagpie extends MagpieUpscalingService {
  _RecordingMagpie()
      : super(
          modeReader: () => MagpieUpscalingMode.off,
          isWindowsOverride: false,
        );

  final List<String> calls = <String>[];

  @override
  Future<void> onGameWindowReady({required int hwnd}) async {
    calls.add('ready:$hwnd');
  }

  @override
  Future<void> onSessionEnded({bool urgent = false}) async {
    calls.add(urgent ? 'ended:urgent' : 'ended');
  }
}

class _FakeLoopbackSource extends LoopbackGalAudioSource {
  @override
  Future<PcmFormat?> start() async => const PcmFormat(
        sampleRate: 44100,
        channels: 2,
        bitsPerSample: 32,
        isFloat: true,
      );

  @override
  Future<void> stop() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TexthookerService texthooker;
  late ChangeNotifier endpoints;
  late _RecordingMagpie magpie;
  late GalHookSessionController controller;

  setUp(() {
    // 退出注册表是进程级单例：每个用例从干净状态开始，否则计数会被别的用例污染。
    ExitFlushRegistry.instance.clear();
    texthooker = TexthookerService.test();
    endpoints = ChangeNotifier();
    magpie = _RecordingMagpie();
    controller = GalHookSessionController(
      textService: texthooker,
      isWindows: true,
      injectorResolver: ({required bool is32Bit}) async => null,
      exe32BitProbe: (_) async => false,
      loopbackSourceFactory: _FakeLoopbackSource.new,
      windowListLoader: () async => const <ExternalWindowInfo>[],
      windowPollAttempts: 1,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );
    controller.attachMagpieUpscaling(magpie);
  });

  tearDown(() {
    ExitFlushRegistry.instance.clear();
    endpoints.dispose();
  });

  group('判据本身（开与关唯一的共同事实）', () {
    test('没绑窗口 / 会话没跑 → 没有超分目标', () {
      expect(
        GalHookSessionController.magpieUpscalingTargetHwnd(
          const GalHookSessionState(),
        ),
        isNull,
      );
      // 只在窗口列表里选中一个窗口（phase 仍 idle）不算「在玩」。
      expect(
        GalHookSessionController.magpieUpscalingTargetHwnd(
          const GalHookSessionState(boundWindow: kWindow),
        ),
        isNull,
      );
    });

    test('会话在跑 + 绑了窗口 → 目标就是那个 hwnd', () {
      for (final GalHookSessionPhase phase in <GalHookSessionPhase>[
        GalHookSessionPhase.resolving,
        GalHookSessionPhase.injecting,
        GalHookSessionPhase.running,
        GalHookSessionPhase.degraded,
        GalHookSessionPhase.stopping,
      ]) {
        expect(
          GalHookSessionController.magpieUpscalingTargetHwnd(
            GalHookSessionState(boundWindow: kWindow, phase: phase),
          ),
          kWindow.hwnd,
          reason: '$phase 时会话是活的，超分该挂着',
        );
      }
    });
  });

  group('开 / 关对称', () {
    test('只绑窗口不开始会话 → 一个字节都不动用户的显示', () async {
      await controller.bindWindow(kWindow);
      await controller.magpieUpscalingSettled;
      expect(magpie.calls, isEmpty);
      expect(controller.magpieArmedHwnd, isNull);
    });

    test('会话跑起来才挂超分，停下就关（同一判据驱动）', () async {
      await controller.startAttachedCapture(kWindow);
      await controller.magpieUpscalingSettled;
      expect(magpie.calls, <String>['ready:4242']);
      expect(controller.magpieArmedHwnd, kWindow.hwnd);

      await controller.stopCapture();
      await controller.magpieUpscalingSettled;
      expect(magpie.calls, <String>['ready:4242', 'ended']);
      expect(controller.magpieArmedHwnd, isNull);
      // keepBinding 默认 true：窗口绑定还在，但超分已经关了 —— 旧实现正是把
      // 「还绑着」当成「还挂着」，第二局的开边沿因此永不发生。
      expect(controller.state.boundWindow, kWindow);
    });

    test('🔴 第二局仍能拉起（keepBinding 保留 boundWindow 不再吃掉开边沿）', () async {
      await controller.startAttachedCapture(kWindow);
      await controller.stopCapture();
      await controller.startAttachedCapture(kWindow);
      await controller.magpieUpscalingSettled;
      expect(
        magpie.calls,
        <String>['ready:4242', 'ended', 'ready:4242'],
        reason: '第二局必须重新拉起超分，而不是静默失效',
      );
      expect(controller.magpieArmedHwnd, kWindow.hwnd);
    });

    test('🔴 stopCapture 的 idle 早退分支也不留孤儿', () async {
      await controller.startAttachedCapture(kWindow);
      await controller.stopCapture();
      await controller.magpieUpscalingSettled;
      expect(magpie.calls, <String>['ready:4242', 'ended']);

      // 第二次 stopCapture 命中 phase == idle && _audioSource == null 早退分支。
      // 旧实现在这条分支上 return 得比通知结束还早；现在判据已经是「没挂」，
      // 既不会重复关，也不可能漏关。
      await controller.stopCapture();
      await controller.magpieUpscalingSettled;
      expect(magpie.calls, <String>['ready:4242', 'ended']);
      expect(controller.magpieArmedHwnd, isNull);
    });

    test('换绑到另一个窗口 = 先关旧的再开新的（顺序不能乱）', () async {
      await controller.startAttachedCapture(kWindow);
      await controller.startAttachedCapture(kOtherWindow);
      await controller.magpieUpscalingSettled;
      expect(magpie.calls, <String>['ready:4242', 'ended', 'ready:9999']);
    });
  });

  group('正常退出不留孤儿', () {
    test('注入即登记退出清理（桌面点 X 直接快杀，没人会调 close）', () {
      expect(ExitFlushRegistry.instance.callbackCount, 1);
      // 重复注入不该登记第二遍。
      controller.attachMagpieUpscaling(magpie);
      expect(ExitFlushRegistry.instance.callbackCount, 1);
    });

    test('🔴 flushAll 真的把超分关掉，而且是 urgent（退出链每个来源只有 2s）', () async {
      await controller.startAttachedCapture(kWindow);
      await controller.magpieUpscalingSettled;
      expect(magpie.calls, <String>['ready:4242']);

      await ExitFlushRegistry.instance.flushAll();
      expect(magpie.calls, <String>['ready:4242', 'ended:urgent']);
      expect(controller.magpieArmedHwnd, isNull);
    });

    test('没挂过超分时退出清理是零成本空操作', () async {
      await ExitFlushRegistry.instance.flushAll();
      expect(magpie.calls, isEmpty);
    });

    test('close() 收干净并注销退出回调（不留悬垂闭包）', () async {
      await controller.startAttachedCapture(kWindow);
      await controller.close();
      expect(magpie.calls, <String>['ready:4242', 'ended:urgent']);
      expect(ExitFlushRegistry.instance.callbackCount, 0);
    });
  });
}
