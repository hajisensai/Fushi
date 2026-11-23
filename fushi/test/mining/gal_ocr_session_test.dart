import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/gal_ocr_line_source.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/galgame_japanese_locale.dart';
import 'package:fushi/src/mining/galgame_play_tracker.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/sync/texthooker_ws_client.dart';

/// OCR 游戏模式的会话集成（拍板台 v5GSgDau9u / BUG-5083）：不注入、音频走系统回录且不算
/// 降级、OCR 行以 screenOcr 来源进台词流并参与渐进折叠、停止监听停泵并退出 OCR 模式。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ExternalWindowInfo window = ExternalWindowInfo(
    hwnd: 31,
    pid: 5151,
    title: 'Online game',
  );
  const GalOcrRegion region = GalOcrRegion(
    left: 0.1,
    top: 0.7,
    width: 0.8,
    height: 0.25,
  );

  late TexthookerService service;
  late ChangeNotifier endpoints;
  late GalHookSessionController controller;
  late List<String> injections;
  late List<({int hwnd, GalOcrRegion region})> createdSources;
  late GalOcrLineSource source;
  late void Function(String text) emitLine;
  late void Function(GalOcrSourceIssue issue, Object? detail) emitIssue;
  late LoopbackGalAudioSource Function() loopbackFactory;
  late bool createdBinarize;

  /// 窗口 PID → exe 路径（默认查不到：与第一期一样没有游戏身份）。
  String? imagePath;

  setUp(() {
    imagePath = null;
    createdBinarize = false;
    service = TexthookerService.test();
    endpoints = ChangeNotifier();
    injections = <String>[];
    createdSources = <({int hwnd, GalOcrRegion region})>[];
    loopbackFactory = _QuietLoopback.new;
    controller = GalHookSessionController(
      textService: service,
      isWindows: true,
      targetImagePathProbe: (int pid) => pid == window.pid ? imagePath : null,
      targetWow64Probe: (_) async {
        injections.add('wow64');
        return false;
      },
      injectorResolver: ({required bool is32Bit}) async {
        injections.add('injector');
        // 附着路径走到「helper 缺失 → 回录」即可，不需要真的起引擎。
        return null;
      },
      engineSourceFactory:
          ({
            required int targetPid,
            required String? launchExe,
            required String injectorPath,
            required bool lunaPcHooks,
            int? lunaCodepage,
            List<String> launchArguments = const <String>[],
            String launchWorkdir = '',
            GalJapaneseLocaleMode japaneseLocaleMode =
                kGalDefaultJapaneseLocaleMode,
            String? contentLanguage,
          }) {
            injections.add('engine');
            throw StateError('OCR mode must not inject');
          },
      loopbackSourceFactory: () => loopbackFactory(),
      gameProcessProbe: _AliveProbe(),
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
      ocrSourceFactory:
          ({
            required int hwnd,
            required GalOcrRegion region,
            required bool binarize,
            required GalOcrRecognize recognize,
            required void Function(String text) onLine,
            required void Function(GalOcrSourceIssue issue, Object? detail)
            onIssue,
          }) {
            createdSources.add((hwnd: hwnd, region: region));
            createdBinarize = binarize;
            emitLine = onLine;
            emitIssue = onIssue;
            // 真泵，但截窗永远失败、间隔很长：本测试直接经 onLine 喂行，只验会话侧。
            return source = GalOcrLineSource(
              hwnd: hwnd,
              region: region,
              binarize: binarize,
              recognize: recognize,
              onLine: onLine,
              interval: const Duration(hours: 1),
              capture: (int _) async =>
                  const WindowCaptureResult(error: 'test'),
            );
          },
    );
  });

  tearDown(() async {
    await controller.close();
    endpoints.dispose();
  });

  Future<String> recognize(Uint8List rgba, int width, int height) async => '';

  test('不注入；回录是设计内音源，不算降级；泵按窗口与区域启动', () async {
    await controller.startOcrCapture(
      window,
      region: region,
      recognize: recognize,
    );
    final GalHookSessionState state = controller.state;
    expect(injections, isEmpty, reason: 'OCR 模式不得探位数 / 找 helper / 注入');
    expect(state.isOcrMode, isTrue);
    expect(state.ocrRegion, region);
    expect(state.phase, GalHookSessionPhase.waitingSignals);
    expect(state.isDegraded, isFalse);
    expect(state.fallbackReason, isNull);
    expect(state.audioBackend, GalHookAudioBackend.systemLoopback);
    expect(state.externalWindowMode, isTrue);
    expect(state.boundWindow?.hwnd, window.hwnd);
    expect(createdSources, <({int hwnd, GalOcrRegion region})>[
      (hwnd: window.hwnd, region: region),
    ]);
    expect(source.isRunning, isTrue);
  });

  test('OCR 行以 screenOcr 来源进台词流，续写折叠成同一行，会话转 running', () async {
    await controller.startOcrCapture(
      window,
      region: region,
      recognize: recognize,
    );
    emitLine('今日はとても');
    final TexthookerLineEntry first = service.entries.last;
    expect(first.source, TexthookerLineSource.screenOcr);
    expect(first.sourceLabel, kGalScreenOcrLineSourceLabel);
    expect(controller.state.phase, GalHookSessionPhase.running);
    expect(controller.state.textSignalReceived, isTrue);

    emitLine('今日はとてもいい天気ですね');
    expect(service.entries, hasLength(1), reason: 'Rust 判出的续写是严格前缀扩展，台词流并成一行');
    expect(service.entries.single.id, first.id);
    expect(service.entries.single.text, '今日はとてもいい天気ですね');

    emitLine('次の台詞');
    expect(service.entries, hasLength(2));
    expect(
      controller.workbenchLines.map((TexthookerLineEntry e) => e.text),
      <String>['今日はとてもいい天気ですね', '次の台詞'],
    );
  });

  test('泵故障进状态；换区域更新状态与泵；停止监听停泵并退出 OCR 模式', () async {
    await controller.startOcrCapture(
      window,
      region: region,
      recognize: recognize,
    );
    emitIssue(GalOcrSourceIssue.captureFailed, 'minimized');
    expect(controller.state.ocrIssue, GalOcrSourceIssue.captureFailed);

    const GalOcrRegion moved = GalOcrRegion(
      left: 0,
      top: 0.5,
      width: 1,
      height: 0.5,
    );
    controller.setOcrRegion(moved);
    expect(controller.state.ocrRegion, moved);
    expect(source.region, moved);

    await controller.stopCapture();
    expect(source.isRunning, isFalse);
    expect(controller.state.isOcrMode, isFalse);
    expect(controller.state.ocrIssue, GalOcrSourceIssue.none);
    expect(controller.state.phase, GalHookSessionPhase.idle);
  });

  test('OCR 设置按游戏记（BUG-5141 ②）：框与二值化进该游戏捕获记忆，下次按窗口交回', () async {
    final Map<String, GalCaptureMemory> store = <String, GalCaptureMemory>{};
    controller.attachCaptureMemory(
      load: (String key) => store[key] ?? const GalCaptureMemory(),
      save: (String key, GalCaptureMemory memory) => store[key] = memory,
    );
    imagePath = r'C:\Games\Online\Game.exe';
    const String key = r'c:\games\online\game.exe';
    // 没开过 OCR 模式：没有记忆。
    expect(controller.rememberedOcrSettingsFor(window), (
      region: null,
      binarize: false,
    ));

    await controller.startOcrCapture(
      window,
      region: region,
      recognize: recognize,
      binarize: true,
    );
    expect(createdBinarize, isTrue);
    expect(source.binarize, isTrue);
    expect(controller.state.ocrBinarize, isTrue);
    expect(store[key]?.ocrRegion, region);
    expect(store[key]?.ocrBinarize, isTrue);

    const GalOcrRegion moved = GalOcrRegion(
      left: 0.2,
      top: 0.6,
      width: 0.6,
      height: 0.3,
    );
    controller.setOcrRegion(moved);
    controller.setOcrBinarize(false);
    expect(source.binarize, isFalse);
    expect(controller.state.ocrBinarize, isFalse);
    expect(store[key]?.ocrRegion, moved);
    expect(store[key]?.ocrBinarize, isFalse);
    // 会话中：交回本局设置。
    expect(controller.rememberedOcrSettingsFor(window), (
      region: moved,
      binarize: false,
    ));

    await controller.stopCapture();
    expect(controller.state.ocrBinarize, isFalse);
    // 会话结束后：按窗口 PID → exe 读记忆。
    expect(controller.rememberedOcrSettingsFor(window), (
      region: moved,
      binarize: false,
    ));
    // JSON 往返（偏好里存的是 toJson）。
    final GalCaptureMemory roundTrip = GalCaptureMemory.fromJson(
      store[key]!.toJson().cast<Object?, Object?>(),
    );
    expect(roundTrip.ocrRegion, moved);
    expect(roundTrip.ocrBinarize, isFalse);
    expect(roundTrip.isEmpty, isFalse);
  });

  test('查不到游戏 exe：OCR 设置只活在会话内，不写记忆', () async {
    final Map<String, GalCaptureMemory> store = <String, GalCaptureMemory>{};
    controller.attachCaptureMemory(
      load: (String key) => store[key] ?? const GalCaptureMemory(),
      save: (String key, GalCaptureMemory memory) => store[key] = memory,
    );
    await controller.startOcrCapture(
      window,
      region: region,
      recognize: recognize,
    );
    expect(store, isEmpty);
    await controller.stopCapture();
    expect(controller.rememberedOcrSettingsFor(window).region, isNull);
  });

  test('OCR 会话启动途中停止监听：不留下 OCR 模式（泵还没建起来也要退出）', () async {
    final Completer<void> entered = Completer<void>();
    final Completer<void> release = Completer<void>();
    loopbackFactory = () =>
        _GatedStartLoopback(entered: entered, release: release);
    final Future<void> starting = controller.startOcrCapture(
      window,
      region: region,
      recognize: recognize,
    );
    await entered.future;
    expect(controller.state.isOcrMode, isTrue);
    final Future<void> stopping = controller.stopCapture();
    release.complete();
    await starting;
    await stopping;
    expect(createdSources, isEmpty, reason: '被停止抢先的启动不得再建泵');
    expect(controller.state.phase, GalHookSessionPhase.idle);
    expect(
      controller.state.isOcrMode,
      isFalse,
      reason: '泵没建起来时停止也必须清掉 ocrRegion，否则下一局附着会挂着「OCR 模式」',
    );
  });

  test('从 OCR 模式切到附着捕获：先停泵、退出 OCR 模式', () async {
    await controller.startOcrCapture(
      window,
      region: region,
      recognize: recognize,
    );
    final GalOcrLineSource ocr = source;
    unawaited(controller.startAttachedCapture(window));
    for (int i = 0; i < 200 && injections.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(ocr.isRunning, isFalse);
    expect(controller.state.isOcrMode, isFalse);
    await controller.stopCapture();
  });
}

/// 回录 start 卡在 [release] 上：用来把「停止监听」插进 OCR 会话启动途中。
class _GatedStartLoopback extends _QuietLoopback {
  _GatedStartLoopback({required this.entered, required this.release});

  final Completer<void> entered;
  final Completer<void> release;

  @override
  Future<PcmFormat?> start() async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return super.start();
  }
}

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

class _AliveProbe implements GalgameProcessProbe {
  @override
  int? foregroundProcessId() => null;

  @override
  bool isProcessAlive(int pid) => true;

  @override
  String? processImagePath(int pid) => null;

  @override
  List<GalgameProcessInfo> listProcesses() => const <GalgameProcessInfo>[];

  @override
  String? canonicalize(String path) => null;
}
