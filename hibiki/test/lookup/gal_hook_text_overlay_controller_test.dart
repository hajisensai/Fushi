import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/lookup/gal_hook_text_overlay_controller.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/mining/galgame_audio_encode.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/platform/gal_hook_text_overlay_channel.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';

import '../helpers/test_platform_services.dart';

class _OverlayTestEngine extends EngineHookGalAudioSource {
  _OverlayTestEngine()
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

Future<void> _waitUntil(bool Function() done) async {
  for (int i = 0; i < 100 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue, reason: 'asynchronous overlay state did not settle');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel =
      MethodChannel('app.fushi.reader/gal_hook_text');
  late List<MethodCall> nativeCalls;
  late TexthookerService textService;
  late GalHookSessionController session;
  late GalHookTextOverlayController controller;
  late Map<String, Object?> preferences;

  setUp(() {
    nativeCalls = <MethodCall>[];
    preferences = <String, Object?>{};
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
          _OverlayTestEngine(),
      endpointStatusLoader: () => const [],
    );
    controller = GalHookTextOverlayController.test(
      session: session,
      preferenceReader: (
        String key, {
        required Object? defaultValue,
      }) =>
          preferences[key] ?? defaultValue,
      preferenceWriter: (String key, Object? value) async {
        preferences[key] = value;
      },
    );
  });

  tearDown(() async {
    await controller.stopForTesting();
    await session.close();
    GalHookTextOverlayChannel.platformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> startSession() async {
    await session.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 77, pid: 1234, title: 'Game'),
    );
  }

  test('first line auto-shows, pause freezes, and resume catches up', () async {
    await controller.start(appModel: AppModel(testPlatformServices()));
    await startSession();
    final TexthookerLineEntry first = textService.appendLine(
      '最初の台詞',
      source: TexthookerLineSource.websocket,
    )!;

    await _waitUntil(() => controller.displayedLineId == first.id);
    expect(controller.isVisible, isTrue);
    expect(
      nativeCalls.where((MethodCall call) => call.method == 'show'),
      hasLength(1),
    );
    final MethodCall firstUpdate = nativeCalls.firstWhere(
      (MethodCall call) => call.method == 'updateText',
    );
    expect(
        (firstUpdate.arguments as Map<Object?, Object?>)['lineId'], first.id);

    await controller.toggleFollowing();
    final TexthookerLineEntry second = textService.appendLine(
      '暂停期间的新台词',
      source: TexthookerLineSource.websocket,
    )!;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(controller.displayedLineId, first.id);

    await controller.toggleFollowing();
    await _waitUntil(() => controller.displayedLineId == second.id);
    expect(controller.isFollowing, isTrue);
  });

