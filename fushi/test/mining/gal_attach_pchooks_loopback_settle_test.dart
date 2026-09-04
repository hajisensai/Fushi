import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_japanese_locale.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/sync/texthooker_ws_client.dart';

/// BUG-1267 attach 路径不装 LunaHook PC hooks / BUG-2127 制卡必须等 loopback 冻结窗口到点。
///
/// 两条都是「用户中途接管一局已经在跑的游戏」时才暴露的缺陷：
///  ① attach（捕获窗口 / 引擎重试）此前把 `lunaPcHooks` 硬编码成 false，因为它没有
///     exe 路径可喂给 [shouldUseLunaPcHooksForExecutable]——「判据取不到」被写成了
///     「判为否」，于是 Unity/Siglus 目标只要不是 Hibiki 亲自拉起就永远抓不到文本。
///  ② 用户在台词还在播时就查词/制卡：[GalHookSessionController.captureAudioBytes]
///     此前按「已等时长」提前收束 loopback 冻结，卡片只拿到这句语音的前半段（BUG-1287
///     的到点补全只修正列表里的缓存，卡已经写进 Anki）。现在制卡在队列之外先等冻结
///     窗口到点，首次回取就是完整窗口（BUG-2127）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> waitUntil(bool Function() done, {int ticks = 400}) async {
    for (int i = 0; i < ticks && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  group('BUG-1267 attach 模式按 PID→exe 判定 LunaHook PC hooks', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('hibiki_pchooks_test');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    /// 跑一次 attach 捕获，回报工厂实际收到的 `lunaPcHooks`。
    Future<bool?> captureLunaPcHooksForAttach({
      required String? imagePath,
    }) async {
      final TexthookerService service = TexthookerService.test();
      final ChangeNotifier endpoints = ChangeNotifier();
      final _AttachEngine engine = _AttachEngine();
      bool? seen;
      final GalHookSessionController controller = GalHookSessionController(
        textService: service,
        isWindows: true,
        targetWow64Probe: (_) async => false,
        targetImagePathProbe: (_) => imagePath,
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
          String? contentLanguage,
        }) {
          seen = lunaPcHooks;
          return engine;
        },
        loopbackSourceFactory: () => _QuietLoopback(),
        textPollInterval: const Duration(milliseconds: 5),
        endpointListenable: endpoints,
        endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
      );

      await controller.startAttachedCapture(
        const ExternalWindowInfo(hwnd: 21, pid: 4242, title: 'Attached game'),
      );
      // v13：采集期不再按选定线程丢行，过滤挪到消费期，
      // 「选了哪条线程」因此成了本用例的显式前提。
      await controller.selectTextThread(5);
      await waitUntil(() => seen != null);
      await controller.close();
      endpoints.dispose();
      return seen;
    }

    test('Unity/IL2CPP 目标中途接管时补装 PC hooks', () async {
      final String sep = Platform.pathSeparator;
      final String exePath = '${tempDir.path}${sep}game.exe';
      File(exePath).writeAsStringSync('stub');
      // 判据要 UnityPlayer.dll **加上** IL2CPP/Mono 证据，两者缺一不算 Unity 目标。
      File('${tempDir.path}${sep}UnityPlayer.dll').writeAsStringSync('stub');
      File('${tempDir.path}${sep}GameAssembly.dll').writeAsStringSync('stub');

      // 修复前这里恒为 false：injector 拿不到 --luna-pchooks，Unity 的文本线程一条
      // 都建不起来，用户侧表现就是 `text=0`「捕获上了但什么都不出」。
      expect(await captureLunaPcHooksForAttach(imagePath: exePath), isTrue);
    });

    test('非 Unity 目标不会平白多装 PC hooks', () async {
      final String exePath = '${tempDir.path}${Platform.pathSeparator}game.exe';
      File(exePath).writeAsStringSync('stub');

      expect(await captureLunaPcHooksForAttach(imagePath: exePath), isFalse);
    });

    test('只有 UnityPlayer.dll 而无 IL2CPP/Mono 证据时不算 Unity 目标', () async {
      final String sep = Platform.pathSeparator;
      final String exePath = '${tempDir.path}${sep}game.exe';
      File(exePath).writeAsStringSync('stub');
      File('${tempDir.path}${sep}UnityPlayer.dll').writeAsStringSync('stub');

      expect(await captureLunaPcHooksForAttach(imagePath: exePath), isFalse);
    });

    test('PID 查不到 exe 路径时回落到旧行为，不装也不崩', () async {
      expect(await captureLunaPcHooksForAttach(imagePath: null), isFalse);
    });
  });

  /// 建一条「文本 + Loopback」会话并送进一句台词，回报 lineId。
  Future<
      ({
        GalHookSessionController controller,
        TexthookerService service,
        ChangeNotifier endpoints,
        String lineId,
      })> startVoicedLoopbackSession({
    required _ProportionalLoopback loopback,
    required Duration freezeDelay,
    required String text,
  }) async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _AttachEngine engine = _AttachEngine(
      lines: <GalHookedLine>[
        GalHookedLine(
          seq: 1,
          timestampMs: 3000,
          text: text,
          threadId: 5,
          hookName: 'fake',
        ),
      ],
    );
    final GalHookSessionController controller = GalHookSessionController(
      textService: service,
      isWindows: true,
      targetWow64Probe: (_) async => false,
      targetImagePathProbe: (_) => null,
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
        String? contentLanguage,
      }) =>
          engine,
      loopbackSourceFactory: () => loopback,
      textPollInterval: const Duration(milliseconds: 5),
      loopbackFreezeDelay: freezeDelay,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
      startWindowRecording: ({required int hwnd}) async => false,
      stopWindowRecording: () async {},
    );

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 21, pid: 4242, title: 'Attached game'),
    );
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(5);
    await waitUntil(() => service.entries.isNotEmpty);
    return (
      controller: controller,
      service: service,
      endpoints: endpoints,
      lineId: service.entries.single.id,
    );
  }

  test('BUG-2127 语音还在播时制卡：先等冻结窗口到点，首次回取就是完整窗口', () async {
    // 台词到达 → 排一次 400ms 后到点的冻结（完整窗口 backMs = 400 + preRoll 1000）。
    const Duration freezeDelay = Duration(milliseconds: 400);
    final _ProportionalLoopback loopback = _ProportionalLoopback();
    final session = await startVoicedLoopbackSession(
      loopback: loopback,
      freezeDelay: freezeDelay,
      text: 'まだ声の途中で辞書を引いた',
    );

    // 语音还在播（窗口远未到点）时就查词/制卡——这正是用户报的那一刻。
    final Stopwatch waited = Stopwatch()..start();
    await session.controller.captureAudioBytes(
      lineId: session.lineId,
      sentence: session.service.entries.single.text,
      outputExtension: 'wav',
    );
    await waitUntil(() => loopback.backMsCalls.isNotEmpty);

    const int fullBackMs = 400 + 1000; // freezeDelay + _loopbackPreRollMs
    // BUG-1287 的旧契约是「按已等时长提前收束，随后到点补全」——制卡拿到的仍是半句。
    // 新契约：制卡在队列之外等冻结窗口到点，第一次回取就是完整窗口。
    expect(
      loopback.backMsCalls.first,
      fullBackMs,
      reason: '制卡必须等这句语音的冻结窗口到点，而不是按已等时长拿半句',
    );
    expect(
      waited.elapsedMilliseconds,
      greaterThanOrEqualTo(freezeDelay.inMilliseconds - 50),
      reason: '等待发生在 captureAudioBytes 内部',
    );
    expect(
      loopback.backMsCalls.where((int b) => b < fullBackMs),
      isEmpty,
      reason: '没有任何一次按半窗口回取',
    );

    await waitUntil(
      () => session.service.entries.single.audioDurationMs == fullBackMs,
      ticks: 400,
    );
    expect(session.service.entries.single.audioDurationMs, fullBackMs);

    await session.controller.close();
    session.endpoints.dispose();
  });

  test(
      'BUG-2127 §2.4 game_resource 行先 pending 排了冻结、后被资源匹配提升：'
      '制卡零等待取整段原件，不触发那段被丢弃的 loopback 冻结', () async {
    // 冻结窗故意设大：若制卡仍为「已被撤销/终将丢弃」的冻结窗干等，用例会耗到 4s+，
    // 断言 elapsed < 1500ms 会把回归钉红。
    const Duration freezeDelay = Duration(seconds: 4);
    final _ProportionalLoopback loopback = _ProportionalLoopback();
    final _LateResourceEngine engine = _LateResourceEngine(
      lines: <GalHookedLine>[
        GalHookedLine(
          seq: 1,
          timestampMs: 3000,
          text: '資源が文本より遅れて落ちる台詞',
          threadId: 5,
          hookName: 'fake',
        ),
      ],
    );
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final GalHookSessionController controller = GalHookSessionController(
      textService: service,
      isWindows: true,
      targetWow64Probe: (_) async => false,
      targetImagePathProbe: (_) => null,
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
        String? contentLanguage,
      }) =>
          engine,
      loopbackSourceFactory: () => loopback,
      textPollInterval: const Duration(milliseconds: 5),
      loopbackFreezeDelay: freezeDelay,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
      startWindowRecording: ({required int hwnd}) async => false,
      stopWindowRecording: () async {},
    );

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 21, pid: 4242, title: 'Attached game'),
    );
    await controller.selectTextThread(5);
    await waitUntil(() => service.entries.isNotEmpty);
    final String lineId = service.entries.single.id;

    // 资源比文本晚落盘：行到达时 rawVoiceReady=true 但 findPairedVoiceResourceId 返回 null
    // → 行标 pending，并为它排了一个 4s 的 loopback 冻结兜底（这正是 §2.4 描述的时序）。
    await waitUntil(
      () =>
          service.entries.single.audioStatus ==
          TexthookerLineAudioStatus.pending,
    );

    // 资源随后落盘：poll 循环的 _refreshPendingResourceMatches 把行提升为 matched，
    // 并（本次修复）撤掉那个已无意义的冻结定时器。
    engine.revealResource();
    await waitUntil(
      () =>
          service.entries.single.audioStatus ==
          TexthookerLineAudioStatus.matched,
    );

    // 「台词一出就制卡」：资源已固化到本行 → 走整段源 Ogg 分支，零等待。
    final Stopwatch waited = Stopwatch()..start();
    final Uint8List? bytes = await controller.captureAudioBytes(
      lineId: lineId,
      sentence: service.entries.single.text,
      outputExtension: 'm4a',
    );
    waited.stop();

    expect(bytes, isNotNull, reason: '制卡必须拿到整段源资源字节');
    expect(bytes!.isNotEmpty, isTrue);
    expect(
      waited.elapsedMilliseconds,
      lessThan(1500),
      reason: '资源已匹配的行不该为一个终将丢弃的 loopback 冻结窗干等（§2.4）',
    );
    expect(
      loopback.backMsCalls,
      isEmpty,
      reason: '走 game_resource 整段原件，绝不回取 loopback 混音片段',
    );
    expect(service.entries.single.audioBackend, 'game_resource');

    await controller.close();
    endpoints.dispose();
  });

  test('BUG-2127 冻结已到点的历史行：制卡不再多等', () async {
    const Duration freezeDelay = Duration(milliseconds: 100);
    final _ProportionalLoopback loopback = _ProportionalLoopback();
    final session = await startVoicedLoopbackSession(
      loopback: loopback,
      freezeDelay: freezeDelay,
      text: 'もう鳴り終わった台詞',
    );
    // 让冻结自然到点。
    await waitUntil(() => loopback.backMsCalls.isNotEmpty);
    final int callsBefore = loopback.backMsCalls.length;

    final Stopwatch waited = Stopwatch()..start();
    await session.controller.captureAudioBytes(
      lineId: session.lineId,
      sentence: session.service.entries.single.text,
      outputExtension: 'wav',
    );
    expect(
      waited.elapsedMilliseconds,
      lessThan(1000),
      reason: '窗口已到点就没有可等的东西，制卡立即入队',
    );
    // 已冻结的切片直接复用，不需要再回取。
    expect(loopback.backMsCalls.length, callsBefore);

    await session.controller.close();
    session.endpoints.dispose();
  });
}

