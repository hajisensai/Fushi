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

import '../helpers/source_guard.dart';

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
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(5);
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

    // ── 会话卡这一侧：锚点钉在**契约**上，不是某个页面里的字面调用串 ──────────
    //
    // 旧判据是 `page.contains('galHookFallbackLabel(state.fallbackReason!)')`。
    // 它守的不是不变式，是「那一行长什么样」：PR#753（BUG-1446）把三级取值收口成
    // 共享入口 `galHookFallbackHeadline(failure:, fallbackReason:)` 之后，不变式
    // **被保留而且加强了**（内联表达式 → 单一入口），字面串却没了，守卫当场转红。
    // 同型事故本仓已有两次：PR#758 的 `SetTimer(` token 禁令、9fd30d281 的字面量锚点。
    //
    // 新判据问的是真正要守的那句话：**内部代码 `state.fallbackReason` 被交给了谁？**
    // 接收它的那个调用，必须直接、或经 gal_hook_failure_text.dart 里的共享入口一跳，
    // 落到翻译表 [galHookFallbackLabel] 上。把原始代码直接塞进 `Text(...)`
    // ——BUG-1100 的原始症状——无论重构成哪种形状都拿不到这条可达性。
    //
    // 三处「绝不静默变绿」：卡片类改名 → `balancedBlockFrom` 之前的断言先红；
    // 降级原因整行被删 → `enclosingCallOf` 找不到锚点直接 fail；
    // 换成本文件之外定义的中转函数 → 解析不到实现体，判 false 并在失败信息里点名。
    final String card = _sessionOverviewCardSource();
    final EnclosingCall sink = enclosingCallOf(card, 'state.fallbackReason!');
    expect(
      _routesThroughFallbackLabel(sink.name),
      isTrue,
      reason: '状态卡必须先翻译降级原因，翻不到才回退内部代码；'
          '现在它把内部代码直接交给了 `${sink.name}(...)`，'
          '而这个调用既不是 $_kFallbackLabel，也不是 '
          '$_kFailureTextPath 里任何一个会先查翻译表的共享入口',
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
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(5);
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
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(5);
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

    // 轨列表内容体已抽到共享面板（诊断页与捕获工作台音轨对话框同一份），
    // BUG-1102 的判据守卫跟着真相走：扫共享面板文件，另确认诊断页在消费它。
    final String panel = File(
      'lib/src/mining/gal_audio_tracks_panel.dart',
    ).readAsStringSync();
    expect(
      panel.contains('galTrackSelectionAffectsCapture(state.audioBackend)'),
      isTrue,
      reason: '解释/禁用判据必须是后端，不能再是 audioTracks.isEmpty',
    );
    expect(
      panel.contains('state.audioTracks.isEmpty && emptyHint'),
      isFalse,
      reason: '列表非空时解释态被跳过，正是 BUG-1102 里整套死控件照常渲染的原因',
    );
    expect(panel.contains('selectable: selectionEffective'), isTrue);
    expect(panel.contains('enabled: selectable && !excluded'), isTrue,
        reason: '非引擎 PCM 后端必须禁用「选为语音轨」');
    expect(panel.contains('t.game_track_silent_at_cue'), isTrue,
        reason: '此刻没有声音的轨必须标注，而不是和可用轨长一个样');
    // BUG-1165：判据不得再用 clipCount——native 的 clip_count 是全环累计，一条轨
    // 能被列出就至少有 1 个片段，`clipCount <= 0` 恒假，置灰从来没生效过。
    expect(panel.contains('track.clipCount <= 0'), isFalse,
        reason: 'clipCount 是全环累计，拿它判「此刻有没有声音」恒为假');
    expect(panel.contains('final bool silent = track.isSilentAtCue'), isTrue,
        reason: '静音判据必须走文本时刻窗能量（与试听抓取用同一个窗）');
    expect(panel.contains('t.game_tracks_pcm_only_hint'), isTrue);
    final String page = File(
      'lib/src/pages/implementations/game_diagnostics_page.dart',
    ).readAsStringSync();
    expect(page.contains('GalAudioTracksPanel('), isTrue,
        reason: '诊断页必须消费共享面板，不得另写一份轨列表');

    final String workbench = File(
      'lib/src/pages/implementations/texthooker_page.dart',
    ).readAsStringSync();
    expect(workbench.contains('_session.setTrackExcluded'), isTrue,
        reason: '捕获工作台逐句选轨弹窗必须能直接把 BGM 轨加入排除集合');
    expect(workbench.contains('t.game_track_exclude_bgm'), isTrue);
    expect(workbench.contains('t.game_track_restore'), isTrue);
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
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(5);
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

  test('逐句选轨试听与确认必须使用同一句时间戳', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    DateTime clock = DateTime(2020, 1, 1, 12);
    final _FakeEngine engine = _FakeEngine(
      rawVoice: true,
      pairedCandidate: true,
      utterance: GalAudioSlice(pcm: Uint8List(9600), format: kPcm),
      lines: const <GalHookedLine>[
        GalHookedLine(
          seq: 1,
          timestampMs: 4321,
          text: '先に表示された台詞',
          threadId: 5,
          hookName: 'fake',
        ),
        GalHookedLine(
          seq: 2,
          timestampMs: 9876,
          text: 'いま一番新しい台詞',
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
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(5);
    await waitUntil(() => service.entries.length == 2);
    final TexthookerLineEntry first = service.entries.first;
    engine.utteranceTimestamps.clear();
    engine.utteranceSourcePtrs.clear();

    final GalTrackPreview? preview =
        await controller.exportLineTrackPreview(first.id, 0xABC);
    expect(preview, isNotNull);
    expect(await controller.setLineVoiceTrack(first.id, 0xABC), isTrue);
    expect(engine.utteranceTimestamps, <int>[4321, 4321],
        reason: '试听若偷用最新句 9876，用户会听见声音但确认当前句时却得到无音轨');
    expect(engine.utteranceSourcePtrs, <int>[0xABC, 0xABC]);
    final String? previewPath = preview?.filePath;
    if (previewPath != null) {
      final File previewFile = File(previewPath);
      if (previewFile.existsSync()) previewFile.deleteSync();
    }

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
    // v13：采集期不再按选定线程丢行，过滤挪到消费期，
    // 「选了哪条线程」因此成了本用例的显式前提。
    await controller.selectTextThread(5);
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

  test('BUG-1165：此刻静音判据走时刻窗片段数，clipCount 不参与、非 16-bit 不误伤', () {
    GalAudioTrack track({
      required int bits,
      required double energy,
      int clips = 5,
      int clipsAtCue = -1,
    }) =>
        GalAudioTrack(
          sourcePtr: 0x1234,
          format: PcmFormat(
            sampleRate: 48000,
            channels: 2,
            bitsPerSample: bits,
            isFloat: bits == 32,
          ),
          avgBytes: 1024,
          avgEnergy: energy,
          orderIndex: 0,
          clipCount: clips,
          clipCountAtCue: clipsAtCue,
        );

    // 新 runner：时刻窗片段数是唯一判据，与位深、与能量都无关。
    expect(track(bits: 16, energy: -1, clipsAtCue: 0).isSilentAtCue, isTrue);
    expect(
        track(bits: 16, energy: 120.5, clipsAtCue: 3).isSilentAtCue, isFalse);
    // 非 16-bit 轨 native 算不出能量（恒 -1），但窗内确实有段 = 此刻在响，不得置灰。
    expect(track(bits: 32, energy: -1, clipsAtCue: 4).isSilentAtCue, isFalse);
    expect(track(bits: 32, energy: -1, clipsAtCue: 0).isSilentAtCue, isTrue,
        reason: '有了片段数，非 16-bit 轨也能被正确判定为此刻静音');
    // clipCount 是全环累计、恒 >= 1，绝不参与判据（原实现就栽在这）。
    expect(track(bits: 16, energy: 9, clips: 99, clipsAtCue: 0).isSilentAtCue,
        isTrue);

    // 老 runner 不发该字段（-1 = 未知）：退回能量判据，且只对 16-bit 下结论——
    // 宁可不置灰也不误伤非 16-bit 的可用轨。
    expect(track(bits: 16, energy: -1).isSilentAtCue, isTrue);
    expect(track(bits: 16, energy: 120.5).isSilentAtCue, isFalse);
    expect(track(bits: 32, energy: -1).energyUnknown, isTrue);
    expect(track(bits: 32, energy: -1).isSilentAtCue, isFalse);

    // 缺字段的 native map 必须解析成 -1（未知），不能拿 0 冒充「窗内没段」。
    final GalAudioTrack? legacy = GalAudioTrack.fromMap(<Object?, Object?>{
      'sourcePtr': 0x99,
      'sampleRate': 48000,
      'channels': 2,
      'bitsPerSample': 16,
      'isFloat': false,
      'avgEnergy': 42.0,
      'clipCount': 7,
    });
    expect(legacy?.clipCountAtCue, -1);
    expect(legacy?.isSilentAtCue, isFalse);
  });
}

// ---------------------------------------------------------------------------
// 「降级文案必须先走翻译」的契约判据（BUG-1100）
// ---------------------------------------------------------------------------

/// 翻译表本体：把内部代码翻成人话的唯一入口。
const String _kFallbackLabel = 'galHookFallbackLabel';

/// 翻译层模块。会话卡若把内部代码转交给别人，那个「别人」必须在这里定义——
/// 「UI 只在这里把它翻成人话」本身就是 gal_hook_failure_text.dart 的文档契约。
const String _kFailureTextPath = 'lib/src/mining/gal_hook_failure_text.dart';

/// 降级会话卡（`_SessionOverviewCard`）的类体原文。
///
/// 用 [balancedBlockFrom] 而不是整文件：texthooker_page.dart 六千多行，别处出现
/// `state.fallbackReason` 的话窗口会锚到不相干的地方去。
String _sessionOverviewCardSource() {
  final File file = File('lib/src/pages/implementations/texthooker_page.dart');
  expect(file.existsSync(), isTrue, reason: '会话卡源文件不在了？守卫失去锚点，先修路径再谈断言');
  final String src = file.readAsStringSync();
  final int start =
      maskCommentsAndStrings(src).indexOf('class _SessionOverviewCard');
  expect(start, greaterThanOrEqualTo(0),
      reason: '_SessionOverviewCard 改名了：守卫锚点必须跟着改，不能静默失效');
  return balancedBlockFrom(src, start, what: '_SessionOverviewCard');
}

/// 接收内部代码的这个调用 [callee]，会不会先查翻译表。
///
/// 直接调 [_kFallbackLabel] 算数；调 [_kFailureTextPath] 里某个共享入口、而那个入口
/// 自己调 [_kFallbackLabel] 也算（一跳可达，PR#753 的 `galHookFallbackHeadline`
/// 正是这种）。除此以外一律不算——把 `state.fallbackReason` 直接塞进 `Text(...)`
/// 这种 BUG-1100 的原始形态，以及「中转函数自己把翻译那一跳删了」，都落在这一侧。
bool _routesThroughFallbackLabel(String callee) {
  if (callee == _kFallbackLabel) return true;
  final String? body = _topLevelFunctionBody(
    File(_kFailureTextPath).readAsStringSync(),
    callee,
  );
  if (body == null) return false;
  return containsIdentifierCall(body, _kFallbackLabel);
}

/// 取 [src] 里顶层函数 [name] 的**实现体**原文；`=> expr;` 与 `{ … }` 两种形态都认。
/// 找不到声明返回 null（失败信息由调用方给，这里不 fail）。
///
/// 为什么不能直接用 [methodBody]：它只认花括号体。`galHookFallbackHeadline` 是箭头
/// 函数，[methodBody] 会跳过参数表后一路找到**下一个**声明的花括号——紧随其后的正是
/// `galHookFallbackLabel` 那个 switch 块，于是「一跳可达」会因为读到了邻居的实现而
/// 假绿。窗口锚错时守卫不报错、只是静默守错对象，这是最难发现的一类塌陷。
String? _topLevelFunctionBody(String src, String name) {
  final String structural = maskCommentsAndStrings(src);
  final RegExp declaration = RegExp(
    r'(?<![A-Za-z0-9_$.])' + RegExp.escape(name) + r'\s*\(',
  );
  for (final RegExpMatch match in declaration.allMatches(structural)) {
    final int open = match.end - 1;
    int depth = 0;
    int close = -1;
    for (int i = open; i < structural.length; i++) {
      if (structural[i] == '(') depth++;
      if (structural[i] == ')') {
        depth--;
        if (depth == 0) {
          close = i;
          break;
        }
      }
    }
    if (close < 0) continue;
    int i = close + 1;
    while (i < structural.length && structural[i].trim().isEmpty) {
      i++;
    }
    if (i + 1 < structural.length &&
        structural[i] == '=' &&
        structural[i + 1] == '>') {
      // 箭头体：收口在**深度 0** 的分号上。`=> switch (x) { … };` 里的花括号、
      // 以及实参里的分号都不算，否则窗口会在半路截断。
      int nest = 0;
      for (int j = i + 2; j < structural.length; j++) {
        final String c = structural[j];
        if (c == '(' || c == '[' || c == '{') nest++;
        if (c == ')' || c == ']' || c == '}') nest--;
        if (c == ';' && nest == 0) return src.substring(i + 2, j);
      }
      return null;
    }
    if (i < structural.length && structural[i] == '{') {
      return balancedBlockFrom(src, i, what: '$name 的实现体');
    }
    // 既不是 `=>` 也不是 `{`：这一处是**调用**而不是声明，继续找下一处。
  }
  return null;
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
  final List<int> utteranceTimestamps = <int>[];
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
    utteranceTimestamps.add(tsMs);
    if (sourcePtr != null) utteranceSourcePtrs.add(sourcePtr);
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
