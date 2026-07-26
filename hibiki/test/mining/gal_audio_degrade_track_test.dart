import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/gal_hook_failure_text.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/mining/galgame_audio_encode.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/src/sync/texthooker_ws_client.dart';

/// BUG-1100 降级不可恢复 / BUG-1101 降级下音频配错句 / BUG-1102 活跃音轨面板无效 /
/// BUG-1094 手动补录固定 8 秒，以及「单条台词可改对应音轨」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const PcmFormat kPcm = PcmFormat(
    sampleRate: 48000,
    channels: 2,
    bitsPerSample: 16,
    isFloat: false,
  );

  Future<void> waitUntil(bool Function() done, {int ticks = 400}) async {
    for (int i = 0; i < ticks && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  GalHookSessionController build({
    required TexthookerService service,
    required Listenable endpoints,
    required _FakeEngine engine,
    required _RecordingLoopback loopback,
    required DateTime Function() now,
    Duration loopbackFreezeDelay = const Duration(milliseconds: 20),
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
          // PR#427 给工厂加了 launch 专用可选参数；本 fake 不关心其取值，
          // 但签名必须跟上 typedef，否则赋值类型不兼容。
          List<String> launchArguments = const <String>[],
          String launchWorkdir = '',
        }) =>
            engine,
        loopbackSourceFactory: () => loopback,
        textPollInterval: const Duration(milliseconds: 5),
        loopbackFreezeDelay: loopbackFreezeDelay,
        now: now,
        endpointListenable: endpoints,
        endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
      );

  test('BUG-1100 引擎 PCM 晚到时把降级的 Loopback 升格回引擎，且不重放台词', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    DateTime clock = DateTime(2020, 1, 1, 12);
    final _FakeEngine engine = _FakeEngine(
      lines: const <GalHookedLine>[
        GalHookedLine(
          seq: 1,
          timestampMs: 1000,
          text: 'まだ声は鳴っていない',
          threadId: 5,
          hookName: 'fake',
        ),
      ],
    );
    final _RecordingLoopback loopback = _RecordingLoopback();
    final GalHookSessionController controller = build(
      service: service,
      endpoints: endpoints,
      engine: engine,
      loopback: loopback,
      now: () => clock,
    );

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 3, pid: 4242, title: 'Game'),
    );
    // 游戏刚启动、一句语音都没播：hook 装好了但共享内存里没有格式 -> 临时 Loopback。
    expect(controller.state.phase, GalHookSessionPhase.degraded);
    expect(controller.state.audioBackend, GalHookAudioBackend.systemLoopback);
    expect(controller.state.fallbackReason, 'engine_pcm_unavailable');
    await waitUntil(() => service.entries.isNotEmpty);
    expect(service.entries, hasLength(1));

    // 玩家推进到第一句语音：helper 通过与 start() 相同的就绪门给出格式。
    engine.readyFormat = kPcm;
    await waitUntil(() {
      clock = clock.add(const Duration(seconds: 1));
      return controller.state.audioBackend == GalHookAudioBackend.enginePcm;
    });

    expect(
      controller.state.audioBackend,
      GalHookAudioBackend.enginePcm,
      reason: '「还没播过语音」只能是临时降级，不能是终局',
    );
    expect(controller.state.audioFormat, kPcm);
    expect(controller.state.fallbackReason, isNull);
    expect(controller.state.phase, GalHookSessionPhase.running);
    expect(loopback.stopCalls, 1, reason: '升格后必须停掉降级用的 Loopback');
    expect(engine.stopCalls, 0, reason: '升格复用存活的 engine，不得重新注入');
    expect(
      service.entries,
      hasLength(1),
      reason: '升格不得重置文本轮询游标，否则整段历史台词会被重放一遍',
    );

    await controller.close();
    endpoints.dispose();
  });

  test('BUG-1100 降级原因必须有人话文案，不再把内部代码甩给用户', () {
    expect(galHookFallbackLabel('engine_pcm_unavailable'), isNotNull);
    expect(galHookFallbackLabel('engine_pcm_unavailable'),
        isNot('engine_pcm_unavailable'));
    expect(galHookFallbackLabel('all_audio_sources_failed'), isNotNull);
    expect(galHookFallbackLabel('window_not_found'), isNotNull);
    expect(galHookFallbackLabel('engine_attach_failed'), isNotNull);
    expect(galHookFallbackLabel('launch_injection_failed'), isNotNull);
    expect(galHookFallbackLabel('helper_missing'), isNotNull);
    expect(galHookFallbackLabel('target_missing'), isNotNull);
    expect(
      galHookFallbackLabel('some_future_reason'),
      isNull,
      reason: '未知代码返回 null 让调用方显示原始代码，绝不编造原因',
    );

    final String page = File(
      'lib/src/pages/implementations/texthooker_page.dart',
    ).readAsStringSync();
    expect(
      page.contains('galHookFallbackLabel(state.fallbackReason!)'),
      isTrue,
      reason: '状态卡必须先翻译降级原因，再才回退内部代码',
    );
  });

  test('BUG-1101 逐行 loopback 改为延迟冻结：窗口向前，不再抓上一句', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    DateTime clock = DateTime(2020, 1, 1, 12);
    final _FakeEngine engine = _FakeEngine(
      lines: const <GalHookedLine>[
        GalHookedLine(
          seq: 1,
          timestampMs: 1000,
          text: 'この台詞の声',
          threadId: 5,
          hookName: 'fake',
        ),
      ],
    );
    final _RecordingLoopback loopback = _RecordingLoopback();
    final GalHookSessionController controller = build(
      service: service,
      endpoints: endpoints,
      engine: engine,
      loopback: loopback,
      now: () => clock,
      loopbackFreezeDelay: const Duration(milliseconds: 150),
    );

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 3, pid: 4242, title: 'Game'),
    );
    await waitUntil(() => service.entries.isNotEmpty);
    expect(service.entries, hasLength(1));
    expect(
      loopback.backMsCalls,
      isEmpty,
      reason: '台词刚到就 grabRecent 只会抓到上一句 + BGM，本句语音还没播',
    );

    await waitUntil(() => loopback.backMsCalls.isNotEmpty);
    expect(
      loopback.backMsCalls,
      <int>[150 + 1000],
      reason: '窗口必须等价于 [t0-preRoll, t0+delay]：延后 delay 再回取 delay+preRoll',
    );
    expect(service.entries.single.audioBackend, 'system_loopback');
    expect(
      service.entries.single.audioStatus,
      TexthookerLineAudioStatus.fallback,
    );

    await controller.close();
    endpoints.dispose();
  });

  test('BUG-1101 制卡提前收束延迟冻结，不会拿一份还没冻的空缓存报 missing', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    DateTime clock = DateTime(2020, 1, 1, 12);
    final _FakeEngine engine = _FakeEngine(
      lines: const <GalHookedLine>[
        GalHookedLine(
          seq: 1,
          timestampMs: 1000,
          text: 'すぐカードにしたい',
          threadId: 5,
          hookName: 'fake',
        ),
      ],
    );
    final _RecordingLoopback loopback = _RecordingLoopback();
    final GalHookSessionController controller = build(
      service: service,
      endpoints: endpoints,
      engine: engine,
      loopback: loopback,
      now: () => clock,
      // 长到本轮绝不会自然到点：只能由制卡提前收束触发。
      loopbackFreezeDelay: const Duration(seconds: 30),
    );

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 3, pid: 4242, title: 'Game'),
    );
    await waitUntil(() => service.entries.isNotEmpty);
    expect(loopback.backMsCalls, isEmpty);

    final TexthookerLineEntry line = service.entries.single;
    clock = clock.add(const Duration(milliseconds: 2500));
    await controller.captureAudioBytes(
      lineId: line.id,
      sentence: line.text,
      outputExtension: 'aac',
    );

    expect(
      loopback.backMsCalls,
      hasLength(1),
      reason: '制卡就是「现在就要这段声音」，必须提前收束而不是白等满窗口',
    );
    expect(
      loopback.backMsCalls.single,
      2500 + 1000,
      reason: '提前收束按真实已等待时长回取',
    );

    await controller.close();
    endpoints.dispose();
  });

  test('BUG-1102 选轨是否生效只由音频后端决定（与列表空不空无关）', () {
    expect(
      galTrackSelectionAffectsCapture(GalHookAudioBackend.enginePcm),
      isTrue,
    );
    expect(
      galTrackSelectionAffectsCapture(GalHookAudioBackend.gameResource),
      isFalse,
    );
    expect(
      galTrackSelectionAffectsCapture(GalHookAudioBackend.systemLoopback),
      isFalse,
    );
    expect(galTrackSelectionAffectsCapture(GalHookAudioBackend.none), isFalse);

    final String page = File(
      'lib/src/pages/implementations/game_diagnostics_page.dart',
    ).readAsStringSync();
    final int cardAt = page.indexOf('class _AudioTracksCard');
    expect(cardAt, greaterThan(0));
    final String card = page.substring(cardAt);
    expect(
      card.contains('galTrackSelectionAffectsCapture(state.audioBackend)'),
      isTrue,
      reason: '解释/禁用判据必须是后端，不能再是 audioTracks.isEmpty',
    );
    expect(
      card.contains('state.audioTracks.isEmpty && emptyHint'),
      isFalse,
      reason: '列表非空时解释态被跳过，正是 BUG-1102 里整套死控件照常渲染的原因',
    );
    expect(card.contains('selectable: selectionEffective'), isTrue);
    expect(card.contains('enabled: selectable && !excluded'), isTrue,
        reason: '非引擎 PCM 后端必须禁用「选为语音轨」');
    expect(card.contains('t.game_track_no_clips'), isTrue,
        reason: 'clipCount == 0 的轨必须标注，而不是和可用轨长一个样');
    expect(card.contains('t.game_tracks_pcm_only_hint'), isTrue);
  });

  test('单条台词改音轨：绕开自动门取音，且延迟资源匹配不得改回去', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    DateTime clock = DateTime(2020, 1, 1, 12);
    final _FakeEngine engine = _FakeEngine(
      // 资源语音就绪 + 每句都能配到资源：自动链路会把这行判成 game_resource。
      rawVoice: true,
      pairedCandidate: true,
      utterance: GalAudioSlice(pcm: Uint8List(9600), format: kPcm),
      lines: const <GalHookedLine>[
        GalHookedLine(
          seq: 1,
          timestampMs: 4321,
          text: '別の声が当てられた台詞',
          threadId: 5,
          hookName: 'fake',
        ),
      ],
    );
    final _RecordingLoopback loopback = _RecordingLoopback();
    final GalHookSessionController controller = build(
      service: service,
      endpoints: endpoints,
      engine: engine,
      loopback: loopback,
      now: () => clock,
    );

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 3, pid: 4242, title: 'Game'),
    );
    await waitUntil(() => service.entries.isNotEmpty);
    final TexthookerLineEntry line = service.entries.single;
    expect(line.audioResourceId, isNotNull, reason: '前提：自动链路已配上资源语音');

    expect(await controller.setLineVoiceTrack(line.id, 0xABC), isTrue);
    expect(engine.utteranceSourcePtrs, <int>[0xABC],
        reason: '必须按用户选的轨重抓，且不经过自动选源的 exclude 集合');
    expect(controller.debugLineVoiceSourcePtr(line.id), 0xABC);

    final TexthookerLineEntry overridden = service.entries.single;
    expect(overridden.audioBackend, 'engine_pcm');
    expect(overridden.audioResourceId, isNull);
    expect(overridden.fallbackReason, 'manual_track_override');

    // 后续轮询的资源匹配必须让路，不得把用户裁决改回 game_resource。
    final int pollsBefore = engine.pollCalls;
    await waitUntil(() => engine.pollCalls > pollsBefore + 4);
    expect(service.entries.single.audioResourceId, isNull);
    expect(service.entries.single.audioBackend, 'engine_pcm');

    // 制卡也必须直接用这段，不再回头问资源语音。
    engine.pairedRequests.clear();
    await controller.captureAudioBytes(
      lineId: line.id,
      sentence: line.text,
      outputExtension: 'aac',
    );
    expect(engine.pairedRequests, isEmpty);

    await controller.close();
    endpoints.dispose();
  });

  test('BUG-1094 补录窗口与回取上限解耦：常量与错误注释都必须改掉', () {
    final String src = File(
      'lib/src/mining/gal_hook_session_controller.dart',
    ).readAsStringSync();
    expect(
      src.contains('_galAudioBackMs'),
      isFalse,
      reason: '一个 8000 的常量同时当补录窗口和回取上限，两个语义都被它绑死',
    );
    expect(
      src.contains('static const int _loopbackRingCapacityMs = 60000;'),
      isTrue,
    );
    expect(src.contains('kRingSeconds = 60'), isTrue,
        reason: '必须记下环容量的真相源（native audio_loopback_capture.cpp）');
    expect(
      src.contains(
        'elapsedMs.clamp(_recaptureMinBackMs, _loopbackRingCapacityMs)',
      ),
      isTrue,
      reason: '回取上限应是环的真实容量，不是补录窗口时长',
    );
    expect(
      src.contains('环形缓冲实际保留 60 秒'),
      isTrue,
      reason: '旧注释「8 秒是因为环只有这么长」是错的，必须在原地写清真值',
    );
    expect(
      src.contains(
          'static const Duration _recaptureWindow = Duration(seconds:'),
      isTrue,
      reason: '补录窗口必须是自己的时长常量，不再由回取上限换算而来',
    );
  });

  test('BUG-1094 新台词到达即收束补录窗口（定时器不再是唯一自动收束源）', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    DateTime clock = DateTime(2020, 1, 1, 12);
    final _FakeEngine engine = _FakeEngine(
      lines: const <GalHookedLine>[
        GalHookedLine(
          seq: 1,
          timestampMs: 1000,
          text: '一句目',
          threadId: 5,
          hookName: 'fake',
        ),
      ],
    );
    final _RecordingLoopback loopback = _RecordingLoopback();
    final GalHookSessionController controller = build(
      service: service,
      endpoints: endpoints,
      engine: engine,
      loopback: loopback,
      now: () => clock,
    );

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 3, pid: 4242, title: 'Game'),
    );
    await waitUntil(() => service.entries.isNotEmpty);
    final TexthookerLineEntry first = service.entries.single;

    expect(await controller.startLineRecapture(first.id), isTrue);
    expect(controller.isRecapturing, isTrue);

    // 玩家翻页：新台词到达 = 这句已经过去了，补录窗口没有继续开着的理由。
    engine.enqueue(const GalHookedLine(
      seq: 2,
      timestampMs: 2000,
      text: '二句目',
      threadId: 5,
      hookName: 'fake',
    ));
    await waitUntil(() => !controller.isRecapturing);
    expect(controller.isRecapturing, isFalse);
    expect(controller.recapturingLineId, isNull);

    await controller.close();
    endpoints.dispose();
  });
}

