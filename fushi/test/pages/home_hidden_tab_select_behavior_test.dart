import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
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

/// 测试用：把「一串具名 bool」翻成一个可见性快照（迁移前 [homeActiveTabs] 收的正是
/// 这串具名 bool，默认值逐字保留）。这里只用来做「查词 tab 确实不在可见列表里」的
/// 前置断言，与上面 [_HomeShellAppModel] 桩出来的真实可见性同语义。
ModuleVisibility _visibility({
  required bool video,
  bool books = true,
  bool manga = true,
  bool games = false,
  bool downloads = true,
  bool lookup = true,
  bool browserExtension = false,
}) => ModuleVisibility(<ModuleId>{
  // 首页 2026-10-09 起是可关模块；这些用例的语义是「首页开着」。
  ModuleId.home,
  if (books) ModuleId.books,
  if (manga) ModuleId.manga,
  if (video) ModuleId.video,
  if (games) ModuleId.games,
  if (downloads) ModuleId.browse,
  if (lookup) ModuleId.lookup,
  if (browserExtension) ModuleId.web,
});

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
        ..wireDatabaseForTesting(db)
        // 设置页的语言行读 AppModel.locales（late，生产里由 initialise 填）。
        ..populateLocales()
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

  testWidgets('查词模块开着：请求打开查词落在 tab 上（不推路由），pending 被消费', (
    WidgetTester tester,
  ) async {
    final _HomeShellAppModel appModel = await _pumpHome(
      tester,
      dictionariesEnabled: true,
    );

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

  testWidgets('查词模块关掉：tab 确实隐藏，但请求改推独立路由，pending 仍被消费', (
    WidgetTester tester,
  ) async {
    final _HomeShellAppModel appModel = await _pumpHome(
      tester,
      dictionariesEnabled: false,
    );

    // 前置：查词 tab 真的不在可见列表里，_selectTab 会拒绝切换。
    expect(
      homeActiveTabs(_visibility(video: true, lookup: false)),
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
    expect(appModel.searchedTerms, <String>[
      'hiddenword',
    ], reason: '否则用户按热键只会看到窗口弹到前台却什么都不显示。');
    expect(
      DesktopLookupService.instance.pendingText,
      isNull,
      reason: 'pendingText 必须被消费掉，不能永远挂着。',
    );
    await _unmount(tester);
  });

  testWidgets('查词模块关掉：重复请求不叠第二个查词页（mainTab 分区不得双消费）', (
    WidgetTester tester,
  ) async {
    final _HomeShellAppModel appModel = await _pumpHome(
      tester,
      dictionariesEnabled: false,
    );

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
      reason:
          '同一时刻全 app 只能有一个 HomeDictionaryPage，'
          '否则 mainTab 分区的 pending 查词会被双消费。',
    );
    await _unmount(tester);
  });

  // 全局热键「置顶主窗并打开查词页」（globalExternalOpenLookupPage）最典型的用法就是
  // 「正在 Fushi 里看书 / 看视频 → 切到别的程序 → 按热键」。阅读器 / 播放器 / 漫画
  // 都是 `Navigator.push` 压在 HomePage 之上的全屏路由（BUG-286 记过），此时若只
  // `_selectTab` 切底下那层 IndexedStack，用户看到的是「窗口弹到前台却什么都没变」。
  testWidgets('查词 tab 开着但被全屏路由遮住：必须推独立路由到最上层，且不弹掉原页面', (
    WidgetTester tester,
  ) async {
    final _HomeShellAppModel appModel = await _pumpHome(
      tester,
      dictionariesEnabled: true,
    );

    // 模拟阅读器 / 播放器：一层压在 HomePage 之上的全屏路由。
    unawaited(
      Navigator.of(appModel.navigatorKey.currentContext!).push<void>(
        MaterialPageRoute<void>(
          builder: (_) =>
              const Scaffold(body: Center(child: Text('reader-上层'))),
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('reader-上层'), findsOneWidget);

    DesktopLookupService.instance.triggerLookup(' coveredword ');
    appModel.requestHomeDictionaryTab();
    await _settle(tester);

    expect(
      find.byKey(const ValueKey<String>('home-dictionary-route-back')),
      findsOneWidget,
      reason: '被遮住时必须推独立查词路由压在最上层 —— 只切底下的 tab 等于什么都没做。',
    );
    expect(
      // 被不透明路由完全遮住的那层是 offstage 的，默认 finder 会跳过它 ——
      // 这里要问的是「它还在不在栈上」，不是「它可不可见」，故必须关掉 skipOffstage。
      find.text('reader-上层', skipOffstage: false),
      findsOneWidget,
      reason:
          '**不得** popUntil 把用户正在读的书 / 正在放的视频弹掉'
          '（BUG-286 定过这条边界：不能为看个词强退阅读器并停有声书）。',
    );
    expect(appModel.searchedTerms, <String>['coveredword']);
    expect(DesktopLookupService.instance.pendingText, isNull);
    await _unmount(tester);
  });

  // 上一条的死角：底下那层恰好已经停在查词 tab 上。早退判据若只看 `_currentTab`，
  // 这次请求会变成**彻底的 no-op**（窗口弹到前台、一点反馈都没有）。
  testWidgets('底层已在查词 tab 且被全屏路由遮住：仍必须推独立路由，不得早退成 no-op', (
    WidgetTester tester,
  ) async {
    final _HomeShellAppModel appModel = await _pumpHome(
      tester,
      dictionariesEnabled: true,
    );

    HomePage.debugSelectTab!(HomeTab.dictionaries);
    await _settle(tester);
    expect(find.byType(HomeDictionaryPage), findsOneWidget);

    unawaited(
      Navigator.of(appModel.navigatorKey.currentContext!).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Center(child: Text('video-上层'))),
        ),
      ),
    );
    await _settle(tester);

    appModel.requestHomeDictionaryTab();
    await _settle(tester);

    expect(
      find.byKey(const ValueKey<String>('home-dictionary-route-back')),
      findsOneWidget,
      reason: '「已经在查词 tab 上」只有 HomePage 在栈顶时才等于「已经显示出来了」。',
    );
    expect(find.text('video-上层', skipOffstage: false), findsOneWidget);
    await _unmount(tester);
  });
  // ── 查词 tab 保活（BUG-4849）──

  testWidgets('查词 tab 保活：藏着时不消费待查词，切回同一页才消费', (WidgetTester tester) async {
    final _HomeShellAppModel appModel = await _pumpHome(
      tester,
      dictionariesEnabled: true,
    );
    HomePage.debugSelectTab!(HomeTab.dictionaries);
    await _settle(tester);
    final State<StatefulWidget> before = tester.state(
      find.byType(HomeDictionaryPage),
    );

    HomePage.debugSelectTab!(HomeTab.home);
    await _settle(tester);
    expect(find.byType(HomeDictionaryPage), findsNothing, reason: '查词页已被藏起。');
    expect(
      find.byType(HomeDictionaryPage, skipOffstage: false),
      findsOneWidget,
      reason: '查词 tab 保活：切走只是藏起，不销毁。',
    );

    // 用户在别的 tab 上时来了一条待查词（桌面取词 / 悬浮字幕点词）。
    DesktopLookupService.instance.triggerLookup(' hiddenword ');
    await _settle(tester);
    expect(
      appModel.searchedTerms,
      isEmpty,
      reason: '藏着的查词页不得消费待查词——那等于词被看不见的页面吞掉。',
    );
    expect(DesktopLookupService.instance.pendingText, 'hiddenword');

    appModel.requestHomeDictionaryTab();
    await _settle(tester);
    expect(
      identical(tester.state(find.byType(HomeDictionaryPage)), before),
      isTrue,
      reason: '切回是同一个 State。',
    );
    expect(appModel.searchedTerms, <String>[
      'hiddenword',
    ], reason: 'TODO-376：切到查词 tab 必须消费切过来之前排入的待查词。');
    expect(DesktopLookupService.instance.pendingText, isNull);
    await _unmount(tester);
  });

  testWidgets('查词 tab 保活：藏着时有查询也不拦系统返回', (WidgetTester tester) async {
    await _pumpHome(tester, dictionariesEnabled: true);
    HomePage.debugSelectTab!(HomeTab.dictionaries);
    await _settle(tester);
    await tester.enterText(
      find.descendant(
        of: find.byType(HomeDictionaryPage),
        matching: find.byType(EditableText),
      ),
      'abc',
    );
    await _settle(tester);

    bool pageCanPop() => tester
        .widget<PopScope<dynamic>>(
          find
              .descendant(
                of: find.byType(HomeDictionaryPage, skipOffstage: false),
                matching: find.byWidgetPredicate(
                  (Widget w) => w is PopScope,
                  skipOffstage: false,
                ),
              )
              .first,
        )
        .canPop;

    expect(pageCanPop(), isFalse, reason: '前置：可见且有查询时返回先清查询。');

    HomePage.debugSelectTab!(HomeTab.home);
    await _settle(tester);
    expect(
      pageCanPop(),
      isTrue,
      reason: '藏起的保活查词页不能吃掉用户在别的 tab 上按的返回键（HBK-AUDIT-017）。',
    );
    await _unmount(tester);
  });

  // ── 进设置不卸载正文（BUG-4850）──
  //
  // 原先没有自绘标题栏的平台（Linux / 横屏安卓平板）宽窗进设置走「摘掉侧栏的全屏
  // 设置」分支，正文连同全部保活页被整棵卸载。PR #3676 起设置全平台同壳（rail
  // 常驻 + 二栏），那条分支已删；这里继续守住「进设置不卸载正文」这条不变式。

  testWidgets('宽窗进设置：侧栏常驻、藏着的保活 tab 不被卸载，返回切回来源 tab', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.reset);

    await _pumpHome(tester, dictionariesEnabled: true);
    HomePage.debugSelectTab!(HomeTab.dictionaries);
    await _settle(tester);
    expect(
      find.byType(NavRailBrandButton),
      findsOneWidget,
      reason: '前置：宽窗侧栏布局。',
    );
    final State<StatefulWidget> before = tester.state(
      find.byType(HomeDictionaryPage),
    );

    HomePage.debugSelectTab!(HomeTab.settings);
    await _settle(tester);
    expect(
      find.byType(NavRailBrandButton),
      findsOneWidget,
      reason: '设置与其它 tab 同壳：主导航 rail 常驻（PR #3676）。',
    );
    expect(find.byType(HomeSettingsTabContent), findsOneWidget);
    expect(
      find.byType(HomeDictionaryPage, skipOffstage: false),
      findsOneWidget,
      reason:
          '进设置不得把正文连同保活页整棵卸载——卸载 = 回来每个 tab 冷启动、'
          '远端列表重拉、页内状态全丢。',
    );

    tester
        .widget<HomeSettingsTabContent>(find.byType(HomeSettingsTabContent))
        .onReturnToPreviousTab();
    await _settle(tester);
    expect(find.byType(NavRailBrandButton), findsOneWidget);
    expect(
      identical(tester.state(find.byType(HomeDictionaryPage)), before),
      isTrue,
      reason: '从设置回来是进设置之前的那一页（同一个 State），不是重新挂载的。',
    );
    await _unmount(tester);
  });
}
