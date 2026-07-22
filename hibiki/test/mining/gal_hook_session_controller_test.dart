import 'dart:convert';
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
      loopbackSourceFactory: _FakeLoopbackSource.new,
      windowListLoader: () async => const <ExternalWindowInfo>[],
      windowPollAttempts: 1,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    expect(await controller.launchGame(r'D:\anemoi\SiglusEngine.exe'), isTrue);
    final TexthookerLineEntry entry = service.appendLine('siglus line')!;
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

  test('capture waits for a late resource file before falling back', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _FakeEngineSource engine = _FakeEngineSource(
      pairedBytes: Uint8List.fromList(<int>[9, 8, 7]),
      pairedReadyAfterCalls: 2,
      rawReady: true,
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
      resourceAudioWait: const Duration(milliseconds: 50),
      resourceAudioPollInterval: const Duration(milliseconds: 1),
      loopbackSourceFactory: _FakeLoopbackSource.new,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    expect(await controller.launchGame(r'D:\anemoi\SiglusEngine.exe'), isTrue);
    final TexthookerLineEntry entry = service.appendLine('late resource line')!;
    final Uint8List? bytes = await controller.captureAudioBytes(
      lineId: entry.id,
      sentence: entry.text,
      outputExtension: 'aac',
    );

    expect(bytes, <int>[9, 8, 7]);
    expect(engine.pairedTimestamps, <int>[0, 0]);
    expect(service.entries.single.audioBackend, 'game_resource');
    expect(
      controller.events.map((GalHookEvent event) => event.code),
      isNot(contains('audio.paired_voice_not_found')),
    );

    await controller.close();
    endpoints.dispose();
  });

  test('fallback can be disabled and then missing resource refuses PCM capture',
      () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _FakeEngineSource engine = _FakeEngineSource(
      pairedBytes: Uint8List(0),
      rawReady: true,
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
      loopbackSourceFactory: _FakeLoopbackSource.new,
      windowListLoader: () async => const <ExternalWindowInfo>[],
      windowPollAttempts: 1,
      resourceAudioWait: Duration.zero,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    expect(await controller.launchGame(r'D:\anemoi\SiglusEngine.exe'), isTrue);
    final TexthookerLineEntry entry = service.appendLine('resource only')!;
    controller.setAllowAudioFallback(false);
    expect(controller.state.allowAudioFallback, isFalse);

    final Uint8List? bytes = await controller.captureAudioBytes(
      lineId: entry.id,
      sentence: entry.text,
      outputExtension: 'aac',
    );

    expect(bytes, isNull);
    expect(service.entries.single.audioBackend, 'game_resource');
    expect(
      service.entries.single.fallbackReason,
      'paired_voice_not_found_fallback_disabled',
    );
    expect(
      controller.events.map((GalHookEvent event) => event.code),
      contains('audio.fallback_disabled'),
    );

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

  test('thread discovery reaches selector without becoming a captured line',
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
          text: '',
          threadId: 9,
          threadAddress: 0xf94600,
          sourceKind: 2,
          eventKind: GalTextEventKind.threadDiscovered,
          hookName: 'TextRender',
          hookCode: 'HS932@f94600',
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
      const ExternalWindowInfo(hwnd: 8, pid: 909, title: '9nine'),
    );
    for (int i = 0; i < 20 && service.textThreads.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(service.entries, isEmpty);
    expect(service.textThreads, hasLength(1));
    expect(service.textThreads.single.label, 'TextRender · 0xf94600');
    expect(service.textThreads.single.lineCount, 0);
    expect(service.textThreads.single.nativeThreadId, 9);

    await controller.close();
    endpoints.dispose();
  });

  test('系统 UI 文字行被 poll 剔除，只有真台词进入文本服务', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _FakeEngineSource engine = _FakeEngineSource(
      pairedBytes: Uint8List(0),
      audioFormat: null,
      textReady: true,
      polledLines: const <GalHookedLine>[
        // 读档确认句（系统 UI）——必须被剔除，不进查词面板。
        GalHookedLine(
          seq: 1,
          timestampMs: 111,
          text: 'No.05のデータをロードします',
          threadId: 9,
          hookName: 'TextRender',
        ),
        // 真台词——必须放行。
        GalHookedLine(
          seq: 2,
          timestampMs: 222,
          text: 'やめろ化け物め！',
          threadId: 9,
          hookName: 'TextRender',
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
      const ExternalWindowInfo(hwnd: 8, pid: 909, title: 'Test Game'),
    );
    for (int i = 0; i < 20 && service.entries.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(service.entries.map((TexthookerLineEntry e) => e.text).toList(),
        <String>['やめろ化け物め！'],
        reason: '系统 UI 文字（读档确认句）应被剔除，只放行真台词');

    await controller.close();
    endpoints.dispose();
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
    expect(loopback.grabRecentCalls, 1,
        reason: 'loopback audio is cached when the exact line arrives');

    await controller.captureAudioBytes(
      lineId: service.entries.single.id,
      sentence: service.entries.single.text,
      outputExtension: 'aac',
    );
    expect(loopback.grabRecentCalls, 1,
        reason: 'mining must reuse the line cache instead of recording later');

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
    expect(
      service.entries.single.audioResourceId,
      'fake-609653421.ogg',
    );

    final TexthookerLineEntry historicalLine = service.entries.single;
    final Uint8List? historicalAudio = await controller.captureAudioBytes(
      lineId: historicalLine.id,
      sentence: historicalLine.text,
      outputExtension: 'aac',
    );
    expect(historicalAudio, <int>[7, 8, 9]);
    expect(
      engine.pairedResourceIds,
      <String?>['fake-609653421.ogg'],
      reason: '历史句必须按行内固化的资源 ID 直接导出，不能重新猜最新语音',
    );

    await controller.close();
    expect(engine.stopCalls, 1);
    expect(loopback.stopCalls, 1);
    endpoints.dispose();
  });

  test(
      'RealLive replay fixture selects resource audio through production pairing',
      () async {
    final Map<String, dynamic> fixture = jsonDecode(
      await File(
        'test/fixtures/galhook/reallive_replay.json',
      ).readAsString(),
    ) as Map<String, dynamic>;
    final Map<String, dynamic> expected =
        fixture['expected'] as Map<String, dynamic>;
    final Map<String, dynamic> card =
        (expected['cards'] as List<dynamic>).single as Map<String, dynamic>;

    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _FakeEngineSource engine = _FakeEngineSource(
      pairedBytes: Uint8List.fromList(<int>[11, 12, 13]),
      rawReady: true,
      pairedCandidate: true,
      polledLines: const <GalHookedLine>[
        GalHookedLine(
          seq: 1,
          timestampMs: 2000,
          text: 'synthetic reallive line',
          threadId: 19,
          hookName: 'RealLive fixture',
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
      const ExternalWindowInfo(hwnd: 21, pid: 2200, title: 'RealLive fixture'),
    );
    for (int i = 0; i < 20 && service.entries.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(card['audio_backend'], 'resource_audio');
    expect(service.entries.single.audioBackend, 'game_resource');
    expect(
        service.entries.single.audioStatus, TexthookerLineAudioStatus.matched);
    expect(loopback.startCalls, 1,
        reason: 'loopback stays available as fallback');

    await controller.close();
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

  test('engine PCM is frozen on line arrival and reused for that line',
      () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _FakeEngineSource engine = _FakeEngineSource(
      pairedBytes: Uint8List(0),
      polledLines: const <GalHookedLine>[
        GalHookedLine(
          seq: 7,
          timestampMs: 654321,
          text: 'エンジン音声の台詞',
          threadId: 5,
          hookName: 'Siglus',
        ),
      ],
      utteranceSlice: GalAudioSlice(
        pcm: Uint8List(17640),
        format: const PcmFormat(
          sampleRate: 44100,
          channels: 1,
          bitsPerSample: 16,
          isFloat: false,
        ),
      ),
    );
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
      textPollInterval: const Duration(milliseconds: 5),
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 13, pid: 777, title: 'Engine game'),
    );
    for (int i = 0; i < 20 && service.entries.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final TexthookerLineEntry entry = service.entries.single;
    expect(entry.audioStatus, TexthookerLineAudioStatus.matched);
    expect(entry.audioBackend, 'engine_pcm');
    expect(engine.utteranceTimestamps, <int>[654321]);

    await controller.captureAudioBytes(
      lineId: entry.id,
      sentence: entry.text,
      outputExtension: 'aac',
    );
    expect(engine.utteranceTimestamps, <int>[654321],
        reason: 'mining reuses the exact cached utterance for this line');

    await controller.close();
    endpoints.dispose();
  });

  test('mine 阶段解析语音一律禁用「最新语音」兜底（BUG-955 ①）', () async {
    final TexthookerService service = TexthookerService.test();
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
      loopbackSourceFactory: _FakeLoopbackSource.new,
      windowListLoader: () async => const <ExternalWindowInfo>[],
      windowPollAttempts: 1,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    expect(await controller.launchGame(r'D:\anemoi\SiglusEngine.exe'), isTrue);
    final TexthookerLineEntry entry = service.appendLine('siglus line')!;
    await controller.captureAudioBytes(
      lineId: entry.id,
      sentence: entry.text,
      outputExtension: 'aac',
    );

    expect(engine.grabFallbackFlags, isNotEmpty,
        reason: 'mine 路径应真的调用了 grabPairedVoiceBytes');
    expect(
      engine.grabFallbackFlags.every((bool f) => f == false),
      isTrue,
      reason: 'BUG-955：mine 阶段绝不允许最新语音兜底（防历史行借当前语音）',
    );

    await controller.close();
    endpoints.dispose();
  });

  _bug950Guard();
}

void _bug950Guard() {
  test('poll 循环 await 归来后有 engine generation 复检（BUG-950 回归守卫）', () {
    // grabUtterance/_cacheLoopbackForLine 的 await 跨越 stop/重启时，恢复后必须复检
    // engine == _engineSource 再推进 cursor，否则新会话的 _lastTextSeq 被旧 cursor 倒灌、
    // 新文本全被判 duplicate 丢弃。此为跨异步 gap + 私有 seq 的时序 bug，行为断言留真机轮；
    // 源码守卫确保复检不被后续改动悄悄删掉。
    final File src = File('lib/src/mining/gal_hook_session_controller.dart');
    expect(src.existsSync(), isTrue);
    final String body = src.readAsStringSync();
    final int pollAt = body.indexOf('Future<void> _pollHookedText()');
    expect(pollAt, greaterThan(0), reason: '_pollHookedText 不存在，守卫需更新');
    final int cursorWriteAt =
        body.indexOf('cursor = line.seq;\n      }', pollAt);
    expect(cursorWriteAt, greaterThan(pollAt), reason: '找不到循环末尾 cursor 推进点');
    // 紧邻循环末尾 cursor 推进之前的窗口里，必须存在 engine != _engineSource 复检 + BUG-950 标记
    // （前面别处也有 generation 检查，故只看贴着 cursor 写入的这一段，避免误过）。
    final String window = body.substring(cursorWriteAt - 400, cursorWriteAt);
    expect(
      window.contains('if (engine != _engineSource)') &&
          window.contains('BUG-950'),
      isTrue,
      reason: 'BUG-950：推进 cursor 前必须复检 engine generation（await 跨重启防倒灌）',
    );
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
    this.pairedReadyAfterCalls = 1,
    this.polledLines = const <GalHookedLine>[],
    this.utteranceSlice,
  }) : super(targetPid: 0, launchExe: 'fake.exe', injectorPath: 'fake.exe');

  final Uint8List pairedBytes;
  final PcmFormat? audioFormat;
  final bool textReady;
  bool rawReady;
  final bool lateRawReady;
  final bool pairedCandidate;
  final int pairedReadyAfterCalls;
  final List<GalHookedLine> polledLines;
  final GalAudioSlice? utteranceSlice;
  final List<int> pairedTimestamps = <int>[];
  final List<int> utteranceTimestamps = <int>[];
  final List<String?> pairedResourceIds = <String?>[];
  final List<bool> grabFallbackFlags = <bool>[];
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
    String? resourceId,
    bool allowLatestSessionFallback = true,
  }) async {
    pairedTimestamps.add(textTsMs);
    pairedResourceIds.add(resourceId);
    grabFallbackFlags.add(allowLatestSessionFallback);
    if (pairedTimestamps.length < pairedReadyAfterCalls) return null;
    return pairedBytes;
  }

  @override
  bool hasPairedVoiceCandidate(int textTsMs,
          {bool allowLatestSessionFallback = true}) =>
      pairedCandidate;

  @override
  String? findPairedVoiceResourceId(int textTsMs,
          {bool allowLatestSessionFallback = true}) =>
      pairedCandidate ? 'fake-$textTsMs.ogg' : null;

  @override
  Future<GalAudioSlice?> grabUtterance(
    int tsMs, {
    int? sourcePtr,
    List<int>? exclude,
  }) async {
    utteranceTimestamps.add(tsMs);
    return utteranceSlice;
  }

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
  int grabRecentCalls = 0;

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

  @override
  Future<GalAudioSlice?> grabRecent(int backMs) async {
    grabRecentCalls++;
    return GalAudioSlice(
      pcm: Uint8List.fromList(<int>[0, 0, 1, 1]),
      format: const PcmFormat(
        sampleRate: 44100,
        channels: 2,
        bitsPerSample: 16,
        isFloat: false,
      ),
    );
  }
}
