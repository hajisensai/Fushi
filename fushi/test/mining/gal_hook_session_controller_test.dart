import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/mining/galgame_japanese_locale.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/galgame_play_tracker.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/startup/exit_flush_registry.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/sync/texthooker_ws_client.dart';
import 'package:path/path.dart' as p;

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
      injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
        List<String> launchArguments = const <String>[],
        String launchWorkdir = '',
        GalJapaneseLocaleMode japaneseLocaleMode =
            kGalDefaultJapaneseLocaleMode,
      }) =>
          engine,
      loopbackSourceFactory: _FakeLoopbackSource.new,
      windowListLoader: () async => const <ExternalWindowInfo>[],
      windowPollAttempts: 1,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    expect(
      (await controller.launchGame(r'D:\anemoi\SiglusEngine.exe')).launched,
      isTrue,
    );
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
      injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
        List<String> launchArguments = const <String>[],
        String launchWorkdir = '',
        GalJapaneseLocaleMode japaneseLocaleMode =
            kGalDefaultJapaneseLocaleMode,
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

    expect(
      (await controller.launchGame(r'D:\anemoi\SiglusEngine.exe')).launched,
      isTrue,
    );
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
      injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
        List<String> launchArguments = const <String>[],
        String launchWorkdir = '',
        GalJapaneseLocaleMode japaneseLocaleMode =
            kGalDefaultJapaneseLocaleMode,
      }) =>
          engine,
      loopbackSourceFactory: _FakeLoopbackSource.new,
      windowListLoader: () async => const <ExternalWindowInfo>[],
      windowPollAttempts: 1,
      resourceAudioWait: Duration.zero,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    expect(
      (await controller.launchGame(r'D:\anemoi\SiglusEngine.exe')).launched,
      isTrue,
    );
    final TexthookerLineEntry entry = service.appendLine('resource only')!;
    controller.setAudioFallbackPolicy(GalAudioFallbackPolicy.resourceOnly);
    expect(
      controller.state.audioFallbackPolicy,
      GalAudioFallbackPolicy.resourceOnly,
    );

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

  test('clean-source policy refuses loopback mix for a line with no voice',
      () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _FakeEngineSource engine = _FakeEngineSource(
      pairedBytes: Uint8List(0),
      rawReady: true,
    );
    final _FakeLoopbackSource loopback = _FakeLoopbackSource();
    final GalHookSessionController controller = GalHookSessionController(
      textService: service,
      isWindows: true,
      exe32BitProbe: (_) async => true,
      injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
        List<String> launchArguments = const <String>[],
        String launchWorkdir = '',
        GalJapaneseLocaleMode japaneseLocaleMode =
            kGalDefaultJapaneseLocaleMode,
      }) =>
          engine,
      loopbackSourceFactory: () => loopback,
      windowListLoader: () async => const <ExternalWindowInfo>[],
      windowPollAttempts: 1,
      resourceAudioWait: Duration.zero,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    expect(
      (await controller.launchGame(r'D:\anemoi\SiglusEngine.exe')).launched,
      isTrue,
    );
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(3);
    // 资源模式会话把 `_audioSource` 指向 loopback（原始资源是首选，混音只是兜底），
    // 于是没有配对资源的句子在旧实现里必然拿到一段整机混音 = 纯 BGM。
    final TexthookerLineEntry entry = service.appendLine('無声のモノローグ')!;
    controller.setAudioFallbackPolicy(GalAudioFallbackPolicy.cleanOnly);

    final Uint8List? bytes = await controller.captureAudioBytes(
      lineId: entry.id,
      sentence: entry.text,
      outputExtension: 'aac',
    );

    expect(bytes, isNull, reason: '干净源策略下不得拿混音冒充这句的语音');
    expect(
      loopback.grabRecentCalls,
      0,
      reason: '一次都不该去环形缓冲取混音——取了就说明降级链还活着',
    );
    // 这条会话拿不到任何证据（无原件配对在途、引擎枚举不出候选轨），所以只能如实
    // 说「策略挡掉了唯一可用音源」。**绝不能**说成「这句没配音」：那是有证据才能下
    // 的结论，冒充它会把纯 loopback 降级会话的每一行都说成游戏没配音，也会把资源
    // 模式下的真漏抓一起盖掉。
    expect(
      service.entries.single.fallbackReason,
      kGalCleanSourceSuppressedReason,
      reason: '零证据时必须报「已按策略抑制」，不得冒充「无配音」',
    );
    expect(
      service.entries.single.fallbackReason,
      isNot(kGalLineNoVoiceReason),
    );
    expect(
      controller.events.map((GalHookEvent event) => event.code),
      contains('audio.loopback_suppressed'),
    );

    await controller.close();
    endpoints.dispose();
  });

  test('clean-source policy still reports a missed utterance as a miss',
      () async {
    // 「有配音但漏抓」在 cleanOnly 下必须仍然报疑似漏抓：原件通道是活的、这行还挂着
    // 配对在途，就是证据。把它也说成「无配音」等于用「我没抓到」冒充「它没有」，
    // 用户报的「部分句子有配音」那类游戏首当其冲。
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _FakeEngineSource engine = _FakeEngineSource(
      pairedBytes: Uint8List(0),
      textReady: true,
      rawReady: true,
      polledLines: const <GalHookedLine>[
        GalHookedLine(
          seq: 1,
          timestampMs: 987654,
          text: '声のあるはずの台詞',
          threadId: 3,
          threadAddress: 0xabcdef,
          sourceKind: 2,
          hookName: 'TextRender',
          hookCode: 'HS932@abcdef',
        ),
      ],
    );
    final _FakeLoopbackSource loopback = _FakeLoopbackSource();
    final GalHookSessionController controller = GalHookSessionController(
      textService: service,
      isWindows: true,
      exe32BitProbe: (_) async => true,
      injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
        List<String> launchArguments = const <String>[],
        String launchWorkdir = '',
        GalJapaneseLocaleMode japaneseLocaleMode =
            kGalDefaultJapaneseLocaleMode,
      }) =>
          engine,
      loopbackSourceFactory: () => loopback,
      windowListLoader: () async => const <ExternalWindowInfo>[],
      windowPollAttempts: 1,
      resourceAudioWait: Duration.zero,
      textPollInterval: const Duration(milliseconds: 5),
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    expect(
      (await controller.launchGame(r'D:\anemoi\SiglusEngine.exe')).launched,
      isTrue,
    );
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(3);
    controller.setAudioFallbackPolicy(GalAudioFallbackPolicy.cleanOnly);
    for (int i = 0; i < 40 && service.entries.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(service.entries, hasLength(1));
    final TexthookerLineEntry entry = service.entries.single;

    final Uint8List? bytes = await controller.captureAudioBytes(
      lineId: entry.id,
      sentence: entry.text,
      outputExtension: 'aac',
    );

    expect(bytes, isNull);
    expect(loopback.grabRecentCalls, 0, reason: '策略仍然禁止取整机混音');
    expect(
      service.entries.single.fallbackReason,
      'utterance_not_found',
      reason: '原件配对在途 = 有证据说明这行本该有语音，必须报漏抓而不是无配音',
    );

    await controller.close();
    endpoints.dispose();
  });

  test('audio fallback policy is remembered per game and restored on launch',
      () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final Map<String, GalCaptureMemory> store = <String, GalCaptureMemory>{};
    GalHookSessionController build() {
      final GalHookSessionController controller = GalHookSessionController(
        textService: service,
        isWindows: true,
        exe32BitProbe: (_) async => true,
        injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
        engineSourceFactory: ({
          required int targetPid,
          required String? launchExe,
          required String injectorPath,
          required bool lunaPcHooks,
          int? lunaCodepage,
          List<String> launchArguments = const <String>[],
          String launchWorkdir = '',
          GalJapaneseLocaleMode japaneseLocaleMode =
              kGalDefaultJapaneseLocaleMode,
        }) =>
            _FakeEngineSource(pairedBytes: Uint8List(0), rawReady: true),
        loopbackSourceFactory: _FakeLoopbackSource.new,
        windowListLoader: () async => const <ExternalWindowInfo>[],
        windowPollAttempts: 1,
        resourceAudioWait: Duration.zero,
        endpointListenable: endpoints,
        endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
      );
      controller.attachCaptureMemory(
        load: (String gameKey) => store[gameKey] ?? const GalCaptureMemory(),
        save: (String gameKey, GalCaptureMemory memory) =>
            store[gameKey] = memory,
      );
      return controller;
    }

    final GalHookSessionController first = build();
    expect(
      (await first.launchGame(r'D:\anemoi\SiglusEngine.exe')).launched,
      isTrue,
    );
    first.setAudioFallbackPolicy(GalAudioFallbackPolicy.cleanOnly);
    expect(
      store[r'd:\anemoi\siglusengine.exe']?.audioFallbackPolicy,
      GalAudioFallbackPolicy.cleanOnly,
    );
    await first.close();

    final GalHookSessionController second = build();
    expect(
      (await second.launchGame(r'D:\anemoi\SiglusEngine.exe')).launched,
      isTrue,
    );
    expect(
      second.state.audioFallbackPolicy,
      GalAudioFallbackPolicy.cleanOnly,
      reason: '策略必须在会话启动时就恢复——资源模式不枚举音轨，等音轨快照就等不到',
    );

    // 另一个游戏不得继承上一个游戏的策略（`_beginActivitySession` 重置记忆会话）。
    expect(
      (await second.launchGame(r'D:\other\Game.exe')).launched,
      isTrue,
    );
    expect(
      second.state.audioFallbackPolicy,
      GalAudioFallbackPolicy.full,
      reason: '换游戏必须按新 exe 重新加载记忆，不能串上一个游戏的选择',
    );

    await second.close();
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
      injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
        List<String> launchArguments = const <String>[],
        String launchWorkdir = '',
        GalJapaneseLocaleMode japaneseLocaleMode =
            kGalDefaultJapaneseLocaleMode,
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
      expect((await controller.launchGame(exe.path)).launched, isTrue);
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
      injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
        List<String> launchArguments = const <String>[],
        String launchWorkdir = '',
        GalJapaneseLocaleMode japaneseLocaleMode =
            kGalDefaultJapaneseLocaleMode,
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
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(9);
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
      injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
        List<String> launchArguments = const <String>[],
        String launchWorkdir = '',
        GalJapaneseLocaleMode japaneseLocaleMode =
            kGalDefaultJapaneseLocaleMode,
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
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(9);
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
      injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
        List<String> launchArguments = const <String>[],
        String launchWorkdir = '',
        GalJapaneseLocaleMode japaneseLocaleMode =
            kGalDefaultJapaneseLocaleMode,
      }) =>
          engine,
      loopbackSourceFactory: () => loopback,
      textPollInterval: const Duration(milliseconds: 5),
      // BUG-1101：逐行 loopback 改成「延迟冻结」（台词到达后等本句语音进环再抓）。
      // 单测把等待压到 10ms，断言的仍是同一条链路。
      loopbackFreezeDelay: const Duration(milliseconds: 10),
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

    for (int i = 0; i < 60 && loopback.grabRecentCalls == 0; i++) {
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
      injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
        List<String> launchArguments = const <String>[],
        String launchWorkdir = '',
        GalJapaneseLocaleMode japaneseLocaleMode =
            kGalDefaultJapaneseLocaleMode,
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
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(5);
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
      injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
        List<String> launchArguments = const <String>[],
        String launchWorkdir = '',
        GalJapaneseLocaleMode japaneseLocaleMode =
            kGalDefaultJapaneseLocaleMode,
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
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(19);
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
      injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
        List<String> launchArguments = const <String>[],
        String launchWorkdir = '',
        GalJapaneseLocaleMode japaneseLocaleMode =
            kGalDefaultJapaneseLocaleMode,
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
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(4948456556519461331);
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
      injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
        List<String> launchArguments = const <String>[],
        String launchWorkdir = '',
        GalJapaneseLocaleMode japaneseLocaleMode =
            kGalDefaultJapaneseLocaleMode,
      }) =>
          engine,
      textPollInterval: const Duration(milliseconds: 5),
      // 本例守的是「首取即冻结 + 制卡复用缓存」这半条契约，与 BUG-1109 的增长收敛无关。
      // 关掉收敛让 grab 次数确定为 1，否则断言会随机器快慢抖动（收敛见
      // gal_utterance_settle_test.dart）。
      utteranceSettleMax: Duration.zero,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 13, pid: 777, title: 'Engine game'),
    );
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(5);
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
      injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
        List<String> launchArguments = const <String>[],
        String launchWorkdir = '',
        GalJapaneseLocaleMode japaneseLocaleMode =
            kGalDefaultJapaneseLocaleMode,
      }) =>
          engine,
      loopbackSourceFactory: _FakeLoopbackSource.new,
      windowListLoader: () async => const <ExternalWindowInfo>[],
      windowPollAttempts: 1,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    expect(
      (await controller.launchGame(r'D:\anemoi\SiglusEngine.exe')).launched,
      isTrue,
    );
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
      injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
        List<String> launchArguments = const <String>[],
        String launchWorkdir = '',
        GalJapaneseLocaleMode japaneseLocaleMode =
            kGalDefaultJapaneseLocaleMode,
      }) =>
          engine,
      loopbackSourceFactory: _FakeLoopbackSource.new,
      windowListLoader: () async => windows,
      windowPollAttempts: 1,
      windowRebindInterval: const Duration(milliseconds: 10),
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    expect(
      (await controller.launchGame(r'D:\anemoi\SiglusEngine.exe')).launched,
      isTrue,
    );
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(1);
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
      injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
        List<String> launchArguments = const <String>[],
        String launchWorkdir = '',
        GalJapaneseLocaleMode japaneseLocaleMode =
            kGalDefaultJapaneseLocaleMode,
      }) =>
          engine,
      loopbackSourceFactory: _FakeLoopbackSource.new,
      windowListLoader: () async => windows,
      windowPollAttempts: 1,
      windowRebindInterval: const Duration(milliseconds: 10),
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    expect(
      (await controller.launchGame(r'D:\anemoi\SiglusEngine.exe')).launched,
      isTrue,
    );
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(1);
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

  test('游戏活动落库：hook 台词只把字符数写入 activity_events（game 类别，不写时长）', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
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
      injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
        List<String> launchArguments = const <String>[],
        String launchWorkdir = '',
        GalJapaneseLocaleMode japaneseLocaleMode =
            kGalDefaultJapaneseLocaleMode,
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
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(1);
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
    // 契约 §3.1：时长真相源改为 GalgamePlayTracker（前台窗口计时），hook 文本这条
    // 路径**不再写 durationMs**，否则同一次游玩被计两遍。
    expect(rows.single.durationMs, isNull);

    await controller.close();
    endpoints.dispose();
  });

  test('游戏库启动活动统一写 galgames.id 与当前显示名，不再把 exePath 当 mediaKey', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
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
          text: '統一された活動',
          threadId: 1,
          hookName: 'Unity',
        ),
      ],
    );
    final GalHookSessionController controller = GalHookSessionController(
      textService: service,
      isWindows: true,
      exe32BitProbe: (_) async => false,
      injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
        List<String> launchArguments = const <String>[],
        String launchWorkdir = '',
        GalJapaneseLocaleMode japaneseLocaleMode =
            kGalDefaultJapaneseLocaleMode,
      }) =>
          engine,
      loopbackSourceFactory: _FakeLoopbackSource.new,
      windowListLoader: () async => const <ExternalWindowInfo>[],
      windowPollAttempts: 1,
      textPollInterval: const Duration(milliseconds: 5),
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );
    controller.attachActivityDatabase(() => db);

    final GalHookLaunchResult result = await controller.launchGame(
      r'D:\Games\LegacyName.exe',
      gameId: 'galgame-row-42',
      gameTitle: '统一后的显示名',
    );
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(1);
    expect(result.launched, isTrue);
    for (int i = 0; i < 40 && service.entries.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(service.entries, hasLength(1));

    await controller.stopCapture();
    List<ActivityEventRow> rows = const <ActivityEventRow>[];
    for (int i = 0; i < 40 && rows.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      rows =
          await db.getRecentActivityEvents(eventTypes: <String>[kActivityGame]);
    }
    expect(rows, hasLength(1));
    expect(rows.single.title, '统一后的显示名');
    expect(rows.single.mediaKey, 'galgame-row-42');
    expect(rows.single.mediaKey, isNot(r'D:\Games\LegacyName.exe'));

    await controller.close();
    endpoints.dispose();
  });

  test('BUG-1085：重复台词/标点不计入字数，引擎计数后外部通道行不再双计', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
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
          text: '「こんにちは。」', // 5 字（括号句号不计）
          threadId: 1,
          hookName: 'Unity',
        ),
        GalHookedLine(
          seq: 2,
          timestampMs: 2000,
          text: '「こんにちは。」', // 引擎重发同句 → 0
          threadId: 1,
          hookName: 'Unity',
        ),
        GalHookedLine(
          seq: 3,
          timestampMs: 3000,
          text: 'ありがとう', // 5 字
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
      injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
        List<String> launchArguments = const <String>[],
        String launchWorkdir = '',
        GalJapaneseLocaleMode japaneseLocaleMode =
            kGalDefaultJapaneseLocaleMode,
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
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(1);
    for (int i = 0; i < 40 && service.entries.length < 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(service.entries, hasLength(3));

    // 引擎已计数后，外部 WS 通道送来的同游戏台词不得再计（Luna 并行双计场景）。
    service.appendLine(
      '外部フックの台詞',
      source: TexthookerLineSource.websocket,
    );

    await controller.stopCapture();
    List<ActivityEventRow> rows = const <ActivityEventRow>[];
    for (int i = 0; i < 40 && rows.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      rows =
          await db.getRecentActivityEvents(eventTypes: <String>[kActivityGame]);
    }
    expect(rows, hasLength(1));
    // 5（首句去标点）+ 0（重发）+ 5（ありがとう）；外部行被单计数源门挡下。
    expect(rows.single.charsDelta, 10);

    await controller.close();
    endpoints.dispose();
  });

  test('BUG-1085：引擎无文本时外部通道是唯一计数源，照常计数', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _FakeEngineSource engine = _FakeEngineSource(
      pairedBytes: Uint8List(0),
      audioFormat: null,
      textReady: true,
    );
    final _FakeLoopbackSource loopback = _FakeLoopbackSource();
    final GalHookSessionController controller = GalHookSessionController(
      textService: service,
      isWindows: true,
      targetWow64Probe: (_) async => false,
      injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
        List<String> launchArguments = const <String>[],
        String launchWorkdir = '',
        GalJapaneseLocaleMode japaneseLocaleMode =
            kGalDefaultJapaneseLocaleMode,
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
    service.appendLine(
      '「こんにちは、世界。」', // 7 字
      source: TexthookerLineSource.websocket,
    );

    await controller.stopCapture();
    List<ActivityEventRow> rows = const <ActivityEventRow>[];
    for (int i = 0; i < 40 && rows.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      rows =
          await db.getRecentActivityEvents(eventTypes: <String>[kActivityGame]);
    }
    expect(rows, hasLength(1));
    expect(rows.single.charsDelta, 7);

    await controller.close();
    endpoints.dispose();
  });

  _playTrackerLaunchWiring();
  _playTrackerWiringGuard();
  _bug950Guard();
}

