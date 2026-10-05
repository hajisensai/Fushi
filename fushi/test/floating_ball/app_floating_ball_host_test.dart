import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/floating_ball/app_floating_ball_host.dart';
import 'package:fushi/src/floating_ball/floating_ball_channel.dart';
import 'package:fushi/src/floating_ball/floating_ball_config.dart';
import 'package:fushi/src/floating_ball/floating_ball_scene.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_lookup_host.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

class _ReadyAppModel extends AppModel {
  _ReadyAppModel() : super(testPlatformServices());

  @override
  bool get isInitialised => true;

  // 桩没有主题子系统；宿主读它决定球要不要动画。
  @override
  bool get einkMode => false;
}

ReaderHeaderAction _action(String key) => ReaderHeaderAction(
  key: ValueKey<String>(key),
  icon: Icons.play_arrow,
  label: key,
  onPressed: () {},
);

/// 视频场景：登记播放 / 暂停与收藏两颗专属按钮。
Widget _videoScene() => FloatingBallScene(
  scope: FloatingBallScope.video,
  actions: <String, ReaderHeaderAction>{
    'play_pause': _action('scene_play_pause'),
    'favorite': _action('scene_favorite'),
  },
);

void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late _ReadyAppModel appModel;
  late Directory storeDir;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    FloatingBallSceneRegistry.instance.debugReset();
    FloatingLyricLookupNotifier.instance.debugReset();
    // 通道回调是进程级一次性安装：不重置的话后面的用例里原生消息会打到前一个
    // 用例已销毁的宿主上。
    FloatingBallChannel.debugResetHandler();
    pendingExternalLookup.value = null;
    pendingSystemOcrSetup.value = false;
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_floating_ball');
    appModel = _ReadyAppModel()
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir)
      ..wireDatabaseForTesting(db);
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
  });

  Future<void> pumpHost(WidgetTester tester, {Widget? home}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: appModel.navigatorKey,
            navigatorObservers: <NavigatorObserver>[floatingBallRouteObserver],
            home: Scaffold(body: home ?? const SizedBox()),
            builder: (BuildContext context, Widget? child) =>
                Stack(children: <Widget>[child!, const AppFloatingBallHost()]),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder ball() =>
      find.byKey(const ValueKey<String>('fushi_app_floating_ball'));

  Finder byKey(String key) => find.byKey(ValueKey<String>(key));

  Future<void> expand(WidgetTester tester) async {
    await tester.tap(byKey('fushi_reader_floating_ball_icon'));
    await tester.pumpAndSettle();
  }

  testWidgets('默认开着应用内悬浮球；没有场景的页面只有全局按钮', (WidgetTester tester) async {
    await pumpHost(tester);
    expect(ball(), findsOneWidget);
    await expand(tester);
    expect(byKey('floating_ball_action_lookup'), findsOneWidget);
    expect(byKey('floating_ball_action_clipboard'), findsOneWidget);
    // 截屏识字只有 Android / iOS 有。
    expect(
      byKey('floating_ball_action_screen_ocr'),
      Platform.isAndroid || Platform.isIOS ? findsOneWidget : findsNothing,
    );
    // 拍照查词只有 Android / iOS 有（桌面没有相机入口）。
    expect(
      byKey('floating_ball_action_camera_ocr'),
      Platform.isAndroid || Platform.isIOS ? findsOneWidget : findsNothing,
    );
    // 应用外查词（独立查词窗）只有 Android 有。
    expect(
      byKey('floating_ball_action_popup_lookup'),
      Platform.isAndroid ? findsOneWidget : findsNothing,
    );
    // 立即同步出厂不勾（多数人没配同步），要在设置里自己勾上。
    expect(byKey('floating_ball_action_sync'), findsNothing);
  });

  testWidgets('设置里关掉应用内悬浮球：不画球', (WidgetTester tester) async {
    await prefs.setFloatingBallInApp(false);
    await pumpHost(tester, home: _videoScene());
    await tester.pump();
    expect(ball(), findsNothing);
  });

  testWidgets('出厂：场景专属按钮排在全局按钮前面', (WidgetTester tester) async {
    await pumpHost(tester, home: _videoScene());
    await tester.pump();
    await expand(tester);
    final Finder play = byKey('scene_play_pause');
    final Finder lookup = byKey('floating_ball_action_lookup');
    expect(play, findsOneWidget);
    expect(byKey('scene_favorite'), findsOneWidget);
    expect(lookup, findsOneWidget);
    // 竖排：列表里越靠前越在上面。
    expect(tester.getCenter(play).dy, lessThan(tester.getCenter(lookup).dy));
  });

  testWidgets('只显示为当前场景勾选的按钮', (WidgetTester tester) async {
    await prefs.setFloatingBallButtons(FloatingBallScope.video, <String>[
      'favorite',
      'clipboard',
    ]);
    await pumpHost(tester, home: _videoScene());
    await tester.pump();
    await expand(tester);
    expect(byKey('scene_favorite'), findsOneWidget);
    expect(byKey('floating_ball_action_clipboard'), findsOneWidget);
    expect(byKey('scene_play_pause'), findsNothing);
    expect(byKey('floating_ball_action_lookup'), findsNothing);
  });

  testWidgets('各场景的勾选互不影响', (WidgetTester tester) async {
    // 「其它页面」只留查词，视频场景仍按出厂。
    await prefs.setFloatingBallButtons(FloatingBallScope.general, <String>[
      'lookup',
    ]);
    await pumpHost(tester, home: _videoScene());
    await tester.pump();
    await expand(tester);
    expect(byKey('scene_play_pause'), findsOneWidget);
    expect(byKey('floating_ball_action_clipboard'), findsOneWidget);
  });

  testWidgets('勾选了但页面此刻没提供的专属按钮跳过', (WidgetTester tester) async {
    await prefs.setFloatingBallButtons(FloatingBallScope.manga, <String>[
      'chapters',
      'next',
    ]);
    await pumpHost(
      tester,
      home: FloatingBallScene(
        scope: FloatingBallScope.manga,
        actions: <String, ReaderHeaderAction>{'next': _action('scene_next')},
      ),
    );
    await tester.pump();
    await expand(tester);
    expect(byKey('scene_next'), findsOneWidget);
  });

  testWidgets('一颗按钮都不剩就不画球', (WidgetTester tester) async {
    await prefs.setFloatingBallButtons(
      FloatingBallScope.general,
      const <String>[],
    );
    await pumpHost(tester);
    expect(ball(), findsNothing);
  });

  testWidgets('剪贴板查词把剪贴板文字交给应用内查词弹窗', (WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async => call.method == 'Clipboard.getData'
          ? <String, Object?>{'text': ' 猫 '}
          : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pumpHost(tester);
    await expand(tester);
    await tester.tap(byKey('floating_ball_action_clipboard'));
    await tester.pump();
    final FloatingLyricLookupRequest? request = FloatingLyricLookupNotifier
        .instance
        .consume();
    expect(request?.text, '猫');
    expect(request?.index, 0);
  });

  testWidgets('立即同步走与设置页同一个手动同步入口（已有同步在跑时只提示）', (WidgetTester tester) async {
    // 已有一轮同步在跑：统一入口第一步就返回 busy 并提示，不碰同步通道——用它
    // 证明按钮接的是 runManualSyncWithFeedback 而不是另起一套。
    syncInProgress.value = true;
    addTearDown(() => syncInProgress.value = false);
    await prefs.setFloatingBallButtons(FloatingBallScope.general, <String>[
      'sync',
    ]);
    await pumpHost(tester);
    await expand(tester);
    await tester.tap(byKey('floating_ball_action_sync'));
    await tester.pump();
    expect(find.text(t.sync_now_busy), findsOneWidget);
  });

  testWidgets('球外的空白处点击照常落到底下页面', (WidgetTester tester) async {
    int taps = 0;
    await pumpHost(
      tester,
      home: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => taps++,
        child: const SizedBox.expand(),
      ),
    );
    expect(ball(), findsOneWidget);
    await tester.tapAt(const Offset(40, 40));
    expect(taps, 1);
  });

  testWidgets('场景要求隐藏时不画球', (WidgetTester tester) async {
    await pumpHost(
      tester,
      home: const FloatingBallScene(
        scope: FloatingBallScope.video,
        actions: <String, ReaderHeaderAction>{},
        hideBall: true,
      ),
    );
    await tester.pump();
    expect(ball(), findsNothing);
  });

  testWidgets('BUG-2906：原生报系统 OCR 模型未就绪 → 就绪后弹出模型配置，而不是只提示', (
    WidgetTester tester,
  ) async {
    // 通道回调只在有系统球 / 截屏识字的平台装；测试机按桌面装上。
    debugDesktopSystemBallPlatformOverride = true;
    addTearDown(() => debugDesktopSystemBallPlatformOverride = null);
    // Android 原生侧：模型还没由 Play 服务取下。
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      kSystemOcrChannel,
      (MethodCall call) async =>
          call.method == 'modelStatus' ? 'missing' : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        kSystemOcrChannel,
        null,
      ),
    );
    await pumpHost(tester);
    expect(find.text(t.ocr_system_model_title), findsNothing);

    final ByteData message = const StandardMethodCodec().encodeMethodCall(
      const MethodCall('openSystemOcrSetup'),
    );
    await tester.runAsync(() async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        FloatingBallChannel.channel.name,
        message,
        (_) {},
      );
    });
    await tester.pump();
    await tester.pumpAndSettle();
    expect(pendingSystemOcrSetup.value, isFalse);
    expect(find.text(t.ocr_system_model_title), findsOneWidget);
    expect(find.text(t.ocr_system_model_missing), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('system_ocr_setup_download')),
      findsOneWidget,
    );
  });

  testWidgets('外部查词（深链 / App Intent）在就绪后交给查词弹窗', (WidgetTester tester) async {
    await pumpHost(tester);
    deliverExternalLookup(' 犬 ');
    await tester.pump();
    await tester.pump();
    expect(pendingExternalLookup.value, isNull);
    expect(FloatingLyricLookupNotifier.instance.consume()?.text, '犬');
  });

  testWidgets('关闭键只收起这一页：弹对话框仍收着，离开再回来自动恢复，不改设置', (WidgetTester tester) async {
    await pumpHost(tester, home: _videoScene());
    await tester.pump();
    await expand(tester);
    final Finder close = byKey('floating_ball_action_close');
    expect(close, findsOneWidget);
    // 离球最远：比任何勾选的按钮都靠上。
    expect(
      tester.getCenter(close).dy,
      lessThan(tester.getCenter(byKey('scene_play_pause')).dy),
    );
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(ball(), findsNothing);
    expect(prefs.floatingBallInApp, isTrue, reason: '「这次不要，之后要」：不动设置');

    // 同一页上弹对话框：人还在这页，球仍收着。
    final NavigatorState nav = appModel.navigatorKey.currentState!;
    showDialog<void>(
      context: nav.context,
      builder: (BuildContext context) => const AlertDialog(content: Text('d')),
    );
    await tester.pumpAndSettle();
    expect(ball(), findsNothing);
    nav.pop();
    await tester.pumpAndSettle();
    expect(ball(), findsNothing);

    // 离开这一页（进别的页面）：恢复。
    nav.push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const Scaffold(body: SizedBox()),
      ),
    );
    await tester.pumpAndSettle();
    expect(ball(), findsOneWidget);

    // 回到视频页：也照常在（这次关掉的已经过去了）。
    nav.pop();
    await tester.pumpAndSettle();
    expect(ball(), findsOneWidget);
  });

  /// 把 app 切到后台再切回来（按真实的生命周期顺序逐级走）。
  Future<void> backgroundAndReturn(WidgetTester tester) async {
    for (final AppLifecycleState state in <AppLifecycleState>[
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
  }

  testWidgets('自动恢复含应用内：本页关掉的球从后台回到 Fushi 时恢复', (WidgetTester tester) async {
    await pumpHost(tester, home: _videoScene());
    await tester.pump();
    await expand(tester);
    await tester.tap(byKey('floating_ball_action_close'));
    await tester.pumpAndSettle();
    expect(ball(), findsNothing);

    await backgroundAndReturn(tester);
    expect(ball(), findsOneWidget);
    expect(prefs.floatingBallInApp, isTrue);
  });

  testWidgets('不自动恢复：关闭即关掉「应用内显示」，换页、回到 Fushi 都不回来', (
    WidgetTester tester,
  ) async {
    await prefs.setFloatingBallAutoRestore(FloatingBallAutoRestore.off);
    await pumpHost(tester, home: _videoScene());
    await tester.pump();
    await expand(tester);
    await tester.tap(byKey('floating_ball_action_close'));
    await tester.pumpAndSettle();
    expect(ball(), findsNothing);
    expect(prefs.floatingBallInApp, isFalse);

    appModel.navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const Scaffold(body: SizedBox()),
      ),
    );
    await tester.pumpAndSettle();
    expect(ball(), findsNothing);
    await backgroundAndReturn(tester);
    expect(ball(), findsNothing);
  });

  testWidgets('本页关掉球后把自动恢复改成「不自动恢复」：关闭落定为关掉「应用内显示」，回到 Fushi 不再出现', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester, home: _videoScene());
    await tester.pump();
    await expand(tester);
    await tester.tap(byKey('floating_ball_action_close'));
    await tester.pumpAndSettle();
    expect(ball(), findsNothing);
    expect(prefs.floatingBallInApp, isTrue);

    debugLatestClosedBallSettle = null;
    await tester.runAsync(() async {
      await prefs.setFloatingBallAutoRestore(FloatingBallAutoRestore.off);
      expect(debugLatestClosedBallSettle, isNotNull, reason: '应当落定这次关闭');
      await debugLatestClosedBallSettle;
    });
    await tester.pumpAndSettle();
    expect(prefs.floatingBallInApp, isFalse, reason: '按新选项落定这次关闭');

    await backgroundAndReturn(tester);
    expect(ball(), findsNothing);
  });

  test('自动恢复三态：持久化值往返，未知值回落出厂「仅应用内」', () async {
    expect(prefs.floatingBallAutoRestore, FloatingBallAutoRestore.inApp);
    for (final FloatingBallAutoRestore value
        in FloatingBallAutoRestore.values) {
      await prefs.setFloatingBallAutoRestore(value);
      expect(prefs.floatingBallAutoRestore, value);
    }
    expect(
      FloatingBallAutoRestore.fromStorage('bogus'),
      FloatingBallAutoRestore.inApp,
    );
    expect(FloatingBallAutoRestore.both.restoresSystem, isTrue);
    expect(FloatingBallAutoRestore.inApp.restoresSystem, isFalse);
    expect(FloatingBallAutoRestore.inApp.restoresInApp, isTrue);
    expect(FloatingBallAutoRestore.off.restoresInApp, isFalse);
  });

  group('页面把必需入口托付给球（阅读器关掉顶栏和底栏）', () {
    /// 阅读器场景：登记返回 / 设置 / 开回栏 + 播放键；[pinned] 为 true 时前三颗
    /// 固定在球上。
    Widget readerScene({required bool pinned}) => FloatingBallScene(
      scope: FloatingBallScope.reader,
      pinnedIds: pinned
          ? const <String>['back', 'settings', 'toolbars']
          : const <String>[],
      actions: <String, ReaderHeaderAction>{
        'back': _action('scene_back'),
        'settings': _action('scene_settings'),
        'toolbars': _action('scene_toolbars'),
        'audiobookPlayPause': _action('scene_play_pause'),
      },
    );

    testWidgets('不看勾选、排在最上；没有关闭键；勾选全关也照样有球', (WidgetTester tester) async {
      await prefs.setFloatingBallButtons(FloatingBallScope.reader, <String>[
        'audiobookPlayPause',
        'settings',
      ]);
      await pumpHost(tester, home: readerScene(pinned: true));
      await tester.pump();
      await expand(tester);
      expect(byKey('floating_ball_action_close'), findsNothing);
      final List<double> ys = <String>[
        'scene_back',
        'scene_settings',
        'scene_toolbars',
        'scene_play_pause',
      ].map((String k) => tester.getCenter(byKey(k)).dy).toList();
      for (int i = 1; i < ys.length; i++) {
        expect(ys[i - 1], lessThan(ys[i]), reason: '固定按钮在上、勾选的在下');
      }
      // 勾选里也有「设置」：不重复出现。
      expect(byKey('scene_settings'), findsOneWidget);

      await prefs.setFloatingBallButtons(
        FloatingBallScope.reader,
        const <String>[],
      );
      await tester.pumpAndSettle();
      expect(ball(), findsOneWidget, reason: '球是此刻唯一的返回 / 设置入口');
    });

    testWidgets('本页先前点过「关闭」：接管一开始球立即回来', (WidgetTester tester) async {
      final ValueNotifier<bool> pinned = ValueNotifier<bool>(false);
      addTearDown(pinned.dispose);
      await pumpHost(
        tester,
        home: ValueListenableBuilder<bool>(
          valueListenable: pinned,
          builder: (BuildContext context, bool value, Widget? child) =>
              readerScene(pinned: value),
        ),
      );
      await tester.pump();
      await expand(tester);
      await tester.tap(byKey('floating_ball_action_close'));
      await tester.pumpAndSettle();
      expect(ball(), findsNothing);

      pinned.value = true;
      await tester.pumpAndSettle();
      expect(ball(), findsOneWidget);

      // 接管结束（栏开回来）：关闭键回来了，而且不会沿用接管前的那次「关闭」。
      pinned.value = false;
      await tester.pumpAndSettle();
      expect(ball(), findsOneWidget);
      await expand(tester);
      expect(byKey('floating_ball_action_close'), findsOneWidget);
    });

    testWidgets('设置里关掉应用内悬浮球：照样不画（页面据此不关栏）', (WidgetTester tester) async {
      await prefs.setFloatingBallInApp(false);
      await pumpHost(tester, home: readerScene(pinned: true));
      await tester.pump();
      expect(ball(), findsNothing);
    });
  });

  test('原生系统球的图标表：每个全局按钮与应用内同一颗，外加打开 / 关闭', () {
    final Map<String, int> icons = floatingBallNativeIcons();
    for (final FloatingBallGlobalAction action
        in FloatingBallGlobalAction.values) {
      expect(
        icons[action.storageValue],
        floatingBallGlobalActionIcon(action).codePoint,
        reason: '${action.storageValue} 在原生球上要画成应用内同一颗图标',
      );
    }
    expect(icons['open_app'], kFloatingBallOpenAppIcon.codePoint);
    expect(icons['close'], kFloatingBallCloseIcon.codePoint);
    expect(floatingBallNativeLabels()['ball'], isNotEmpty);
  });

  test('原生系统球的配色取当前主题三色', () {
    const ColorScheme scheme = ColorScheme.light(
      surface: Color(0xFF101112),
      onSurface: Color(0xFF202122),
      primary: Color(0xFF303132),
    );
    expect(floatingBallNativeColors(scheme), <String, int>{
      'surface': 0xFF101112,
      'onSurface': 0xFF202122,
      'primary': 0xFF303132,
    });
  });

  // 桌面应用外球：平台门走测试缝，任何平台（含 Linux CI）都跑这组。
  group('桌面应用外球', () {
    late List<MethodCall> calls;
    late _RecordingActionTarget target;

    /// 原生侧的桩：记下每次调用；[takeClosed] / [startReply] 给
    /// `takeSystemBallClosedByUser` / `startSystemBall` 一个可控的回话（竞态用例
    /// 靠它把起球闭包卡在对应的 await 上）。
    ///
    /// 可控回话的 Completer 必须在 `tester.runAsync` 里建：fake zone 里建的
    /// Completer 完成时把回调排进 fake zone 的微任务队列，要等 runAsync 结束后
    /// 的下一次 pump 才冲刷——闭包在观察窗内根本醒不过来，断言就成了空壳。
    void mockNative(
      WidgetTester tester, {
      Future<bool> Function()? takeClosed,
      Future<bool> Function()? startReply,
      bool started = true,
    }) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        FloatingBallChannel.channel,
        (MethodCall call) async {
          calls.add(call);
          return switch (call.method) {
            'startSystemBall' =>
              startReply == null ? started : await startReply(),
            'takeSystemBallClosedByUser' =>
              takeClosed == null ? false : await takeClosed(),
            _ => null,
          };
        },
      );
    }

    setUp(() {
      calls = <MethodCall>[];
      debugLatestSystemBallSync = null;
      target = _RecordingActionTarget();
      debugDesktopSystemBallPlatformOverride = true;
      desktopSystemBallActionTarget = target;
    });

    tearDown(() {
      debugDesktopSystemBallPlatformOverride = null;
      desktopSystemBallActionTarget = const DesktopSystemBallActionTarget();
      FloatingBallChannel.debugResetHandler();
    });

    List<MethodCall> starts() => <MethodCall>[
      for (final MethodCall c in calls)
        if (c.method == 'startSystemBall') c,
    ];

    List<String> startedActions(MethodCall start) => <String>[
      for (final Object? a
          in (start.arguments as Map<Object?, Object?>)['actions']!
              as List<Object?>)
        a! as String,
    ];

    /// 在真实异步里等 [done] 成立（起球要画图标 PNG、读球面资源，只在真实
    /// zone 里走得完）。
    Future<void> waitFor(bool Function() done) async {
      for (int i = 0; i < 100 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    /// 原生报一条消息给 Dart（点了按钮 / 吸附了位置）。
    Future<void> fromNative(
      WidgetTester tester,
      String method,
      Map<String, Object?> args,
    ) async {
      final ByteData message = const StandardMethodCodec().encodeMethodCall(
        MethodCall(method, args),
      );
      await tester.runAsync(() async {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          FloatingBallChannel.channel.name,
          message,
          (_) {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
    }

    testWidgets('打开开关即起原生球，带已着色图标 PNG、球面与存盘位置；吸附后落库', (
      WidgetTester tester,
    ) async {
      mockNative(tester);
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          FloatingBallChannel.channel,
          null,
        ),
      );
      await prefs.setFloatingBallSystemPosition('left', 0.4);
      await pumpHost(tester);
      await tester.runAsync(() async {
        await prefs.setFloatingBallSystem(true);
        await waitFor(() => starts().isNotEmpty);
      });
      await tester.pump();
      final MethodCall start = starts().last;
      final Map<Object?, Object?> args =
          start.arguments as Map<Object?, Object?>;
      // 桌面应用外球的按钮：查词 / 应用外查词（查选区）/ 剪贴板 / 截屏识字。
      expect(startedActions(start), <String>[
        'lookup',
        'popup_lookup',
        'clipboard',
        'screen_ocr',
      ]);
      final Map<Object?, Object?> images =
          args['iconImages']! as Map<Object?, Object?>;
      expect(
        images.keys.toSet(),
        containsAll(<String>['lookup', 'clipboard', 'open_app', 'close']),
      );
      expect((args['ballImage']! as Uint8List).length, greaterThan(100));
      expect(args['dock'], 'left');
      expect(args['fraction'], 0.4);
      expect(
        (args['colors']! as Map<Object?, Object?>).keys,
        contains('primary'),
      );

      // 原生报吸附后的位置：Dart 落库。
      await fromNative(tester, 'systemBallPositionChanged', <String, Object?>{
        'dock': 'right',
        'fraction': 0.8,
      });
      expect(prefs.floatingBallSystemDock, 'right');
      expect(prefs.floatingBallSystemVerticalFraction, 0.8);

      // 关掉开关：停原生球。
      await tester.runAsync(() => prefs.setFloatingBallSystem(false));
      await tester.pump();
      expect(calls.last.method, 'stopSystemBall');
    });

    testWidgets('查词模块关着：应用外球不下发「查词」「应用外查词」「截屏识字」，模块打开后重新同步补上', (
      WidgetTester tester,
    ) async {
      mockNative(tester);
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          FloatingBallChannel.channel,
          null,
        ),
      );
      await prefs.setModuleEnabled(ModuleId.lookup, false);
      await pumpHost(tester);
      await tester.runAsync(() async {
        await prefs.setFloatingBallSystem(true);
        await waitFor(() => starts().isNotEmpty);
      });
      await tester.pump();
      expect(startedActions(starts().last), <String>['clipboard']);

      await tester.runAsync(() async {
        await prefs.setModuleEnabled(ModuleId.lookup, true);
        await waitFor(() => starts().length >= 2);
      });
      await tester.pump();
      expect(startedActions(starts().last), <String>[
        'lookup',
        'popup_lookup',
        'clipboard',
        'screen_ocr',
      ]);
    });

    bool tookClosedFlag() =>
        calls.any((MethodCall c) => c.method == 'takeSystemBallClosedByUser');

    testWidgets('起球途中关掉开关：发 stop，醒来的起球闭包不再把球拉起来', (WidgetTester tester) async {
      late Completer<bool> take;
      mockNative(tester, takeClosed: () => take.future);
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          FloatingBallChannel.channel,
          null,
        ),
      );
      await pumpHost(tester);
      await tester.runAsync(() async {
        take = Completer<bool>();
        await prefs.setFloatingBallSystem(true);
        final Future<void> sync = debugLatestSystemBallSync!;
        await waitFor(tookClosedFlag);
        // 起球闭包卡在第一个 await 上时，用户关了开关。
        await prefs.setFloatingBallSystem(false);
        take.complete(false);
        // 闭包醒来会画图标、读球面（桌面分支），再走到 start 前的门：等它真的
        // 跑完再断言。
        await sync;
      });
      await tester.pump();
      expect(
        calls.map((MethodCall c) => c.method),
        contains('stopSystemBall'),
        reason: '签名还没落时关开关也要停',
      );
      expect(starts(), isEmpty, reason: '过期的起球闭包不得再调 start');
    });

    testWidgets('start 回话前关掉开关：过期代不记签名，再打开同样配置照常起球', (
      WidgetTester tester,
    ) async {
      late Completer<bool> firstStart;
      mockNative(
        tester,
        startReply: () =>
            starts().length == 1 ? firstStart.future : Future<bool>.value(true),
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          FloatingBallChannel.channel,
          null,
        ),
      );
      await pumpHost(tester);
      await tester.runAsync(() async {
        firstStart = Completer<bool>();
        await prefs.setFloatingBallSystem(true);
        final Future<void> first = debugLatestSystemBallSync!;
        await waitFor(() => starts().isNotEmpty);
        // 原生还在建窗，用户关了开关；随后原生回报「起来了」。
        await prefs.setFloatingBallSystem(false);
        firstStart.complete(true);
        await first;
        // 再打开：配置与上一代一模一样。
        await prefs.setFloatingBallSystem(true);
        await debugLatestSystemBallSync;
      });
      await tester.pump();
      expect(
        starts(),
        hasLength(2),
        reason: '过期代若记下签名，这次同样配置的起球会被当成已下发跳过——开关开着却没有球',
      );
    });

    testWidgets('一次性「用户关过系统球」标记落在已过期的那一代：照样关掉开关，不再起球', (
      WidgetTester tester,
    ) async {
      final List<Completer<bool>> takes = <Completer<bool>>[];
      mockNative(
        tester,
        takeClosed: () {
          final Completer<bool> c = Completer<bool>();
          takes.add(c);
          return c.future;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          FloatingBallChannel.channel,
          null,
        ),
      );
      await pumpHost(tester);
      await tester.runAsync(() async {
        await prefs.setFloatingBallSystem(true);
        final Future<void> gen1 = debugLatestSystemBallSync!;
        await waitFor(() => takes.isNotEmpty);
        // 第一代还在等标记的回话，配置变了：第二代起球，也去取标记。
        await prefs.setFloatingBallButtons(FloatingBallScope.system, <String>[
          'clipboard',
        ]);
        final Future<void> gen2 = debugLatestSystemBallSync!;
        await waitFor(() => takes.length >= 2);
        // Android 读即清：原生先回第一代 true（标记已清），第二代只剩 false。
        takes[0].complete(true);
        await gen1;
        takes[1].complete(false);
        await gen2;
      });
      await tester.pump();
      expect(prefs.floatingBallSystem, isFalse, reason: '用户在系统球上点过关闭');
      expect(starts(), isEmpty, reason: '不得违背用户刚做的「关闭」把球拉起来');
    });

    /// 开着应用外球、等第一次起球落地。
    Future<void> startSystemBall(WidgetTester tester) async {
      await pumpHost(tester);
      await tester.runAsync(() async {
        await prefs.setFloatingBallSystem(true);
        await debugLatestSystemBallSync;
      });
      await tester.pump();
      expect(starts(), hasLength(1));
    }

    testWidgets('出厂「仅应用内」：用户在应用外球上点关闭 → 关掉「应用外显示」', (
      WidgetTester tester,
    ) async {
      mockNative(tester);
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          FloatingBallChannel.channel,
          null,
        ),
      );
      await startSystemBall(tester);
      await fromNative(tester, 'systemBallClosedByUser', <String, Object?>{});
      expect(prefs.floatingBallSystem, isFalse);
    });

    testWidgets('自动恢复「应用内外」：关闭不动开关，回到 Fushi 时重新起球', (
      WidgetTester tester,
    ) async {
      mockNative(tester);
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          FloatingBallChannel.channel,
          null,
        ),
      );
      await prefs.setFloatingBallAutoRestore(FloatingBallAutoRestore.both);
      await startSystemBall(tester);
      await fromNative(tester, 'systemBallClosedByUser', <String, Object?>{});
      expect(prefs.floatingBallSystem, isTrue, reason: '只关这一次，不动设置');

      // 关着期间配置变化（换主题 / 改按钮）不能把球拉起来。
      await tester.runAsync(() async {
        await prefs.setFloatingBallButtons(FloatingBallScope.system, <String>[
          'clipboard',
        ]);
        await debugLatestSystemBallSync;
      });
      await tester.pump();
      expect(starts(), hasLength(1));

      // 主窗失焦再拿回焦点（桌面只到 inactive）：算回到 Fushi。
      // 起球闭包要在真实 zone 里跑完（见 mockNative 的说明）。
      await tester.runAsync(() async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await debugLatestSystemBallSync;
      });
      await tester.pump();
      expect(starts(), hasLength(2));
      expect(startedActions(starts().last), <String>['clipboard']);
    });

    testWidgets('关掉应用外球后把自动恢复改成不含应用外：关闭落定为关掉「应用外显示」，回到 Fushi 不再起球', (
      WidgetTester tester,
    ) async {
      mockNative(tester);
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          FloatingBallChannel.channel,
          null,
        ),
      );
      await prefs.setFloatingBallAutoRestore(FloatingBallAutoRestore.both);
      await startSystemBall(tester);
      await fromNative(tester, 'systemBallClosedByUser', <String, Object?>{});
      expect(prefs.floatingBallSystem, isTrue);

      debugLatestClosedBallSettle = null;
      await tester.runAsync(() async {
        await prefs.setFloatingBallAutoRestore(FloatingBallAutoRestore.off);
        expect(debugLatestClosedBallSettle, isNotNull, reason: '应当落定这次关闭');
        await debugLatestClosedBallSettle;
        await debugLatestSystemBallSync;
      });
      await tester.pump();
      expect(prefs.floatingBallSystem, isFalse, reason: '按新选项落定这次关闭');

      await tester.runAsync(() async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await debugLatestSystemBallSync;
      });
      await tester.pump();
      expect(starts(), hasLength(1), reason: '不得按旧选项把关掉的球拉起来');
      expect(prefs.floatingBallSystem, isFalse);
    });

    testWidgets('自动恢复「应用内外」：启动时读到「用户关过」标记 → 照常起球、不关开关', (
      WidgetTester tester,
    ) async {
      mockNative(tester, takeClosed: () async => true);
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          FloatingBallChannel.channel,
          null,
        ),
      );
      await prefs.setFloatingBallAutoRestore(FloatingBallAutoRestore.both);
      await pumpHost(tester);
      // 起球闭包要在真实 zone 里跑完（见 mockNative 的说明），所以在这里开开关
      // 触发首次起球；它读到的仍是「主引擎不在时用户关过」的一次性标记。
      await tester.runAsync(() async {
        await prefs.setFloatingBallSystem(true);
        await debugLatestSystemBallSync;
      });
      await tester.pump();
      expect(prefs.floatingBallSystem, isTrue);
      expect(starts(), hasLength(1), reason: '打开 Fushi 即自动恢复');
    });

    testWidgets('连续两次同步、先发的闭包后醒：以最新配置为准，旧闭包作废', (WidgetTester tester) async {
      final List<Completer<bool>> takes = <Completer<bool>>[];
      mockNative(
        tester,
        takeClosed: () {
          final Completer<bool> c = Completer<bool>();
          takes.add(c);
          return c.future;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          FloatingBallChannel.channel,
          null,
        ),
      );
      await pumpHost(tester);
      await tester.runAsync(() async {
        await prefs.setFloatingBallSystem(true);
        final Future<void> gen1 = debugLatestSystemBallSync!;
        await waitFor(() => takes.isNotEmpty);
        // 第一代还卡着，用户改了按钮：第二代起球。
        await prefs.setFloatingBallButtons(FloatingBallScope.system, <String>[
          'clipboard',
        ]);
        final Future<void> gen2 = debugLatestSystemBallSync!;
        await waitFor(() => takes.length >= 2);
        // 第二代先醒、先起完；第一代后醒。
        takes[1].complete(false);
        await gen2;
        takes[0].complete(false);
        await gen1;
      });
      await tester.pump();
      expect(starts(), hasLength(1), reason: '旧代不得再起一次盖掉新配置');
      expect(startedActions(starts().single), <String>['clipboard']);
    });

    testWidgets('原生回报起不来：不记签名，同样的配置下次同步会再试', (WidgetTester tester) async {
      mockNative(tester, started: false);
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          FloatingBallChannel.channel,
          null,
        ),
      );
      await pumpHost(tester);
      await tester.runAsync(() async {
        await prefs.setFloatingBallSystem(true);
        await waitFor(() => starts().isNotEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        // 与球无关的偏好变化触发一次同步：配置没变，但上次没起来，得再试。
        await prefs.setFloatingBallInApp(false);
        await waitFor(() => starts().length >= 2);
      });
      await tester.pump();
      expect(starts(), hasLength(2));
    });

    group('动作分发', () {
      setUp(() {
        target.overlayAvailable = true;
      });

      Future<void> tapAction(
        WidgetTester tester,
        String id, {
        List<double> anchor = const <double>[1800, 900, 1896, 996],
      }) => fromNative(tester, 'systemBallAction', <String, Object?>{
        'id': id,
        'anchor': anchor,
      });

      void mockClipboard(WidgetTester tester, String text) {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (MethodCall call) async => call.method == 'Clipboard.getData'
              ? <String, Object?>{'text': text}
              : null,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
      }

      testWidgets('查词：唤起主窗并请求打开查词页、聚焦搜索框', (WidgetTester tester) async {
        await pumpHost(tester);
        final int before = appModel.homeDictionaryTabRequest.value.seq;
        await tapAction(tester, 'lookup');
        expect(target.log, <String>['front']);
        expect(appModel.homeDictionaryTabRequest.value.seq, before + 1);
        expect(appModel.homeDictionaryTabRequest.value.focusSearch, isTrue);
      });

      testWidgets('应用外查词：查前台程序的选区，不唤起主窗', (WidgetTester tester) async {
        await pumpHost(tester);
        await tapAction(tester, 'popup_lookup');
        expect(target.log, <String>['selection']);
      });

      testWidgets('剪贴板：锚点按物理像素交给覆盖窗（不当逻辑像素再乘 DPR）', (
        WidgetTester tester,
      ) async {
        mockClipboard(tester, ' 猫 ');
        await pumpHost(tester);
        await tapAction(tester, 'clipboard');
        expect(target.log, <String>['lookupText']);
        final _LookupTextCall call = target.lookups.single;
        expect(call.text, '猫');
        expect(call.anchorScreenRect, isNull, reason: '逻辑像素通道不得带锚点');
        expect(
          call.physicalPlacement?.anchorScreenRect,
          const Rect.fromLTRB(1800, 900, 1896, 996),
        );
      });

      testWidgets('剪贴板：覆盖窗不可用时退回主窗查词弹窗', (WidgetTester tester) async {
        target.overlayAvailable = false;
        mockClipboard(tester, '犬');
        await pumpHost(tester);
        await tapAction(tester, 'clipboard');
        expect(target.log, <String>['front']);
        expect(FloatingLyricLookupNotifier.instance.consume()?.text, '犬');
      });

      testWidgets('立即同步：唤起主窗再走手动同步入口（结果提示在主窗里）', (WidgetTester tester) async {
        syncInProgress.value = true;
        addTearDown(() => syncInProgress.value = false);
        await pumpHost(tester);
        await tapAction(tester, 'sync');
        expect(target.log, <String>['front']);
        expect(find.text(t.sync_now_busy), findsOneWidget);
      });

      testWidgets('Android 系统球推来的 openSync：就绪后走手动同步入口', (
        WidgetTester tester,
      ) async {
        syncInProgress.value = true;
        addTearDown(() => syncInProgress.value = false);
        await pumpHost(tester);
        await fromNative(tester, 'openSync', const <String, Object?>{});
        await tester.pump();
        expect(pendingSync.value, isFalse);
        expect(find.text(t.sync_now_busy), findsOneWidget);
      });

      group('截屏识字', () {
        /// 横排一行「吾輩は猫」：截图像素 (100,200)–(500,250)，每字 100 宽。
        const SystemOcrTextLine line = SystemOcrTextLine(
          text: '吾輩は猫',
          rect: Rect.fromLTRB(100, 200, 500, 250),
          isVertical: false,
        );
        final Uint8List png = Uint8List.fromList(<int>[1, 2, 3]);

        /// 原生桩：`startScreenOcrCapture` 回 [capture]，其余只记录。
        void mockCapture(WidgetTester tester, Map<String, Object?> capture) {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            FloatingBallChannel.channel,
            (MethodCall call) async {
              calls.add(call);
              return switch (call.method) {
                'startScreenOcrCapture' => capture,
                'startSystemBall' => true,
                'takeSystemBallClosedByUser' => false,
                _ => null,
              };
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(FloatingBallChannel.channel, null),
          );
        }

        MethodCall lastCall(String method) =>
            calls.lastWhere((MethodCall c) => c.method == method);

        bool called(String method) =>
            calls.any((MethodCall c) => c.method == method);

        Map<Object?, Object?> argsOf(String method) =>
            lastCall(method).arguments as Map<Object?, Object?>;

        Future<void> startOcr(WidgetTester tester) async {
          mockCapture(tester, <String, Object?>{
            'png': png,
            // 第二块显示器：左上 (1920, 0)。
            'screen': <double>[1920, 0, 3840, 1080],
          });
          target.onRecognize = (Uint8List bytes) async {
            expect(bytes, png);
            return const SystemOcrPageResult(
              lines: <SystemOcrTextLine>[line],
              imageWidth: 1920,
              imageHeight: 1080,
            );
          };
          await pumpHost(tester);
          await tapAction(tester, 'screen_ocr');
        }

        testWidgets('先收起查词卡再截屏（带球锚点），识别后把行框交给冻结层', (WidgetTester tester) async {
          await startOcr(tester);
          expect(target.log, <String>['dismiss', 'recognize']);
          final Map<Object?, Object?> start = argsOf('startScreenOcrCapture');
          expect(start['anchor'], <double>[1800, 900, 1896, 996]);
          expect(
            (start['labels']! as Map<Object?, Object?>).keys,
            containsAll(<String>['recognizing', 'hint', 'close']),
          );
          expect(
            (start['colors']! as Map<Object?, Object?>).keys,
            contains('primary'),
          );
          final Map<Object?, Object?> update = argsOf('updateScreenOcrOverlay');
          expect(update['lines'], <List<double>>[
            <double>[100, 200, 500, 250],
          ]);
          expect(update['message'], isNull);
        });

        testWidgets('点在字上：查从这个字起的后缀、整行作句子，卡锚在该字的屏幕物理像素框', (
          WidgetTester tester,
        ) async {
          await startOcr(tester);
          // 第三个字「は」：x 300..400。
          await fromNative(tester, 'screenOcrTap', <String, Object?>{
            'x': 350.0,
            'y': 220.0,
          });
          final _LookupTextCall call = target.lookups.single;
          expect(call.text, 'は猫');
          expect(call.sentence, '吾輩は猫');
          expect(call.anchorScreenRect, isNull, reason: '逻辑像素通道不得带锚点');
          // 截图像素 + 显示器左上 (1920, 0)。
          expect(
            call.physicalPlacement?.anchorScreenRect,
            const Rect.fromLTRB(2220, 200, 2320, 250),
          );
          expect(called('stopScreenOcr'), isFalse, reason: '查词时冻结层留着');
        });

        testWidgets('点在字外：关冻结层并收起查词卡；之后的点击不再查词', (WidgetTester tester) async {
          await startOcr(tester);
          target.log.clear();
          await fromNative(tester, 'screenOcrTap', <String, Object?>{
            'x': 1000.0,
            'y': 900.0,
          });
          expect(called('stopScreenOcr'), isTrue);
          expect(target.log, <String>['dismiss']);
          await fromNative(tester, 'screenOcrTap', <String, Object?>{
            'x': 350.0,
            'y': 220.0,
          });
          expect(target.lookups, isEmpty);
        });

        testWidgets('原生报冻结层被关掉：收起查词卡，不再回 stop', (WidgetTester tester) async {
          await startOcr(tester);
          target.log.clear();
          await fromNative(
            tester,
            'screenOcrDismissed',
            const <String, Object?>{},
          );
          expect(target.log, <String>['dismiss']);
          expect(called('stopScreenOcr'), isFalse);
        });

        testWidgets('没装日语识别器：冻结层提示去装语言，点任意处退出', (WidgetTester tester) async {
          mockCapture(tester, <String, Object?>{
            'png': png,
            'screen': <double>[0, 0, 1920, 1080],
          });
          target.onRecognize = (Uint8List bytes) async =>
              throw const SystemOcrUnavailableException(
                kSystemOcrLanguageUnavailableReason,
              );
          await pumpHost(tester);
          await tapAction(tester, 'screen_ocr');
          final Map<Object?, Object?> update = argsOf('updateScreenOcrOverlay');
          expect(update['message'], t.floating_ball_ocr_language_missing);
          expect(update['lines'], isEmpty);
          await fromNative(tester, 'screenOcrTap', <String, Object?>{
            'x': 10.0,
            'y': 10.0,
          });
          expect(called('stopScreenOcr'), isTrue);
        });

        testWidgets('没识别到字：冻结层上直接说', (WidgetTester tester) async {
          mockCapture(tester, <String, Object?>{
            'png': png,
            'screen': <double>[0, 0, 1920, 1080],
          });
          await pumpHost(tester);
          await tapAction(tester, 'screen_ocr');
          expect(
            argsOf('updateScreenOcrOverlay')['message'],
            t.floating_ball_ocr_empty,
          );
        });

        testWidgets('没有屏幕录制权限：不识别，唤起主窗提示去系统设置授权', (WidgetTester tester) async {
          mockCapture(tester, <String, Object?>{'error': 'permission_denied'});
          await pumpHost(tester);
          await tapAction(tester, 'screen_ocr');
          expect(target.log, <String>['dismiss', 'front']);
          await tester.pump();
          expect(
            find.text(t.floating_ball_ocr_screen_permission),
            findsOneWidget,
          );
          expect(called('updateScreenOcrOverlay'), isFalse);
        });
      });

      testWidgets('打开 Fushi：只唤起主窗', (WidgetTester tester) async {
        await pumpHost(tester);
        final int before = appModel.homeDictionaryTabRequest.value.seq;
        await tapAction(tester, 'open_app');
        expect(target.log, <String>['front']);
        expect(appModel.homeDictionaryTabRequest.value.seq, before);
      });
    });
  });

  // BUG-2911：iOS 横屏左右安全区对称，只避让灵动岛那一侧。平台门走测试缝，
  // 任何平台都跑这组。
  group('BUG-2911 iOS 横屏外壳边', () {
    const Size window = Size(869, 399.7);
    const double inset = 61.6;
    late Object? nativeEdge;
    late int queries;

    setUp(() {
      debugSensorHousingEdgePlatformOverride = true;
      nativeEdge = 'left';
      queries = 0;
    });

    tearDown(() {
      debugSensorHousingEdgePlatformOverride = null;
      FloatingBallChannel.debugResetHandler();
    });

    /// iPhone 17 Pro 横屏实测窗口与安全区；原生查询回 [nativeEdge]。
    Future<void> pumpLandscape(WidgetTester tester, String dock) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = window;
      tester.view.viewPadding = const FakeViewPadding(
        left: inset,
        right: inset,
        bottom: 19.9,
      );
      addTearDown(tester.view.reset);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        FloatingBallChannel.channel,
        (MethodCall call) async {
          if (call.method != 'sensorHousingEdge') return null;
          queries++;
          return nativeEdge;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          FloatingBallChannel.channel,
          null,
        ),
      );
      await prefs.setFloatingBallPosition(dock, 0.5);
      await pumpHost(tester);
      await tester.pumpAndSettle();
    }

    /// 原生在界面方向变化时推来的新外壳边。
    Future<void> pushEdge(WidgetTester tester, String? edge) async {
      final ByteData message = const StandardMethodCodec().encodeMethodCall(
        MethodCall('sensorHousingEdgeChanged', edge),
      );
      await tester.runAsync(() async {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          FloatingBallChannel.channel.name,
          message,
          (_) {},
        );
      });
      await tester.pumpAndSettle();
    }

    Rect ballRect(WidgetTester tester) =>
        tester.getRect(byKey('fushi_reader_floating_ball_icon'));

    testWidgets('外壳在左：右停靠收起球贴屏幕右缘；推来「右」后改为避让右侧', (WidgetTester tester) async {
      await pumpLandscape(tester, 'right');
      expect(queries, 1, reason: '首次取值走查询');
      expect(ballRect(tester).right, greaterThan(window.width));

      // 横屏左 ↔ 右翻转：窗口尺寸与安全区都不变，查询也不再发生（原生若被
      // 重查仍会答旧的 left），只有推送能把球挪出灵动岛底下。
      await pushEdge(tester, 'right');
      expect(queries, 1);
      expect(ballRect(tester).right, lessThan(window.width - inset + 20));
    });

    testWidgets('外壳在左：左停靠球仍避让 inset；推来「右」后左侧贴边', (WidgetTester tester) async {
      await pumpLandscape(tester, 'left');
      expect(ballRect(tester).left, greaterThan(inset - 20));

      await pushEdge(tester, 'right');
      expect(ballRect(tester).left, lessThan(0));

      // 原生说不知道（方向未知）：两侧都避让。
      await pushEdge(tester, null);
      expect(ballRect(tester).left, greaterThan(inset - 20));
    });
  });
}