/// attach 路径用的引擎替身：握手时没有 PCM 格式，于是控制器走「文本 + Loopback」，
/// 正是用户「LE 启动 → hibiki 捕获窗口」那条链。
class _AttachEngine extends EngineHookGalAudioSource {
  _AttachEngine({List<GalHookedLine> lines = const <GalHookedLine>[]})
      : _pending = List<GalHookedLine>.of(lines),
        super(targetPid: 0, launchExe: null, injectorPath: 'fake.exe');

  final List<GalHookedLine> _pending;

  @override
  int? get gamePid => 4242;

  @override
  bool get textHookReady => true;

  @override
  bool get rawVoiceReady => false;

  @override
  PcmFormat? get readyPcmFormat => null;

  @override
  bool get pcmReady => false;

  @override
  Future<PcmFormat?> start() async => null;

  @override
  Future<bool> refreshReadiness() async => false;

  @override
  Future<GalTextPoll?> pollText(int fromSeq) async {
    final List<GalHookedLine> fresh = _pending
        .where((GalHookedLine line) => line.seq > fromSeq)
        .toList(growable: false);
    return GalTextPoll(count: _pending.length, lines: fresh);
  }

  @override
  Future<bool> selectTextThread(int? threadId) async => true;

  @override
  Future<GalAudioSlice?> grabUtterance(
    int tsMs, {
    int? sourcePtr,
    List<int>? exclude,
    int? endTsMs,
  }) async =>
      null;

