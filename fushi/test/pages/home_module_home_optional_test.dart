// 首页模块可关 + 手机布局横滑切模块，挂真的 [HomePage] 钉住（反馈 8XMLWV4brz，
// 2026-10-09）。
//
// - 首页关掉：冷启动落到第一个启用的模块，首页 dashboard 根本不建；
// - 首页开着：照旧落在首页（回归基线）；
// - 手机底栏布局：在模块页上横滑切到底栏顺序的相邻模块。
//
// 设 `FUSHI_PREVIEW=1` 时顺带把手机布局的真实像素写成 PNG（输出目录
// `FUSHI_PREVIEW_OUT`，缺省 `../.claude/preview/module_swipe`，不入库）。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/pages/implementations/video_library_shell.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/fushi_icon_fonts.dart';
import '../helpers/test_platform_services.dart';

class _ModulesAppModel extends AppModel {
  _ModulesAppModel(this._dir, {required this.disabled})
    : super(testPlatformServices());

  final Directory _dir;

  /// 用户关掉的模块（「功能模块」用户意愿的唯一读取点只桩这一个方法）。
  final Set<ModuleId> disabled;

  @override
  bool moduleEnabled(ModuleId module) =>
      !disabled.contains(module) && super.moduleEnabled(module);

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

  // 视频库外壳的刮削运行时读界面语言；本宿主不走 initialise()，语言表没装。
  @override
  Locale get appLocale => const Locale('en');

  // 更新检查调度器是 30 分钟的周期定时器；预览模式里真实时间流过让它被拉起，
  // 留到测试结束会撞 `!timersPending`。与本测试主题无关，直接不起。
  @override
  void startUpdateChecks() {}

  @override
  bool get isDatabaseOpen => true;

  @override
  bool get isFirstTimeSetup => false;

  @override
  bool get onboardingCompleted => true;
}

const String _fontFamily = 'PreviewCJK';
const List<String> _fontCandidates = <String>[
  r'C:\Windows\Fonts\NotoSansSC-VF.ttf',
  r'C:\Windows\Fonts\segoeui.ttf',
];

bool get _preview => Platform.environment['FUSHI_PREVIEW'] == '1';

String get _outDir =>
    Platform.environment['FUSHI_PREVIEW_OUT'] ??
    '${Directory.current.path}/../.claude/preview/module_swipe';

final GlobalKey _shotKey = GlobalKey();

