// BUG-1027：诊断页音轨快照自动化 + 逐轨试听 + 选轨反馈的控制器行为测试。
//
// 覆盖：
//   ① 会话激活后音轨快照自动填充（不再依赖诊断页手动「刷新音轨」按钮）；
//   ② 引擎 PCM 后端下会话级低频定时器持续刷新，stopCapture 后定时器停止且快照清空；
//   ③ 晚到资源 hook 把 backend 切成 gameResource 后自动重刷一次并停掉低频定时器；
//   ④ exportTrackPreview 按轨抓整句 PCM 落临时 WAV（文件名/时长/参数正确），
//      无 engine / 无 PCM 时返回 null 且记结构化事件；
//   ⑤ selectVoiceTrack 无 engine 不再静默，记录警告事件；
//   ⑥ 轨成员未变化时重复刷新只记一条 tracks_refreshed 事件（防事件日志噪音）。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/mining/galgame_audio_encode.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/src/sync/texthooker_ws_client.dart';

const PcmFormat _pcm16Mono = PcmFormat(
  sampleRate: 44100,
  channels: 1,
  bitsPerSample: 16,
  isFloat: false,
);

GalAudioTrack _track(int sourcePtr) => GalAudioTrack(
      sourcePtr: sourcePtr,
      format: _pcm16Mono,
      avgBytes: 4096,
      avgEnergy: 120.5,
      orderIndex: 0,
      clipCount: 3,
    );

class _TrackFakeEngine extends EngineHookGalAudioSource {
  _TrackFakeEngine({
    this.audioFormat = _pcm16Mono,
    this.textReady = false,
    this.lateRawReady = false,
    this.tracks = const <GalAudioTrack>[],
    this.utteranceSlice,
  }) : super(targetPid: 0, launchExe: 'fake.exe', injectorPath: 'fake.exe');

  final PcmFormat? audioFormat;
  final bool textReady;
  final bool lateRawReady;
  List<GalAudioTrack> tracks;
  final GalAudioSlice? utteranceSlice;

  bool rawReady = false;
  int listCalls = 0;
  int stopCalls = 0;
  final List<int> utteranceSourcePtrs = <int>[];
  final List<List<int>> utteranceExcludes = <List<int>>[];

  @override
  int? get gamePid => 4242;

  @override
  bool get textHookReady => textReady;

  @override
  bool get rawVoiceReady => rawReady;

  @override
  Future<PcmFormat?> start() async => audioFormat;

  @override
  Future<bool> refreshReadiness() async {
    if (lateRawReady) rawReady = true;
    return rawReady;
  }

  @override
  Future<List<GalAudioTrack>> listAudioTracks(int tsMs) async {
    listCalls++;
    return tracks;
  }

  @override
  Future<GalAudioSlice?> grabUtterance(
    int tsMs, {
    int? sourcePtr,
    List<int>? exclude,
  }) async {
    utteranceSourcePtrs.add(sourcePtr ?? selectedAudioSourcePtr);
    utteranceExcludes.add(exclude ?? excludedAudioSourcePtrs.toList());
    return utteranceSlice;
  }

  @override
  Future<GalAudioSlice?> grabClipNear(int tsMs, {int tolMs = 8000}) async =>
      null;

  @override
  Future<GalTextPoll?> pollText(int fromSeq) async =>
      const GalTextPoll(count: 0, lines: <GalHookedLine>[]);

  @override
  Future<bool> selectTextThread(int? threadId) async => true;

  @override
  Future<void> stop() async {
    stopCalls++;
  }
}

