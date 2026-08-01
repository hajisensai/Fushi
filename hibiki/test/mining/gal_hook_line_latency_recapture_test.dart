import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/mining/galgame_audio_encode.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/src/sync/texthooker_ws_client.dart';

/// BUG-1063：台词显示不得被自己的语音配对拖慢，以及浮窗「重播并录音」补录链路。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> waitUntil(bool Function() done) async {
    for (int i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('语音抓取挂起时后续台词照常显示（BUG-1063 显示延迟根因守卫）', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final Completer<GalAudioSlice?> blockedUtterance =
        Completer<GalAudioSlice?>();
    final _LatencyEngine engine = _LatencyEngine(
      utterance: blockedUtterance.future,
      polledLines: const <GalHookedLine>[
        GalHookedLine(
          seq: 1,
          timestampMs: 1000,
          text: '一句目',
          threadId: 5,
          hookName: 'fake',
        ),
        GalHookedLine(
          seq: 2,
          timestampMs: 2000,
          text: '二句目',
          threadId: 5,
          hookName: 'fake',
        ),
      ],
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
        List<String> launchArguments = const <String>[],
        String launchWorkdir = '',
      }) =>
          engine,
      loopbackSourceFactory: _SilentLoopback.new,
      textPollInterval: const Duration(milliseconds: 5),
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 3, pid: 4242, title: 'Game'),
    );
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(5);
    await waitUntil(() => service.entries.length >= 2);

    expect(
      service.entries.map((TexthookerLineEntry e) => e.text),
      <String>['一句目', '二句目'],
      reason: '第一句的语音抓取还挂着，第二句台词也必须已经显示',
    );
    expect(engine.utteranceCalls, greaterThan(0));

    blockedUtterance.complete(null);
    await controller.close();
    endpoints.dispose();
  });

  test('poll 提速后 readiness 查询仍被降频（不给文本链路加 IPC 往返）', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    DateTime clock = DateTime(2026, 7, 24, 12);
    final _LatencyEngine engine = _LatencyEngine(
      utterance: Future<GalAudioSlice?>.value(),
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
        List<String> launchArguments = const <String>[],
        String launchWorkdir = '',
      }) =>
          engine,
      loopbackSourceFactory: _SilentLoopback.new,
      textPollInterval: const Duration(milliseconds: 5),
      now: () => clock,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 3, pid: 4242, title: 'Game'),
    );
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(5);
    await waitUntil(() => engine.pollCalls >= 8);
    expect(
      engine.readinessCalls,
      lessThan(engine.pollCalls),
      reason: '文本轮询每 tick 都跑，readiness 不能跟着每 tick 做一次 IPC',
    );

    // 时钟推过节流窗口后，晚到的资源 hook 仍能被发现。
    final int before = engine.readinessCalls;
    clock = clock.add(const Duration(seconds: 2));
    await waitUntil(() => engine.readinessCalls > before);
    expect(engine.readinessCalls, greaterThan(before));

    await controller.close();
    endpoints.dispose();
  });

  test('手动补录把 loopback 录到的语音绑定到该行，并优先于资源配对', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _LatencyEngine engine = _LatencyEngine(
      utterance: Future<GalAudioSlice?>.value(),
      audioFormat: null,
      rawReady: true,
      pairedCandidate: true,
    );
    final _SilentLoopback loopback = _SilentLoopback(withPcm: true);
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
        List<String> launchArguments = const <String>[],
        String launchWorkdir = '',
      }) =>
          engine,
      loopbackSourceFactory: () => loopback,
      textPollInterval: const Duration(milliseconds: 5),
      // BUG-1101：逐行 loopback 是延迟冻结的，单测把等待压到 10ms 才能确定地
      // 先看到自动兜底那一次 grabRecent。
      loopbackFreezeDelay: const Duration(milliseconds: 10),
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 3, pid: 4242, title: 'Game'),
    );
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(5);
    final TexthookerLineEntry line = service.appendLine(
      '補録したい台詞',
      source: TexthookerLineSource.websocket,
    )!;

    // 先让会话自身的逐行 loopback 兜底跑完，再补录——否则断言看到的是它写的状态。
    await waitUntil(() => loopback.grabRecentCalls > 0);
    final int autoGrabs = loopback.grabRecentCalls;

    expect(await controller.startLineRecapture(line.id), isTrue);
    expect(controller.isRecapturing, isTrue);
    expect(controller.recapturingLineId, line.id);
    expect(
      service.entries.last.audioStatus,
      TexthookerLineAudioStatus.pending,
    );

    expect(await controller.finishLineRecapture(), isTrue);
    expect(controller.isRecapturing, isFalse);
    final TexthookerLineEntry recaptured = service.entries.last;
    expect(recaptured.audioStatus, TexthookerLineAudioStatus.fallback);
    expect(recaptured.audioBackend, 'system_loopback');
    expect(recaptured.fallbackReason, 'manual_recapture');
    expect(controller.debugIsManualRecapture(line.id), isTrue);
    expect(
      loopback.grabRecentCalls,
      autoGrabs + 1,
      reason: '补录必须自己冻结一段环形缓冲，而不是复用自动兜底的那一段',
    );

    // 补录即用户裁决：制卡不得再回头等资源配对把它顶掉。
    await controller.captureAudioBytes(
      lineId: line.id,
      sentence: line.text,
      outputExtension: 'aac',
    );
    expect(
      engine.pairedRequests,
      isEmpty,
      reason: '补录过的行必须直接用补录切片，不再询问资源语音',
    );

    await controller.close();
    endpoints.dispose();
  });

  test('会话结束会收束补录窗口并停掉临时 loopback', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _LatencyEngine engine = _LatencyEngine(
      utterance: Future<GalAudioSlice?>.value(),
      rawReady: true,
    );
    final List<_SilentLoopback> loopbacks = <_SilentLoopback>[];
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
        List<String> launchArguments = const <String>[],
        String launchWorkdir = '',
      }) =>
          engine,
      loopbackSourceFactory: () {
        final _SilentLoopback source = _SilentLoopback(withPcm: true);
        loopbacks.add(source);
        return source;
      },
      textPollInterval: const Duration(milliseconds: 5),
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 3, pid: 4242, title: 'Game'),
    );
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(5);
    final TexthookerLineEntry line = service.appendLine(
      '会話終了時の台詞',
      source: TexthookerLineSource.websocket,
    )!;
    expect(await controller.startLineRecapture(line.id), isTrue);

    await controller.stopCapture();
    expect(controller.isRecapturing, isFalse);
    for (final _SilentLoopback source in loopbacks) {
      expect(source.stopCalls, greaterThan(0));
    }

    await controller.close();
    endpoints.dispose();
  });
}

