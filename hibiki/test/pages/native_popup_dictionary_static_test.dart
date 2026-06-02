import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const String popupActivityPath =
      'android/app/src/main/java/app/hibiki/reader/PopupDictActivity.kt';

  test('native popup stores initial lookup text before WebView callbacks', () {
    final String source = File(popupActivityPath).readAsStringSync();
    final String onCreateSource = _functionSource(
      source,
      'override fun onCreate(savedInstanceState: Bundle?) {',
      'override fun onNewIntent(intent: Intent) {',
    );

    final int extractIndex =
        onCreateSource.indexOf('val processText = extractProcessText(intent)');
    final int assignIndex =
        onCreateSource.indexOf('currentSearchTerm = processText');
    final int buildLayoutIndex = onCreateSource.indexOf('buildLayout()');

    expect(extractIndex, isNonNegative);
    expect(assignIndex, isNonNegative);
    expect(buildLayoutIndex, isNonNegative);
    expect(assignIndex, lessThan(buildLayoutIndex));
  });

  test('native popup shell uses MD3-style surface and search controls', () {
    final String source = File(popupActivityPath).readAsStringSync();
    final String layoutSource = _functionSource(
      source,
      'private fun buildLayout() {',
      'private fun buildPopupHtml(): String {',
    );

    expect(layoutSource, contains('buildMaterialSearchBar('));
    expect(layoutSource, contains('roundedRect('));
    expect(layoutSource, contains('PopupMaterialColors.fromPrefs('));
    expect(layoutSource, contains('colors.surface'));
    expect(layoutSource, contains('colors.outlineVariant'));
    expect(layoutSource, contains('setTextColor'));
    expect(layoutSource, contains('setHintTextColor'));
    expect(layoutSource, isNot(contains('android.R.drawable.ic_menu_search')));
  });

  test('native popup mirrors in-reader popup surface and compact search row',
      () {
    final String source = File(popupActivityPath).readAsStringSync();
    final String layoutSource = _functionSource(
      source,
      'private fun buildLayout() {',
      'private fun buildMaterialSearchBar(colors: PopupMaterialColors): LinearLayout {',
    );
    final String searchSource = _functionSource(
      source,
      'private fun buildMaterialSearchBar(colors: PopupMaterialColors): LinearLayout {',
      'private fun buildIconButton(',
    );
    final String iconSource = _functionSource(
      source,
      'private fun buildIconButton(',
      'private fun submitSearchFromField()',
    );
    final String injectionSource = _functionSource(
      source,
      'private fun injectResults(',
      'private fun injectError(message: String) {',
    );

    expect(source, contains('POPUP_SURFACE_RADIUS_DP = 12f'));
    expect(source, contains('SEARCH_ROW_RADIUS_DP = 16f'));
    expect(source, contains('SEARCH_ROW_HEIGHT_DP = 44f'));
    expect(source, contains('ICON_BUTTON_SIZE_DP = 40f'));
    expect(layoutSource, contains('radiusDp = POPUP_SURFACE_RADIUS_DP'));
    expect(layoutSource, contains('setBackgroundColor(Color.TRANSPARENT)'));
    expect(layoutSource, contains('addPopupDivider(root, colors)'));
    expect(layoutSource, isNot(contains('setPadding(dp(10f)')));
    expect(searchSource, contains('radiusDp = SEARCH_ROW_RADIUS_DP'));
    expect(searchSource, contains('dp(SEARCH_ROW_HEIGHT_DP)'));
    expect(searchSource, contains('colors.search'));
    expect(
        searchSource, contains('setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)'));
    expect(iconSource, contains('dp(ICON_BUTTON_SIZE_DP)'));
    expect(iconSource, contains('colors.onSurfaceVariant'));
    expect(injectionSource,
        contains('val bgColor = safeDictColor ?: "transparent"'));
    expect(injectionSource, contains('--background-color'));
  });

  test('native popup injects MD3 color tokens into popup html', () {
    final String source = File(popupActivityPath).readAsStringSync();
    final String injectionSource = _functionSource(
      source,
      'private fun injectResults(',
      'private fun escapeForJs(s: String): String {',
    );

    expect(injectionSource, contains('--surface-container'));
    expect(injectionSource, contains('--outline-variant'));
    expect(injectionSource, contains('--primary-color'));
    expect(injectionSource, contains('popup-shell-loaded'));
  });
}

String _functionSource(
  String source,
  String startToken,
  String endToken,
) {
  final int start = source.indexOf(startToken);
  final int end = source.indexOf(endToken, start + startToken.length);
  expect(start, isNonNegative, reason: 'missing $startToken');
  expect(end, greaterThan(start),
      reason: 'missing $endToken after $startToken');
  return source.substring(start, end);
}
