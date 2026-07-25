import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/lookup/gal_hook_text_overlay_controller.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/mining/galgame_audio_encode.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/platform/gal_hook_text_overlay_channel.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';

import '../helpers/test_platform_services.dart';

/// 浮窗语音控件（「重播」/「重播并录音」）：native 按钮 → Dart 分发 → 状态回推。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel =
      MethodChannel('app.hibiki.reader/gal_hook_text');
  late List<MethodCall> nativeCalls;
  late TexthookerService textService;
  late GalHookSessionController session;
  late GalHookTextOverlayController controller;

  setUp(() {
    nativeCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      nativeCalls.add(call);
      if (call.method == 'show' || call.method == 'isShowing') return true;
      return null;
    });
    GalHookTextOverlayChannel.platformOverride = true;
    textService = TexthookerService.test();
    session = GalHookSessionController(
      textService: textService,
      isWindows: true,
      targetWow64Probe: (_) async => false,
      injectorResolver: ({required bool is32Bit}) => 'fake.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
        List<String> launchArguments = const <String>[],
        String launchWorkdir = '',
      }) =>
          _VoiceTestEngine(),
      loopbackSourceFactory: _VoiceTestLoopback.new,
      endpointStatusLoader: () => const [],
    );
    controller = GalHookTextOverlayController.test(
      session: session,
      preferenceReader: (String key, {required Object? defaultValue}) =>
          defaultValue,
      preferenceWriter: (String key, Object? value) async {},
    );
  });

  tearDown(() async {
    await controller.stopForTesting();
    await session.close();
    GalHookTextOverlayChannel.platformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> invokeNative(String method) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
      (_) {},
    );
  }

  Future<void> waitUntil(bool Function() done) async {
    for (int i = 0; i < 100 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<TexthookerLineEntry> showFirstLine() async {
    await controller.start(appModel: AppModel(testPlatformServices()));
    await session.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 77, pid: 1234, title: 'Game'),
    );
    final TexthookerLineEntry line = textService.appendLine(
      '補録テスト台詞',
      source: TexthookerLineSource.websocket,
    )!;
    await waitUntil(() => controller.displayedLineId == line.id);
    return line;
  }

  test('native 的 recaptureVoice 按钮开启补录窗口并把状态推回浮窗', () async {
    final TexthookerLineEntry line = await showFirstLine();

    await invokeNative('recaptureVoice');
    await waitUntil(() => session.isRecapturing);

    expect(session.recapturingLineId, line.id);
    expect(controller.isRecapturing, isTrue);
    final MethodCall pushed = nativeCalls.lastWhere(
      (MethodCall call) => call.method == 'setVoiceState',
    );
    expect(
      (pushed.arguments as Map<Object?, Object?>)['recapturing'],
      isTrue,
    );

    // 再点一次 = 立即收束；状态必须回推成静止态。
    await invokeNative('recaptureVoice');
    await waitUntil(() => !session.isRecapturing);
    final MethodCall settled = nativeCalls.lastWhere(
      (MethodCall call) => call.method == 'setVoiceState',
    );
    expect(
      (settled.arguments as Map<Object?, Object?>)['recapturing'],
      isFalse,
    );
  });

  test('没有可播语音时 replayVoice 不进入试听态', () async {
    await showFirstLine();

    await invokeNative('replayVoice');
    await waitUntil(() => false);

    expect(controller.isReplaying, isFalse);
    expect(
      nativeCalls.where(
        (MethodCall call) =>
            call.method == 'setVoiceState' &&
            (call.arguments as Map<Object?, Object?>)['replaying'] == true,
      ),
      isEmpty,
    );
  });
}

class _VoiceTestEngine extends EngineHookGalAudioSource {
  _VoiceTestEngine()
      : super(targetPid: 0, launchExe: null, injectorPath: 'fake.exe');

  @override
  bool get textHookReady => true;

  @override
  Future<PcmFormat?> start() async => null;

  @override
  Future<bool> refreshReadiness() async => false;

  @override
  Future<GalTextPoll?> pollText(int sinceSeq) async =>
      const GalTextPoll(count: 0, lines: <GalHookedLine>[]);

  @override
  Future<bool> selectTextThread(int? threadId) async => true;

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

class _VoiceTestLoopback extends LoopbackGalAudioSource {
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
