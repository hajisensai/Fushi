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
import 'package:fushi/src/floating_ball/floating_ball_mode.dart';
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
}

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

  Future<void> expand(WidgetTester tester) async {
    await tester.tap(
      find.byKey(const ValueKey<String>('fushi_reader_floating_ball_icon')),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('默认关闭：不画全局球', (WidgetTester tester) async {
    await pumpHost(tester);
    expect(ball(), findsNothing);
  });

  testWidgets('应用内常驻：场景按钮排在全局按钮前面', (WidgetTester tester) async {
    await prefs.setFloatingBallMode(FloatingBallMode.inApp);
    await pumpHost(
      tester,
      home: FloatingBallScene(
        actions: <ReaderHeaderAction>[
          ReaderHeaderAction(
            key: const ValueKey<String>('scene_action'),
            icon: Icons.play_arrow,
            label: 'Play',
            onPressed: () {},
          ),
        ],
      ),
    );
    await tester.pump();
    expect(ball(), findsOneWidget);
    await expand(tester);

    final Finder scene = find.byKey(const ValueKey<String>('scene_action'));
    final Finder lookup = find.byKey(
      const ValueKey<String>('floating_ball_action_lookup'),
    );
    final Finder clipboard = find.byKey(
      const ValueKey<String>('floating_ball_action_clipboard'),
    );
    expect(scene, findsOneWidget);
    expect(lookup, findsOneWidget);
    expect(clipboard, findsOneWidget);
    // 竖排：列表里越靠前越在上面。
    expect(tester.getCenter(scene).dy, lessThan(tester.getCenter(lookup).dy));
    // 截屏识字只有 Android / iOS 有。
    expect(
      find.byKey(const ValueKey<String>('floating_ball_action_screen_ocr')),
      Platform.isAndroid || Platform.isIOS ? findsOneWidget : findsNothing,
    );
  });

  testWidgets('关掉的全局按钮不出现', (WidgetTester tester) async {
    await prefs.setFloatingBallMode(FloatingBallMode.inApp);
    await prefs.setFloatingBallActions(<FloatingBallGlobalAction>[
      FloatingBallGlobalAction.clipboard,
    ]);
    await pumpHost(tester);
    await expand(tester);
    expect(
      find.byKey(const ValueKey<String>('floating_ball_action_lookup')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('floating_ball_action_clipboard')),
      findsOneWidget,
    );
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
    await prefs.setFloatingBallMode(FloatingBallMode.inApp);
    await pumpHost(tester);
    await expand(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('floating_ball_action_clipboard')),
    );
    await tester.pump();
    final FloatingLyricLookupRequest? request = FloatingLyricLookupNotifier
        .instance
        .consume();
    expect(request?.text, '猫');
    expect(request?.index, 0);
  });

  testWidgets('球外的空白处点击照常落到底下页面', (WidgetTester tester) async {
    int taps = 0;
    await prefs.setFloatingBallMode(FloatingBallMode.inApp);
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
    await prefs.setFloatingBallMode(FloatingBallMode.inApp);
    await pumpHost(
      tester,
      home: const FloatingBallScene(
        actions: <ReaderHeaderAction>[],
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
}