/// 可控就绪状态 / 可排队台词的引擎 helper 替身。
class _FakeEngine extends EngineHookGalAudioSource {
  _FakeEngine({
    List<GalHookedLine> lines = const <GalHookedLine>[],
    this.rawVoice = false,
    this.pairedCandidate = false,
    this.utterance,
  })  : _pending = List<GalHookedLine>.of(lines),
        super(targetPid: 0, launchExe: 'fake.exe', injectorPath: 'fake.exe');

  final List<GalHookedLine> _pending;
  final bool rawVoice;
  final bool pairedCandidate;
  final GalAudioSlice? utterance;

  /// 会话运行中才出现的引擎 PCM 就绪格式（BUG-1100 的升格触发点）。
  PcmFormat? readyFormat;

  int pollCalls = 0;
  int stopCalls = 0;
  final List<int> utteranceSourcePtrs = <int>[];
  final List<int> pairedRequests = <int>[];

  void enqueue(GalHookedLine line) => _pending.add(line);

  @override
  int? get gamePid => 4242;

  @override
  bool get textHookReady => true;

  @override
  bool get rawVoiceReady => rawVoice;

  @override
  PcmFormat? get readyPcmFormat => readyFormat;

  @override
  bool get pcmReady => readyFormat != null;

  /// 握手那一刻没有 PCM 格式：控制器据此走「文本 + Loopback」临时降级。
  @override
  Future<PcmFormat?> start() async => null;

  @override
  Future<bool> refreshReadiness() async => rawVoice;

  @override
  Future<GalTextPoll?> pollText(int fromSeq) async {
    pollCalls++;
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
  }) async {
    if (sourcePtr != null) utteranceSourcePtrs.add(sourcePtr);
    return utterance;
  }

  @override
  Future<GalAudioSlice?> grabClipNear(int tsMs, {int tolMs = 8000}) async =>
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
  Future<void> pruneVoiceDump({
    int keepNewest = 400,
    Duration maxAge = const Duration(minutes: 30),
  }) async {}

  @override
  Future<void> stop() async {
    stopCalls++;
  }
}

/// 记录每次 `grabRecent` 的回取长度，用来断言窗口而不是只断言「调了没」。
class _RecordingLoopback extends LoopbackGalAudioSource {
  int startCalls = 0;
  int stopCalls = 0;
  final List<int> backMsCalls = <int>[];

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
    backMsCalls.add(backMs);
    return GalAudioSlice(
      pcm: Uint8List.fromList(List<int>.filled(1024, 5)),
      format: const PcmFormat(
        sampleRate: 44100,
        channels: 2,
        bitsPerSample: 16,
        isFloat: false,
      ),
    );
  }
}