  @override
  Future<GalAudioSlice?> grabClipNear(
    int tsMs, {
    int tolMs = 8000,
    int? sourcePtr,
    List<int>? exclude,
    int? endTsMs,
  }) async =>
      null;

  @override
  Future<List<GalAudioTrack>> listAudioTracks(int tsMs) async =>
      const <GalAudioTrack>[];

  @override
  String? findPairedVoiceResourceId(
    int textTsMs, {
    int? textEventId,
    bool allowLatestSessionFallback = true,
  }) =>
      null;

  @override
  Future<Uint8List?> grabPairedVoiceBytes(
    int textTsMs, {
    required String outputExtension,
    int? textEventId,
    String? resourceId,
    bool allowLatestSessionFallback = true,
  }) async =>
      null;

  @override
  Future<void> pruneVoiceDump({
    int keepNewest = 400,
    Duration maxAge = const Duration(minutes: 30),
  }) async {}

  @override
  Future<void> stop() async {}
}

/// game_resource（HUNEX/SGRE 式）引擎替身：rawVoiceReady 一直为真，但配对资源 id 先返回
/// null（资源比文本晚落盘），[revealResource] 之后才返回。用来复现 BUG-2127 §2.4：行到达
/// 时先 pending + 排冻结，随后被资源匹配提升。
class _LateResourceEngine extends EngineHookGalAudioSource {
  _LateResourceEngine({List<GalHookedLine> lines = const <GalHookedLine>[]})
      : _pending = List<GalHookedLine>.of(lines),
        super(targetPid: 0, launchExe: null, injectorPath: 'fake.exe');