class _LatencyEngine extends EngineHookGalAudioSource {
  _LatencyEngine({
    required this.utterance,
    this.polledLines = const <GalHookedLine>[],
    this.audioFormat = const PcmFormat(
      sampleRate: 44100,
      channels: 1,
      bitsPerSample: 16,
      isFloat: false,
    ),
    this.rawReady = false,
    this.pairedCandidate = false,
  }) : super(targetPid: 0, launchExe: 'fake.exe', injectorPath: 'fake.exe');

  final Future<GalAudioSlice?> utterance;
  final List<GalHookedLine> polledLines;
  final PcmFormat? audioFormat;
  final bool rawReady;
  final bool pairedCandidate;

  int pollCalls = 0;
  int readinessCalls = 0;
  int utteranceCalls = 0;
  final List<int> pairedRequests = <int>[];

  @override
  int? get gamePid => 4242;

  @override
  bool get textHookReady => true;

  @override
  bool get rawVoiceReady => rawReady;

  @override
  bool get pcmReady => !rawReady && audioFormat != null;

  @override
  Future<PcmFormat?> start() async => audioFormat;

  @override
  Future<bool> refreshReadiness() async {
    readinessCalls++;
    return rawReady;
  }

  @override
  Future<GalTextPoll?> pollText(int sinceSeq) async {
    pollCalls++;
    return GalTextPoll(
      count: polledLines.length,
      lines: pollCalls == 1 ? polledLines : const <GalHookedLine>[],
    );
  }

  @override
  Future<bool> selectTextThread(int? threadId) async => true;

  @override
  Future<GalAudioSlice?> grabUtterance(
    int tsMs, {
    int? sourcePtr,
    List<int>? exclude,
  }) {
    utteranceCalls++;
    return utterance;
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
  String? findPairedVoiceResourceId(
    int textTsMs, {
    int? textEventId,
    bool allowLatestSessionFallback = true,
  }) =>
      pairedCandidate ? 'fake-$textTsMs.ogg' : null;

  @override
  Future<Uint8List?> grabPairedVoiceBytes(
    int textTsMs, {
    required String outputExtension,
    int? textEventId,
    String? resourceId,
    bool allowLatestSessionFallback = true,
  }) async {
    pairedRequests.add(textTsMs);
    return null;
  }

  @override
  Future<void> stop() async {}
}

class _SilentLoopback extends LoopbackGalAudioSource {
  _SilentLoopback({this.withPcm = false});

  final bool withPcm;
  int startCalls = 0;
  int stopCalls = 0;
  int grabRecentCalls = 0;

  @override
  Future<PcmFormat?> start() async {
    startCalls++;
    return const PcmFormat(
      sampleRate: 44100,
      channels: 2,
      bitsPerSample: 16,
      isFloat: false,
    );
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<GalAudioSlice?> grabRecent(int backMs) async {
    grabRecentCalls++;
    if (!withPcm) return null;
    return GalAudioSlice(
      pcm: Uint8List.fromList(List<int>.filled(64, 3)),
      format: const PcmFormat(
        sampleRate: 44100,
        channels: 2,
        bitsPerSample: 16,
        isFloat: false,
      ),
    );
  }
}
