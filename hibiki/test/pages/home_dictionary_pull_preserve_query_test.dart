import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/home_dictionary_page.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';
import 'package:hibiki/src/utils/spacing.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import '../helpers/fake_inappwebview_platform.dart';
import '../helpers/test_platform_services.dart';

class _ClearRaceAppModel extends AppModel {
  _ClearRaceAppModel() : super(testPlatformServices());

  final List<String> searchedTerms = <String>[];
  final Map<String, Completer<DictionarySearchResult>> _searches =
      <String, Completer<DictionarySearchResult>>{};

  @override
  bool get autoSearchEnabled => false;

  @override
  bool get desktopClipboardEnabled => false;

  @override
  DesktopClipboardWindowMode get desktopClipboardWindowMode =>
      DesktopClipboardWindowMode.normal;

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
  }) {
    searchedTerms.add(searchTerm);
    return (_searches[searchTerm] ??= Completer<DictionarySearchResult>())
        .future;
  }

  void completeSearch(String searchTerm, DictionarySearchResult result) {
    final Completer<DictionarySearchResult>? completer = _searches[searchTerm];
    if (completer != null && !completer.isCompleted) {
      completer.complete(result);
    }
  }
}

Widget _wrapHomeDictionary(_ClearRaceAppModel appModel) {
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

DictionarySearchResult _resultWithEntry(String searchTerm, String word) {
  return DictionarySearchResult(
    searchTerm: searchTerm,
    entries: <DictionaryEntry>[
      DictionaryEntry(
        dictionaryName: 'Test',
        word: word,
        reading: word,
        meaning: '["stale"]',
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(installFakeInAppWebViewPlatform);

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    DesktopLookupService.instance.debugReset();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
    DesktopLookupService.instance.debugReset();
  });

  String read(String path) => File(path).readAsStringSync();

  test('home dictionary submitted lookup keeps the search field focused', () {
    final String src =
        read('lib/src/pages/implementations/home_dictionary_page.dart');

    expect(
      src,
      isNot(contains('void _submitSearch(String query)')),
      reason: 'Home dictionary lookup is intentionally an input-mode flow: '
          'mobile should keep the keyboard/search field open and desktop '
          'typing should stay in the search box after lookup.',
    );

    final int searchHeaderStart = src.indexOf('Widget _buildSearchHeader()');
    final int bodyStart = src.indexOf('Widget _buildBody()');
    expect(searchHeaderStart, isNonNegative);
    expect(bodyStart, greaterThan(searchHeaderStart));
    final String searchHeader = src.substring(searchHeaderStart, bodyStart);
    expect(searchHeader, contains('onSubmitted: _search'));
  });

  test('back while a dictionary query is active clears the query directly', () {
    final String src =
        read('lib/src/pages/implementations/home_dictionary_page.dart');

    final int popScopeStart = src.indexOf('return PopScope(');
    final int desktopLayoutStart = src.indexOf('child: DesktopContentLayout(');
    expect(popScopeStart, isNonNegative);
    expect(desktopLayoutStart, greaterThan(popScopeStart));
    final String popScope = src.substring(popScopeStart, desktopLayoutStart);

    expect(
      popScope,
      isNot(contains('else if (_searchFocusNode.hasFocus)')),
      reason: 'Home dictionary result state keeps search input focused; back '
          'from an active query should clear the query instead of only '
          'leaving input mode.',
    );
    final int clearBranch = popScope.indexOf('else if (_hasActiveQuery)');
    expect(clearBranch, isNonNegative);
    expect(popScope.substring(clearBranch), contains('_clearSearch();'));
  });

  test('home dictionary result pull release clears the search query', () {
    final String src =
        read('lib/src/pages/implementations/home_dictionary_page.dart');
    final String webViewSrc =
        read('lib/src/pages/implementations/dictionary_popup_webview.dart');

    expect(
      src,
      contains('void _clearSearch()'),
      reason: 'The page can still clear from explicit second back/navigation '
          'paths.',
    );

    final int resultBodyStart = src.indexOf('Widget _buildSearchResultBody()');
    final int pushPopupStart = src.indexOf('Future<void> _pushNestedPopup(');
    expect(resultBodyStart, isNonNegative);
    expect(pushPopupStart, greaterThan(resultBodyStart));
    final String resultBody = src.substring(resultBodyStart, pushPopupStart);

    expect(
        resultBody, contains('onTopPullReleased: _clearSearchFromResultPull'));

    final int clearFromPullStart =
        src.indexOf('void _clearSearchFromResultPull()');
    final int buildStart = src.indexOf('// ── build');
    expect(clearFromPullStart, isNonNegative);
    expect(buildStart, greaterThan(clearFromPullStart));
    final String clearFromPull = src.substring(clearFromPullStart, buildStart);
    // TODO-931：常驻热槽使 entries 永不空，pull-clear 判据改用 hasVisiblePopup（隐藏热槽不算）。
    expect(
      clearFromPull,
      contains('_popup.hasVisiblePopup || _popup.isSearchingUi'),
    );
    expect(clearFromPull, contains('_clearSearch();'));

    expect(webViewSrc, contains('final VoidCallback? onTopPullReleased;'));
    expect(webViewSrc, contains("handlerName: 'topPullReleased'"));
    // TODO-854 M1a-2：下滑关闭 JS 收口到 kPopupTopPullReleaseJs（桌面 in-app 弹窗 +
    // Windows 全局查词覆盖窗共用）。WebView 仍注入该脚本（_topPullReleaseJs ＝
    // kPopupTopPullReleaseJs），脚本本身回调 topPullReleased——保护意图不变，只是
    // 真相源搬到了共享常量。
    expect(webViewSrc, contains('_topPullReleaseJs = kPopupTopPullReleaseJs'));
    expect(
        webViewSrc, contains('evaluateJavascript(source: _topPullReleaseJs)'));
    final String swipeJsSrc =
        read('lib/src/reader/popup_swipe_close_script.dart');
    expect(
      swipeJsSrc,
      contains("callHandler('topPullReleased')"),
      reason: 'The real definition WebView must report a top pull release; '
          'an outer Flutter scroll wrapper would not reliably receive WebView '
          'touch drags.',
    );
    // TODO-931：外点遮罩同样改用 _hasVisiblePopup（隐藏热槽不该挂遮罩）。
    expect(
      resultBody,
      contains('_hasVisiblePopup || _popup.isSearchingUi'),
      reason:
          'The outside-tap shield should exist only for visible popup state, '
          'not as a general result-body gesture catcher.',
    );
  });

  test('home dictionary search field exposes a focused clear affordance', () {
    final String src =
        read('lib/src/pages/implementations/home_dictionary_page.dart');

    final int searchHeaderStart = src.indexOf('Widget _buildSearchHeader()');
    final int bodyStart = src.indexOf('Widget _buildBody()');
    expect(searchHeaderStart, isNonNegative);
    expect(bodyStart, greaterThan(searchHeaderStart));
    final String searchHeader = src.substring(searchHeaderStart, bodyStart);

    expect(
      searchHeader,
      contains("'home_dictionary_search_clear_button'"),
      reason: 'TODO-510 needs a stable X clear button on the home dictionary '
          'search field when text is present.',
    );
    expect(searchHeader, contains('onClear: _clearSearch'));

    final int clearSearchStart = src.indexOf('void _clearSearch()');
    final int pullClearStart = src.indexOf('void _clearSearchFromResultPull()');
    expect(clearSearchStart, isNonNegative);
    expect(pullClearStart, greaterThan(clearSearchStart));
    final String clearSearch = src.substring(clearSearchStart, pullClearStart);

    expect(clearSearch, contains('_debounceTimer?.cancel();'));
    expect(clearSearch, contains('_controller.clear();'));
    expect(clearSearch, contains('_result = null;'));
    expect(clearSearch, contains('_searchFocusNode.requestFocus();'));
    expect(
      clearSearch,
      isNot(contains('_searchFocusNode.unfocus()')),
      reason: 'Clearing text is still input mode; focus should stay in the '
          'search box where possible.',
    );
  });

  testWidgets('clearing invalidates an in-flight search result', (
    WidgetTester tester,
  ) async {
    final _ClearRaceAppModel appModel = _ClearRaceAppModel();
    final Finder searchField = find.byKey(
      const ValueKey<String>('home_dictionary_search_field'),
    );
    final Finder clearButton = find.byKey(
      const ValueKey<String>('home_dictionary_search_clear_button'),
    );
    final Finder resultEvidence = find.byKey(
      const ValueKey<String>('home_dictionary_result_evidence'),
    );

    await tester.pumpWidget(_wrapHomeDictionary(appModel));
    await tester.pump();

    await tester.tap(searchField);
    await tester.enterText(searchField, 'old');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    expect(appModel.searchedTerms, <String>['old']);
    expect(clearButton, findsOneWidget);

    await tester.tap(clearButton);
    await tester.pump();

    expect(clearButton, findsNothing);
    expect(resultEvidence, findsNothing);

    appModel.completeSearch('old', _resultWithEntry('old', 'old-result'));
    await tester.pump();

    expect(
      resultEvidence,
      findsNothing,
      reason: 'A search completed after clear must not write stale _result.',
    );

    await tester.tap(searchField);
    await tester.enterText(searchField, 'new');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    expect(appModel.searchedTerms, <String>['old', 'new']);
    expect(
      resultEvidence,
      findsNothing,
      reason:
          'Starting a fresh lookup after clear must not show the old result '
          'while the new Future is still pending.',
    );

    appModel.completeSearch(
      'new',
      DictionarySearchResult(searchTerm: 'new'),
    );
    await tester.pump();
  });
}