  final List<GalHookedLine> _pending;
  bool _resourceRevealed = false;

  void revealResource() => _resourceRevealed = true;

  @override
  int? get gamePid => 4242;

  @override
  bool get textHookReady => true;

  // 引擎已握到源资源音频（late game_resource ready），但逐条的配对要等资源落盘。
  @override
  bool get rawVoiceReady => true;

  @override
  PcmFormat? get readyPcmFormat => null;

  @override
  bool get pcmReady => false;

  @override
  Future<PcmFormat?> start() async => null;

  @override
  Future<bool> refreshReadiness() async => false;

  @override
  Future<GalTextPoll?> pollText(int fromSeq) async {
    final List<GalHookedLine> fresh = _pending
        .where((GalHookedLine line) => line.seq > fromSeq)
        .toList(growable: false);
    return GalTextPoll(count: _pending.length, lines: fresh);
  }

  @override
  Future<bool> selectTextThread(int? threadId) async => true;

  @override
  Future<GalAudioSlice?> grabUtterance(
    int tsMs, {
    int? sourcePtr,
    List<int>? exclude,
    int? endTsMs,
  }) async =>
      null;

  @override
  Future<GalAudioSlice?> grabClipNear(
    int tsMs, {
    int tolMs = 8000,
    int? sourcePtr,
    List<int>? exclude,
    int? endTsMs,
  }) async =>
      null;

