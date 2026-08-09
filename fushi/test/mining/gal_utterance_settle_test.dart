import 'dart:async';
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
          GalJapaneseLocaleMode japaneseLocaleMode =
              kGalDefaultJapaneseLocaleMode,
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

    // BUG-1475 契约变更：收手时**允许且只允许**再抓一次「封口 grab」，而且那一次
    // 必须带上下一句的时间戳作前向上界。BUG-1109 要防的是「下一句的段被拼进上一句」，
    // 由上界保住；而「从最后一次成功 grab 到下一句到达之间已进环的那 ≤250ms」本来
    // 时间戳就严格早于下一句，把它一起丢掉是误伤（用户报的「切句打断已捕获的音频」）。
    expect(engine.callsFor(111111), lessThanOrEqualTo(2),
        reason: '旧句最多再抓一次封口 grab，不得继续无界重取');
    final List<int?> bounds = engine.endBoundsFor(111111);
    if (bounds.length > 1) {
      expect(bounds.last, 222222,
          reason: '封口 grab 必须以下一句的 ts 为前向上界，否则就是 BUG-1109 复发');
    }
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
        // 旧句一旦被**无界**多抓一次就会长到 1000ms —— 那是混进了下一句的证据。
        111111: <int>[4410, kHalfSecondBytes * 2],
        222222: <int>[4410, kHalfSecondBytes],
      },
      // BUG-1475：带上界的封口 grab 只能拿回本句自己的尾巴（500ms），
      // 拿不到下一句那半段。这正是「补回尾巴」与「串味」的分界。
      boundedBytesByTs: <int, int>{111111: kHalfSecondBytes},
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

    // BUG-1475：同上，收手时允许一次**带界**的封口 grab。真正要守的不变量是
    // 「不得无界重取」——无界那一次的 `[ts-200, ts+6000]` 里已经有下一句的段。
    expect(engine.callsFor(111111), lessThanOrEqualTo(2),
        reason: 'delay 期间下一句已到，旧句最多再抓一次带界的封口 grab');
    final List<int?> bounds = engine.endBoundsFor(111111);
    for (int i = 1; i < bounds.length; i++) {
      expect(bounds[i], isNotNull, reason: '收手之后的每一次 grab 都必须带前向上界');
      expect(bounds[i], lessThanOrEqualTo(222222),
          reason: '上界不得越过下一句的时间戳，否则就是 BUG-1109 复发');
    }
    // 正面断言封口 grab **确实发生了**并把尾巴补了回来（用户报的「切句打断已捕获的
    // 音频」丢的就是这段），同时**没有**长到 1000ms —— 那个数才是混进下一句的证据。
    expect(engine.callsFor(111111), 2, reason: '收手时必须补一次封口 grab');
    expect(service.entries.first.audioDurationMs, 500,
        reason: '带界的封口 grab 补回本句尾巴；长到 1000 即为串味，停在 50 即为误伤');

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
    this.boundedBytesByTs = const <int, int>{},
  }) : super(targetPid: 0, launchExe: 'fake.exe', injectorPath: 'fake.exe');

  final Map<int, List<int>> stepsByTs;

  /// 带前向上界（`endTsMs` 非空非 0）时该 ts 应当返回的字节数（BUG-1475）。
  ///
  /// 模拟 native 的真实行为：上界把 `[ts-200, ts+forward]` 的右界收窄，于是拿到的
  /// 一定**不多于**无界那次。桩不模拟这一点的话，「上界真的起作用」就测不出来——
  /// 只按调用序号返回会让带界的封口 grab 拿到和无界一样多的数据，等于假绿。
  final Map<int, int> boundedBytesByTs;
  final List<GalHookedLine> lines;

  /// 首批之后才到达的台词（[laterAfter] 之后的第一次 pollText 交出）：用来把「下一句
  /// 到达」精确地放进上一句收敛的 `await delay` **中间**。
  final List<GalHookedLine> laterLines;
  final Duration laterAfter;

  final Map<int, int> _calls = <int, int>{};
  final Map<int, List<int?>> _endBounds = <int, List<int?>>{};
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

  /// 该 ts 上每次 grab 传入的前向上界（BUG-1475）。收敛期的常规 grab 恒为 null/0，
  /// 只有封口 grab 会带下一句的时间戳。
  List<int?> endBoundsFor(int tsMs) => _endBounds[tsMs] ?? const <int?>[];

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
    int? endTsMs,
  }) async {
    final int index = _calls[tsMs] ?? 0;
    _calls[tsMs] = index + 1;
    // BUG-1475：记下每次 grab 的前向上界，供「封口 grab 必须带界」的断言核对。
    (_endBounds[tsMs] ??= <int?>[]).add(endTsMs);
    if (endTsMs != null && endTsMs != 0) {
      final int? bounded = boundedBytesByTs[tsMs];
      if (bounded != null) {
        return bounded <= 0
            ? null
            : GalAudioSlice(pcm: Uint8List(bounded), format: _format);
      }
    }
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