/// P4 B1：游玩时长账本接线（`GalgamePlayTracker` → `galgame_sessions` +
/// 带时长的 game 活动行）。计时语义按状态机既有设计 = 前台聚焦计时（playtime），
/// 与 `galgame_sessions` 表注释「前台窗口计时器」一致。
void _playTrackerLaunchWiring() {
  final String gameDir = p.join(p.rootPrefix(p.current), 'Games', 'Anemoi');
  final String gameExe = p.join(gameDir, 'game.exe');

  /// 与库页启动同参的 launch 用控制器：真 [GalgamePlayTracker]（假 probe +
  /// 1ms 双定时器，1 个 accrual tick = 1「前台秒」）驱动，工厂调用与实例可断言。
  ({
    GalHookSessionController controller,
    _FakePlayProbe probe,
    List<({String gameId, String gameDirectory})> factoryCalls,
    ChangeNotifier endpoints,
  }) buildHarness(FushiDatabase db) {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _FakePlayProbe probe = _FakePlayProbe(
      processes: <int, String>{4242: gameExe},
      foregroundPid: 4242,
    );
    final List<({String gameId, String gameDirectory})> factoryCalls =
        <({String gameId, String gameDirectory})>[];
    final GalHookSessionController controller = GalHookSessionController(
      textService: service,
      isWindows: true,
      exe32BitProbe: (_) async => false,
      injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
        List<String> launchArguments = const <String>[],
        String launchWorkdir = '',
        GalJapaneseLocaleMode japaneseLocaleMode =
            kGalDefaultJapaneseLocaleMode,
      }) =>
          _FakeEngineSource(
        pairedBytes: Uint8List(0),
        audioFormat: null,
        textReady: true,
      ),
      loopbackSourceFactory: _FakeLoopbackSource.new,
      windowListLoader: () async => const <ExternalWindowInfo>[],
      windowPollAttempts: 1,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
      playTrackerFactory: ({
        required String gameId,
        required String gameDirectory,
        required GalgamePlaySessionSink onSessionEnded,
      }) {
        factoryCalls.add((gameId: gameId, gameDirectory: gameDirectory));
        return GalgamePlayTracker(
          gameId: gameId,
          gameDirectory: gameDirectory,
          onSessionEnded: onSessionEnded,
          probe: probe,
          isWindows: true,
          foregroundInterval: const Duration(milliseconds: 1),
          accrualInterval: const Duration(milliseconds: 1),
        );
      },
    );
    controller.attachActivityDatabase(() => db);
    return (
      controller: controller,
      probe: probe,
      factoryCalls: factoryCalls,
      endpoints: endpoints,
    );
  }

  Future<FushiDatabase> openDbWithGame() async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.upsertGalgame(
      GalgamesCompanion.insert(
        id: 'galgame-row-42',
        name: '统一后的显示名',
        exePath: gameExe,
        workdir: gameDir,
        addedAt: 0,
      ),
    );
    return db;
  }

  Future<void> accrueUntil(GalgamePlayTracker tracker, int seconds) async {
    for (int i = 0;
        i < 400 && (tracker.machine?.activeSeconds ?? 0) < seconds;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(tracker.machine?.activeSeconds ?? 0, greaterThanOrEqualTo(seconds));
  }

  test('P4 B1：库页启动接线游玩计时，游戏进程退出自动结算落库', () async {
    final FushiDatabase db = await openDbWithGame();
    final harness = buildHarness(db);

    final GalHookLaunchResult result = await harness.controller.launchGame(
      gameExe,
      gameId: 'galgame-row-42',
      gameTitle: '统一后的显示名',
    );
    expect(result.launched, isTrue);
    // 工厂拿到的是 galgames.id + 由 exe 路径派生的游戏目录（候选进程组判归属用）。
    expect(harness.factoryCalls, hasLength(1));
    expect(harness.factoryCalls.single.gameId, 'galgame-row-42');
    expect(
        harness.factoryCalls.single.gameDirectory, File(gameExe).parent.path);
    final GalgamePlayTracker tracker = harness.controller.playTracker!;
    expect(tracker.isRunning, isTrue);

    await accrueUntil(tracker, kMinSessionSeconds);

    // 游戏进程退出 → 连续判活失败 → 状态机自行结束并结算（无需任何 UI 动作）。
    harness.probe.processes.clear();
    harness.probe.deadPids.add(4242);
    List<GalgameSessionRow> sessions = const <GalgameSessionRow>[];
    for (int i = 0; i < 400 && sessions.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      sessions = await db.getGalgameSessions('galgame-row-42');
    }
    expect(sessions, hasLength(1));
    final GalgameSessionRow session = sessions.single;
    expect(session.durationSeconds, greaterThanOrEqualTo(kMinSessionSeconds));
    expect(session.endMs, greaterThanOrEqualTo(session.startMs));
    expect(
      session.dateKey,
      // 与事实表 dateKey 约定同源：取 endMs 的本地日期。
      matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')),
    );

    // 活动行是时长侧的**对偶写入**：durationMs 有值、charsDelta 恒 null（字符侧
    // 由 hook 文本路径独立写行，两侧 SUM 才不会把同一次游玩计两遍）。
    final List<ActivityEventRow> activities =
        await db.getRecentActivityEvents(eventTypes: <String>[kActivityGame]);
    expect(activities, hasLength(1));
    expect(activities.single.mediaType, kActivityMediaGame);
    expect(activities.single.title, '统一后的显示名');
    expect(activities.single.mediaKey, 'galgame-row-42');
    expect(activities.single.durationMs, session.durationSeconds * 1000);
    expect(activities.single.charsDelta, isNull);
    expect(activities.single.dateKey, session.dateKey);

    // getActivityDailyTotals(kActivityGame) 的 duration 不再恒 0（B1 缺口本体）。
    final List<(String, int, int)> totals =
        await db.getActivityDailyTotals(kActivityGame);
    expect(totals.single.$3, session.durationSeconds * 1000);

    await harness.controller.close();
    harness.endpoints.dispose();
  });

  test('P4 B1：重复启动 → 上一场先结算落库、旧计时器停止不泄漏', () async {
    final FushiDatabase db = await openDbWithGame();
    final harness = buildHarness(db);

    expect(
      (await harness.controller.launchGame(
        gameExe,
        gameId: 'galgame-row-42',
        gameTitle: '统一后的显示名',
      ))
          .launched,
      isTrue,
    );
    final GalgamePlayTracker first = harness.controller.playTracker!;
    await accrueUntil(first, kMinSessionSeconds);

    expect(
      (await harness.controller.launchGame(
        gameExe,
        gameId: 'galgame-row-42',
        gameTitle: '统一后的显示名',
      ))
          .launched,
      isTrue,
    );
    // 入口先 stop 旧计时器并 await 结算写穿，无需轮询即可读到上一场。
    expect(first.isRunning, isFalse);
    expect(await db.getGalgameSessions('galgame-row-42'), hasLength(1));
    final GalgamePlayTracker second = harness.controller.playTracker!;
    expect(identical(first, second), isFalse);
    expect(second.isRunning, isTrue);
    expect(harness.factoryCalls, hasLength(2));

    // 第二场未达门槛即关闭：计时器停止、不落第二行。
    await harness.controller.close();
    expect(second.isRunning, isFalse);
    expect(await db.getGalgameSessions('galgame-row-42'), hasLength(1));
    harness.endpoints.dispose();
  });

  test('P4 B1：app 退出（close / 退出 flush 登记）结算在跑会话', () async {
    final FushiDatabase db = await openDbWithGame();
    final harness = buildHarness(db);
    final int flushBaseline = ExitFlushRegistry.instance.callbackCount;

    expect(
      (await harness.controller.launchGame(
        gameExe,
        gameId: 'galgame-row-42',
        gameTitle: '统一后的显示名',
      ))
          .launched,
      isTrue,
    );
    // 桌面点 X 走 exit(0) 快杀，close 不可靠——启动即登记退出 flush（与超分同款）。
    expect(ExitFlushRegistry.instance.callbackCount, flushBaseline + 1);
    final GalgamePlayTracker tracker = harness.controller.playTracker!;
    await accrueUntil(tracker, kMinSessionSeconds);

    await harness.controller.close();
    expect(tracker.isRunning, isFalse);
    expect(ExitFlushRegistry.instance.callbackCount, flushBaseline);
    expect(await db.getGalgameSessions('galgame-row-42'), hasLength(1));
    harness.endpoints.dispose();
  });

  test('P4 B1：裸 exe 启动（无 galgames.id）不建计时器', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final harness = buildHarness(db);

    expect(
      (await harness.controller.launchGame(gameExe)).launched,
      isTrue,
    );
    expect(harness.factoryCalls, isEmpty);
    expect(harness.controller.playTracker, isNull);

    await harness.controller.close();
    harness.endpoints.dispose();
  });
}

