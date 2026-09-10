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
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/test_platform_services.dart';

/// 用户报告：底栏点「查词」进不了输入状态——搜索框既不聚焦（键盘不弹），上一次的
/// 查询词还留在框里，得先手动点 × 再点框。
///
/// 判据落在**导航点击**这条路径上（[_HomePageState._selectTabFromNav]）：从导航点
/// 「查词」是「我要查个新词」这一条意图，故发一条 `clearQuery: true` 的
/// [DictionaryFocusRequest]，查词页消费后清空+聚焦。这里挂真的 [HomePage] 底栏，
/// 用真实点击驱动，断言两件事：
/// - 从别的 tab 点进查词：搜索框直接拿到焦点（焦点即是键盘弹起的前提）；
/// - **已经在查词 tab 上再点一次**：残留的查询被清掉，焦点仍在搜索框。
///   这正是用户截图里的场景（查词 tab 已高亮、框里留着上次的词）。
class _NavTapAppModel extends AppModel {
  _NavTapAppModel(this._dir) : super(testPlatformServices());

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
  }) async =>
      DictionarySearchResult(searchTerm: searchTerm);
}

const ValueKey<String> _searchFieldKey =
    ValueKey<String>('home_dictionary_search_field');

Future<void> _pumpHome(WidgetTester tester) async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final PreferencesRepository prefsRepo = PreferencesRepository(db);
  await prefsRepo.loadFromDb();
  final Directory tmpDir =
      Directory.systemTemp.createTempSync('fushi_dict_nav_tap_');
  addTearDown(() {
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  final _NavTapAppModel appModel = _NavTapAppModel(tmpDir)
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
}

/// 有界推帧：整页 HomePage 挂着持续动画与周期定时器，`pumpAndSettle` 永远等不到
/// 静止（与 home_hidden_tab_select_behavior_test 同因）。
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

/// 点底栏上的一个 destination（按可见 label 定位）。
Future<void> _tapNav(WidgetTester tester, String label) async {
  final Finder target = find.descendant(
    of: find.byKey(fushiMaterialNavKey),
    matching: find.text(label),
  );
  expect(target, findsOneWidget, reason: '底栏上应有「$label」这个 destination');
  await tester.tap(target);
  await _settle(tester);
}

SearchBar _searchBar(WidgetTester tester) =>
    tester.widget<SearchBar>(find.byKey(_searchFieldKey));

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

  testWidgets('底栏点「查词」：搜索框直接聚焦（键盘随焦点弹起）', (WidgetTester tester) async {
    // compact 宽度才走底栏布局（≥600 是侧栏 rail）。
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpHome(tester);
    expect(find.byType(HomeDictionaryPage), findsNothing,
        reason: '起点是首页，查词页尚未挂载。');

    await _tapNav(tester, t.nav_lookup);

    expect(find.byType(HomeDictionaryPage), findsOneWidget);
    expect(
      _searchBar(tester).focusNode?.hasFocus,
      isTrue,
      reason: '点导航进查词 = 要查新词；焦点必须已经在搜索框上，键盘才会弹。',
    );
    await _unmount(tester);
  });

  testWidgets('已在查词 tab 再点一次「查词」：清空残留查询并重新聚焦', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpHome(tester);
    await _tapNav(tester, t.nav_lookup);
    expect(find.byType(HomeDictionaryPage), findsOneWidget);

    // 用户上一次查的词还留在框里（截图里的「おばさん」）。
    await tester.enterText(find.byKey(_searchFieldKey), 'おばさん');
    await _settle(tester);
    expect(_searchBar(tester).controller?.text, 'おばさん');

    // 查词 tab 已是当前 tab，再点一次底栏的「查词」。
    await _tapNav(tester, t.nav_lookup);

    expect(
      _searchBar(tester).controller?.text,
      isEmpty,
      reason: '再点一次 = 重新开始查；残留的查询必须被清掉。',
    );
    expect(
      _searchBar(tester).focusNode?.hasFocus,
      isTrue,
      reason: '清空之后焦点仍要留在搜索框上，用户直接就能打字。',
    );
    await _unmount(tester);
  });
}
