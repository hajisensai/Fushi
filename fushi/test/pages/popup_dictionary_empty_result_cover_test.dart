import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/pages/implementations/popup_dictionary_page.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../helpers/test_platform_services.dart';
import '../helpers/popup_mining_target_overrides.dart';

/// app 外查词窗（PopupDictionaryPage）查一个没词条的词，「未找到」叠成两份：
/// 基础层传 `overrideFillColor: Colors.transparent`（整卡由外层 surface 画），
/// BUG-2588 的热槽「不透明」空结果盖板 `ColoredBox(fillColor)` 于是是全透明的——
/// 热槽 WebView 里 popup.js 自己画的「未找到」透出来，Flutter 占位又盖一份。
/// 修复：盖板底色走 [DictionaryPopupLayer.coverFillColor]，基础层由宿主给外层卡片的
/// 不透明色。
class _EmptyResultAppModel extends AppModel {
  _EmptyResultAppModel() : super(testPlatformServices());

  @override
  bool get isInitialised => true;

  @override
  bool get lowMemoryMode => false;

  @override
  int get maximumTerms => 10;

  @override
  double get popupMaxWidth => 300;

  @override
  double get dictionaryFontSize => 16;

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
    return DictionarySearchResult(searchTerm: searchTerm);
  }
}

Widget _buildApp(AppModel appModel) {
  return ProviderScope(
    overrides: [
      appProvider.overrideWith((ref) => appModel),
      ...popupMiningTargetTestOverrides(),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: appModel.navigatorKey,
        home: PopupDictionaryPage(
          searchTerm: 'fushi',
          closeInApp: () {},
          autoSearchOnOpen: false,
        ),
      ),
    ),
  );
}

/// 「未找到」占位最近的 [ColoredBox] 祖先——即热槽空结果盖板。
Color _coverColorAbove(WidgetTester tester, Finder placeholder) {
  return tester
      .widget<ColoredBox>(
        find.ancestor(of: placeholder, matching: find.byType(ColoredBox)).first,
      )
      .color;
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets('app 外查词窗热槽空结果：盖板不透明且与卡片同色，WebView 自画的空态不透出', (
    WidgetTester tester,
  ) async {
    final AppModel appModel = _EmptyResultAppModel();
    await tester.pumpWidget(_buildApp(appModel));
    await tester.pump();

    final Finder searchField = find.byKey(
      const ValueKey<String>('popup_dictionary_search_field'),
    );
    await tester.showKeyboard(searchField);
    await tester.enterText(searchField, 'fushi');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));

    final Finder layerFinder = find.byType(DictionaryPopupLayer);
    expect(layerFinder, findsOneWidget);
    final DictionaryPopupLayer layer = tester.widget(layerFinder);
    expect(layer.keepWebViewWarm, isTrue, reason: '基础层复用常驻热槽（BUG-2588 路径）');
    expect(
      layer.overrideFillColor,
      Colors.transparent,
      reason: '前提：基础层面板透明，整卡由外层画',
    );

    expect(
      find.byType(DictionaryPopupWebView),
      findsOneWidget,
      reason: '热槽 WebView 仍在树上，它自己也会渲染「未找到」',
    );
    final Finder placeholder = find.byType(FushiPlaceholderMessage);
    expect(placeholder, findsOneWidget);

    final Color cover = _coverColorAbove(tester, placeholder);
    expect(cover.a, 1.0, reason: '盖板透明 = 没盖住 WebView，两份「未找到」叠在一起');
    expect(cover, layer.coverFillColor, reason: '盖板取宿主给的卡片色，与外层卡片无缝');
  });
}
