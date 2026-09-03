import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_dictionary_page.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/test_platform_services.dart';

/// PR #997 给「下载」「查词」加模块开关后，`_HomePageState._selectTab` 新增
/// `if (!_activeTabs().contains(tab)) return;`。这是本次改动**唯一有行为风险**的
/// 一行：所有指向被隐藏 tab 的入口都会因此静默失效。
///
/// 本文件挂真的 [HomePage]，用生产钩子 [HomePage.debugSelectTab] 与真实的
/// [AppModel.requestHomeDictionaryTab]（桌面悬浮字幕点词 / 剪贴板 mainTab 分区走的
/// 就是它）钉住隐藏 tab 的行为：
/// - 隐藏 tab 时 `_selectTab` 确实拒绝切换（不把 `_currentTab` 弄脏）；
/// - 但**查词请求绝不因此丢失**：tab 隐藏时改推独立路由承载同一个
///   [HomeDictionaryPage]，pending 照常被消费。这正是「按热键 → 窗口弹到前台 →
///   什么也不显示、pendingText 永远挂着」那条坏路径的判据。
/// - 重复请求不叠第二个查词页（mainTab 分区若有两个消费者就会双消费）。
class _HomeShellAppModel extends AppModel {
  _HomeShellAppModel(this._dir, {required this.dictionariesEnabled})
      : super(testPlatformServices());

  final Directory _dir;
  final bool dictionariesEnabled;
  final List<String> searchedTerms = <String>[];

  @override
  bool get moduleDictionariesEnabled => dictionariesEnabled;

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
  final Directory tmpDir =
      Directory.systemTemp.createTempSync('fushi_home_hidden_tab_');
  addTearDown(() {
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  final _HomeShellAppModel appModel = _HomeShellAppModel(
    tmpDir,
    dictionariesEnabled: dictionariesEnabled,
  )
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
          navigatorKey: appModel.navigatorKey,
          home: const HomePage(),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(HomePage.debugSelectTab, isNotNull,
      reason: 'HomePage 必须已挂载并注册 debugSelectTab 生产钩子');
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

  testWidgets('查词模块开着：请求打开查词落在 tab 上（不推路由），pending 被消费',
      (WidgetTester tester) async {
    final _HomeShellAppModel appModel =
        await _pumpHome(tester, dictionariesEnabled: true);

    DesktopLookupService.instance.triggerLookup(' tabword ');
    appModel.requestHomeDictionaryTab();
    await _settle(tester);

    expect(find.byType(HomeDictionaryPage), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('home-dictionary-route-back')),
      findsNothing,
      reason: 'tab 承载不产生路由栈，不该画返回箭头。',
    );
    expect(appModel.searchedTerms, <String>['tabword']);
    expect(DesktopLookupService.instance.pendingText, isNull);
    await _unmount(tester);
  });

  testWidgets('查词模块关掉：tab 确实隐藏，但请求改推独立路由，pending 仍被消费',
      (WidgetTester tester) async {
    final _HomeShellAppModel appModel =
        await _pumpHome(tester, dictionariesEnabled: false);

    // 前置：查词 tab 真的不在可见列表里，_selectTab 会拒绝切换。
    expect(
      homeActiveTabs(videoEnabled: true, dictionariesEnabled: false),
      isNot(contains(HomeTab.dictionaries)),
    );
    HomePage.debugSelectTab!(HomeTab.dictionaries);
    await tester.pump();
    expect(
      find.byType(HomeDictionaryPage),
      findsNothing,
      reason: '_selectTab 对隐藏 tab 是 no-op —— 这正是本 PR 新引入的坏状态成因。',
    );

    // 真实入口：悬浮字幕点词先排 pending，再请求打开查词。
    DesktopLookupService.instance.triggerLookup(' hiddenword ');
    appModel.requestHomeDictionaryTab();
    await _settle(tester);

    expect(
      find.byType(HomeDictionaryPage),
      findsOneWidget,
      reason: '「功能模块」隐藏的是导航项，不是查词能力：tab 不在时必须推独立路由承载。',
    );
    expect(
      find.byKey(const ValueKey<String>('home-dictionary-route-back')),
      findsOneWidget,
      reason: '推成路由必须给得出返回路径。',
    );
    expect(
      appModel.searchedTerms,
      <String>['hiddenword'],
      reason: '否则用户按热键只会看到窗口弹到前台却什么都不显示。',
    );
    expect(
      DesktopLookupService.instance.pendingText,
      isNull,
      reason: 'pendingText 必须被消费掉，不能永远挂着。',
    );
    await _unmount(tester);
  });

  testWidgets('查词模块关掉：重复请求不叠第二个查词页（mainTab 分区不得双消费）',
      (WidgetTester tester) async {
    final _HomeShellAppModel appModel =
        await _pumpHome(tester, dictionariesEnabled: false);

    appModel.requestHomeDictionaryTab();
    await _settle(tester);
    expect(find.byType(HomeDictionaryPage), findsOneWidget);

    appModel.requestHomeDictionaryTab();
    await _settle(tester);
    appModel.requestHomeDictionaryTab();
    await _settle(tester);

    expect(
      find.byType(HomeDictionaryPage),
      findsOneWidget,
      reason: '同一时刻全 app 只能有一个 HomeDictionaryPage，'
          '否则 mainTab 分区的 pending 查词会被双消费。',
    );
    await _unmount(tester);
  });
}