/// P4 B1 源码守卫：钉死「时长账本有人写」。缺口形状（data-layer-p4-plan.md §4）：
/// `GalgamePlayTracker` 在 lib 无构造点、`insertGalgameSession` 无生产调用方——
/// 账本断供后 UI 不红不报，`getActivityDailyTotals(kActivityGame)` 只是恒 0。
void _playTrackerWiringGuard() {
  test('P4 B1 守卫：launch 路径必须接线游玩计时器并落 galgame_sessions', () {
    final File src = File('lib/src/mining/gal_hook_session_controller.dart');
    expect(src.existsSync(), isTrue);
    // 注释里出现的同名字面量不算接线：先剥掉行注释再匹配。
    final String body = src.readAsStringSync().split('\n').map((String line) {
      final int at = line.indexOf('//');
      return at >= 0 ? line.substring(0, at) : line;
    }).join('\n');
    expect(
      body.contains('GalgamePlayTracker('),
      isTrue,
      reason: '生产构造点（默认工厂）不得移除；接线挪家请同步更新本守卫',
    );
    expect(
      body.contains('.insertGalgameSession('),
      isTrue,
      reason: 'galgame_sessions 事实表必须由会话结算 sink 落库（B1）',
    );
    final int launchAt =
        body.indexOf('Future<GalHookLaunchResult> launchGame(');
    expect(launchAt, greaterThan(0), reason: 'launchGame 不存在，守卫需更新');
    final int launchEnd =
        body.indexOf('void _startWindowRebindWatch', launchAt);
    expect(launchEnd, greaterThan(launchAt), reason: '找不到 launchGame 结尾');
    final String launchBody = body.substring(launchAt, launchEnd);
    expect(
      RegExp(r'_startPlayTracker\(').allMatches(launchBody).length,
      2,
      reason: 'launch 的两条成功路径（正常 / 注入失败但游戏在跑）都必须起计时',
    );
    expect(
      launchBody.contains('_stopPlayTracker('),
      isTrue,
      reason: '重复启动必须先结算上一场，否则旧计时器泄漏',
    );
  });
}