class _SilentLoopback extends LoopbackGalAudioSource {
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

GalHookSessionController _controller({
  required TexthookerService service,
  required ChangeNotifier endpoints,
  required _TrackFakeEngine engine,
  Duration trackRefreshInterval = const Duration(milliseconds: 20),
  Duration textPollInterval = const Duration(milliseconds: 5),
}) {
  return GalHookSessionController(
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
    textPollInterval: textPollInterval,
    trackRefreshInterval: trackRefreshInterval,
    endpointListenable: endpoints,
    endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
  );
}

Future<void> _waitUntil(bool Function() done) async {
  for (int i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue, reason: '异步状态未在期限内收敛');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('会话激活自动填充音轨快照，stopCapture 停定时器并清空（BUG-1027 ①）', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _TrackFakeEngine engine = _TrackFakeEngine(
      tracks: <GalAudioTrack>[_track(0xA1)],
    );
    final GalHookSessionController controller = _controller(
      service: service,
      endpoints: endpoints,
      engine: engine,
    );

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 1, pid: 100, title: 'Engine game'),
    );
    // 无任何手动 refreshAudioTracks 调用，快照必须自动出现。
    await _waitUntil(() => controller.state.audioTracks.isNotEmpty);
    expect(controller.state.audioTracks.single.sourcePtr, 0xA1);
    expect(controller.state.audioBackend, GalHookAudioBackend.enginePcm);

    // 低频定时器（20ms）持续刷新。
    final int before = engine.listCalls;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(engine.listCalls, greaterThan(before),
        reason: '引擎 PCM 后端应有会话级低频自动刷新');

    await controller.stopCapture();
    expect(controller.state.audioTracks, isEmpty);
    final int afterStop = engine.listCalls;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(engine.listCalls, afterStop, reason: 'stopCapture 后音轨刷新定时器必须停止');

