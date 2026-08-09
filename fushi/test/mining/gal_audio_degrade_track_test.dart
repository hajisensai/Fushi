import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_japanese_locale.dart';
import 'package:fushi/src/mining/gal_hook_failure_text.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/sync/texthooker_ws_client.dart';

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
          GalJapaneseLocaleMode japaneseLocaleMode =
              kGalDefaultJapaneseLocaleMode,
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
    // 「可选性」这个量本身必须由**后端**算出来。
    expect(
      initializerExpression(panel, 'selectionEffective'),
      'galTrackSelectionAffectsCapture(state.audioBackend)',
      reason: '解释/禁用判据必须是后端，不能再是 audioTracks.isEmpty',
    );
    // 解释态同理：先看后端，再谈别的。旧断言写的是
    // `isFalse` + `'state.audioTracks.isEmpty && emptyHint'` —— 那个串在实现里
    // **从来就不存在**（真实写法是 `... && backendHint == null`），是一条永远零命中
    // 的禁止型断言：判据自己坏掉时没有任何东西会发现。改成钉可达顺序。
    final String? hintExpr = initializerExpression(panel, 'backendHint');
    expect(hintExpr, isNotNull, reason: 'backendHint 改名了：守卫失去锚点');
    expect(
      hintExpr!.trimLeft().startsWith('selectionEffective'),
      isTrue,
      reason: '列表空不空只能决定末梢文案；先决条件必须是后端 —— '
          '反过来就是 BUG-1102 里整套死控件照常渲染的成因',
    );
    // TODO-2727：下面两条原本是 `panel.contains('selectable: selectionEffective')`
    // 与 `panel.contains('enabled: selectable && !excluded')` —— 把**参数顺序、空格、
    // 布尔表达式的书写顺序**全钉进了契约。`!excluded && selectable` 是同一语义的
    // 合法写法，旧断言会在实现完全正确时转红；反过来把 `selectable:` 换给别的控件
    // 而字面量恰好还在文件里某处，旧断言又照样绿。
    //
    // 改成问「这个值被交给了谁」：轨行拿到的 selectable 就是后端判据本身，
    // 「设为语音轨」那个按钮的 enabled 必须同时受 selectable 与 excluded 约束。
    final int tileAt = maskComments(panel).indexOf('GalTrackTile(');
    expect(tileAt, greaterThanOrEqualTo(0),
        reason: 'GalTrackTile 改名了：守卫锚点必须跟着改，不能静默失效');
    final EnclosingCall tile =
        enclosingCall(panel, tileAt + 'GalTrackTile('.length);
    expect(tile.name, 'GalTrackTile');
    expect(namedArgumentValues(tile.text, 'selectable'),
        <String>['selectionEffective'],
        reason: '轨行的可选性必须直接来自后端判据 selectionEffective');

    // 「设为语音轨」按钮：用 onTap 认它是哪一个（语义锚），再看它的 enabled 判据。
    final EnclosingCall selectButton =
        enclosingCallOf(panel, 'onTap: onSelect');
    final List<String> enabled =
        namedArgumentValues(selectButton.text, 'enabled');
    expect(enabled, hasLength(1), reason: '「设为语音轨」按钮必须显式声明 enabled，缺省即恒可点');
    expect(containsIdentifier(enabled.single, 'selectable'), isTrue,
        reason: '非引擎 PCM 后端必须禁用「选为语音轨」');
    expect(containsIdentifier(enabled.single, 'excluded'), isTrue,
        reason: '已排除为 BGM 的轨不得再被选成语音轨');
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

  test('BUG-1094 补录窗口与回取上限解耦：两个量各有各的常量，环容量对齐 native 真相源', () {
    // TODO-2727：这一条原本是六条 `src.contains('<原样抄下来的一行>')`。那批判据
    // 钉的是**拼写**（修饰符顺序、空格、结尾分号、甚至一整句中文注释），而不是不变式：
    // - `dart format` 重排、加一个 `final`、把常量挪进别的类 ⇒ 实现完全正确却转红；
    // - 反过来，只要那些串还在文件里的**任何位置**（哪怕在注释里）就照样绿；
    // - 其中两条（`kRingSeconds = 60`、`环形缓冲实际保留 60 秒`）钉的干脆就是注释
    //   内容——等于把断言字面量存在被守文件的注释里，而注释里那个 `:21` 行号今天
    //   已经指错（真实位置是 `audio_loopback_capture.cpp:22`）。**注释是会漂的，
    //   它不是真相源**。真相源是 native 那个常量本身，所以下面直接读它对账。
    final String src = File(
      'lib/src/mining/gal_hook_session_controller.dart',
    ).readAsStringSync();
    final String code = maskComments(src);

    // ① 那个「一个 8000 绑死两个语义」的旧标识符不许回来。
    //    只扫代码：这是禁止型断言，被一句解释性注释判红比漏掉更糟——守卫会永久红。
    //    带标识符边界：`_galAudioBackMsLegacy` 这类更长的名字不算命中。
    expect(
      containsIdentifier(code, '_galAudioBackMs'),
      isFalse,
      reason: '一个 8000 的常量同时当补录窗口和回取上限，两个语义都被它绑死',
    );

    // ② 环容量常量的**值**必须等于 native 的真相源。
    //    这是跨语言契约，只有两边一起读才守得住；旧写法钉一行 Dart 字面量 + 一句
    //    中文注释，native 那边把 kRingSeconds 改成 30 时它一动不动。
    final String? capacity =
        initializerExpression(src, '_loopbackRingCapacityMs');
    expect(capacity, isNotNull, reason: '环容量常量改名了：守卫失去锚点，先修锚点再谈断言');
    final File nativeFile = File('windows/runner/audio_loopback_capture.cpp');
    expect(nativeFile.existsSync(), isTrue,
        reason: 'native loopback 采集源不在了：跨语言契约的真相源必须先修');
    final RegExpMatch? ring = RegExp(r'kRingSeconds\s*=\s*(\d+)')
        .firstMatch(maskComments(nativeFile.readAsStringSync()));
    expect(ring, isNotNull, reason: 'native kRingSeconds 改名了：Dart 侧上限失去依据');
    expect(
      int.parse(capacity!),
      int.parse(ring!.group(1)!) * 1000,
      reason: 'Dart 侧回取上限必须等于 native 环形缓冲的真实容量',
    );

    // ③ 回取长度这个量**是怎么算出来的**：上限是环容量，不是补录窗口。
    final String finish = methodBody(
      src,
      'Future<bool> finishLineRecapture({bool discard = false}) async',
    );
    final String? backMs = initializerExpression(finish, 'backMs');
    expect(backMs, isNotNull, reason: '回取长度不再是一个具名局部量：守卫失去锚点');
    expect(
      containsIdentifier(backMs!, '_loopbackRingCapacityMs'),
      isTrue,
      reason: '回取上限应是环的真实容量，不是补录窗口时长',
    );
    expect(
      containsIdentifier(backMs, '_recaptureWindow'),
      isFalse,
      reason: '回取长度一旦又由补录窗口换算而来，BUG-1094 就原地复活',
    );

    // ④ 补录窗口是自己的时长常量，且不由环容量换算而来。
    final String? window = initializerExpression(src, '_recaptureWindow');
    expect(window, isNotNull, reason: '补录窗口常量改名了：守卫失去锚点');
    expect(containsIdentifierCall(window!, 'Duration'), isTrue,
        reason: '补录窗口必须是自己的时长常量，不再由回取上限换算而来');
    expect(
      containsIdentifier(window, '_loopbackRingCapacityMs'),
      isFalse,
      reason: '两个量必须解耦：窗口时长不许再引用环容量',
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
  // 用共享原语 [topLevelFunctionBody]：`=> expr;` 与 `{ … }` 两种体都认。
  // 这里曾有一份私有实现（PR#762），因为当时的 [methodBody] 只认花括号体——
  // `galHookFallbackHeadline` 是箭头函数，它会跳过参数表后一路找到**下一个**声明的
  // 花括号（紧随其后的 `galHookFallbackLabel` 那个 switch 块），于是「一跳可达」
  // 因为读到了邻居的实现而假绿。TODO-2726 把箭头体支持合回共享原语，私有副本删除：
  // 两份收口逻辑各写一遍只会慢慢漂开。
  final String? body = topLevelFunctionBody(
    File(_kFailureTextPath).readAsStringSync(),
    callee,
  );
  if (body == null) return false;
  return containsIdentifierCall(body, _kFallbackLabel);
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
    int? endTsMs,
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
