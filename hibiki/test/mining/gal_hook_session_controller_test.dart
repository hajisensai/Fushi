import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/mining/galgame_audio_encode.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/src/sync/texthooker_ws_client.dart';

void main() {
  test('window binding is app-level state and stop keeps binding by default',
      () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final GalHookSessionController controller = GalHookSessionController(
      textService: service,
      isWindows: false,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );
    const ExternalWindowInfo window = ExternalWindowInfo(
      hwnd: 77,
      pid: 1234,
      title: 'Test Game',
    );

    await controller.bindWindow(window);
    expect(controller.state.boundWindow, window);
    expect(controller.state.gamePid, 1234);
    expect(
      controller.events.map((event) => event.code),
      contains('window.bound'),
    );

    await controller.stopCapture();
    expect(controller.state.phase, GalHookSessionPhase.idle);
    expect(controller.state.boundWindow, window);

    await controller.close();
    endpoints.dispose();
  });

  test('new external line is observed after the text ring buffer is full',
      () async {
    final TexthookerService service = TexthookerService.test();
    for (int i = 0; i < TexthookerService.maxLines; i++) {
      service.appendLine('line $i');
    }
    final ChangeNotifier endpoints = ChangeNotifier();
    final GalHookSessionController controller = GalHookSessionController(
      textService: service,
      isWindows: false,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );
    expect(controller.state.hasText, isTrue);

    service.appendLine(
      'newest',
      source: TexthookerLineSource.websocket,
      sourceLabel: 'ws://localhost:6677',
    );

    expect(service.entries, hasLength(TexthookerService.maxLines));
    expect(
      controller.events.map((event) => event.code),
      contains('text.external_line_received'),
    );

    await controller.close();
    endpoints.dispose();
  });

  test('captureAudioBytes asks paired voice even without a text timestamp',
      () async {
    final TexthookerService service = TexthookerService.test();
    final TexthookerLineEntry entry = service.appendLine('siglus line')!;
    final ChangeNotifier endpoints = ChangeNotifier();
    final _FakeEngineSource engine = _FakeEngineSource(
      pairedBytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
    );
    final GalHookSessionController controller = GalHookSessionController(
      textService: service,
      isWindows: true,
      exe32BitProbe: (_) async => true,
      injectorResolver: ({required bool is32Bit}) => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
      }) =>
          engine,
      windowListLoader: () async => const <ExternalWindowInfo>[],
      windowPollAttempts: 1,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    expect(await controller.launchGame(r'D:\anemoi\SiglusEngine.exe'), isTrue);
    final Uint8List? bytes = await controller.captureAudioBytes(
      lineId: entry.id,
      sentence: entry.text,
      outputExtension: 'aac',
    );

    expect(bytes, <int>[1, 2, 3, 4]);
    expect(engine.pairedTimestamps, <int>[0]);
    expect(
        service.entries.single.audioStatus, TexthookerLineAudioStatus.encoded);
    expect(service.entries.single.audioBackend, 'game_resource');

    await controller.close();
    endpoints.dispose();
  });

  test('launchGame passes Luna PC hooks for manosaba Unity target', () async {
    final Directory dir =
        await Directory.systemTemp.createTemp('gal_manosaba_');
    final File exe = File('${dir.path}${Platform.pathSeparator}manosaba.exe');
    await exe.writeAsBytes(<int>[0], flush: true);
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _FakeEngineSource engine = _FakeEngineSource(
      pairedBytes: Uint8List(0),
    );
    bool? capturedLunaPcHooks;
    final GalHookSessionController controller = GalHookSessionController(
      textService: service,
      isWindows: true,
      exe32BitProbe: (_) async => false,
      injectorResolver: ({required bool is32Bit}) => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
      }) {
        capturedLunaPcHooks = lunaPcHooks;
        return engine;
      },
      windowListLoader: () async => const <ExternalWindowInfo>[],
      windowPollAttempts: 1,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    try {
      expect(await controller.launchGame(exe.path), isTrue);
      expect(capturedLunaPcHooks, isTrue);
      final GalHookEvent launch = controller.events.firstWhere(
        (GalHookEvent event) => event.code == 'game.launch_started',
      );
      expect(launch.details['lunaPcHooks'], isTrue);
      expect(launch.details['arch'], 'x64');
    } finally {
      await controller.close();
      endpoints.dispose();
      if (dir.existsSync()) await dir.delete(recursive: true);
    }
  });

  test('text-only engine hook stays active with loopback audio fallback',
      () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _FakeEngineSource engine = _FakeEngineSource(
      pairedBytes: Uint8List(0),
      audioFormat: null,
      textReady: true,
      polledLines: const <GalHookedLine>[
        GalHookedLine(
          seq: 1,
          timestampMs: 123456,
          text: 'やめろ化け物め！',
          threadId: 99,
          hookName: 'Unity',
        ),
      ],
    );
    final _FakeLoopbackSource loopback = _FakeLoopbackSource();
    final GalHookSessionController controller = GalHookSessionController(
      textService: service,
      isWindows: true,
      targetWow64Probe: (_) async => false,
      injectorResolver: ({required bool is32Bit}) => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
      }) =>
          engine,
      loopbackSourceFactory: () => loopback,
      textPollInterval: const Duration(milliseconds: 5),
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 7, pid: 19332, title: 'manosaba'),
    );

    expect(controller.state.phase, GalHookSessionPhase.degraded);
    expect(controller.state.audioBackend, GalHookAudioBackend.systemLoopback);
    expect(controller.state.fallbackReason, 'engine_pcm_unavailable');
    expect(engine.stopCalls, 0,
        reason: 'text helper must remain alive when only engine PCM is absent');
    expect(loopback.startCalls, 1);
    expect(await controller.selectTextThread(99), isTrue,
        reason: 'retained engine helper must still accept Luna thread choices');

    for (int i = 0; i < 20 && service.entries.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(service.entries, hasLength(1));
    expect(service.entries.single.text, 'やめろ化け物め！');
    expect(
      service.entries.single.audioStatus,
      TexthookerLineAudioStatus.fallback,
      reason: 'loopback availability must not be mislabeled as no audio',
    );
    expect(service.entries.single.audioBackend, 'system_loopback');

    await controller.close();
    expect(engine.stopCalls, 1);
    expect(loopback.stopCalls, 1);
    endpoints.dispose();
  });

  test('resource voice is primary while loopback remains a fallback', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _FakeEngineSource engine = _FakeEngineSource(
      pairedBytes: Uint8List.fromList(<int>[7, 8, 9]),
      rawReady: true,
      pairedCandidate: true,
      polledLines: const <GalHookedLine>[
        GalHookedLine(
          seq: 1,
          timestampMs: 609653421,
          text: '「ひょ、とっ、ほあたぁ！」',
          threadId: 5,
          hookName: 'SiglusEngine exact',
        ),
      ],
    );
    final _FakeLoopbackSource loopback = _FakeLoopbackSource();
    final GalHookSessionController controller = GalHookSessionController(
      textService: service,
      isWindows: true,
      targetWow64Probe: (_) async => true,
      injectorResolver: ({required bool is32Bit}) => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
      }) =>
          engine,
      loopbackSourceFactory: () => loopback,
      textPollInterval: const Duration(milliseconds: 5),
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 9, pid: 28140, title: 'anemoi'),
    );
    expect(controller.state.audioBackend, GalHookAudioBackend.gameResource);
    expect(controller.state.audioFormat, isNull,
        reason: 'resource-only readiness must not be presented as fake PCM');
    expect(loopback.startCalls, 1,
        reason: 'loopback must remain available behind the resource source');

    for (int i = 0; i < 20 && service.entries.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(
        service.entries.single.audioStatus, TexthookerLineAudioStatus.matched);
    expect(service.entries.single.audioBackend, 'game_resource');

    await controller.close();
    expect(engine.stopCalls, 1);
    expect(loopback.stopCalls, 1);
    endpoints.dispose();
  });

  test('late KiriKiri resource hook upgrades loopback and pairs the line',
      () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _FakeEngineSource engine = _FakeEngineSource(
      pairedBytes: Uint8List.fromList(<int>[4, 5, 6]),
      audioFormat: null,
      textReady: true,
      lateRawReady: true,
      pairedCandidate: true,
      polledLines: const <GalHookedLine>[
        GalHookedLine(
          seq: 1,
          timestampMs: 611165750,
          text: 'これからたくさんデートもできる。',
          threadId: 4948456556519461331,
          hookName: 'EmbedKrkrZ',
        ),
      ],
    );
    final _FakeLoopbackSource loopback = _FakeLoopbackSource();
    final GalHookSessionController controller = GalHookSessionController(
      textService: service,
      isWindows: true,
      targetWow64Probe: (_) async => true,
      injectorResolver: ({required bool is32Bit}) => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
      }) =>
          engine,
      loopbackSourceFactory: () => loopback,
      textPollInterval: const Duration(milliseconds: 5),
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 11, pid: 22812, title: '9-nine'),
    );
    expect(controller.state.audioBackend, GalHookAudioBackend.systemLoopback);

    for (int i = 0;
        i < 20 &&
            (service.entries.isEmpty ||
                controller.state.audioBackend !=
                    GalHookAudioBackend.gameResource);
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(engine.readinessRefreshCalls, greaterThan(0));
    expect(controller.state.audioBackend, GalHookAudioBackend.gameResource);
    expect(controller.state.fallbackReason, isNull);
    expect(loopback.stopCalls, 0,
        reason: 'loopback remains alive only as the per-line fallback');
    expect(
        service.entries.single.audioStatus, TexthookerLineAudioStatus.matched);
    expect(service.entries.single.audioBackend, 'game_resource');
    expect(
      controller.events.map((event) => event.code),
      contains('audio.game_resource_late_ready'),
    );

    await controller.close();
    endpoints.dispose();
  });
}

