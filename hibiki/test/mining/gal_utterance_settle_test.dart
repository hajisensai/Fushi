import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/mining/galgame_audio_encode.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/src/sync/texthooker_ws_client.dart';

/// BUG-1109 守卫：「抓到音频了，但莫名少一截」。
///
/// 两条链各有一个「读得太早」的时刻：
///  ① 引擎 PCM：native `GrabUtterance` 的拼接窗口是前向的 `[ts-200, ts+6000]`，但台词
///     一到（文本轮询 80ms）就读，窗口的前向部分还是空的，只能拼到这句语音已提交给
///     混音器的开头；冻结进 `_lineVoiceCache` 后先到先得，这句就永远缺尾巴。
///  ② 资源原件：hook 还在往 dump 文件里写时就转码/试听，OGG 是分页容器，截断的文件
///     照样解出前半段——表现为「有音频但少一截」而不是报错。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 桩引擎的格式恒为 44.1kHz/单声道/16bit（见 [_GrowingEngine._format]），
  // byteRate = 44100 * 1 * 2 = 88200 B/s，故 4410B=50ms、17640B=200ms、44100B=500ms。
  const int kHalfSecondBytes = 44100;

  GalHookSessionController buildController({
    required TexthookerService service,
    required Listenable endpoints,
    required EngineHookGalAudioSource engine,
    Duration settleMax = const Duration(seconds: 2),
    Duration settleInterval = const Duration(milliseconds: 5),
    GalLoopbackSourceFactory? loopbackSourceFactory,
  }) =>
      GalHookSessionController(
        textService: service,
        isWindows: true,
        loopbackSourceFactory: loopbackSourceFactory,
        targetWow64Probe: (_) async => false,
        injectorResolver: ({required bool is32Bit}) => 'injector.exe',
        engineSourceFactory: ({
          required int targetPid,
          required String? launchExe,
          required String injectorPath,
          required bool lunaPcHooks,
          int? lunaCodepage,
          List<String> launchArguments = const <String>[],
          String launchWorkdir = '',
        }) =>
            engine,
        textPollInterval: const Duration(milliseconds: 5),
        utteranceSettleInterval: settleInterval,
        utteranceSettleMax: settleMax,
        endpointListenable: endpoints,
        endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
      );

  test('BUG-1109 引擎 PCM 按增长收敛取整句，不再停在首取的半句', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    // 语音分块提交：首取只有 50ms，后续两块补到 500ms，之后不再增长（这句播完了）。
    final _GrowingEngine engine = _GrowingEngine(
      stepsByTs: <int, List<int>>{
        654321: <int>[4410, 17640, kHalfSecondBytes],
      },
      lines: const <GalHookedLine>[
        GalHookedLine(
          seq: 7,
          timestampMs: 654321,
          text: 'エンジン音声の台詞',
          threadId: 5,
          hookName: 'Siglus',
        ),
      ],
    );
    final GalHookSessionController controller = buildController(
      service: service,
      endpoints: endpoints,
      engine: engine,
    );

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 13, pid: 777, title: 'Engine game'),
    );
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(5);
    for (int i = 0; i < 40 && service.entries.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final String lineId = service.entries.single.id;
    // 首取就是被截断的那半句——这正是修复前卡里落下的内容。
    expect(service.entries.single.audioDurationMs, 50,
        reason: '台词到达时窗口的前向部分还是空的，首取只能拿到开头');

    for (int i = 0;
        i < 200 && service.entries.single.audioDurationMs != 500;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(service.entries.single.audioDurationMs, 500,
        reason: '收敛必须把后续到达的段补齐成整句');
    expect(service.entries.single.audioBackend, 'engine_pcm');

    // 制卡/试听读的都是同一份缓存：缓存里必须已经是整句，而不是首取的半句。
    final GalTrackPreview? preview =
        await controller.exportLineAudioPreview(lineId);
    expect(preview, isNotNull);
    expect(preview!.durationMs, 500);

    await controller.close();
    endpoints.dispose();
  });

  test('BUG-1109 下一句台词到达即收手，不把下一句的段拼进上一句', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    // 同一批里两句：seq 7 的收敛必须因为 seq 8 已到而立刻收手，
    // 否则 `[ts-200, ts+6000]` 会把下一句的语音也拼进 seq 7。
    final _GrowingEngine engine = _GrowingEngine(
      stepsByTs: <int, List<int>>{
        111111: <int>[4410, kHalfSecondBytes],
        222222: <int>[4410, kHalfSecondBytes],
      },
      lines: const <GalHookedLine>[
        GalHookedLine(
          seq: 7,
          timestampMs: 111111,
          text: '一句目',
          threadId: 5,
          hookName: 'Siglus',
        ),
        GalHookedLine(
          seq: 8,
          timestampMs: 222222,
          text: '二句目',
          threadId: 5,
          hookName: 'Siglus',
        ),
      ],
    );
    final GalHookSessionController controller = buildController(
      service: service,
      endpoints: endpoints,
      engine: engine,
    );

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 13, pid: 777, title: 'Engine game'),
    );
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(5);
    for (int i = 0; i < 40 && service.entries.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    // 给足收敛时间，再断言旧句没有被继续重取。
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(engine.callsFor(111111), 1, reason: '下一句已到，旧句只保留首取，绝不继续往前向窗口里拼');
    expect(engine.callsFor(222222), greaterThan(1), reason: '最新一句仍然正常收敛');

    await controller.close();
    endpoints.dispose();
  });

  test('BUG-1109 下一句在收敛 delay **期间**到达也必须收手（判据每轮复查）', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    // 旧实现只在 `await delay` **之前**查 `_lastTextSeq > line.seq`：下一句在 delay 里
    // 到达时判据已经过期，仍会再抓一次——而那一次的 `[ts-200, ts+6000]` 窗口里已经有
    // 下一句的段，等于把下一句的语音拼进上一句（审查探针实测）。
    final _GrowingEngine engine = _GrowingEngine(
      stepsByTs: <int, List<int>>{
        // 旧句一旦被多抓一次就会长到 1000ms —— 那是混进了下一句的证据。
        111111: <int>[4410, kHalfSecondBytes * 2],
        222222: <int>[4410, kHalfSecondBytes],
      },
      lines: const <GalHookedLine>[
        GalHookedLine(
          seq: 7,
          timestampMs: 111111,
          text: '一句目',
          threadId: 5,
          hookName: 'Siglus',
        ),
      ],
      // 第二句在旧句的第一个收敛 delay（300ms）**中间**才到达。
      laterLines: const <GalHookedLine>[
        GalHookedLine(
          seq: 8,
          timestampMs: 222222,
          text: '二句目',
          threadId: 5,
          hookName: 'Siglus',
        ),
      ],
      laterAfter: const Duration(milliseconds: 60),
    );
    final GalHookSessionController controller = buildController(
      service: service,
      endpoints: endpoints,
      engine: engine,
      settleInterval: const Duration(milliseconds: 300),
      settleMax: const Duration(seconds: 3),
    );

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 13, pid: 777, title: 'Engine game'),
    );
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(5);
    for (int i = 0; i < 200 && service.entries.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(service.entries.length, 2, reason: '第二句必须在收敛 delay 期间就已到达');
    // 越过旧句的第一个 delay 边界，让被漏查的那一轮有机会发生。
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(engine.callsFor(111111), 1,
        reason: 'delay 期间下一句已到，旧句不得再抓——那一次会把下一句拼进来');
    expect(service.entries.first.audioDurationMs, 50,
        reason: '旧句只保留首取；变长即说明混进了下一句的段');

    await controller.close();
    endpoints.dispose();
  });

  test('BUG-1109 行被升格成 game_resource 后收敛立刻收手，不把 backend 改回 engine_pcm',
      () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    // 语音持续变长：只要收敛还在跑，下一轮就一定会写回 engine_pcm。
    final _GrowingEngine engine = _GrowingEngine(
      stepsByTs: <int, List<int>>{
        654321: List<int>.generate(80, (int i) => 4410 * (i + 1)),
      },
      lines: const <GalHookedLine>[
        GalHookedLine(
          seq: 7,
          timestampMs: 654321,
          text: 'リソース昇格',
          threadId: 5,
          hookName: 'Siglus',
        ),
      ],
    );
    final GalHookSessionController controller = buildController(
      service: service,
      endpoints: endpoints,
      engine: engine,
      settleInterval: const Duration(milliseconds: 20),
      settleMax: const Duration(seconds: 5),
    );

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 13, pid: 777, title: 'Engine game'),
    );
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(5);
    for (int i = 0; i < 200 && service.entries.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final String lineId = service.entries.single.id;

    // 延迟资源匹配（`_refreshPendingResourceMatches` / `_promoteLateResourceAudio`）落地：
    // 这行现在有原始 dump 原件，原件永远优先于 PCM 拼接。
    service.updateLineAudio(
      lineId,
      status: TexthookerLineAudioStatus.matched,
      backend: 'game_resource',
      resourceId: 'voice_0001',
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final int callsAfterPromote = engine.callsFor(654321);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(service.entries.single.audioBackend, 'game_resource',
        reason: '升格后仍在跑的收敛绝不能把 backend 改回 engine_pcm');
    expect(service.entries.single.audioResourceId, 'voice_0001');
    expect(engine.callsFor(654321), callsAfterPromote,
        reason: '收敛必须已经退出，不再继续抓 PCM');

    await controller.close();
    endpoints.dispose();
  });

  test('BUG-1109 补录窗口开着时收敛收手，不把「录音中」刷成 matched', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _GrowingEngine engine = _GrowingEngine(
      stepsByTs: <int, List<int>>{
        654321: List<int>.generate(80, (int i) => 4410 * (i + 1)),
      },
      lines: const <GalHookedLine>[
        GalHookedLine(
          seq: 7,
          timestampMs: 654321,
          text: '補録中の台詞',
          threadId: 5,
          hookName: 'Siglus',
        ),
      ],
    );
    final GalHookSessionController controller = buildController(
      service: service,
      endpoints: endpoints,
      engine: engine,
      settleInterval: const Duration(milliseconds: 20),
      settleMax: const Duration(seconds: 5),
      loopbackSourceFactory: _SettleLoopback.new,
    );

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 13, pid: 777, title: 'Engine game'),
    );
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(5);
    for (int i = 0; i < 200 && service.entries.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final String lineId = service.entries.single.id;

    // 用户点「重播并录音」：窗口期内 `_manualRecaptureLines` 还没写（只有
    // finishLineRecapture 才 add），`_isUserAdjudicated` 兜不住这一段。
    expect(await controller.startLineRecapture(lineId), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final int callsAfterRecaptureStart = engine.callsFor(654321);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(
        service.entries.single.audioStatus, TexthookerLineAudioStatus.pending,
        reason: '补录窗口期内这行的状态归用户裁决，收敛不得把它刷成 matched');
    expect(service.entries.single.audioBackend, 'system_loopback');
    expect(service.entries.single.fallbackReason, 'manual_recapture_recording');
    expect(engine.callsFor(654321), callsAfterRecaptureStart,
        reason: '收敛必须已经退出，不再继续抓 PCM');

    await controller.close();
    endpoints.dispose();
  });

  test('BUG-1109 awaitStableVoiceDumpFile 等到 dump 文件停止增长才放行', () async {
    final Directory dir =
        await Directory.systemTemp.createTemp('hibiki-gal-dump-');
    addTearDown(() => dir.delete(recursive: true));
    final File file = File('${dir.path}${Platform.pathSeparator}voice.ogg');
    await file.writeAsBytes(Uint8List(100), flush: true);

    // hook 还在分块写：20ms / 40ms 各补一块，之后停笔。
    final List<Timer> writers = <Timer>[
      Timer(const Duration(milliseconds: 20),
          () => file.writeAsBytesSync(Uint8List(200), mode: FileMode.append)),
      Timer(const Duration(milliseconds: 40),
          () => file.writeAsBytesSync(Uint8List(300), mode: FileMode.append)),
    ];
    addTearDown(() {
      for (final Timer t in writers) {
        t.cancel();
      }
    });

    await awaitStableVoiceDumpFile(
      file,
      pollInterval: const Duration(milliseconds: 10),
      // 静默期必须比写入块之间的间隙长，否则「这一瞬间没在写」会被误判成写完。
      quietPeriod: const Duration(milliseconds: 60),
      timeout: const Duration(seconds: 5),
    );

    expect(file.lengthSync(), 600, reason: '放行时文件必须已经写完，否则转码/试听拿到的是截断的前半段');
  });

  test('BUG-1109 awaitStableVoiceDumpFile 到上限仍在写则 fail-open，不挂死', () async {
    final Directory dir =
        await Directory.systemTemp.createTemp('hibiki-gal-dump-');
    addTearDown(() => dir.delete(recursive: true));
    final File file = File('${dir.path}${Platform.pathSeparator}voice.ogg');
    await file.writeAsBytes(Uint8List(100), flush: true);
    final Timer writer = Timer.periodic(
      const Duration(milliseconds: 5),
      (_) => file.writeAsBytesSync(Uint8List(50), mode: FileMode.append),
    );
    addTearDown(writer.cancel);

    final Stopwatch elapsed = Stopwatch()..start();
    await awaitStableVoiceDumpFile(
      file,
      pollInterval: const Duration(milliseconds: 5),
      quietPeriod: const Duration(milliseconds: 40),
      timeout: const Duration(milliseconds: 120),
    );
    elapsed.stop();

    // 宁可短一点也不能一声不出：到点就放行（Never break）。
    expect(elapsed.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('BUG-1109 dump 文件不存在时立即返回，交调用方按缺文件处理', () async {
    final Directory dir =
        await Directory.systemTemp.createTemp('hibiki-gal-dump-');
    addTearDown(() => dir.delete(recursive: true));
    final Stopwatch elapsed = Stopwatch()..start();
    await awaitStableVoiceDumpFile(
      File('${dir.path}${Platform.pathSeparator}missing.ogg'),
      pollInterval: const Duration(milliseconds: 10),
      quietPeriod: const Duration(milliseconds: 60),
      timeout: const Duration(seconds: 5),
    );
    elapsed.stop();
    expect(elapsed.elapsed, lessThan(const Duration(seconds: 2)));
  });
}

/// 逐次返回**更长** PCM 的引擎桩：模拟游戏把一句语音分块提交给混音器，
/// native 拼接窗口里的段随时间变多。同一 `tsMs` 的取用序列由 [stepsByTs] 给出，
/// 用尽后固定停在最后一个值（这句已经播完，不再增长）。
class _GrowingEngine extends EngineHookGalAudioSource {
  _GrowingEngine({
    required this.stepsByTs,
    required this.lines,
    this.laterLines = const <GalHookedLine>[],
    this.laterAfter = Duration.zero,
  }) : super(targetPid: 0, launchExe: 'fake.exe', injectorPath: 'fake.exe');

  final Map<int, List<int>> stepsByTs;
  final List<GalHookedLine> lines;

  /// 首批之后才到达的台词（[laterAfter] 之后的第一次 pollText 交出）：用来把「下一句
  /// 到达」精确地放进上一句收敛的 `await delay` **中间**。
  final List<GalHookedLine> laterLines;
  final Duration laterAfter;

  final Map<int, int> _calls = <int, int>{};
  final Stopwatch _since = Stopwatch();
  bool _laterDelivered = false;
  int _pollCalls = 0;

  static const PcmFormat _format = PcmFormat(
    sampleRate: 44100,
    channels: 1,
    bitsPerSample: 16,
    isFloat: false,
  );

  int callsFor(int tsMs) => _calls[tsMs] ?? 0;

  @override
  int? get gamePid => 4242;

  @override
  GalHookInjectorDiagnostics get lastFailure =>
      const GalHookInjectorDiagnostics();

  @override
  bool get textHookReady => false;

  @override
  bool get rawVoiceReady => false;

  @override
  bool get pcmReady => true;

  @override
  Future<PcmFormat?> start() async => _format;

  @override
  Future<bool> refreshReadiness() async => false;

  @override
  Future<GalAudioSlice?> grabUtterance(
    int tsMs, {
    int? sourcePtr,
    List<int>? exclude,
  }) async {
    final int index = _calls[tsMs] ?? 0;
    _calls[tsMs] = index + 1;
    final List<int>? steps = stepsByTs[tsMs];
    if (steps == null || steps.isEmpty) return null;
    final int bytes = steps[index < steps.length ? index : steps.length - 1];
    if (bytes <= 0) return null;
    return GalAudioSlice(pcm: Uint8List(bytes), format: _format);
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
    if (_pollCalls == 1) {
      _since.start();
      return GalTextPoll(count: lines.length, lines: lines);
    }
    if (!_laterDelivered &&
        laterLines.isNotEmpty &&
        _since.elapsed >= laterAfter) {
      _laterDelivered = true;
      return GalTextPoll(
        count: lines.length + laterLines.length,
        lines: laterLines,
      );
    }
    return GalTextPoll(
      count: lines.length + laterLines.length,
      lines: const <GalHookedLine>[],
    );
  }

  @override
  Future<bool> selectTextThread(int? threadId) async => true;

  @override
  Future<void> stop() async {}
}

/// 补录窗口用的 loopback 桩：只需要 `start()` 给得出格式，收敛守卫看的是
/// `_recapturingLineId`，与环里到底有没有声音无关。
class _SettleLoopback extends LoopbackGalAudioSource {
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