  @override
  Future<List<GalAudioTrack>> listAudioTracks(int tsMs) async =>
      const <GalAudioTrack>[];

  @override
  String? findPairedVoiceResourceId(
    int textTsMs, {
    int? textEventId,
    bool allowLatestSessionFallback = true,
  }) =>
      _resourceRevealed ? 'res-$textEventId' : null;

  @override
  Future<Uint8List?> grabPairedVoiceBytes(
    int textTsMs, {
    required String outputExtension,
    int? textEventId,
    String? resourceId,
    bool allowLatestSessionFallback = true,
  }) async =>
      _resourceRevealed
          ? Uint8List.fromList(const <int>[0x4F, 0x67, 0x67, 0x53]) // "OggS"
          : null;

  @override
  Future<void> pruneVoiceDump({
    int keepNewest = 400,
    Duration maxAge = const Duration(minutes: 30),
  }) async {}

  @override
  Future<void> stop() async {}
}

/// 只需要给得出格式的安静 loopback（PC hooks 判据与环里有没有声音无关）。
class _QuietLoopback extends LoopbackGalAudioSource {
  @override
  Future<PcmFormat?> start() async => const PcmFormat(
        sampleRate: 44100,
        channels: 2,
        bitsPerSample: 16,
        isFloat: false,
      );

  @override
  Future<void> stop() async {}

  @override
  Future<GalAudioSlice?> grabRecent(int backMs) async => null;
}

/// 回取长度与请求窗口成正比的 loopback：`grabRecent(backMs)` 给出 backMs 毫秒的 PCM。
/// 这样「补全后的切片是否真的更长」可以直接从 `audioDurationMs` 上断言，而不是只看
/// 调用次数——次数对了但写回的还是旧的短切片，同样是没修好。
class _ProportionalLoopback extends LoopbackGalAudioSource {
  _ProportionalLoopback();

  final List<int> backMsCalls = <int>[];

  static const PcmFormat _format = PcmFormat(
    sampleRate: 44100,
    channels: 2,
    bitsPerSample: 16,
    isFloat: false,
  );

  @override
  Future<PcmFormat?> start() async => _format;

  @override
  Future<void> stop() async {}

  @override
  Future<GalAudioSlice?> grabRecent(int backMs) async {
    backMsCalls.add(backMs);
    // byteRate = 44100 * 2ch * 2B = 176400 B/s，故 backMs 毫秒 = backMs * 176.4 B。
    final int bytes = (backMs * _format.byteRate) ~/ 1000;
    return GalAudioSlice(
      pcm: Uint8List.fromList(List<int>.filled(bytes, 9)),
      format: _format,
    );
  }
}
