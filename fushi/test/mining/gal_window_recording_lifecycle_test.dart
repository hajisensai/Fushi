// 滚动窗口录制（制卡「视频片段」画面）的会话生命周期对称性。
//
// 与 Magpie 超分同一条纪律（见 magpie_session_lifecycle_test.dart）：开与关由**同一个**
// 纯函数判据驱动（会话在跑 + 绑了游戏窗口），因此不存在「某条早退分支忘了停录」。
// 录制器只是锦上添花：起不来只记事件，不影响会话。

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
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
  late List<String> calls;
  late GalHookSessionController controller;

  GalHookSessionController build({bool startSucceeds = true}) =>
      GalHookSessionController(
        textService: texthooker,
        isWindows: true,
        injectorResolver: ({required bool is32Bit}) async => null,
        exe32BitProbe: (_) async => false,
        loopbackSourceFactory: _FakeLoopbackSource.new,
        windowListLoader: () async => const <ExternalWindowInfo>[],
        windowPollAttempts: 1,
        endpointListenable: endpoints,
        endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
        startWindowRecording: ({required int hwnd}) async {
          calls.add('start:$hwnd');
          return startSucceeds;
        },
        stopWindowRecording: () async {
          calls.add('stop');
        },
      );

  setUp(() {
    ExitFlushRegistry.instance.clear();
    texthooker = TexthookerService.test();
    endpoints = ChangeNotifier();
    calls = <String>[];
    controller = build();
  });

  tearDown(() {
    ExitFlushRegistry.instance.clear();
    endpoints.dispose();
  });

  group('判据（与超分同源）', () {
    test('没绑窗口 / 会话没跑 → 不录', () {
      expect(
        GalHookSessionController.windowRecordingTargetHwnd(
          const GalHookSessionState(),
        ),
        isNull,
      );
      expect(
        GalHookSessionController.windowRecordingTargetHwnd(
          const GalHookSessionState(boundWindow: kWindow),
        ),
        isNull,
      );
    });

    test('会话在跑 + 绑了窗口 → 录那个 hwnd，且与超分判据逐相等', () {
      for (final GalHookSessionPhase phase in GalHookSessionPhase.values) {
        final GalHookSessionState state = GalHookSessionState(
          boundWindow: kWindow,
          phase: phase,
        );
        expect(
          GalHookSessionController.windowRecordingTargetHwnd(state),
          GalHookSessionController.magpieUpscalingTargetHwnd(state),
          reason: '$phase：录制与超分必须共用同一条判据',
        );
      }
    });
  });

  group('开 / 关对称', () {
    test('只绑窗口不开始会话 → 不录', () async {
      await controller.bindWindow(kWindow);
      await controller.windowRecordingSettled;
      expect(calls, isEmpty);
      expect(controller.windowRecordingArmedHwnd, isNull);
    });

    test('会话跑起来才录，停下就停', () async {
      await controller.startAttachedCapture(kWindow);
      await controller.windowRecordingSettled;
      expect(calls, <String>['start:4242']);
      expect(controller.windowRecordingArmedHwnd, kWindow.hwnd);

      await controller.stopCapture();
      await controller.windowRecordingSettled;
      expect(calls, <String>['start:4242', 'stop']);
      expect(controller.windowRecordingArmedHwnd, isNull);
      expect(controller.state.boundWindow, kWindow);
    });

    test('第二局仍能重新开录（keepBinding 不吃掉开边沿）', () async {
      await controller.startAttachedCapture(kWindow);
      await controller.stopCapture();
      await controller.startAttachedCapture(kWindow);
      await controller.windowRecordingSettled;
      expect(calls, <String>['start:4242', 'stop', 'start:4242']);
    });

    test('换绑到另一个窗口 = 先停旧的再录新的', () async {
      await controller.startAttachedCapture(kWindow);
      await controller.startAttachedCapture(kOtherWindow);
      await controller.windowRecordingSettled;
      expect(calls, <String>['start:4242', 'stop', 'start:9999']);
    });

    test('close() 停录并等它停完', () async {
      await controller.startAttachedCapture(kWindow);
      await controller.close();
      expect(calls, <String>['start:4242', 'stop']);
      expect(controller.windowRecordingArmedHwnd, isNull);
    });
  });

  group('录制不可用只降级，不影响会话', () {
    test('start 返回 false → 会话照常，事件记 recording_unavailable', () async {
      controller = build(startSucceeds: false);
      await controller.startAttachedCapture(kWindow);
      await controller.windowRecordingSettled;
      expect(calls, <String>['start:4242']);
      expect(controller.state.boundWindow, kWindow);
      expect(
        controller.events.map((GalHookEvent e) => e.code),
        contains('window.recording_unavailable'),
      );
    });

    test('start 抛异常 → 同样只记事件', () async {
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
        startWindowRecording: ({required int hwnd}) async =>
            throw StateError('channel missing'),
        stopWindowRecording: () async {},
      );
      await controller.startAttachedCapture(kWindow);
      await controller.windowRecordingSettled;
      expect(
        controller.events.map((GalHookEvent e) => e.code),
        contains('window.recording_unavailable'),
      );
      expect(controller.state.phase, isNot(GalHookSessionPhase.idle));
    });
  });
}