    await controller.close();
    endpoints.dispose();
  });

  test('轨成员不变时重复刷新只记一条 tracks_refreshed 事件', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _TrackFakeEngine engine = _TrackFakeEngine(
      tracks: <GalAudioTrack>[_track(0xB2)],
    );
    final GalHookSessionController controller = _controller(
      service: service,
      endpoints: endpoints,
      engine: engine,
    );

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 2, pid: 200, title: 'Engine game'),
    );
    await _waitUntil(() => controller.state.audioTracks.isNotEmpty);
    // 再等几轮定时刷新 + 一次手动刷新，成员未变化不得刷屏事件。
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await controller.refreshAudioTracks();
    expect(engine.listCalls, greaterThan(2));
    expect(
      controller.events
          .where((GalHookEvent e) => e.code == 'audio.tracks_refreshed'),
      hasLength(1),
      reason: '只有轨成员变化才记事件，低频刷新不得把事件日志刷成噪音',
    );

    await controller.close();
    endpoints.dispose();
  });

  test('晚到资源 hook 切 backend 后重刷一次并停掉低频定时器（BUG-1027 ①）', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _TrackFakeEngine engine = _TrackFakeEngine(
      audioFormat: null,
      textReady: true,
      lateRawReady: true,
    );
    final GalHookSessionController controller = _controller(
      service: service,
      endpoints: endpoints,
      engine: engine,
      trackRefreshInterval: const Duration(milliseconds: 30),
    );

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 3, pid: 300, title: 'KiriKiri game'),
    );
    expect(controller.state.audioBackend, GalHookAudioBackend.systemLoopback);
    await _waitUntil(
      () => controller.state.audioBackend == GalHookAudioBackend.gameResource,
    );
    expect(engine.listCalls, greaterThan(0), reason: 'backend 变化后应自动重刷音轨快照');

    // gameResource 不进 PCM 环：低频定时器必须已停。
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final int settled = engine.listCalls;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(engine.listCalls, settled, reason: 'gameResource 模式不应保留低频音轨刷新定时器');

    await controller.close();
    endpoints.dispose();
  });

  test('exportTrackPreview 按轨抓整句 PCM 并落临时 WAV（BUG-1027 试听）', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final Uint8List pcm = Uint8List(44100); // 0.5s @ 44100Hz/16bit/mono
    final _TrackFakeEngine engine = _TrackFakeEngine(
      tracks: <GalAudioTrack>[_track(0xC3)],
      utteranceSlice: GalAudioSlice(pcm: pcm, format: _pcm16Mono),
    );
    final GalHookSessionController controller = _controller(
      service: service,
      endpoints: endpoints,
      engine: engine,
    );

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 4, pid: 400, title: 'Engine game'),
    );
    final GalTrackPreview? preview = await controller.exportTrackPreview(0xC3);
    expect(preview, isNotNull);
    // 按轨抓取：sourcePtr 直传、exclude 为空（试听已排除轨同样允许）。
    expect(engine.utteranceSourcePtrs, contains(0xC3));
    expect(engine.utteranceExcludes.last, isEmpty);
    // 文件名/时长与纯函数契约一致；WAV = 44 字节头 + 原始 PCM。
    final File wav = File(preview!.filePath);
    expect(wav.existsSync(), isTrue);
    expect(
      wav.uri.pathSegments.last,
      galTrackPreviewFileName(sourcePtr: 0xC3, timestampMs: 0),
    );
    expect(preview.durationMs, pcmDurationMs(pcm.length, _pcm16Mono.byteRate));
    expect(wav.lengthSync(), 44 + pcm.length);
    wav.deleteSync();

    await controller.close();
    endpoints.dispose();
  });

  test('exportTrackPreview 无 engine 返回 null；无 PCM 记结构化事件', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _TrackFakeEngine engine = _TrackFakeEngine(utteranceSlice: null);
    final GalHookSessionController controller = _controller(
      service: service,
      endpoints: endpoints,
      engine: engine,
    );

    // 会话未激活（无 engine）：直接 null。
    expect(await controller.exportTrackPreview(0x1), isNull);

    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 5, pid: 500, title: 'Engine game'),
    );
    // engine 在但该轨窗口内无 PCM：null + 事件（页面据此 toast，不静默）。
    expect(await controller.exportTrackPreview(0x1), isNull);
    expect(
      controller.events.map((GalHookEvent e) => e.code),
      contains('audio.track_preview_empty'),
    );

    await controller.close();
    endpoints.dispose();
  });

  test('selectVoiceTrack 无 engine 记录警告事件而非静默（BUG-1027 ④）', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final GalHookSessionController controller = GalHookSessionController(
      textService: service,
      isWindows: false,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    expect(controller.hasEngineSource, isFalse);
    controller.selectVoiceTrack(0xD4);
    expect(
      controller.events.map((GalHookEvent e) => e.code),
      contains('audio.voice_track_select_unavailable'),
    );
    // 未选中任何轨（选择不生效）。
    expect(controller.state.selectedAudioSourcePtr, 0);

    await controller.close();
    endpoints.dispose();
  });

  group('纯函数', () {
    test('galTrackPreviewFileName 契约：十六进制指针 + 时间戳 + .wav', () {
      expect(
        galTrackPreviewFileName(sourcePtr: 0xABCD, timestampMs: 123456),
        'gal_track_preview_abcd_123456.wav',
      );
    });

    test('galTrackEmptyHintFor：资源/回环模式给解释态，其余通用空态', () {
      expect(
        galTrackEmptyHintFor(GalHookAudioBackend.gameResource),
        GalTrackEmptyHint.resourceMode,
      );
      expect(
        galTrackEmptyHintFor(GalHookAudioBackend.systemLoopback),
        GalTrackEmptyHint.loopbackMode,
      );
      expect(
        galTrackEmptyHintFor(GalHookAudioBackend.enginePcm),
        GalTrackEmptyHint.generic,
      );
      expect(
        galTrackEmptyHintFor(GalHookAudioBackend.none),
        GalTrackEmptyHint.generic,
      );
    });

    test('sameTrackMembership 只比 sourcePtr 序列', () {
      final List<GalAudioTrack> a = <GalAudioTrack>[_track(1), _track(2)];
      final List<GalAudioTrack> b = <GalAudioTrack>[_track(1), _track(2)];
      final List<GalAudioTrack> c = <GalAudioTrack>[_track(1), _track(3)];
      expect(GalHookSessionController.sameTrackMembership(a, b), isTrue);
      expect(GalHookSessionController.sameTrackMembership(a, c), isFalse);
      expect(
        GalHookSessionController.sameTrackMembership(a, <GalAudioTrack>[]),
        isFalse,
      );
    });
  });
}
