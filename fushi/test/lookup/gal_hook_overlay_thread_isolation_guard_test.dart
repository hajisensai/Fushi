import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_japanese_locale.dart';
import 'package:fushi/src/lookup/gal_hook_text_overlay_controller.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';
import 'package:fushi/src/sync/texthooker_service.dart';

import '../helpers/test_platform_services.dart';

/// BUG-1315 的**另一个方向**：放开无线程身份的行时不能连带放开「已选线程」这一支。
///
/// 修 BUG-1315 时容易把谓词写成「无身份行无条件放行」。那样一来，用户已经显式选定
/// 一条引擎线程后，同时挂着的 WebSocket / Textractor 端点仍会把平行文本推进正式消费面：
/// 浮窗的 `latest` 在两个来源之间跳，而无身份行没有 `textEventId`（只有引擎行会写
/// `_lineTextEventIdCache`），逐句语音配对只能退回时间戳兜底窗 —— BUG-1159 的失败链。
///
/// 本守卫钉住「选了哪条线程就只看哪条」这条 v12 之前就成立、且 BUG-1315 不该动的不变量。
class _IsolationTestEngine extends EngineHookGalAudioSource {
  _IsolationTestEngine()
      : super(targetPid: 0, launchExe: null, injectorPath: 'fake.exe');

  @override
  Future<PcmFormat?> start() async => const PcmFormat(
        sampleRate: 44100,
        channels: 1,
        bitsPerSample: 16,
        isFloat: false,
      );

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('app.fushi.reader/gal_hook_text');
  late TexthookerService textService;
  late GalHookSessionController session;
  late GalHookTextOverlayController controller;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
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
        GalJapaneseLocaleMode japaneseLocaleMode =
            kGalDefaultJapaneseLocaleMode,
      }) =>
          _IsolationTestEngine(),
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

  Future<void> waitUntil(bool Function() done) async {
    for (int i = 0; i < 100 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('已选定引擎线程后，WebSocket 无身份行不得混进浮窗与正式消费面', () async {
    await controller.start(appModel: AppModel(testPlatformServices()));
    await session.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 77, pid: 1234, title: 'Game'),
    );
    expect(
      await session.selectTextThread(11, threadKey: 'luna:first'),
      isTrue,
    );

    final TexthookerLineEntry hooked = textService.appendLine(
      '引擎线程台词',
      source: TexthookerLineSource.engineHook,
      textThreadKey: 'luna:first',
      nativeTextThreadId: 11,
    )!;
    await waitUntil(() => controller.displayedLineId == hooked.id);
    expect(controller.displayedLineId, hooked.id, reason: '前提：选中线程的行已上屏');

    // 同一时刻另有一个 WebSocket / Textractor 端点在喂无身份行。
    final TexthookerLineEntry anonymous = textService.appendLine(
      'Textractor 平行文本',
      source: TexthookerLineSource.websocket,
    )!;
    await waitUntil(() => controller.displayedLineId == anonymous.id);

    expect(
      session.selectedSessionLines.map((TexthookerLineEntry e) => e.id),
      <String>[hooked.id],
      reason: '已选线程时无身份行必须让位，否则逐句配对退回时间戳兜底窗（BUG-1159 失败链）',
    );
    expect(
      controller.displayedLineId,
      hooked.id,
      reason: '浮窗的 latest 不得在两个来源之间跳',
    );
    expect(
      session.workbenchLines.map((TexthookerLineEntry e) => e.id),
      <String>[hooked.id],
      reason: '工作台与浮窗必须同一份可发布集合',
    );
  });

  test('未选定任何线程时，WebSocket 无身份行仍然发布（BUG-1315 正方向不被本守卫削弱）', () async {
    await controller.start(appModel: AppModel(testPlatformServices()));
    await session.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 77, pid: 1234, title: 'Game'),
    );

    final TexthookerLineEntry anonymous = textService.appendLine(
      'Textractor 独立文本',
      source: TexthookerLineSource.websocket,
    )!;
    await waitUntil(() => controller.displayedLineId == anonymous.id);

    expect(controller.displayedLineId, anonymous.id);
    expect(
      session.selectedSessionLines.map((TexthookerLineEntry e) => e.id),
      <String>[anonymous.id],
    );
  });
}