class _FakeEngineSource extends EngineHookGalAudioSource {
  _FakeEngineSource({
    required this.pairedBytes,
    this.audioFormat = const PcmFormat(
      sampleRate: 44100,
      channels: 1,
      bitsPerSample: 16,
      isFloat: false,
    ),
    this.textReady = false,
    this.rawReady = false,
    this.lateRawReady = false,
    this.pairedCandidate = false,
    this.polledLines = const <GalHookedLine>[],
  }) : super(targetPid: 0, launchExe: 'fake.exe', injectorPath: 'fake.exe');

  final Uint8List pairedBytes;
  final PcmFormat? audioFormat;
  final bool textReady;
  bool rawReady;
  final bool lateRawReady;
  final bool pairedCandidate;
  final List<GalHookedLine> polledLines;
  final List<int> pairedTimestamps = <int>[];
  int stopCalls = 0;
  int readinessRefreshCalls = 0;
  int _pollCalls = 0;

  @override
  int? get gamePid => 4242;

  @override
  bool get textHookReady => textReady;

  @override
  bool get rawVoiceReady => rawReady;

  @override
  bool get pcmReady => !rawReady && audioFormat != null;

  @override
  Future<PcmFormat?> start() async => audioFormat;

  @override
  Future<bool> refreshReadiness() async {
    readinessRefreshCalls++;
    if (lateRawReady) rawReady = true;
    return rawReady;
  }

