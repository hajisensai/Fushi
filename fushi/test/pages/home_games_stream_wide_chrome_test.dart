import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/game_stream_client_page.dart';
import 'package:fushi/src/pages/implementations/game_stream_library_page.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/home_reader_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/test_platform_services.dart';

class _HomeShellAppModel extends AppModel {
  _HomeShellAppModel(this._dir, PlatformServices services) : super(services);

  final Directory _dir;

  @override
  PackageInfo get packageInfo => PackageInfo(
    appName: 'Fushi',
    packageName: 'app.hibiki.reader',
    version: '1.0.0',
    buildNumber: '1',
  );

  @override
  Directory get appDirectory => _dir;

  @override
  Directory get temporaryDirectory => _dir;

  @override
  Directory get dictionaryResourceDirectory => _dir;

  @override
  bool get isDatabaseOpen => true;

  @override
  bool get isFirstTimeSetup => false;

  @override
  bool get onboardingCompleted => true;
}

final GlobalKey _boundary = GlobalKey();

Future<void> _pumpHome(
  WidgetTester tester, {
  required PlatformServices services,
}) async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final PreferencesRepository prefsRepo = PreferencesRepository(db);
  await prefsRepo.loadFromDb();
  final Directory tmpDir = Directory.systemTemp.createTempSync(
    'fushi_home_games_stream_',
  );
  addTearDown(() {
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  // 首页首帧串行的「选一种库页布局」检查要读 themeNotifier；空快照 = 没有待弹的
  // 布局选择（不在页面上盖弹窗）。
  final ThemeNotifier themeNotifier = ThemeNotifier(db, () => const TextTheme())
    ..loadFromPrefsSnapshot(<String, String>{});
  addTearDown(themeNotifier.dispose);
  final _HomeShellAppModel appModel = _HomeShellAppModel(tmpDir, services)
    ..themeNotifier = themeNotifier
    ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tmpDir)
    ..wireDatabaseForTesting(db)
    ..populateLanguages()
    ..populateMediaTypes()
    ..populateMediaSources();

  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('window_manager'),
    (MethodCall call) {
      if (call.method == 'isFocused') return Future<bool>.value(true);
      return Future<void>.value();
    },
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((ref) => appModel),
        platformServicesProvider.overrideWithValue(services),
      ],
      child: TranslationProvider(
        child: RepaintBoundary(
          key: _boundary,
          child: MaterialApp(
            navigatorKey: appModel.navigatorKey,
            home: const HomePage(),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(HomePage.debugSelectTab, isNotNull);
}

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(Duration.zero);
  await tester.pump(const Duration(milliseconds: 10));
}

/// 预览图输出目录（`--dart-define=GSSW_SHOT_DIR=...`）；不给就不出图。
const String _shotDir = String.fromEnvironment('GSSW_SHOT_DIR');

Future<void> _shot(WidgetTester tester, String name) async {
  if (_shotDir.isEmpty) return;
  await tester.runAsync(() async {
    final RenderRepaintBoundary boundary =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final ui.Image image = await boundary.toImage();
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    File('$_shotDir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

Future<void> _loadFont(WidgetTester tester) async {
  if (_shotDir.isEmpty) return;
  await tester.runAsync(() async {
    final Uint8List bytes = await File(
      'C:/Windows/Fonts/Deng.ttf',
    ).readAsBytes();
    final FontLoader loader = FontLoader('Roboto')
      ..addFont(Future<ByteData>.value(ByteData.view(bytes.buffer)));
    await loader.load();
  });
}

/// [page] 子树里有没有挂库页统一的浮动工具栏（重设计外壳下画成页头大字）。
bool _hostsFloatingChromeBar(Type page) => find
    .descendant(
      of: find.byType(page),
      matching: find.byType(FushiFloatingChromeBar),
    )
    .evaluate()
    .isNotEmpty;

/// 外壳大标题条此刻画的页面名（null = 行高 0，不画）。
String? _shellBarTitle(WidgetTester tester) {
  for (final FushiShellLargeTitleBar bar
      in tester.widgetList<FushiShellLargeTitleBar>(
        find.byType(FushiShellLargeTitleBar),
      )) {
    final String? title = bar.title;
    if (title != null && title.isNotEmpty) return title;
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    UpdateChecker.disableAutoCheckForTesting = true;
    DesktopLookupService.instance.debugReset();
  });

  tearDown(() {
    UpdateChecker.disableAutoCheckForTesting = false;
    DesktopLookupService.instance.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  // 非 Windows 宽屏：macOS / Linux 桌面（串流 + 台词两个视图）与 Android 平板 /
  // iPad（只有串流库）。两种都必须与书架同一套顶栏，不能再是外壳叠的标题胶囊。
  for (final bool desktop in <bool>[true, false]) {
    final String form = desktop ? 'desktop' : 'tablet';
    testWidgets('$form 宽屏：游戏（串流接收端）与书架同一套页头大字顶栏', (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.reset);
      await _loadFont(tester);

      await _pumpHome(
        tester,
        services: testPlatformServices(isWindows: false, isDesktop: desktop),
      );

      HomePage.debugSelectTab!(HomeTab.books);
      await _settle(tester);
      expect(
        _hostsFloatingChromeBar(HomeReaderPage),
        isTrue,
        reason: '前置：书架是库页统一浮动工具栏。',
      );
      final String? booksShellBar = _shellBarTitle(tester);
      await _shot(tester, '${form}_books');

      HomePage.debugSelectTab!(HomeTab.games);
      await _settle(tester);
      await _shot(tester, '${form}_games');
      const Type gamesPage = GameStreamClientPage;
      expect(find.byType(gamesPage), findsOneWidget);
      expect(find.byType(GameStreamLibraryPage), findsOneWidget);
      // 台词视图只在桌面挂：平板的一级页签位是页面名，不是「串流 / 台词」切换。
      expect(
        find.descendant(
          of: find.byKey(GameStreamClientPage.sectionTabsKey),
          matching: find.text(t.texthooker),
        ),
        desktop ? findsOneWidget : findsNothing,
      );

      expect(
        _hostsFloatingChromeBar(gamesPage),
        isTrue,
        reason: '游戏页必须挂库页统一的浮动工具栏（页头大字），与书架同构。',
      );
      expect(
        _shellBarTitle(tester),
        booksShellBar,
        reason: '外壳大标题条在游戏页的形态必须与书架一致：不能再叠一枚「Games」标题胶囊。',
      );
      await _unmount(tester);
    });
  }
}
