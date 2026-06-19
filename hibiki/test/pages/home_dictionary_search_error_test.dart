import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/pages/implementations/home_dictionary_page.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';
import 'package:hibiki/src/utils/spacing.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import '../helpers/fake_inappwebview_platform.dart';
import '../helpers/test_platform_services.dart';

/// TODO-555 回归守卫：首页词典查词抛异常时不得永久转圈、不得永久阻塞「加载更多」。
///
/// 根因（commit 9427a386c 拆 `_search` / `_searchWithGeneration` 时丢了 try/finally）：
/// `_searchWithGeneration` 里 `await appModel.searchDictionary(...)` 之后才有唯一一处
/// `_isSearching = false`。一旦 searchDictionary 抛异常（远程网络查询 + hoshidicts
/// C++ FFI 都可能抛），复位行不可达 → `_isSearching` 永久 true →
/// `_buildQueryBody` 永久显示转圈、`_loadMore` 第一句 `if (_isSearching) return`
/// 永久阻塞。
///
/// 修复在 `await` 外恢复 try/finally：finally 仅对仍是当前 generation 的请求复位
/// `_isSearching`（保留过期守卫，不污染新请求）。撤掉 finally → 本组测试转红
/// （[debugIsSearching] 恒为 true / loadMore 不再发起新查询）。
class _ErrorSearchAppModel extends AppModel {
  _ErrorSearchAppModel() : super(testPlatformServices());

  /// 临时把下一次 searchDictionary 置为抛异常（模拟某次网络 / FFI 失败）。
  bool failNextCall = false;

  int searchCount = 0;
  final List<String> searchedTerms = <String>[];

  /// 默认成功返回满 10 条 → _allLoaded=false，loadMore 可用。
  DictionarySearchResult _buildResult(String term) => DictionarySearchResult(
        searchTerm: term,
        entries: List<DictionaryEntry>.generate(
          10,
          (int i) => DictionaryEntry(word: '$term$i'),
        ),
      );

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
  bool get desktopClipboardEnabled => false;

  // 关掉自动查词：避免 onChanged 路径额外发查询，searchCount 计数确定。
  @override
  bool get autoSearchEnabled => false;

  // 结果列表 DictionaryPopupWebView 渲染依赖的字号/缩放/音频源 getter。
  @override
  double get defaultDictionaryFontSize => 26;

  @override
  double get dictionaryFontSize => 26;

  @override
  double get appUiScale => 1.0;

  @override
  List<String> get enabledAudioSources => const <String>[];

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
    searchCount++;
    searchedTerms.add(searchTerm);
    if (failNextCall) {
      failNextCall = false;
      // 模拟真实失败路径：远程网络 / FFI 抛异常。
      throw StateError('boom: dictionary lookup failed');
    }
    return _buildResult(searchTerm);
  }
}

Widget _wrap(_ErrorSearchAppModel appModel) {
  return ProviderScope(
    overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: appModel.navigatorKey,
        builder: (BuildContext context, Widget? child) => Spacing(
          dataBuilder: (BuildContext context) => SpacingData.generate(10),
          child: child ?? const SizedBox.shrink(),
        ),
        home: const Scaffold(body: HomeDictionaryPage()),
      ),
    ),
  );
}

HomeDictionarySearchDebug _debug(WidgetTester tester) =>
    tester.state(find.byType(HomeDictionaryPage)) as HomeDictionarySearchDebug;

/// await 派发的 future 并捕获其异常（finally 在异常传播前已执行，故 await 返回 /
/// 抛出时 _isSearching 已复位）。返回捕获到的异常（无异常则 null）。
Future<Object?> _runAndCatch(
  WidgetTester tester,
  Future<void> dispatched,
) async {
  Object? caught;
  await tester.runAsync(() async {
    try {
      await dispatched;
    } catch (e) {
      caught = e;
    }
  });
  await tester.pump();
  return caught;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(installFakeInAppWebViewPlatform);

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    DesktopLookupService.instance.debugReset();
  });

  tearDown(() {
    DesktopLookupService.instance.debugReset();
  });

  testWidgets(
      'searchDictionary throws → spinner clears, _isSearching resets, '
      'placeholder shown (no permanent spin)', (WidgetTester tester) async {
    final _ErrorSearchAppModel appModel = _ErrorSearchAppModel();

    await tester.pumpWidget(_wrap(appModel));
    await tester.pump();

    appModel.failNextCall = true;
    final Future<void> dispatched = _debug(tester).debugSearch('foo');
    // 派发瞬间（尚未 drain microtask）_isSearching=true：查词进行中显示转圈。
    expect(_debug(tester).debugIsSearching, isTrue,
        reason: '派发后查询完成前应处于查词中（显示转圈）。');

    final Object? caught = await _runAndCatch(tester, dispatched);

    // 异常确实从派发的 future 逃逸（未被吞掉）——根因修复只复位状态，不掩盖异常。
    expect(caught, isA<StateError>());

    // 核心断言：撤掉 finally 这里恒为 true → 红。
    expect(
      _debug(tester).debugIsSearching,
      isFalse,
      reason: 'searchDictionary 抛异常后 _isSearching 必须复位，否则永久转圈/阻塞。',
    );

    // 转圈消失、回到「无结果」占位（query body 走 placeholder 分支）。
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text(t.no_search_results), findsOneWidget);

    expect(appModel.searchCount, 1);
  });

  testWidgets('loadMore is not permanently blocked after a failed lookup',
      (WidgetTester tester) async {
    final _ErrorSearchAppModel appModel = _ErrorSearchAppModel();

    await tester.pumpWidget(_wrap(appModel));
    await tester.pump();

    // 第一次成功查词：满 10 条 → _allLoaded=false，loadMore 可用。
    final Object? firstErr =
        await _runAndCatch(tester, _debug(tester).debugSearch('foo'));
    expect(firstErr, isNull);
    expect(appModel.searchCount, 1);
    expect(_debug(tester).debugIsSearching, isFalse);

    // 让下一次（loadMore 那次）查词抛异常。
    appModel.failNextCall = true;
    final Object? loadMoreErr =
        await _runAndCatch(tester, _debug(tester).debugLoadMore());
    expect(loadMoreErr, isA<StateError>());
    expect(appModel.searchCount, 2, reason: 'loadMore 应已发起第二次查询。');

    // 关键：失败后 _isSearching 必须复位，否则下一次 loadMore 被 `if(_isSearching)
    // return` 永久挡死。撤掉 finally → 这里恒 true → 红。
    expect(
      _debug(tester).debugIsSearching,
      isFalse,
      reason: 'loadMore 查询失败后 _isSearching 必须复位。',
    );

    // 再次 loadMore：若未被永久阻塞，会发起第三次查询。
    final Object? thirdErr =
        await _runAndCatch(tester, _debug(tester).debugLoadMore());
    expect(thirdErr, isNull);
    expect(
      appModel.searchCount,
      3,
      reason: '失败后 loadMore 不得被永久阻塞，应能再次发起查询。',
    );
    expect(_debug(tester).debugIsSearching, isFalse);
  });
}