  test('close suppresses one session, manual reopen and next session reset',
      () async {
    await controller.start(appModel: AppModel(testPlatformServices()));
    await startSession();
    final TexthookerLineEntry first = textService.appendLine(
      '会话一',
      source: TexthookerLineSource.websocket,
    )!;
    await _waitUntil(() => controller.displayedLineId == first.id);

    await controller.closeForCurrentSession();
    final int showsAfterClose =
        nativeCalls.where((MethodCall call) => call.method == 'show').length;
    textService.appendLine(
      '关闭后不可自动出现',
      source: TexthookerLineSource.websocket,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(controller.isSuppressedForSession, isTrue);
    expect(
      nativeCalls.where((MethodCall call) => call.method == 'show').length,
      showsAfterClose,
    );

    await controller.showManually();
    await _waitUntil(() => controller.isVisible);
    expect(controller.isSuppressedForSession, isFalse);

    await controller.toggleFollowing();
    await controller.togglePassThrough();
    await controller.closeForCurrentSession();
    await session.stopCapture();
    await _waitUntil(() => !controller.isVisible);

    await startSession();
    final TexthookerLineEntry nextSession = textService.appendLine(
      '新会话自动恢复',
      source: TexthookerLineSource.websocket,
    )!;
    await _waitUntil(() => controller.displayedLineId == nextSession.id);
    expect(controller.isFollowing, isTrue);
    expect(controller.isPassThrough, isFalse);
    expect(controller.isSuppressedForSession, isFalse);
  });

  test('selected text thread alone drives the floating line', () async {
    await controller.start(appModel: AppModel(testPlatformServices()));
    await startSession();
    expect(
      await session.selectTextThread(11, threadKey: 'luna:first'),
      isTrue,
    );
    final TexthookerLineEntry firstThread = textService.appendLine(
      '正确线程',
      source: TexthookerLineSource.engineHook,
      textThreadKey: 'luna:first',
      nativeTextThreadId: 11,
    )!;
    await _waitUntil(() => controller.displayedLineId == firstThread.id);

    final TexthookerLineEntry otherThread = textService.appendLine(
      '另一个线程',
      source: TexthookerLineSource.engineHook,
      textThreadKey: 'luna:second',
      nativeTextThreadId: 22,
    )!;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(controller.displayedLineId, firstThread.id);

    expect(
      await session.selectTextThread(22, threadKey: 'luna:second'),
      isTrue,
    );
    await _waitUntil(() => controller.displayedLineId == otherThread.id);
  });

  test('saved rectangle is restored and changed bounds are persisted',
      () async {
    preferences['gal_hook_text_window_rect'] =
        '{"left":12,"top":34,"width":800,"height":180}';
    await controller.start(appModel: AppModel(testPlatformServices()));
    await startSession();
    textService.appendLine(
      '位置を復元する',
      source: TexthookerLineSource.websocket,
    );
    await _waitUntil(() => controller.isVisible);

    final MethodCall show = nativeCalls.lastWhere(
      (MethodCall call) => call.method == 'show',
    );
    final Map<Object?, Object?> args = show.arguments as Map<Object?, Object?>;
    expect(args['left'], 12);
    expect(args['top'], 34);
    expect(args['width'], 800);
    expect(args['height'], 180);

    const MethodCodec codec = StandardMethodCodec();
    final ByteData data = codec.encodeMethodCall(
      const MethodCall('windowRectChanged', <String, Object?>{
        'left': 50,
        'top': 60,
        'width': 950,
        'height': 200,
      }),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'app.fushi.reader/gal_hook_text',
      data,
      (_) {},
    );
    await _waitUntil(
      () =>
          (preferences['gal_hook_text_window_rect'] as String?)
              ?.contains('"left":50') ==
          true,
    );
  });

  // BUG-1095：字号是一条独立偏好，与窗口几何（gal_hook_text_window_rect）互不影响。
  // 修复前 native 按窗口高度缩放字号，「拖高浮窗」＝「放大台词」，可见行数几乎不涨。
  test('保存的字号随 show 一起送给 native，且窗口几何不受影响', () async {
    preferences['gal_hook_text_font_size'] = 48.0;
    preferences['gal_hook_text_window_rect'] =
        '{"left":12,"top":34,"width":800,"height":180}';
    await controller.start(appModel: AppModel(testPlatformServices()));
    await startSession();
    textService.appendLine(
      'フォントサイズ',
      source: TexthookerLineSource.websocket,
    );
    await _waitUntil(() => controller.isVisible);

    final MethodCall show = nativeCalls.lastWhere(
      (MethodCall call) => call.method == 'show',
    );
    final Map<Object?, Object?> args = show.arguments as Map<Object?, Object?>;
    expect(args['fontSize'], 48.0, reason: '字号必须来自偏好，而不是硬常量');
    expect(controller.fontSize, 48.0);
    expect(args['height'], 180, reason: '改字号不得连带改窗口几何（两者已解耦）');
  });

  test('越界的历史脏字号被收敛到合法区间', () async {
    preferences['gal_hook_text_font_size'] = 9999.0;
    await controller.start(appModel: AppModel(testPlatformServices()));
    expect(
      controller.fontSize,
      PreferencesRepository.galHookTextFontSizeMax,
    );
  });

  test('applyFontSizeFromPreferences 立刻把新字号经 updateStyle 推给 native', () async {
    await controller.start(appModel: AppModel(testPlatformServices()));
    await startSession();
    textService.appendLine(
      '設定から変更',
      source: TexthookerLineSource.websocket,
    );
    await _waitUntil(() => controller.isVisible);
    expect(controller.fontSize, kGalHookTextFontSize);

    // 设置页写 pref（真实链路是 AppModel.setGalHookTextFontSize）后调用本方法。
    preferences['gal_hook_text_font_size'] = 20.0;
    await controller.applyFontSizeFromPreferences();

    expect(controller.fontSize, 20.0);
    final MethodCall style = nativeCalls.lastWhere(
      (MethodCall call) => call.method == 'updateStyle',
    );
    expect(
      (style.arguments as Map<Object?, Object?>)['fontSize'],
      20.0,
      reason: '漏掉这一步字号只落了盘，浮窗要等下次改透明度才顺带刷新（TODO-1069 同款纪律）',
    );

    // 幂等：值没变时不再重复推 native。
    final int stylePushes =
        nativeCalls.where((MethodCall c) => c.method == 'updateStyle').length;
    await controller.applyFontSizeFromPreferences();
    expect(
      nativeCalls.where((MethodCall c) => c.method == 'updateStyle').length,
      stylePushes,
    );
  });
}
