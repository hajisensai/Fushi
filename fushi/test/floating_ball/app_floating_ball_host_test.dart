import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/floating_ball/app_floating_ball_host.dart';
import 'package:fushi/src/floating_ball/floating_ball_config.dart';
import 'package:fushi/src/floating_ball/floating_ball_scene.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_lookup_host.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';
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
    pendingExternalLookup.value = null;
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
}
