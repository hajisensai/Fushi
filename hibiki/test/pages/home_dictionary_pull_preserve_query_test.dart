import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String path) => File(path).readAsStringSync();

  test('home dictionary submitted lookup releases the search field focus', () {
    final String src =
        read('lib/src/pages/implementations/home_dictionary_page.dart');

    expect(
      src,
      contains('void _submitSearch(String query)'),
      reason: 'Explicit search submission must leave editing mode before '
          'showing results; otherwise mobile keeps the keyboard open and '
          'desktop typing continues to edit the query while browsing meanings.',
    );

    final int submitStart = src.indexOf('void _submitSearch(String query)');
    final int queryChangedStart = src.indexOf('void _onQueryChanged');
    expect(submitStart, isNonNegative);
    expect(queryChangedStart, greaterThan(submitStart));
    final String submitBody = src.substring(submitStart, queryChangedStart);
    expect(submitBody, contains('_searchFocusNode.unfocus();'));
    expect(submitBody, contains('_search(query'));

    final int searchHeaderStart = src.indexOf('Widget _buildSearchHeader()');
    final int bodyStart = src.indexOf('Widget _buildBody()');
    expect(searchHeaderStart, isNonNegative);
    expect(bodyStart, greaterThan(searchHeaderStart));
    final String searchHeader = src.substring(searchHeaderStart, bodyStart);
    expect(searchHeader, contains('onSubmitted: _submitSearch'));
  });

  test('back while dictionary search field is focused only unfocuses first',
      () {
    final String src =
        read('lib/src/pages/implementations/home_dictionary_page.dart');

    final int popScopeStart = src.indexOf('return PopScope(');
    final int desktopLayoutStart = src.indexOf('child: DesktopContentLayout(');
    expect(popScopeStart, isNonNegative);
    expect(desktopLayoutStart, greaterThan(popScopeStart));
    final String popScope = src.substring(popScopeStart, desktopLayoutStart);

    expect(
      popScope,
      contains('else if (_searchFocusNode.hasFocus)'),
      reason: 'The first back/keyboard-dismiss gesture from result browsing '
          'must only leave input mode. Clearing the query is the second back.',
    );
    expect(popScope, contains('_searchFocusNode.unfocus();'));

    final int unfocusBranch = popScope.indexOf('_searchFocusNode.hasFocus');
    final int clearBranch = popScope.indexOf('else if (_hasActiveQuery)');
    expect(unfocusBranch, isNonNegative);
    expect(clearBranch, greaterThan(unfocusBranch));
  });

  test('home dictionary result browsing never clears search from drag release',
      () {
    final String src =
        read('lib/src/pages/implementations/home_dictionary_page.dart');

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
      resultBody,
      isNot(contains('_clearSearch')),
      reason: 'Dragging/pulling the definition WebView must stay in result '
          'browsing mode and must not route pointer release to the search-clear '
          'path.',
    );
    expect(
      resultBody,
      contains('_popup.entries.isNotEmpty || _popup.isSearchingUi'),
      reason:
          'The outside-tap shield should exist only for nested popup state, '
          'not as a general result-body gesture catcher.',
    );
  });
}