  @override
  Future<Uint8List?> grabPairedVoiceBytes(
    int textTsMs, {
    required String outputExtension,
  }) async {
    pairedTimestamps.add(textTsMs);
    return pairedBytes;
  }

  @override
  bool hasPairedVoiceCandidate(int textTsMs) => pairedCandidate;

  @override
  Future<GalAudioSlice?> grabUtterance(
    int tsMs, {
    int? sourcePtr,
    List<int>? exclude,
  }) async =>
      null;

  @override
  Future<GalAudioSlice?> grabClipNear(
    int tsMs, {
    int tolMs = 8000,
  }) async =>
      null;

  @override
  Future<GalTextPoll?> pollText(int sinceSeq) async {
    _pollCalls++;
    return GalTextPoll(
      count: polledLines.length,
      lines: _pollCalls == 1 ? polledLines : const <GalHookedLine>[],
    );
  }

  @override
  Future<bool> selectTextThread(int? threadId) async => true;

  @override
  Future<void> stop() async {
    stopCalls++;
  }
}

class _FakeLoopbackSource extends LoopbackGalAudioSource {
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<PcmFormat?> start() async {
    startCalls++;
    return const PcmFormat(
      sampleRate: 44100,
      channels: 2,
      bitsPerSample: 32,
      isFloat: true,
    );
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }
}
