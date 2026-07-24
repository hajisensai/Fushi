import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/mining/galgame_audio_encode.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/src/sync/texthooker_ws_client.dart';

void main() {
  // BUG-1027 音轨快照自动刷新会在会话激活后触发（未 mock 的）voice_hook channel 的
  // listAudioTracks——必须先初始化 binding，让调用以 MissingPluginException 收敛为
  // 空列表而不是在无 binding 下直接抛错。
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('BUG-1060 text-only engine ignores stale PCM and caches loopback audio',
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
      // 真实故障里 helper 虽未通过 PCM readiness，旧 DirectSound 段仍可被
      // grabUtterance 读到。降级会话必须忽略它，不能把碎片伪装成 Loopback。
      utteranceSlice: GalAudioSlice(
        pcm: Uint8List(192000),
        format: const PcmFormat(
          sampleRate: 48000,
          channels: 2,
          bitsPerSample: 16,
          isFloat: false,
        ),
      ),
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
    expect(engine.utteranceTimestamps, isEmpty,
        reason: 'failed engine PCM readiness must remain authoritative');

    await controller.captureAudioBytes(
      lineId: service.entries.single.id,
      sentence: service.entries.single.text,
      outputExtension: 'aac',
    );
    expect(loopback.grabRecentCalls, 1,
        reason: 'mining must reuse the line cache instead of recording later');
    expect(engine.utteranceTimestamps, isEmpty,
        reason:
            'mining must not revive stale engine PCM in a loopback session');

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
    expect(engine.findEventIds, <int?>[1]);
    expect(engine.pairedEventIds, <int?>[1]);

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

  test('BUG-1049：窗口迟到时会话继续重绑，不停在 window_not_found', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _FakeEngineSource engine = _FakeEngineSource(
      pairedBytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
    );
    // 启动那一刻游戏窗口还没建好（带启动器/壳解包的真实情况）；几秒后才出现。
    List<ExternalWindowInfo> windows = const <ExternalWindowInfo>[];
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
      windowListLoader: () async => windows,
      windowPollAttempts: 1,
      windowRebindInterval: const Duration(milliseconds: 10),
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    expect(await controller.launchGame(r'D:\anemoi\SiglusEngine.exe'), isTrue);
    expect(controller.state.boundWindow, isNull);
    expect(controller.state.phase, GalHookSessionPhase.degraded);
    expect(controller.state.fallbackReason, 'window_not_found');

    // 窗口出现（pid 与 hook 注入的目标一致）。
    windows = const <ExternalWindowInfo>[
      ExternalWindowInfo(hwnd: 12, pid: 9, title: '别的窗口'),
      ExternalWindowInfo(hwnd: 34, pid: 4242, title: '天使☆騒々 RE-BOOT!'),
    ];
    for (int i = 0; i < 40 && controller.state.boundWindow == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(controller.state.boundWindow?.hwnd, 34,
        reason: '游戏窗口一出现就该自动绑上，不必用户手动去选');
    expect(controller.state.fallbackReason, isNull);
    expect(controller.state.phase, isNot(GalHookSessionPhase.degraded));
    expect(
      controller.events.map((GalHookEvent event) => event.code),
      contains('window.auto_bound_late'),
    );

    await controller.close();
    endpoints.dispose();
  });

  test('BUG-1049：会话停止后不再继续重绑窗口', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _FakeEngineSource engine = _FakeEngineSource(
      pairedBytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
    );
    List<ExternalWindowInfo> windows = const <ExternalWindowInfo>[];
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
      windowListLoader: () async => windows,
      windowPollAttempts: 1,
      windowRebindInterval: const Duration(milliseconds: 10),
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    expect(await controller.launchGame(r'D:\anemoi\SiglusEngine.exe'), isTrue);
    await controller.stopCapture(keepBinding: false);
    windows = const <ExternalWindowInfo>[
      ExternalWindowInfo(hwnd: 34, pid: 4242, title: '天使☆騒々 RE-BOOT!'),
    ];
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(controller.state.boundWindow, isNull,
        reason: '会话已停，迟到的窗口不该把 app 拉回一条死会话');

    await controller.close();
    endpoints.dispose();
  });

  test('游戏活动落库：hook 台词累计字符/时长写入 activity_events（game 类别）', () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _FakeEngineSource engine = _FakeEngineSource(
      pairedBytes: Uint8List(0),
      audioFormat: null,
      textReady: true,
      polledLines: const <GalHookedLine>[
        GalHookedLine(
          seq: 1,
          timestampMs: 1000,
          text: 'あいうえお', // 5 字
          threadId: 1,
          hookName: 'Unity',
        ),
        GalHookedLine(
          seq: 2,
          timestampMs: 2000,
          text: 'かきくけこさ', // 6 字
          threadId: 1,
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
    controller.attachActivityDatabase(() => db);

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 8, pid: 909, title: 'サノバウィッチ'),
    );
    for (int i = 0; i < 40 && service.entries.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(service.entries, hasLength(2));

    // 会话结束落库；flush 内写入是 unawaited，轮询等其完成。
    await controller.stopCapture();
    List<ActivityEventRow> rows = const <ActivityEventRow>[];
    for (int i = 0; i < 40 && rows.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      rows =
          await db.getRecentActivityEvents(eventTypes: <String>[kActivityGame]);
    }
    expect(rows, hasLength(1));
    expect(rows.single.eventType, kActivityGame);
    expect(rows.single.mediaType, kActivityMediaGame);
    expect(rows.single.title, 'サノバウィッチ');
    // attach 模式无稳定可执行文件 id → mediaKey 为空。
    expect(rows.single.mediaKey, isNull);
    // 两行合计 5 + 6 = 11 字。
    expect(rows.single.charsDelta, 11);
    expect(rows.single.durationMs, isNotNull);
    expect(rows.single.durationMs, greaterThanOrEqualTo(0));

    await controller.close();
    endpoints.dispose();
  });

  _bug950Guard();
}

void _bug950Guard() {
  test('文本 poll 主路径零阻塞 + 语音抓取内复检 engine（BUG-950 / BUG-1063 守卫）', () {
    // BUG-1063：文本主循环里一旦重新出现语音抓取的 await，同批后续台词就要排在前一句
    // 的语音之后，_pollInFlight 还会让下一个 tick 整轮跳过——台词显示被自己的语音配对
    // 拖慢。BUG-950：抓取的 await 跨越 stop/重启时，恢复后必须复检 engine == _engineSource，
    // 否则旧会话的数据写进新会话的行。两者都是跨异步 gap 的时序不变量，用源码守卫钉住。
    final File src = File('lib/src/mining/gal_hook_session_controller.dart');
    expect(src.existsSync(), isTrue);
    final String body = src.readAsStringSync();
    final int pollAt = body.indexOf('Future<void> _pollHookedText()');
    expect(pollAt, greaterThan(0), reason: '_pollHookedText 不存在，守卫需更新');
    final int pollEnd =
        body.indexOf('Future<void> _refreshReadinessThrottled', pollAt);
    expect(pollEnd, greaterThan(pollAt), reason: '找不到 _pollHookedText 结尾');
    final List<String> awaited = RegExp(r'await ([A-Za-z_.]+)\(')
        .allMatches(body.substring(pollAt, pollEnd))
        .map((RegExpMatch m) => m.group(1)!)
        .toList();
    expect(
      awaited,
      <String>['_refreshReadinessThrottled', 'engine.pollText'],
      reason: 'BUG-1063：文本主路径只许等 readiness 与 pollText 本身，'
          '语音抓取必须走 _scheduleLineAudioAttach 的后台队列',
    );

    final int attachAt = body.indexOf('Future<void> _attachLineAudio(');
    expect(attachAt, greaterThan(0), reason: '_attachLineAudio 不存在，守卫需更新');
    final String attachBody = body.substring(attachAt, attachAt + 1200);
    expect(
      attachBody.contains('if (engine != _engineSource)') &&
          attachBody.contains('BUG-950'),
      isTrue,
      reason: 'BUG-950：语音抓取 await 归来后必须复检 engine generation',
    );
  });

  group('exportLineAudioPreview（实时台词行内试听）', () {
    test('PCM 缓存路径：冻结切片拼 WAV 落临时目录，时长>0，不改行状态', () async {
      final TexthookerService service = TexthookerService.test();
      final TexthookerLineEntry line = service.appendLine('試聴の台詞')!;
      final ChangeNotifier endpoints = ChangeNotifier();
      final GalHookSessionController controller = GalHookSessionController(
        textService: service,
        isWindows: false,
        endpointListenable: endpoints,
        endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
      );
      controller.debugCacheLineVoice(
        line.id,
        GalAudioSlice(
          pcm: Uint8List(44100), // 单声道 16bit 44.1kHz 下 0.5s
          format: const PcmFormat(
            sampleRate: 44100,
            channels: 1,
            bitsPerSample: 16,
            isFloat: false,
          ),
        ),
      );

      final GalTrackPreview? preview =
          await controller.exportLineAudioPreview(line.id);
      expect(preview, isNotNull);
      expect(File(preview!.filePath).existsSync(), isTrue);
      expect(preview.durationMs, greaterThan(0));
      // 只读试听：不得动行的音频状态（制卡链路语义不受影响）。
      expect(
        service.entryById(line.id)!.audioStatus,
        TexthookerLineAudioStatus.unavailable,
      );

      try {
        File(preview.filePath).deleteSync();
      } catch (_) {}
      await controller.close();
      endpoints.dispose();
    });

    test('无任何已配音频：返回 null 并记结构化事件（不静默）', () async {
      final TexthookerService service = TexthookerService.test();
      final TexthookerLineEntry line = service.appendLine('音無しの台詞')!;
      final ChangeNotifier endpoints = ChangeNotifier();
      final GalHookSessionController controller = GalHookSessionController(
        textService: service,
        isWindows: false,
        endpointListenable: endpoints,
        endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
      );

      expect(await controller.exportLineAudioPreview(line.id), isNull);
      expect(
        controller.events.map((GalHookEvent e) => e.code),
        contains('audio.line_preview_unavailable'),
      );

      await controller.close();
      endpoints.dispose();
    });
  });

  // 引擎 hook 失败后的处置。旧实现：attach 一次失败就永久 Loopback（`_engineSource=null`，
  // 没有任何重试），launch 注入失败就把整个会话判成终态错误——哪怕游戏其实已经在跑。
  group('engine hook failure handling', () {
    test('可自愈的附着失败会在 Loopback 期间重试并升级回引擎源', () async {
      final TexthookerService service = TexthookerService.test();
      final ChangeNotifier endpoints = ChangeNotifier();
      // 第一次 attach：无 PCM 无文本，且 native 报「未收到就绪信号」（可自愈）。
      final _FakeEngineSource failing = _FakeEngineSource(
        pairedBytes: Uint8List(0),
        audioFormat: null,
        failure: const GalHookInjectorDiagnostics(
          failure: GalHookInjectorFailure.readyTimeout,
          exitCode: 2,
          stderrTail: '注入完成但未收到就绪信号（30000ms 超时）；hooked=0',
        ),
      );
      // 重试那次：引擎 PCM 就绪。
      final _FakeEngineSource recovered =
          _FakeEngineSource(pairedBytes: Uint8List(0));
      final List<_FakeEngineSource> queue = <_FakeEngineSource>[
        failing,
        recovered,
      ];
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
            queue.isEmpty ? recovered : queue.removeAt(0),
        loopbackSourceFactory: _FakeLoopbackSource.new,
        windowListLoader: () async => const <ExternalWindowInfo>[],
        windowPollAttempts: 1,
        engineRetryBackoff: const <Duration>[Duration(milliseconds: 10)],
        endpointListenable: endpoints,
        endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
      );

      await controller.startAttachedCapture(
        const ExternalWindowInfo(hwnd: 3, pid: 20096, title: 'manosaba'),
      );

      // 降级发生了，但失败原因必须是结构化的、可执行的，而不是只有一句代码。
      expect(controller.state.phase, GalHookSessionPhase.degraded);
      expect(controller.state.audioBackend, GalHookAudioBackend.systemLoopback);
      expect(
        controller.state.injectorFailure,
        GalHookInjectorFailure.readyTimeout,
      );
      final GalHookEvent failedEvent = controller.events.firstWhere(
        (GalHookEvent e) => e.code == 'audio.engine_attach_failed',
      );
      expect(failedEvent.details['reason'], 'readyTimeout');
      expect(failedEvent.details['exitCode'], 2);
      expect(failedEvent.details['detail'], contains('未收到就绪信号'));
      expect(
        controller.events.map((GalHookEvent e) => e.code),
        contains('engine.retry_scheduled'),
      );

      // 退避到期后自动重试，成功即把音源升级回引擎，不再停在整机混音。
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(
        controller.events.map((GalHookEvent e) => e.code),
        contains('engine.attach_recovered'),
      );
      expect(controller.state.audioBackend, GalHookAudioBackend.enginePcm);
      expect(controller.state.phase, GalHookSessionPhase.waitingSignals);
      expect(
        controller.state.injectorFailure,
        GalHookInjectorFailure.none,
      );
      expect(controller.hasEngineSource, isTrue);

      await controller.close();
      endpoints.dispose();
    });

    test('需要用户处置的失败一次都不重试（提权/位数）', () async {
      final TexthookerService service = TexthookerService.test();
      final ChangeNotifier endpoints = ChangeNotifier();
      int factoryCalls = 0;
      final _FakeEngineSource denied = _FakeEngineSource(
        pairedBytes: Uint8List(0),
        audioFormat: null,
        failure: const GalHookInjectorDiagnostics(
          failure: GalHookInjectorFailure.accessDenied,
          exitCode: 1,
          stderrTail: 'OpenProcess(20096) failed: 5',
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
        }) {
          factoryCalls++;
          return denied;
        },
        loopbackSourceFactory: _FakeLoopbackSource.new,
        windowListLoader: () async => const <ExternalWindowInfo>[],
        windowPollAttempts: 1,
        engineRetryBackoff: const <Duration>[Duration(milliseconds: 10)],
        endpointListenable: endpoints,
        endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
      );

      await controller.startAttachedCapture(
        const ExternalWindowInfo(hwnd: 3, pid: 20096, title: 'game'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(
        controller.state.injectorFailure,
        GalHookInjectorFailure.accessDenied,
      );
      final List<String> codes =
          controller.events.map((GalHookEvent e) => e.code).toList();
      expect(codes, contains('engine.retry_skipped'));
      expect(codes, isNot(contains('engine.retry_scheduled')));
      expect(factoryCalls, 1);

      await controller.close();
      endpoints.dispose();
    });

    test('启动注入失败但游戏已在跑：保留会话降级重试，不报「启动失败」', () async {
      final TexthookerService service = TexthookerService.test();
      final ChangeNotifier endpoints = ChangeNotifier();
      final _FakeEngineSource failing = _FakeEngineSource(
        pairedBytes: Uint8List(0),
        audioFormat: null,
        launched: 20096,
        failure: const GalHookInjectorDiagnostics(
          failure: GalHookInjectorFailure.readyTimeout,
          exitCode: 2,
          stderrTail: '注入完成但未收到就绪信号',
        ),
      );
      final _FakeEngineSource recovered =
          _FakeEngineSource(pairedBytes: Uint8List(0));
      final List<_FakeEngineSource> queue = <_FakeEngineSource>[
        failing,
        recovered,
      ];
      final GalHookSessionController controller = GalHookSessionController(
        textService: service,
        isWindows: true,
        exe32BitProbe: (_) async => false,
        targetWow64Probe: (_) async => false,
        injectorResolver: ({required bool is32Bit}) => 'injector.exe',
        engineSourceFactory: ({
          required int targetPid,
          required String? launchExe,
          required String injectorPath,
          required bool lunaPcHooks,
          int? lunaCodepage,
        }) =>
            queue.isEmpty ? recovered : queue.removeAt(0),
        loopbackSourceFactory: _FakeLoopbackSource.new,
        windowListLoader: () async => const <ExternalWindowInfo>[],
        windowPollAttempts: 1,
        engineRetryBackoff: const <Duration>[Duration(milliseconds: 10)],
        endpointListenable: endpoints,
        endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
      );

      // 游戏确实被拉起来了（injector 回报 LAUNCH pid），只是注入没成：会话必须活着。
      expect(
          await controller.launchGame(r'D:\gal\manosaba\manosaba.exe'), isTrue);
      expect(controller.state.phase, GalHookSessionPhase.degraded);
      expect(controller.state.gamePid, 20096);
      expect(controller.state.fallbackReason, 'launch_injection_failed');
      final List<String> codes =
          controller.events.map((GalHookEvent e) => e.code).toList();
      expect(codes, contains('engine.launch_injection_degraded'));
      expect(codes, isNot(contains('engine.launch_or_inject_failed')));

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(
        controller.events.map((GalHookEvent e) => e.code),
        contains('engine.attach_recovered'),
      );
      expect(controller.state.audioBackend, GalHookAudioBackend.enginePcm);

      await controller.close();
      endpoints.dispose();
    });

    test('injector 未回报 PID（旧 helper）时仍是明确的启动失败，且带结构化原因', () async {
      final TexthookerService service = TexthookerService.test();
      final ChangeNotifier endpoints = ChangeNotifier();
      final _FakeEngineSource failing = _FakeEngineSource(
        pairedBytes: Uint8List(0),
        audioFormat: null,
        failure: const GalHookInjectorDiagnostics(
          failure: GalHookInjectorFailure.elevationRequired,
          exitCode: 1,
          stderrTail: 'CreateProcessW failed: 740',
        ),
      );
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
        }) =>
            failing,
        loopbackSourceFactory: _FakeLoopbackSource.new,
        windowListLoader: () async => const <ExternalWindowInfo>[],
        windowPollAttempts: 1,
        endpointListenable: endpoints,
        endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
      );

      expect(await controller.launchGame(r'D:\gal\x\x.exe'), isFalse);
      expect(controller.state.phase, GalHookSessionPhase.error);
      expect(
        controller.state.injectorFailure,
        GalHookInjectorFailure.elevationRequired,
      );
      final GalHookEvent failed = controller.events.firstWhere(
        (GalHookEvent e) => e.code == 'engine.launch_or_inject_failed',
      );
      expect(failed.details['reason'], 'elevationRequired');

      await controller.close();
      endpoints.dispose();
    });
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
    this.failure = const GalHookInjectorDiagnostics(),
    this.launched,
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

  /// 本次 start 失败时 native 侧的结构化诊断（成功路径为 [GalHookInjectorFailure.none]）。
  final GalHookInjectorDiagnostics failure;

  /// injector 已 `CreateProcess` 出来的游戏 PID；null 模拟不回报该行的旧 helper。
  final int? launched;
  final List<int> pairedTimestamps = <int>[];
  final List<int?> pairedEventIds = <int?>[];
  final List<int?> findEventIds = <int?>[];
  final List<int> utteranceTimestamps = <int>[];
  final List<String?> pairedResourceIds = <String?>[];
  final List<bool> grabFallbackFlags = <bool>[];
  int stopCalls = 0;
  int readinessRefreshCalls = 0;
  int _pollCalls = 0;

  @override
  int? get gamePid => 4242;

  @override
  GalHookInjectorDiagnostics get lastFailure => failure;

  @override
  int? get launchedPid => launched;

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
    int? textEventId,
    String? resourceId,
    bool allowLatestSessionFallback = true,
  }) async {
    pairedTimestamps.add(textTsMs);
    pairedEventIds.add(textEventId);
    pairedResourceIds.add(resourceId);
    grabFallbackFlags.add(allowLatestSessionFallback);
    if (pairedTimestamps.length < pairedReadyAfterCalls) return null;
    return pairedBytes;
  }

  @override
  bool hasPairedVoiceCandidate(int textTsMs,
          {int? textEventId, bool allowLatestSessionFallback = true}) =>
      pairedCandidate;

  @override
  String? findPairedVoiceResourceId(int textTsMs,
      {int? textEventId, bool allowLatestSessionFallback = true}) {
    findEventIds.add(textEventId);
    return pairedCandidate ? 'fake-$textTsMs.ogg' : null;
  }

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