/// 假游玩 probe：进程表 = `{pid: exe 路径}`；前台恒返回 [foregroundPid]，
/// [deadPids] 里的 pid 判活失败。
class _FakePlayProbe implements GalgameProcessProbe {
  _FakePlayProbe({required this.processes, this.foregroundPid});

  final Map<int, String> processes;
  int? foregroundPid;
  final Set<int> deadPids = <int>{};

  @override
  int? foregroundProcessId() => foregroundPid;

  @override
  bool isProcessAlive(int pid) =>
      processes.containsKey(pid) && !deadPids.contains(pid);

  @override
  String? processImagePath(int pid) => processes[pid];

  @override
  List<GalgameProcessInfo> listProcesses() => processes.entries
      .map(
        (MapEntry<int, String> entry) =>
            GalgameProcessInfo(pid: entry.key, imagePath: entry.value),
      )
      .toList(growable: false);

  @override
  String? canonicalize(String path) => path;
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
      <String>[
        '_refreshReadinessThrottled',
        '_pollThreadPreviews',
        'engine.pollText',
      ],
      reason: 'v12 的线程预览必须先于文本环轮询，且 BUG-1063 仍要求'
          '语音抓取走 _scheduleLineAudioAttach 的后台队列',
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
    /// 等某个会话事件出现（重试走真实计时器，固定睡眠在忙机器上会假失败）。
    Future<void> waitForEvent(
      GalHookSessionController controller,
      String code, {
      Duration timeout = const Duration(seconds: 5),
    }) async {
      final DateTime deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        if (controller.events.any((GalHookEvent e) => e.code == code)) return;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      fail('等不到会话事件 $code；实际事件：'
          '${controller.events.map((GalHookEvent e) => e.code).toList()}');
    }

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
        injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
        engineSourceFactory: ({
          required int targetPid,
          required String? launchExe,
          required String injectorPath,
          required bool lunaPcHooks,
          int? lunaCodepage,
          List<String> launchArguments = const <String>[],
          String launchWorkdir = '',
          GalJapaneseLocaleMode japaneseLocaleMode =
              kGalDefaultJapaneseLocaleMode,
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
      await waitForEvent(controller, 'engine.attach_recovered');
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
        injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
        engineSourceFactory: ({
          required int targetPid,
          required String? launchExe,
          required String injectorPath,
          required bool lunaPcHooks,
          int? lunaCodepage,
          List<String> launchArguments = const <String>[],
          String launchWorkdir = '',
          GalJapaneseLocaleMode japaneseLocaleMode =
              kGalDefaultJapaneseLocaleMode,
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
      // 不可自愈的失败：确认跳过事件已落，且给足时间也没有任何重试发生。
      await waitForEvent(controller, 'engine.retry_skipped');
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
        injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
        engineSourceFactory: ({
          required int targetPid,
          required String? launchExe,
          required String injectorPath,
          required bool lunaPcHooks,
          int? lunaCodepage,
          List<String> launchArguments = const <String>[],
          String launchWorkdir = '',
          GalJapaneseLocaleMode japaneseLocaleMode =
              kGalDefaultJapaneseLocaleMode,
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
        (await controller.launchGame(r'D:\gal\manosaba\manosaba.exe')).launched,
        isTrue,
      );
      expect(controller.state.phase, GalHookSessionPhase.degraded);
      expect(controller.state.gamePid, 20096);
      expect(controller.state.fallbackReason, 'launch_injection_failed');
      final List<String> codes =
          controller.events.map((GalHookEvent e) => e.code).toList();
      expect(codes, contains('engine.launch_injection_degraded'));
      expect(codes, isNot(contains('engine.launch_or_inject_failed')));

      await waitForEvent(controller, 'engine.attach_recovered');
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
        injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
        engineSourceFactory: ({
          required int targetPid,
          required String? launchExe,
          required String injectorPath,
          required bool lunaPcHooks,
          int? lunaCodepage,
          List<String> launchArguments = const <String>[],
          String launchWorkdir = '',
          GalJapaneseLocaleMode japaneseLocaleMode =
              kGalDefaultJapaneseLocaleMode,
        }) =>
            failing,
        loopbackSourceFactory: _FakeLoopbackSource.new,
        windowListLoader: () async => const <ExternalWindowInfo>[],
        windowPollAttempts: 1,
        endpointListenable: endpoints,
        endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
      );

      final GalHookLaunchResult result =
          await controller.launchGame(r'D:\gal\x\x.exe');
      expect(result.launched, isFalse);
      // BUG-1142：注入失败必须带结构化原因 + native 诊断，不能退化成无信息兜底。
      expect(result.reason, GalHookLaunchFailureReason.injectionFailed);
      expect(
          result.diagnostics.failure, GalHookInjectorFailure.elevationRequired);
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
    int? endTsMs,
  }) async {
    utteranceTimestamps.add(tsMs);
    return utteranceSlice;
  }

  @override
  Future<GalAudioSlice?> grabClipNear(
    int tsMs, {
    int tolMs = 8000,
    int? sourcePtr,
    List<int>? exclude,
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
