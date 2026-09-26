import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_dictionary_page.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/components/nav_rail_brand_button.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/test_platform_services.dart';

/// BUG-2719：首页 tab 正文跨布局断点保持 State。
///
/// 用户报告：关掉视频后视频库总是回到第一个「首页」分区，而不是刚才所在的分区。
/// 根因：[HomePage] 的 [LayoutBuilder] 按宽度在底栏布局（<600）与侧栏布局（≥600）
/// 之间二选一，两者把 tab 正文挂在不同的父链下；手机竖屏点开视频 → 播放页转横屏，
/// 被盖住的首页随之变宽换布局，整棵正文被卸载重建，`VideoLibraryShell` 的分区选择
/// 随 State 一起丢失（退出视频转回竖屏再丢一次）。
///
/// 本文件挂真的 [HomePage]，只改窗口宽度跨过断点，断言 tab 页面是**同一个** State
/// （不是被重建出的新 State）。查词 tab 在这套桩里最轻，且它是「非保活」tab——
/// 连它都不重建，保活 tab（视频 / 书架 / 游戏）更不会。

class _HomeShellAppModel extends AppModel {
  _HomeShellAppModel(this._dir, {required this.dictionariesEnabled})
    : super(testPlatformServices());

  final Directory _dir;
  final bool dictionariesEnabled;
  final List<String> searchedTerms = <String>[];

  // 「功能模块」用户意愿的唯一读取点（[AppModel.moduleVisibility] 经 `prefOf`
  // 调它合成可见集合），故只桩这一个方法即可决定查词 tab 的显隐；其余模块仍走
  // 真实偏好，平台判据仍由 [ModuleId.availableOn] 判。
  @override
  bool moduleEnabled(ModuleId module) => module == ModuleId.lookup
      ? dictionariesEnabled
      : super.moduleEnabled(module);

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

  // HomePage.build 的第一道门：库没开就整页 SizedBox.shrink，什么 tab 都不渲染。
  // 测试用内存库经 wireDatabaseForTesting 注入，不走 initialise()，故直接开门。
  @override
  bool get isDatabaseOpen => true;

  // 跳过新手引导整条路由（不属于本测试主题）。
  @override
  bool get isFirstTimeSetup => false;

  @override
  bool get onboardingCompleted => true;

  // ── 查词页需要的最小桩（与 home_dictionary_pending_on_mount_test 同构）──

  @override
  List<DictionarySearchResult> get dictionaryHistory =>
      <DictionarySearchResult>[];

  @override
  List<Dictionary> get dictionaries => <Dictionary>[
    Dictionary(name: 'Test', formatKey: 'test', order: 0),
  ];

  @override
  int get maximumTerms => 10;

  @override
  void addToSearchHistory({
    required String historyKey,
    required String searchTerm,
  }) {}

  @override
  void addToDictionaryHistory({required DictionarySearchResult result}) {}

  @override
  Future<DictionarySearchResult> searchDictionary({
    required String searchTerm,
    required bool searchWithWildcards,
    int? overrideMaximumTerms,
    bool useCache = true,
    bool allowRemoteLookup = true,
  }) async {
    searchedTerms.add(searchTerm);
    return DictionarySearchResult(searchTerm: searchTerm);
  }
}

Future<_HomeShellAppModel> _pumpHome(
  WidgetTester tester, {
  required bool dictionariesEnabled,
}) async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final PreferencesRepository prefsRepo = PreferencesRepository(db);
  await prefsRepo.loadFromDb();
  final Directory tmpDir = Directory.systemTemp.createTempSync(
    'fushi_home_hidden_tab_',
  );
  addTearDown(() {
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  final _HomeShellAppModel appModel =
      _HomeShellAppModel(tmpDir, dictionariesEnabled: dictionariesEnabled)
        ..wireLocalAudioForTesting(
          prefsRepo: prefsRepo,
          databaseDirectory: tmpDir,
        )
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
  return appModel;
}

/// 有界推帧。整页 HomePage 挂着同步横幅/仪表盘的持续动画与 1 分钟周期定时器，
/// `pumpAndSettle` 永远等不到静止（实测挂满 10 分钟），只能按固定帧数推进。
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

  testWidgets('窄屏 ↔ 宽屏换布局（如看视频转横屏再转回）不重建 tab 页面 State', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 900);
    addTearDown(tester.view.reset);

    await _pumpHome(tester, dictionariesEnabled: true);
    HomePage.debugSelectTab!(HomeTab.dictionaries);
    await _settle(tester);

    expect(
      find.byType(NavRailBrandButton),
      findsNothing,
      reason: '前置：400 宽是底栏布局。',
    );
    final State<StatefulWidget> before = tester.state(
      find.byType(HomeDictionaryPage),
    );

    // 播放页转横屏：被盖住的首页变宽，跨过 600 断点换成侧栏布局。
    tester.view.physicalSize = const Size(900, 400);
    await _settle(tester);
    expect(
      find.byType(NavRailBrandButton),
      findsOneWidget,
      reason: '前置：900 宽必须真的换成了侧栏布局，否则本测试什么也没测。',
    );
    expect(
      identical(tester.state(find.byType(HomeDictionaryPage)), before),
      isTrue,
      reason: '换布局必须把正文整棵挪到新父节点下，而不是卸载重建。',
    );

    // 退出视频转回竖屏：再换回底栏布局，仍是同一个 State、仍停在原 tab。
    tester.view.physicalSize = const Size(400, 900);
    await _settle(tester);
    expect(find.byType(NavRailBrandButton), findsNothing);
    expect(
      identical(tester.state(find.byType(HomeDictionaryPage)), before),
      isTrue,
    );
    await _unmount(tester);
  });
}
