import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/sync/texthooker_ws_client.dart';

/// BUG-1267 attach 路径不装 LunaHook PC hooks / BUG-1287 提前收束的 loopback 不补全。
///
/// 两条都是「用户中途接管一局已经在跑的游戏」时才暴露的缺陷：
///  ① attach（捕获窗口 / 引擎重试）此前把 `lunaPcHooks` 硬编码成 false，因为它没有
///     exe 路径可喂给 [shouldUseLunaPcHooksForExecutable]——「判据取不到」被写成了
///     「判为否」，于是 Unity/Siglus 目标只要不是 Hibiki 亲自拉起就永远抓不到文本。
///  ② 用户在台词播到中后段才查词/制卡时，[GalHookSessionController.captureAudioBytes]
///     会提前收束那一行的 loopback 冻结；旧实现收束后就再也不碰它，半句话被永久钉死。
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
        injectorResolver: ({required bool is32Bit}) => 'injector.exe',
        engineSourceFactory: ({
          required int targetPid,
          required String? launchExe,
          required String injectorPath,
          required bool lunaPcHooks,
          int? lunaCodepage,
          List<String> launchArguments = const <String>[],
          String launchWorkdir = '',
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

  test('BUG-1287 提前收束后仍按原窗口补全，半句话不再被永久钉死', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    // 台词到达 → 排一次 400ms 后到点的冻结（完整窗口 backMs = 400 + preRoll 1000）。
    const Duration freezeDelay = Duration(milliseconds: 400);
    final _AttachEngine engine = _AttachEngine(
      lines: const <GalHookedLine>[
        GalHookedLine(
          seq: 1,
          timestampMs: 3000,
          text: 'まだ声の途中で辞書を引いた',
          threadId: 5,
          hookName: 'fake',
        ),
      ],
    );
    final _ProportionalLoopback loopback = _ProportionalLoopback();
    final GalHookSessionController controller = GalHookSessionController(
      textService: service,
      isWindows: true,
      targetWow64Probe: (_) async => false,
      targetImagePathProbe: (_) => null,
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
      loopbackSourceFactory: () => loopback,
      textPollInterval: const Duration(milliseconds: 5),
      loopbackFreezeDelay: freezeDelay,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 21, pid: 4242, title: 'Attached game'),
    );
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(5);
    await waitUntil(() => service.entries.isNotEmpty);
    final String lineId = service.entries.single.id;

    // 语音还在播（窗口远未到点）时就查词/制卡——这正是用户报的那一刻。
    await controller.captureAudioBytes(
      lineId: lineId,
      sentence: service.entries.single.text,
      outputExtension: 'wav',
    );
    await waitUntil(() => loopback.backMsCalls.isNotEmpty);

    // 断言全部落在**最终状态**上，不依赖读取时机：captureAudioBytes 内部还有资源等待，
    // 返回时补全可能早已跑完，此刻去读「收束瞬间的时长」拿到的会是补全后的值。
    const int fullBackMs = 400 + 1000; // freezeDelay + _loopbackPreRollMs
    final int flushedBackMs = loopback.backMsCalls.first;
    expect(
      flushedBackMs,
      lessThan(fullBackMs),
      reason: '提前收束只能按已等待时长回取，拿到的必然是这句语音的前半段',
    );

    // 修复前到此为止：定时器被 cancel，这一行再也不会被回取，半句话就是最终结果。
    await waitUntil(
      () => loopback.backMsCalls.contains(fullBackMs),
      ticks: 400,
    );
    expect(
      loopback.backMsCalls,
      contains(fullBackMs),
      reason: '原窗口到点后必须再取一次完整长度 delay + preRoll',
    );

    await waitUntil(
      () => service.entries.single.audioDurationMs == fullBackMs,
      ticks: 400,
    );
    expect(
      service.entries.single.audioDurationMs,
      fullBackMs,
      reason: '补全必须把更长的整句写回去，否则用户听到的还是半句',
    );
    expect(
      service.entries.single.audioDurationMs,
      greaterThan(flushedBackMs),
      reason: '写回的必须严格长于提前收束那一段',
    );

    await controller.close();
    endpoints.dispose();
  });

  test('BUG-1287 补全取空时保留已冻结的短切片，不清空也不缩短', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    const Duration freezeDelay = Duration(milliseconds: 400);
    final _AttachEngine engine = _AttachEngine(
      lines: const <GalHookedLine>[
        GalHookedLine(
          seq: 1,
          timestampMs: 3000,
          text: '補完だけ空振りする場合',
          threadId: 5,
          hookName: 'fake',
        ),
      ],
    );
    // 让**补全那一次**（完整窗口 400+1000）取空：环里这一段已被后续音频挤掉。
    final _ProportionalLoopback loopback =
        _ProportionalLoopback(nullWhenBackMs: 1400);
    final GalHookSessionController controller = GalHookSessionController(
      textService: service,
      isWindows: true,
      targetWow64Probe: (_) async => false,
      targetImagePathProbe: (_) => null,
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
      loopbackSourceFactory: () => loopback,
      textPollInterval: const Duration(milliseconds: 5),
      loopbackFreezeDelay: freezeDelay,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 21, pid: 4242, title: 'Attached game'),
    );
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(5);
    await waitUntil(() => service.entries.isNotEmpty);
    final String lineId = service.entries.single.id;

    await controller.captureAudioBytes(
      lineId: lineId,
      sentence: service.entries.single.text,
      outputExtension: 'wav',
    );
    await waitUntil(() => loopback.backMsCalls.isNotEmpty);
    final int frozenBackMs = loopback.backMsCalls.first;

    // 等补全那一次真的发生过（它会取空）。
    await waitUntil(() => loopback.backMsCalls.contains(1400), ticks: 400);
    // 再等几拍，确认没有任何异步回调把这一行翻成 missing。
    await Future<void>.delayed(const Duration(milliseconds: 60));

    // 只断言时长而**不**断言 audioStatus：本装置里 captureAudioBytes 注定产不出字节
    // （没有真实编码器/资源），它自己那条失败路径会把行标成 missing，与补全无关。
    // 「补全取空有没有毁掉已冻结的那段」的真正证据就是时长原封不动。
    // ±1ms 是 PCM 字节数两次整除的舍入（backMs→bytes→durationMs），不是长度变化。
    expect(
      service.entries.single.audioDurationMs,
      closeTo(frozenBackMs, 1),
      reason: '补全取空时必须原样保留提前收束冻下来的那段，不能被清掉或缩短',
    );

    await controller.close();
    endpoints.dispose();
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
  _ProportionalLoopback({this.nullWhenBackMs});

  /// 恰好这个回取窗口返回 null。按 **backMs 值**而不是调用序号来定位，才能精确命中
  /// 「补全那一次」——captureAudioBytes 内部还会为别的用途取音频，按序号会误伤。
  final int? nullWhenBackMs;

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
    if (nullWhenBackMs != null && backMs == nullWhenBackMs) {
      return null;
    }
    // byteRate = 44100 * 2ch * 2B = 176400 B/s，故 backMs 毫秒 = backMs * 176.4 B。
    final int bytes = (backMs * _format.byteRate) ~/ 1000;
    return GalAudioSlice(
      pcm: Uint8List.fromList(List<int>.filled(bytes, 9)),
      format: _format,
    );
  }
}