Future<_ModulesAppModel> _pumpHome(
  WidgetTester tester, {
  Set<ModuleId> disabled = const <ModuleId>{},
  bool mobile = false,
}) async {
  if (mobile) {
    const double dpr = 2.5;
    tester.view.physicalSize = const Size(400, 860) * dpr;
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
  }
  if (_preview) {
    await tester.runAsync(() async {
      await loadFushiIconFonts();
      for (final String path in _fontCandidates) {
        final File file = File(path);
        if (!file.existsSync()) continue;
        final FontLoader loader = FontLoader(_fontFamily)
          ..addFont(
            Future<ByteData>.value(
              ByteData.sublistView(await file.readAsBytes()),
            ),
          );
        await loader.load();
        break;
      }
    });
  }
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final PreferencesRepository prefsRepo = PreferencesRepository(db);
  await prefsRepo.loadFromDb();
  final Directory tmpDir = Directory.systemTemp.createTempSync(
    'fushi_home_optional_',
  );
  addTearDown(() {
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  final _ModulesAppModel appModel = _ModulesAppModel(tmpDir, disabled: disabled)
    ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tmpDir)
    ..wireDatabaseForTesting(db);

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
        platformServicesProvider.overrideWithValue(testPlatformServices()),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _preview
              ? ThemeData(useMaterial3: true, fontFamily: _fontFamily)
              : null,
          navigatorKey: appModel.navigatorKey,
          // 截图边界包住整个 Navigator：推出来的设置详情页也在框里。
          builder: (BuildContext context, Widget? child) =>
              RepaintBoundary(key: _shotKey, child: child),
          home: const HomePage(),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return appModel;
}

/// 有界推帧（整页 HomePage 有持续动画与周期定时器，pumpAndSettle 等不到静止）。
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(Duration.zero);
  await tester.pump(const Duration(milliseconds: 10));
  // 预览模式多了真实 IO（runAsync 截图）与中文字体，页面的防抖定时器可能还
  // 挂着；推过它们，免得撞 `!timersPending` 不变式。
  if (_preview) await tester.pump(const Duration(seconds: 5));
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_preview) return;
  final RenderRepaintBoundary boundary =
      _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  for (int i = 0; i < 20 && boundary.debugNeedsPaint; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.runAsync(() async {
    final ui.Image image = await boundary.toImage(
      pixelRatio: tester.view.devicePixelRatio,
    );
    final ByteData? bytes = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    image.dispose();
    final File out = File('$_outDir/$name.png');
    out.parent.createSync(recursive: true);
    await out.writeAsBytes(bytes!.buffer.asUint8List());
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LocaleSettings.setLocale(_preview ? AppLocale.zhCn : AppLocale.en);
    UpdateChecker.disableAutoCheckForTesting = true;
    DesktopLookupService.instance.debugReset();
  });

  tearDown(() {
    UpdateChecker.disableAutoCheckForTesting = false;
    DesktopLookupService.instance.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  testWidgets('首页开着：冷启动照旧落在首页 dashboard（回归基线）', (WidgetTester tester) async {
    await _pumpHome(tester, mobile: true);
    await _settle(tester);
    expect(find.byType(HomeDashboardPage), findsOneWidget);
    await _capture(tester, '01_home_on_dashboard');
    await _unmount(tester);
  });

  // 书架页在本测试宿主里起不来（要 initialise() 装好 mediaSources），所以用
  // 「首页 + 书架 + 漫画都关」让第一个启用的模块落在视频上；「首页关 → 第一个
  // 启用的模块」这条规则本身由 home_page_tabs_test 的 homeLandingTab 用例钉住。
  testWidgets('首页关掉：冷启动落到第一个启用的模块，dashboard 不建', (WidgetTester tester) async {
    await _pumpHome(
      tester,
      disabled: const <ModuleId>{ModuleId.home, ModuleId.books, ModuleId.manga},
      mobile: true,
    );
    await _settle(tester);
    expect(
      find.byType(HomeDashboardPage, skipOffstage: false),
      findsNothing,
      reason: '首页模块关了，dashboard 不该挂在树上（连保活的 Offstage 也不该有）',
    );
    expect(find.byType(VideoLibraryShell), findsOneWidget);
    await _capture(tester, '02_home_off_lands_on_first_module');

    // 显式要去首页也被拒绝（隐藏 tab 不可达），不会把用户甩到空白页。
    HomePage.debugSelectTab!(HomeTab.home);
    await _settle(tester);
    expect(find.byType(HomeDashboardPage, skipOffstage: false), findsNothing);
    expect(find.byType(VideoLibraryShell), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('BUG-3256 停在首页时首页被关（非设置页途径）：选中身份与 notifier 跟着落地', (
    WidgetTester tester,
  ) async {
    // 书架 / 漫画在本宿主里起不来（见上），让落地 tab 是视频。
    final Set<ModuleId> disabled = <ModuleId>{ModuleId.books, ModuleId.manga};
    final _ModulesAppModel appModel = await _pumpHome(
      tester,
      disabled: disabled,
      mobile: true,
    );
    await _settle(tester);
    expect(homeShellTabNotifier.value, HomeTab.home);

    // ctl `/api/admin/modules` / 偏好恢复的形态：直接改用户意愿再通知。
    disabled.add(ModuleId.home);
    appModel.notifyListeners();
    await _settle(tester);
    expect(find.byType(VideoLibraryShell), findsOneWidget);
    expect(
      homeShellTabNotifier.value,
      HomeTab.video,
      reason: '桌面标题栏 / macOS 侧栏读的 notifier 不能还停在「首页」',
    );
    await _unmount(tester);
  });

  testWidgets('首页与书架都关：落到下一个启用的模块（漫画）', (WidgetTester tester) async {
    await _pumpHome(
      tester,
      disabled: const <ModuleId>{ModuleId.home, ModuleId.books},
    );
    await _settle(tester);
    expect(find.byType(HomeDashboardPage, skipOffstage: false), findsNothing);
    expect(find.byType(MangaLibraryPage), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('手机底栏布局：首页横滑切模块，库页首分区再往外滑接力回首页', (WidgetTester tester) async {
    await _pumpHome(
      tester,
      disabled: const <ModuleId>{ModuleId.books},
      mobile: true,
    );
    await _settle(tester);
    expect(find.byType(HomeDashboardPage), findsOneWidget);

    // 首页没有分区横滑：从内容区中下部向左甩，直接切到底栏右边的漫画。
    final Size size = tester.view.physicalSize / tester.view.devicePixelRatio;
    await tester.flingFrom(
      Offset(size.width * 0.85, size.height * 0.55),
      Offset(-size.width * 0.6, 0),
      1500,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));
    await _capture(tester, '03_swipe_transition_mid');
    await _settle(tester);
    expect(
      find.byType(MangaLibraryPage),
      findsOneWidget,
      reason: '首页左滑应切到底栏右边的漫画',
    );
    await _capture(tester, '04_swipe_landed_manga');

    // 漫画库停在首分区（书架）：右滑越过首分区，接力切回首页。
    await tester.flingFrom(
      Offset(size.width * 0.15, size.height * 0.55),
      Offset(size.width * 0.6, 0),
      1500,
    );
    await _settle(tester);
    expect(
      find.byType(HomeDashboardPage),
      findsOneWidget,
      reason: '库页首分区再往右滑应接力切到左边的模块',
    );
    await _unmount(tester);
  });

  // 只在 FUSHI_PREVIEW=1 时跑：首页关掉后，设置 › 系统 里出现的「首页入口」分区
  // （视觉证据，不是断言型测试）。外观页在本宿主里起不来（要 themeNotifier）。
  testWidgets('预览：设置里的首页入口', (WidgetTester tester) async {
    await _pumpHome(
      tester,
      disabled: const <ModuleId>{ModuleId.home, ModuleId.books, ModuleId.manga},
      mobile: true,
    );
    await _settle(tester);
    HomePage.debugSelectTab!(HomeTab.settings);
    await _settle(tester);

    Future<void> openDestination(String title) async {
      final Finder entry = find.text(title).first;
      await tester.scrollUntilVisible(
        entry,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(entry);
      await _settle(tester);
    }

    await openDestination(t.settings_destination_system_about);
    expect(find.text(t.settings_section_home_shortcuts), findsWidgets);
    await _capture(tester, '05_settings_system_home_shortcuts');
    await _unmount(tester);
  }, skip: !_preview);
}