class _LookupTextCall {
  _LookupTextCall(
    this.text,
    this.anchorScreenRect,
    this.physicalPlacement, {
    this.sentence = '',
  });

  final String text;
  final String sentence;
  final Rect? anchorScreenRect;
  final GlobalLookupPhysicalPlacement? physicalPlacement;
}

/// 记下宿主把每颗按钮分发到了哪条路、带了什么参数。
class _RecordingActionTarget extends DesktopSystemBallActionTarget {
  bool overlayAvailable = true;
  final List<String> log = <String>[];
  final List<_LookupTextCall> lookups = <_LookupTextCall>[];

  @override
  bool get overlayLookupAvailable => overlayAvailable;

  @override
  Future<void> lookupSelection() async => log.add('selection');

  @override
  Future<bool> lookupText(
    String text, {
    String sentence = '',
    Rect? anchorScreenRect,
    GlobalLookupPhysicalPlacement? physicalPlacement,
  }) async {
    log.add('lookupText');
    lookups.add(
      _LookupTextCall(
        text,
        anchorScreenRect,
        physicalPlacement,
        sentence: sentence,
      ),
    );
    return true;
  }

  /// 截屏识字的识别结果（测试按需替换成抛错 / 空结果）。
  Future<SystemOcrPageResult> Function(Uint8List png) onRecognize =
      (Uint8List png) async => const SystemOcrPageResult(
        lines: <SystemOcrTextLine>[],
        imageWidth: 1,
        imageHeight: 1,
      );

  @override
  Future<SystemOcrPageResult> recognize(Uint8List png) async {
    log.add('recognize');
    return onRecognize(png);
  }

  @override
  Future<void> dismissLookup() async => log.add('dismiss');

  @override
  Future<void> bringMainWindowToFront() async => log.add('front');
}
