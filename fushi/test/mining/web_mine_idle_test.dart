import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/web_mine_idle.dart';

/// 空闲自动制卡调度（`web_mine_idle.dart`）与静音进程树采集的 channel 契约。
/// 判据与让位语义见 `docs/specs/2026-10-27-web-mine-idle-silent-replay.md`。
void main() {
  group('webMineInputIdleFromTicks', () {
    test('plain difference', () {
      expect(
        webMineInputIdleFromTicks(now: 10000, lastInput: 4000),
        const Duration(milliseconds: 6000),
      );
    });

    test('GetTickCount wrap-around is an unsigned difference', () {
      expect(
        webMineInputIdleFromTicks(now: 500, lastInput: 0xFFFFFF00),
        const Duration(milliseconds: 500 + 0x100),
      );
    });
  });

  group('WebMineIdleScheduler', () {
    late Duration? idle;
    late bool canStart;
    late int idleCalls;
    late int activeCalls;
    late WebMineIdleScheduler scheduler;

    WebMineIdleScheduler build() => WebMineIdleScheduler(
      inputIdle: () => idle,
      canStart: () => canStart,
      onIdle: () => idleCalls++,
      onUserActive: () => activeCalls++,
      // 计时器由测试手动 tick()，不让真 Timer 介入。
      createTimer: (Duration d, void Function() f) =>
          Timer(const Duration(days: 1), f),
    );

    setUp(() {
      idle = Duration.zero;
      canStart = true;
      idleCalls = 0;
      activeCalls = 0;
      scheduler = build();
    });

    tearDown(() => scheduler.dispose());

    test('starts only once system idle reaches the threshold', () {
      idle = kWebMineIdleThreshold - const Duration(seconds: 1);
      scheduler.tick();
      expect(idleCalls, 0);
      idle = kWebMineIdleThreshold;
      scheduler.tick();
      expect(idleCalls, 1);
      expect(scheduler.running, isTrue);
    });

    test('page conditions gate the start', () {
      idle = const Duration(minutes: 10);
      canStart = false;
      scheduler.tick();
      expect(idleCalls, 0);
      expect(scheduler.running, isFalse);
    });

    test('no idle signal (non-Windows) never starts', () {
      idle = null;
      scheduler.tick();
      expect(idleCalls, 0);
    });

    test('does not start twice while a run is in progress', () {
      idle = const Duration(minutes: 3);
      scheduler.tick();
      idle = const Duration(minutes: 4);
      scheduler.tick();
      expect(idleCalls, 1);
      expect(activeCalls, 0);
    });

    test('any input during the run (idle shrinks) yields exactly once', () {
      idle = const Duration(minutes: 3);
      scheduler.tick();
      idle = const Duration(minutes: 3, seconds: 1);
      scheduler.tick();
      expect(activeCalls, 0);
      idle = const Duration(milliseconds: 200);
      scheduler.tick();
      idle = const Duration(milliseconds: 100);
      scheduler.tick();
      expect(activeCalls, 1);
    });

    test('after runFinished it needs a full threshold again', () {
      idle = const Duration(minutes: 3);
      scheduler.tick();
      idle = const Duration(seconds: 1);
      scheduler.tick();
      scheduler.runFinished();
      expect(scheduler.running, isFalse);
      idle = const Duration(seconds: 30);
      scheduler.tick();
      expect(idleCalls, 1);
      idle = kWebMineIdleThreshold;
      scheduler.tick();
      expect(idleCalls, 2);
    });

    test('adoptRun: handoff page watches for input from the start', () {
      idle = const Duration(minutes: 3);
      scheduler.adoptRun();
      expect(scheduler.running, isTrue);
      expect(activeCalls, 0);
      idle = const Duration(milliseconds: 50);
      scheduler.tick();
      expect(activeCalls, 1);
    });

    test('adoptRun: user already back during the handoff yields at once', () {
      idle = const Duration(seconds: 3);
      scheduler.adoptRun();
      expect(activeCalls, 1);
    });

    test('disposed scheduler ignores ticks', () {
      idle = const Duration(minutes: 5);
      scheduler.dispose();
      scheduler.tick();
      expect(idleCalls, 0);
    });
  });

  group('LoopbackGalAudioSource process-tree mode', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const MethodChannel channel = LoopbackGalAudioSource.kAudioLoopbackChannel;
    final List<MethodCall> calls = <MethodCall>[];

    void mock(Future<Object?> Function(MethodCall call) h) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) {
            calls.add(call);
            return h(call);
          });
    }

    setUp(calls.clear);
    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    test('system mix keeps the argument-less start (galgame path)', () async {
      mock(
        (_) async => <String, Object?>{
          'sampleRate': 48000,
          'channels': 2,
          'bitsPerSample': 32,
          'isFloat': true,
        },
      );
      expect(await LoopbackGalAudioSource().start(), isNotNull);
      expect(calls.single.arguments, isNull);
    });

    test('silent process tree passes folder + silent', () async {
      mock(
        (_) async => <String, Object?>{
          'sampleRate': 48000,
          'channels': 2,
          'bitsPerSample': 32,
          'isFloat': true,
        },
      );
      final LoopbackGalAudioSource src = LoopbackGalAudioSource(
        userDataFolder: r'C:\Fushi\WebVideoWebView2',
        silent: true,
      );
      expect(await src.start(), isNotNull);
      expect(src.lastStartError, isNull);
      expect(calls.single.arguments, <String, Object?>{
        'userDataFolder': r'C:\Fushi\WebVideoWebView2',
        'silent': true,
      });
    });

    test('native failure code is surfaced', () async {
      mock(
        (_) async => <String, Object?>{
          'error': 'loopback start failed',
          'code': 'unsupported',
        },
      );
      final LoopbackGalAudioSource src = LoopbackGalAudioSource(
        userDataFolder: 'x',
        silent: true,
      );
      expect(await src.start(), isNull);
      expect(src.lastStartError, 'unsupported');
    });

    test('missing plugin is a distinct failure', () async {
      final LoopbackGalAudioSource src = LoopbackGalAudioSource(
        userDataFolder: 'x',
        silent: true,
      );
      expect(await src.start(), isNull);
      expect(src.lastStartError, 'missing_plugin');
    });

    test('restoreDuckedSessions forwards the folder', () async {
      mock((_) async => 2);
      expect(await LoopbackGalAudioSource.restoreDuckedSessions('udf'), 2);
      expect(calls.single.method, 'restoreDucked');
      expect(calls.single.arguments, <String, Object?>{
        'userDataFolder': 'udf',
      });
    });
  });
}
