import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_dashboard_page.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/home_reader_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/test_platform_services.dart';

/// BUG-4851：切 tab 时，隐藏着的保活页不该跟着重建。
///
/// 群反馈（2026-11-16 录屏）「切 tab 变卡了」。profile 实测：在库页（书架 / 漫画 /
/// 视频 / 音乐 / 游戏 / 浏览）与首页 / 查词 / 复习 / 设置之间切，那一帧 build
/// 30～100 ms，timeline 里能看到与本次切换无关的隐藏书架网格被整份重建；同类
/// 之间切（漫画 ↔ 视频 ↔ 浏览）则是干净的。
///
/// 根因：外壳给内容让出的顶部高度（[FushiFloatingChromeInset]）按**当前可见 tab**
/// 算、挂在全部保活 tab 的共同祖先上——库页是 [kFushiFloatingChromeGap]，其余是
/// 0。跨类一切这个 InheritedWidget 的值就翻一次，所有访问过的隐藏页里读它的
/// 浮动工具区 / 滚动视图 / 网格全部被通知重建 + 重排。
///
/// 本文件挂真的 [HomePage]：访问过的保活页被藏起后，它读到的让位高度必须仍是
/// **它自己**的那份，不随可见 tab 变（值不变 = InheritedWidget 不通知 = 隐藏页
/// 不重建）。
class _HomeShellAppModel extends AppModel {
  _HomeShellAppModel(this._dir) : super(testPlatformServices());

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

  // HomePage.build 的第一道门：库没开就整页 SizedBox.shrink。测试用内存库经
  // wireDatabaseForTesting 注入，不走 initialise()，故直接开门。
  @override
  bool get isDatabaseOpen => true;

  @override
  bool get isFirstTimeSetup => false;

  @override
  bool get onboardingCompleted => true;
}

Future<void> _pumpHome(WidgetTester tester) async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final PreferencesRepository prefsRepo = PreferencesRepository(db);
  await prefsRepo.loadFromDb();
  final Directory tmpDir = Directory.systemTemp.createTempSync(
    'fushi_home_tab_inset_',
  );
  addTearDown(() {
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  final _HomeShellAppModel appModel = _HomeShellAppModel(tmpDir)
    ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tmpDir)
    ..wireDatabaseForTesting(db)
    // 书架页经 `BaseTabPageState.mediaSource` 取阅读器媒体源，三张 late 表得先填。
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
        platformServicesProvider.overrideWithValue(testPlatformServices()),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: appModel.navigatorKey,
          home: const HomePage(),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(
    HomePage.debugSelectTab,
    isNotNull,
    reason: 'HomePage 必须已挂载并注册 debugSelectTab 生产钩子',
  );
}

/// 有界推帧：整页 HomePage 挂着持续动画与周期定时器，`pumpAndSettle` 等不到静止。
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 断言做完后主动卸载：drift `.watch()` 的 StreamQueryStore 在 ProviderScope
/// dispose 时排一个零时长 Timer，留到测试结束会撞 `!timersPending` 不变式。
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(Duration.zero);
  await tester.pump(const Duration(milliseconds: 10));
}

/// [page] 所在位置读到的、由外壳下发的让位高度（页面自己的浮动工具区在它下面，
/// 这里取到的是外壳那一层）。
double _shellInsetAt(WidgetTester tester, Type page) {
  final Element element = tester.element(
    find.byType(page, skipOffstage: false),
  );
  final FushiFloatingChromeInset? inset = element
      .getInheritedWidgetOfExactType<FushiFloatingChromeInset>();
  expect(inset, isNotNull, reason: '外壳必须给 $page 下发让位高度');
  return inset!.top;
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

  testWidgets('藏起的保活库页读到的外壳让位高度不随可见 tab 变', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.reset);

    await _pumpHome(tester);
    // 书架：保活、内容顶部是叠放的浮动工具栏（宽窗下页面名并进工具栏行，外壳
    // 只留 [kFushiFloatingChromeGap] 的呼吸）。
    HomePage.debugSelectTab!(HomeTab.books);
    await _settle(tester);
    expect(
      _shellInsetAt(tester, HomeReaderPage),
      kFushiFloatingChromeGap,
      reason: '前置：宽窗 MD3 下库页的外壳让位是浮动工具区间距。',
    );

    // 切到首页（外壳标题不叠放，让位 0）：书架被 Offstage 藏起，但它读到的值必须
    // 还是自己的那份。
    HomePage.debugSelectTab!(HomeTab.home);
    await _settle(tester);
    expect(
      find.byType(HomeReaderPage),
      findsNothing,
      reason: '前置：书架此刻是藏起的保活页。',
    );
    expect(
      _shellInsetAt(tester, HomeDashboardPage),
      0,
      reason: '首页的外壳标题不叠放，让位是 0。',
    );
    expect(
      _shellInsetAt(tester, HomeReaderPage),
      kFushiFloatingChromeGap,
      reason:
          '隐藏的保活页必须读到它自己的让位高度：值随可见 tab 翻转会让所有访问过的'
          '隐藏页在切 tab 那一帧重建 + 重排（BUG-4851）。',
    );

    // 再切回书架：首页成了藏起的那一页，读到的仍是它自己的 0。
    HomePage.debugSelectTab!(HomeTab.books);
    await _settle(tester);
    expect(_shellInsetAt(tester, HomeReaderPage), kFushiFloatingChromeGap);
    expect(_shellInsetAt(tester, HomeDashboardPage), 0);
    await _unmount(tester);
  });
}
