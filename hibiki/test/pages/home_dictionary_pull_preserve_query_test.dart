import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
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
    expect(
      clearFromPull,
      contains('_popup.entries.isNotEmpty || _popup.isSearchingUi'),
    );
    expect(clearFromPull, contains('_clearSearch();'));

    expect(webViewSrc, contains('final VoidCallback? onTopPullReleased;'));
    expect(webViewSrc, contains("handlerName: 'topPullReleased'"));
    expect(
      webViewSrc,
      contains("callHandler('topPullReleased')"),
      reason: 'The real definition WebView must report a top pull release; '
          'an outer Flutter scroll wrapper would not reliably receive WebView '
          'touch drags.',
    );
    expect(
      resultBody,
      contains('_popup.entries.isNotEmpty || _popup.isSearchingUi'),
      reason:
          'The outside-tap shield should exist only for nested popup state, '
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
}
