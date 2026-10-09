import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/pages/implementations/popup_settings_injection.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../helpers/test_platform_services.dart';

/// 停驻的热槽页里加载动画无限循环（Windows WebView2 停驻仍 `IsVisible(true)`、文档仍
/// visible，空闲持续出帧）：宿主注入的 `window.lookupPending` 曾按「结果是搜索期占位
/// 单例」推 true，而热槽 seed / 复位 / 停驻 realm 挂的都是那个单例。现在由
/// `popupLookupPending`（层在屏上 && 查询进行中 && 还没有内容）唯一派生，
/// [DictionaryPopupLayer] 把它交给 [DictionaryPopupWebView.lookupPending]。
class _AppModel extends AppModel {
  _AppModel() : super(testPlatformServices());

  @override
  int get maximumTerms => 10;
  @override
  double get popupMaxWidth => 360;
  @override
  double get popupMaxHeight => 360;
  @override
  bool get popupBottomDocked => false;
  @override
  double get appUiScale => 1.0;
  @override
  bool get lowMemoryMode => false;
  @override
  List<String> get enabledAudioSources => const <String>[];
  @override
  List<AudioSourceConfig> get audioSourceConfigs => const <AudioSourceConfig>[];
  @override
  double get dictionaryFontSize => 16;
  @override
  double get popupWheelSpeed => 1.0;
  @override
  bool get popupInstantScroll => false;
  @override
  double get popupInstantScrollWheelStep => 0.5;
  @override
  double get popupInstantScrollTouchStep => 0.25;
  @override
  bool get compactGlossaries => false;
  @override
  bool get dictionaryUnifiedStyle => true;
  @override
  int get popupDictionaryColumns => 1;
  @override
  int get popupAutoExpandDictionaries => 0;
  @override
  bool get deduplicatePitchAccents => false;
  @override
  bool get harmonicFrequency => false;
  @override
  bool get showExpressionTags => false;
  @override
  bool get collapseDictionaries => false;
  @override
  List<Dictionary> get dictionaries => const <Dictionary>[];
  @override
  Map<String, String> get customDictCSS => const <String, String>{};
  @override
  String get globalDictCSS => '';
}

final GlobalKey<DictionaryPopupWebViewState> _webViewKey =
    GlobalKey<DictionaryPopupWebViewState>();

Widget _host({
  required bool visible,
  required bool isSearching,
  required DictionarySearchResult? result,
}) {
  const Size screen = Size(800, 600);
  return ProviderScope(
    overrides: <Override>[appProvider.overrideWith((ref) => _AppModel())],
    child: TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              parkedPopupLayer(
                pos: const Rect.fromLTWH(10, 10, 360, 360),
                visible: visible,
                screen: screen,
                child: DictionaryPopupLayer(
                  result: result,
                  isSearching: isSearching,
                  keepWebViewWarm: true,
                  webViewKey: _webViewKey,
                  onDismiss: () {},
                  onTextSelected: (String _, Rect __) {},
                  onLinkClick: (String _, Rect __) {},
                  onMineEntry: (Map<String, String> _) async =>
                      const MinePopupResult(),
                  onDuplicateCheck: (String _, String __) async => false,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

bool _injectedPending(WidgetTester tester) => tester
    .widget<DictionaryPopupWebView>(find.byType(DictionaryPopupWebView))
    .lookupPending;

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  final DictionarySearchResult hit = DictionarySearchResult(
    searchTerm: 'あ',
    entries: <DictionaryEntry>[
      DictionaryEntry(word: '亜', reading: 'あ', meaning: 'sub'),
    ],
  );

  testWidgets('停驻 seed → 激活查词 → 结果到达 → 复位：pending false/true/false/false', (
    WidgetTester tester,
  ) async {
    // 停驻空闲（seed）：占位单例，层在屏外。
    await tester.pumpWidget(_host(
      visible: false,
      isSearching: false,
      result: kPopupSearchingPlaceholderResult,
    ));
    expect(_injectedPending(tester), false);
    final State<DictionaryPopupWebView>? seeded = _webViewKey.currentState;

    // 复用热槽激活查词：结果对象仍是同一个占位单例，只有查询状态与可见性在变。
    await tester.pumpWidget(_host(
      visible: true,
      isSearching: true,
      result: kPopupSearchingPlaceholderResult,
    ));
    expect(_injectedPending(tester), true);
    expect(identical(_webViewKey.currentState, seeded), true,
        reason: '同一个热槽 WebView，靠 lookupPending 独立比较触发重推');

    await tester.pumpWidget(_host(visible: true, isSearching: false, result: hit));
    expect(_injectedPending(tester), false, reason: '结果到达即 pending=false');

    await tester.pumpWidget(_host(
      visible: false,
      isSearching: false,
      result: kPopupSearchingPlaceholderResult,
    ));
    expect(_injectedPending(tester), false, reason: '关栈复位回停驻空闲');
  });

  testWidgets('查询中但层被挪到屏外（对话框 / 就绪才显示）：pending=false', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(
      visible: false,
      isSearching: true,
      result: kPopupSearchingPlaceholderResult,
    ));
    expect(_injectedPending(tester), false);
  });

  test('buildPopupEntriesJs 不再按占位单例身份推 pending', () {
    expect(
      buildPopupEntriesJs(kPopupSearchingPlaceholderResult),
      contains('window.lookupPending = false;'),
      reason: '停驻 / seed / 复位的占位是空闲',
    );
    expect(
      buildPopupEntriesJs(kPopupSearchingPlaceholderResult, pending: true),
      contains('window.lookupPending = true;'),
    );
    expect(
      buildPopupEntriesJs(hit),
      contains('window.lookupPending = false;'),
    );
  });
}
