import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/mining/galgame_audio_encode.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/src/sync/texthooker_ws_client.dart';

/// BUG-1118 防混入 BGM 的完整性链：
/// - `grabClipNear` 兜底与 `grabUtterance` 同一份选轨/排除契约（不再绕过排除集）；
/// - 无配音句与疑似漏抓按「该句时刻候选轨是否有能量」分类，不再一律红标；
/// - 超长切片门把几十秒混音标成可疑，不顶正常标签入卡；
/// - 跨会话 BGM 排除记忆按弱指纹恢复，用户恢复某轨后记忆同步删除。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const PcmFormat kPcm = PcmFormat(
    sampleRate: 48000,
    channels: 2,
    bitsPerSample: 16,
    isFloat: false,
  );

  GalAudioTrack track({
    required int sourcePtr,
    required int orderIndex,
    double avgEnergy = 100,
    int clipCount = 3,
  }) =>
      GalAudioTrack(
        sourcePtr: sourcePtr,
        format: kPcm,
        avgBytes: 4096,
        avgEnergy: avgEnergy,
        orderIndex: orderIndex,
        clipCount: clipCount,
      );

  Future<void> waitUntil(bool Function() done, {int ticks = 400}) async {
    for (int i = 0; i < ticks && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  group('grabClipNear 选轨/排除契约（BUG-1118 ①）', () {
    const String channelName = 'app.hibiki.reader/voice_hook';

    void setHandler(Future<Object?>? Function(MethodCall)? handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(channelName), handler);
    }

    tearDown(() => setHandler(null));

    test('缺省沿用 selectedAudioSourcePtr / excludedAudioSourcePtrs', () async {
      final List<MethodCall> calls = <MethodCall>[];
      setHandler((MethodCall call) async {
        calls.add(call);
        return <String, Object?>{
          'pcm': Uint8List.fromList(List<int>.filled(96, 1)),
          'sampleRate': 48000,
          'channels': 2,
          'bitsPerSample': 16,
          'isFloat': false,
        };
      });
      final EngineHookGalAudioSource source = EngineHookGalAudioSource(
        targetPid: 1,
        injectorPath: 'fake.exe',
      );
      source.selectedAudioSourcePtr = 0x11;
      source.excludedAudioSourcePtrs.add(0x22);
      final GalAudioSlice? slice = await source.grabClipNear(1000);
      expect(slice, isNotNull);
      expect(calls, hasLength(1));
      final Map<Object?, Object?> args =
          calls.single.arguments as Map<Object?, Object?>;
      expect(args['sourcePtr'], 0x11, reason: '兜底必须与 grabUtterance 用同一条选轨');
      expect(args['exclude'], <int>[0x22],
          reason: '兜底必须携带排除集，否则排除的 BGM 从这里绕回制卡');
    });

    test('显式 sourcePtr/exclude 覆盖缺省（逐行选轨语义）', () async {
      final List<MethodCall> calls = <MethodCall>[];
      setHandler((MethodCall call) async {
        calls.add(call);
        return <String, Object?>{'error': 'none'};
      });
      final EngineHookGalAudioSource source = EngineHookGalAudioSource(
        targetPid: 1,
        injectorPath: 'fake.exe',
      );
      source.selectedAudioSourcePtr = 0x11;
      source.excludedAudioSourcePtrs.add(0x22);
      await source.grabClipNear(1000, sourcePtr: 0x33, exclude: const <int>[]);
      final Map<Object?, Object?> args =
          calls.single.arguments as Map<Object?, Object?>;
      expect(args['sourcePtr'], 0x33);
      expect(args['exclude'], isEmpty);
    });
  });

  group('超长切片门', () {
    test('自动兜底超长 -> 换成可疑标注；正常时长 -> 原样', () {
      expect(
        GalHookSessionController.sliceFallbackReasonFor(
          durationMs: kGalOverlongSliceSuspectMs + 1,
          fallbackReason: 'engine_utterance_unavailable',
        ),
        kGalOverlongSliceSuspectReason,
      );
      expect(
        GalHookSessionController.sliceFallbackReasonFor(
          durationMs: 4000,
          fallbackReason: 'engine_utterance_unavailable',
        ),
        'engine_utterance_unavailable',
      );
    });

    test('用户裁决（补录/选轨）不被二次质疑', () {
      expect(
        GalHookSessionController.sliceFallbackReasonFor(
          durationMs: kGalOverlongSliceSuspectMs * 2,
          fallbackReason: 'manual_recapture',
        ),
        'manual_recapture',
      );
      expect(
        GalHookSessionController.sliceFallbackReasonFor(
          durationMs: kGalOverlongSliceSuspectMs * 2,
          fallbackReason: 'manual_track_override',
        ),
        'manual_track_override',
      );
    });
  });

  test('trackFingerprint 只依赖 orderIndex + 格式（跨会话可锚字段）', () {
    expect(
      GalHookSessionController.trackFingerprint(
        track(sourcePtr: 0xAA, orderIndex: 2),
      ),
      '2:48000:2:16:0',
    );
    // 同一条轨换了 source_ptr（跨启动的常态）指纹不变。
    expect(
      GalHookSessionController.trackFingerprint(
        track(sourcePtr: 0xBB, orderIndex: 2),
      ),
      GalHookSessionController.trackFingerprint(
        track(sourcePtr: 0xAA, orderIndex: 2),
      ),
    );
  });

  group('会话级行为（launch 会话 + 引擎 PCM）', () {
    GalHookSessionController build({
      required TexthookerService service,
      required Listenable endpoints,
      required _FakeEngine engine,
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
          loopbackSourceFactory: () => _NullLoopback(),
          textPollInterval: const Duration(milliseconds: 5),
          trackRefreshInterval: const Duration(milliseconds: 20),
          endpointListenable: endpoints,
          endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
        );

    test('跨会话排除记忆：按指纹恢复排除；用户恢复后记忆同步删除', () async {
      final TexthookerService service = TexthookerService.test();
      final ChangeNotifier endpoints = ChangeNotifier();
      final _FakeEngine engine = _FakeEngine(readyFormat: kPcm)
        ..tracks = <GalAudioTrack>[
          track(sourcePtr: 0x100, orderIndex: 0),
          track(sourcePtr: 0x200, orderIndex: 1),
        ];
      final GalHookSessionController controller = build(
        service: service,
        endpoints: endpoints,
        engine: engine,
      );
      final Map<String, GalCaptureMemory> store = <String, GalCaptureMemory>{
        r'd:\games\fake.exe': GalCaptureMemory(
          excludedTrackFingerprints: <String>[
            GalHookSessionController.trackFingerprint(
              track(sourcePtr: 0x999, orderIndex: 1),
            ),
          ],
        ),
      };
      controller.attachCaptureMemory(
        load: (String gameKey) => store[gameKey] ?? const GalCaptureMemory(),
        save: (String gameKey, GalCaptureMemory memory) =>
            store[gameKey] = memory,
      );

      await controller.launchGame(r'D:\Games\fake.exe');
      await waitUntil(
        () => controller.state.excludedAudioSourcePtrs.isNotEmpty,
      );
      expect(
        controller.state.excludedAudioSourcePtrs,
        <int>{0x200},
        reason: '上次会话排除的轨按指纹（orderIndex+格式）套回新 source_ptr',
      );

      // 用户说这条轨不是 BGM：恢复后记忆必须删掉，下次会话不得再自动排除。
      controller.setTrackExcluded(0x200, false);
      expect(controller.state.excludedAudioSourcePtrs, isEmpty);
      expect(
        store[r'd:\games\fake.exe']!.excludedTrackFingerprints,
        isEmpty,
      );

      // 重新排除另一条轨：指纹写回。
      controller.setTrackExcluded(0x100, true);
      expect(
        store[r'd:\games\fake.exe']!.excludedTrackFingerprints,
        <String>[
          GalHookSessionController.trackFingerprint(
            track(sourcePtr: 0x100, orderIndex: 0),
          ),
        ],
      );

      // 会话语音轨也按同一份记忆持久化（用户明确要求「每个游戏默认持久化音轨」）。
      controller.selectVoiceTrack(0x100);
      expect(
        store[r'd:\games\fake.exe']!.voiceTrackFingerprint,
        GalHookSessionController.trackFingerprint(
          track(sourcePtr: 0x100, orderIndex: 0),
        ),
      );
      controller.selectVoiceTrack(0);
      expect(
        store[r'd:\games\fake.exe']!.voiceTrackFingerprint,
        isNull,
        reason: '改回自动选源要清掉记忆，否则下次仍被钉在旧轨上',
      );

      await controller.close();
      endpoints.dispose();
    });

    test('语音轨记忆按指纹恢复；被排除的轨不得同时当语音轨', () async {
      final TexthookerService service = TexthookerService.test();
      final ChangeNotifier endpoints = ChangeNotifier();
      final _FakeEngine engine = _FakeEngine(readyFormat: kPcm)
        ..tracks = <GalAudioTrack>[
          track(sourcePtr: 0x100, orderIndex: 0),
          track(sourcePtr: 0x200, orderIndex: 1),
        ];
      final GalHookSessionController controller = build(
        service: service,
        endpoints: endpoints,
        engine: engine,
      );
      final String voiceFp = GalHookSessionController.trackFingerprint(
        track(sourcePtr: 0x777, orderIndex: 1),
      );
      controller.attachCaptureMemory(
        load: (String gameKey) => GalCaptureMemory(
          // 同一条轨既在排除集又是记忆里的语音轨：排除必须赢。
          excludedTrackFingerprints: <String>[voiceFp],
          voiceTrackFingerprint: voiceFp,
        ),
        save: (String gameKey, GalCaptureMemory memory) {},
      );
      await controller.launchGame(r'D:\Games\fake.exe');
      await waitUntil(
        () => controller.state.excludedAudioSourcePtrs.isNotEmpty,
      );
      expect(controller.state.excludedAudioSourcePtrs, <int>{0x200});
      expect(
        controller.state.selectedAudioSourcePtr,
        0,
        reason: '被排除的轨不能被记忆恢复成语音轨，否则排除等于没排',
      );

      await controller.close();
      endpoints.dispose();
    });

    test('文本线程记忆：指纹匹配且够行数才恢复，用户手选覆盖记忆', () async {
      final TexthookerService service = TexthookerService.test();
      final ChangeNotifier endpoints = ChangeNotifier();
      final _FakeEngine engine = _FakeEngine(
        readyFormat: kPcm,
        enforceTextSelection: true,
      );
      final GalHookSessionController controller = build(
        service: service,
        endpoints: endpoints,
        engine: engine,
      );
      final Map<String, GalCaptureMemory> store = <String, GalCaptureMemory>{
        r'd:\games\fake.exe': const GalCaptureMemory(
          textThreadFingerprint: 'code:HB4@459F50',
        ),
      };
      controller.attachCaptureMemory(
        load: (String gameKey) => store[gameKey] ?? const GalCaptureMemory(),
        save: (String gameKey, GalCaptureMemory memory) =>
            store[gameKey] = memory,
      );
      await controller.launchGame(r'D:\Games\fake.exe');
      engine.enqueue(
        const GalHookedLine(
          seq: 1,
          timestampMs: 500,
          text: '',
          threadId: 7,
          sourceKind: 2,
          eventKind: GalTextEventKind.threadDiscovered,
          hookName: 'CodeX',
          hookCode: 'HB4@459F50',
        ),
      );

      // 前两行不足门限（3 行）：不得恢复，避免开局蹦一行的 UI 线程把选择钉死。
      for (int i = 1; i <= 2; i++) {
        engine.enqueue(
          GalHookedLine(
            seq: i + 1,
            timestampMs: 1000 * i,
            text: 'せりふ$i',
            threadId: 7,
            sourceKind: 2,
            hookName: 'CodeX',
            hookCode: 'HB4@459F50',
          ),
        );
      }
      await waitUntil(
        () =>
            service.textThreads.length == 1 &&
            service.textThreads.single.observedLineCount == 2,
      );
      expect(service.entries, isEmpty, reason: 'v12 未选线程前文本环必须为空，观测行只存在预览区');
      expect(controller.selectedTextThreadKey, isNull);

      // 第三条预览到达 -> 达到门限，按指纹恢复；恢复后文本环才发布该线程的行。
      engine.enqueue(
        const GalHookedLine(
          seq: 4,
          timestampMs: 3000,
          text: 'せりふ3',
          threadId: 7,
          sourceKind: 2,
          hookName: 'CodeX',
          hookCode: 'HB4@459F50',
        ),
      );
      await waitUntil(() => controller.selectedTextThreadKey != null);
      expect(controller.selectedNativeTextThreadId, 7);
      await waitUntil(() => service.entries.length == 3);

      // 用户取消选择：记忆被清掉，不再自动恢复，正式消费者也必须立刻归零。
      await controller.selectTextThread(null, remember: true);
      expect(store[r'd:\games\fake.exe']!.textThreadFingerprint, isNull);
      expect(
        controller.workbenchLines,
        isEmpty,
        reason: '未选线程时历史正式环只能留作诊断，不得继续进入工作台',
      );
      expect(
        controller.selectedSessionLines,
        isEmpty,
        reason: '未选线程时浮窗、配对和制卡不得消费任何来源',
      );

      await controller.close();
      endpoints.dispose();
    });

    test('无配音 vs 疑似漏抓：按该句时刻候选轨能量分类', () async {
      final TexthookerService service = TexthookerService.test();
      final ChangeNotifier endpoints = ChangeNotifier();
      final _FakeEngine engine = _FakeEngine(readyFormat: kPcm);
      final GalHookSessionController controller = build(
        service: service,
        endpoints: endpoints,
        engine: engine,
      );
      await controller.launchGame(r'D:\Games\fake.exe');
      // v13：采集期不再按选定线程丢行，过滤挪到消费期，
      // 「选了哪条线程」因此成了本用例的显式前提。
      await controller.selectTextThread(5);

      // (a) 候选轨在该句时刻有能量但整句抓取失败 -> 疑似漏抓，保留告警红标。
      engine.tracks = <GalAudioTrack>[
        track(sourcePtr: 0x100, orderIndex: 0, avgEnergy: 88),
      ];
      engine.enqueue(const GalHookedLine(
        seq: 1,
        timestampMs: 1000,
        text: '一句目',
        threadId: 5,
        hookName: 'fake',
      ));
      await waitUntil(() => service.entries.isNotEmpty);
      await waitUntil(
        () => service.entries.first.fallbackReason == 'utterance_not_found',
      );
      expect(
          service.entries.first.audioStatus, TexthookerLineAudioStatus.missing);
      expect(service.entries.first.fallbackReason, 'utterance_not_found');

      // (b) 声音只在被排除的 BGM 轨上 -> 判无配音（灰标不吓人）。
      controller.setTrackExcluded(0x100, true);
      engine.enqueue(const GalHookedLine(
        seq: 2,
        timestampMs: 2000,
        text: '二句目',
        threadId: 5,
        hookName: 'fake',
      ));
      await waitUntil(() => service.entries.length >= 2);
      await waitUntil(
        () => service.entries.last.fallbackReason == kGalLineNoVoiceReason,
      );
      expect(
          service.entries.last.audioStatus, TexthookerLineAudioStatus.missing);
      expect(service.entries.last.fallbackReason, kGalLineNoVoiceReason);

      await controller.close();
      endpoints.dispose();
    });
  });
}

/// 引擎 helper 替身：文本可排队、PCM 立即就绪、音轨快照可配置、整句抓取恒失败
/// （逼出 miss 分类与兜底链）。
class _FakeEngine extends EngineHookGalAudioSource {
  _FakeEngine({
    this.readyFormat,
    this.enforceTextSelection = false,
  }) : super(targetPid: 0, launchExe: 'fake.exe', injectorPath: 'fake.exe');

  final PcmFormat? readyFormat;
  final bool enforceTextSelection;
  List<GalAudioTrack> tracks = <GalAudioTrack>[];
  final List<GalHookedLine> _pending = <GalHookedLine>[];
  int? _selectedTextThreadId;

  void enqueue(GalHookedLine line) => _pending.add(line);

  @override
  int? get gamePid => 4242;

  @override
  bool get textHookReady => true;

  @override
  bool get rawVoiceReady => false;

  @override
  PcmFormat? get readyPcmFormat => readyFormat;

  @override
  bool get pcmReady => readyFormat != null;

  @override
  Future<PcmFormat?> start() async => readyFormat;

  @override
  Future<bool> refreshReadiness() async => false;

  @override
  Future<GalTextPoll?> pollText(int fromSeq) async {
    final List<GalHookedLine> fresh = _pending
        .where(
          (GalHookedLine line) =>
              line.seq > fromSeq &&
              (line.eventKind == GalTextEventKind.threadDiscovered ||
                  !enforceTextSelection ||
                  line.threadId == _selectedTextThreadId),
        )
        .toList(growable: false);
    return GalTextPoll(count: _pending.length, lines: fresh);
  }

  @override
  Future<List<GalTextThreadPreview>?> pollThreadPreviews() async {
    final Map<int, List<GalHookedLine>> byThread = <int, List<GalHookedLine>>{};
    for (final GalHookedLine line in _pending) {
      if (line.eventKind != GalTextEventKind.line || line.threadId == 0) {
        continue;
      }
      byThread.putIfAbsent(line.threadId, () => <GalHookedLine>[]).add(line);
    }
    return <GalTextThreadPreview>[
      for (final MapEntry<int, List<GalHookedLine>> entry in byThread.entries)
        GalTextThreadPreview(
          threadId: entry.key,
          text: entry.value.last.text,
          timestampMs: entry.value.last.timestampMs,
          lineCount: entry.value.length,
        ),
    ];
  }

  @override
  Future<bool> selectTextThread(int? threadId) async {
    _selectedTextThreadId = threadId;
    return true;
  }

  @override
  Future<GalAudioSlice?> grabUtterance(
    int tsMs, {
    int? sourcePtr,
    List<int>? exclude,
  }) async =>
      null;

  @override
  Future<GalAudioSlice?> grabClipNear(
    int tsMs, {
    int tolMs = 8000,
    int? sourcePtr,
    List<int>? exclude,
  }) async =>
      null;

  @override
  Future<List<GalAudioTrack>> listAudioTracks(int tsMs) async => tracks;

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
  Future<void> stop() async {}
}

/// 永不产声的 loopback 替身（本测试只关心引擎 PCM 路径）。
class _NullLoopback extends LoopbackGalAudioSource {
  @override
  Future<PcmFormat?> start() async => kNullPcm;

  static const PcmFormat kNullPcm = PcmFormat(
    sampleRate: 48000,
    channels: 2,
    bitsPerSample: 16,
    isFloat: false,
  );

  @override
  Future<GalAudioSlice?> grabRecent(int backMs) async => null;

  @override
  Future<void> stop() async {}
}
