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

/// BUG-1107 守卫：「抓到音频了，但莫名少一截」。
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
  }) =>
      GalHookSessionController(
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
          List<String> launchArguments = const <String>[],
          String launchWorkdir = '',
        }) =>
            engine,
        textPollInterval: const Duration(milliseconds: 5),
        utteranceSettleInterval: const Duration(milliseconds: 5),
        utteranceSettleMax: settleMax,
        endpointListenable: endpoints,
        endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
      );

  test('BUG-1107 引擎 PCM 按增长收敛取整句，不再停在首取的半句', () async {
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

  test('BUG-1107 下一句台词到达即收手，不把下一句的段拼进上一句', () async {
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

  test('BUG-1107 awaitStableVoiceDumpFile 等到 dump 文件停止增长才放行', () async {
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

  test('BUG-1107 awaitStableVoiceDumpFile 到上限仍在写则 fail-open，不挂死', () async {
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

  test('BUG-1107 dump 文件不存在时立即返回，交调用方按缺文件处理', () async {
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
  _GrowingEngine({required this.stepsByTs, required this.lines})
      : super(targetPid: 0, launchExe: 'fake.exe', injectorPath: 'fake.exe');

  final Map<int, List<int>> stepsByTs;
  final List<GalHookedLine> lines;
  final Map<int, int> _calls = <int, int>{};
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
  Future<GalAudioSlice?> grabClipNear(int tsMs, {int tolMs = 8000}) async =>
      null;

  @override
  Future<GalTextPoll?> pollText(int sinceSeq) async {
    _pollCalls++;
    return GalTextPoll(
      count: lines.length,
      lines: _pollCalls == 1 ? lines : const <GalHookedLine>[],
    );
  }

  @override
  Future<bool> selectTextThread(int? threadId) async => true;

  @override
  Future<void> stop() async {}
}
