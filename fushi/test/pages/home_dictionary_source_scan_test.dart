import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_dictionary_page.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/components/clipboard_lookup_text_panel.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../helpers/fake_inappwebview_platform.dart';
import '../helpers/test_platform_services.dart';

/// 源文本条点字 = Yomitan 式**扫描**：整句留在条上、留在搜索框里，变的只有下方那份
/// 查词结果和条上的高亮跨度。
///
/// 之前这里是「往后扫描 + 在此基础上嵌套查词」：点一个字压一张浮在字上的查词卡
/// （`_pushNestedPopup`），同一次查词裂成两个可见面——条上的高亮挪了，卡片盖在条下面
/// 另起一套结果，而页面本体那份结果还停在上一个词上；再点一个字又是一张卡。本组
/// 测试钉住改回同一份结果之后的不变量：**引擎吃后缀、条与框吃整句、栈不长高**。
class _ScanAppModel extends AppModel {
  _ScanAppModel() : super(testPlatformServices());

  final List<String> searchedTerms = <String>[];
  final List<int?> searchedLimits = <int?>[];

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
  bool get autoSearchEnabled => false;

  @override
  double get defaultDictionaryFontSize => 26;

  @override
  double get dictionaryFontSize => 26;

  @override
  double get appUiScale => 1.0;

  @override
  List<String> get enabledAudioSources => const <String>[];

  // 扫描查词会走朗读（与它取代的浮层路径同行为），朗读要读音频源配置，而那条读的是
  // 未初始化的 prefsRepo → 空断言炸。配一份空音频源让朗读原地无声返回，测的仍是
  // 查词状态机本身。
  @override
  List<AudioSourceConfig> get audioSourceConfigs => const <AudioSourceConfig>[];

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
    searchedLimits.add(overrideMaximumTerms);
    return DictionarySearchResult(
      searchTerm: searchTerm,
      entries: List<DictionaryEntry>.generate(
        10,
        (int i) => DictionaryEntry(word: '$searchTerm$i'),
      ),
      headwordCount: 10,
      truncated: true,
    );
  }
}

Widget _wrap(_ScanAppModel appModel) {
  return ProviderScope(
    overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: appModel.navigatorKey,
        builder: (BuildContext context, Widget? child) =>
            child ?? const SizedBox.shrink(),
        home: const Scaffold(body: HomeDictionaryPage()),
      ),
    ),
  );
}

HomeDictionarySearchDebug _debug(WidgetTester tester) =>
    tester.state(find.byType(HomeDictionaryPage)) as HomeDictionarySearchDebug;

SourceLookupTextPanel _panel(WidgetTester tester) =>
    tester.widget(find.byType(SourceLookupTextPanel));

String _searchBoxText(WidgetTester tester) {
  final FushiSearchField field = tester.widget(find.byType(FushiSearchField));
  return field.controller.text;
}

/// 派发一次查词并把 microtask 排空（假 AppModel 立即返回，无需真实时钟）。
Future<void> _settle(WidgetTester tester, [Future<void>? dispatched]) async {
  await tester.runAsync(() async {
    if (dispatched != null) await dispatched;
  });
  await tester.pump();
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
    'long in-app source scrolls in its own bounded viewport; definitions keep '
    'a fixed size',
    (tester) async {
      final _ScanAppModel appModel = _ScanAppModel();
      final String text = List<String>.generate(
        1600,
        (int i) => String.fromCharCode(0x4e00 + i),
      ).join();
      await tester.pumpWidget(_wrap(appModel));
      await tester.pump();
      await _settle(tester, _debug(tester).debugSearch(text));
      final Finder content = find.byKey(
        const ValueKey<String>('home_dictionary_content'),
      );
      final Finder sourceViewport = find.byKey(
        const ValueKey<String>('home_dictionary_source_scroll'),
      );
      final Finder scrollable = find
          .descendant(of: sourceViewport, matching: find.byType(Scrollable))
          .first;
      final ScrollableState state = tester.state<ScrollableState>(scrollable);
      final Finder webView = find.descendant(
        of: content,
        matching: find.byType(DictionaryPopupWebView),
      );
      expect(webView, findsOneWidget);
      // 结果区 = WebView 所在的 Stack（Expanded 撑满的那块固定区域）。
      final Finder definitions = find
          .ancestor(of: webView, matching: find.byType(Stack))
          .first;
      // 原文限高：视口不超过卡身的一半，长原文只能在视口里滚。
      final double viewportHeight = tester.getSize(sourceViewport).height;
      expect(viewportHeight, greaterThan(0));
      expect(
        viewportHeight,
        lessThanOrEqualTo(
          tester.getSize(content).height * kInAppSourceViewportFraction + 0.5,
        ),
      );
      expect(state.position.maxScrollExtent, greaterThan(0));
      final Rect definitionsBefore = tester.getRect(definitions);
      expect(definitionsBefore.height, greaterThan(0));
      expect(
        definitionsBefore.top,
        greaterThanOrEqualTo(tester.getRect(sourceViewport).bottom),
      );

      final int queries = appModel.searchedTerms.length;
      await tester.scrollUntilVisible(
        find.text(text[1599]),
        250,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(state.position.pixels, greaterThan(0));
      expect(
        appModel.searchedTerms.length,
        queries,
        reason: 'scrolling must not query a glyph',
      );
      // 原文在自己的视口里滚，结果区不跟着改尺寸（TODO-1152）、始终在原文视口下方。
      // （位置可随宿主收起底栏等整页布局平移，那不是本区域在逐帧 resize。）
      void expectDefinitionsStable() {
        expect(tester.getSize(definitions), definitionsBefore.size);
        expect(
          tester.getRect(definitions).top,
          greaterThanOrEqualTo(tester.getRect(sourceViewport).bottom),
        );
      }

      expectDefinitionsStable();

      await tester.tap(find.text(text[1599]));
      await _settle(tester);
      expect(appModel.searchedTerms.last, text.substring(1599));
      expect(_panel(tester).text, text);
      expect(_panel(tester).highlight?.start, 1599);
      expectDefinitionsStable();

      // 真实拖动手势能把原文滚回开头（原文视口一直露在结果区上方）。
      final double scrolled = state.position.pixels;
      await tester.drag(sourceViewport, const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(state.position.pixels, lessThan(scrolled));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('点源文本条的字：引擎吃「从该字起的后缀」，条上与搜索框里的整句都不动', (
    WidgetTester tester,
  ) async {
    final _ScanAppModel appModel = _ScanAppModel();
    await tester.pumpWidget(_wrap(appModel));
    await tester.pump();

    await _settle(tester, _debug(tester).debugSearch('と言いつつ'));

    expect(_panel(tester).text, 'と言いつつ');
    expect(_searchBoxText(tester), 'と言いつつ');
    expect(_panel(tester).highlight?.start, 0, reason: '主查词的命中段锚在条首。');
    expect(appModel.searchedTerms, <String>['と言いつつ']);

    // 点第 2 个字「言」（字素簇下标 1）。
    await tester.tap(find.text('言'));
    await _settle(tester);
    await _settle(tester);

    expect(appModel.searchedTerms.last, '言いつつ', reason: '扫描查词交给引擎的是从被点字起的后缀。');
    expect(
      _panel(tester).text,
      'と言いつつ',
      reason:
          '条上必须留着整句：换成后缀就把被点字左边的上下文丢了，'
          '再想点回「と」已经没得点。',
    );
    expect(_searchBoxText(tester), 'と言いつつ', reason: '搜索框是用户输入的整句，扫描查词不接管它。');
    expect(
      _panel(tester).highlight?.start,
      1,
      reason: '高亮锚在被点的那个字素簇上（Yomitan 的扫描高亮）。',
    );
    expect(
      _debug(tester).debugPopupStackShape.depth,
      0,
      reason: '扫描换的是下方那份结果，不再压一张浮在字上的查词卡。',
    );
  });

  testWidgets('扫描查词后「加载更多」加载的是眼下这份结果的查询串，不是搜索框里的整句', (
    WidgetTester tester,
  ) async {
    final _ScanAppModel appModel = _ScanAppModel();
    await tester.pumpWidget(_wrap(appModel));
    await tester.pump();

    await _settle(tester, _debug(tester).debugSearch('と言いつつ'));
    await tester.tap(find.text('言'));
    await _settle(tester);
    await _settle(tester);
    expect(appModel.searchedTerms.last, '言いつつ');

    await _settle(tester, _debug(tester).debugLoadMore());

    expect(
      appModel.searchedTerms.last,
      '言いつつ',
      reason:
          '滚到底只该要更多同一个词的词头；拿搜索框里的整句去加载更多，'
          '用户会看见结果被悄悄掉包成另一个词的。',
    );
    expect(
      appModel.searchedLimits.last,
      greaterThan(10),
      reason: '加载更多必须把词头上限调大。',
    );
    expect(
      _panel(tester).highlight?.start,
      1,
      reason: '加载更多不换源文本，也就不该把高亮弹回句首。',
    );
  });

  testWidgets('点回条首那个字：整句与搜索框仍不动，高亮回到 0', (WidgetTester tester) async {
    final _ScanAppModel appModel = _ScanAppModel();
    await tester.pumpWidget(_wrap(appModel));
    await tester.pump();

    await _settle(tester, _debug(tester).debugSearch('と言いつつ'));
    await tester.tap(find.text('言'));
    await _settle(tester);
    await _settle(tester);
    expect(_panel(tester).highlight?.start, 1);

    await tester.tap(find.text('と'));
    await _settle(tester);
    await _settle(tester);

    expect(appModel.searchedTerms.last, 'と言いつつ');
    expect(_panel(tester).text, 'と言いつつ');
    expect(_searchBoxText(tester), 'と言いつつ');
    expect(_panel(tester).highlight?.start, 0);
    expect(_debug(tester).debugPopupStackShape.depth, 0);
  });

  test('源码守卫：源文本条的 onLookup 走主查词管线，不再压嵌套浮层', () {
    final String page = File(
      'lib/src/pages/implementations/home_dictionary_page.dart',
    ).readAsStringSync();

    final int panelStart = page.indexOf('SourceLookupTextPanel(');
    expect(panelStart, greaterThan(0), reason: '首页词典 tab 必须挂源文本条。');
    final int panelEnd = page.indexOf('Expanded(', panelStart);
    expect(panelEnd, greaterThan(panelStart));
    final String wiring = page.substring(panelStart, panelEnd);

    expect(
      wiring.contains('_lookupFromSourceStrip('),
      isTrue,
      reason: '点字必须走主查词管线，把下方那份结果整份换掉。',
    );
    expect(
      wiring.contains('_pushNestedPopup('),
      isFalse,
      reason:
          '点字压浮层会让同一次查词裂成两个可见面：条上高亮挪了、卡片另起一套'
          '结果，而页面本体那份结果还停在上一个词上。',
    );
    // 结果卡内部选词 / 点链是另一条入口，仍然走弹窗栈——别把它一起摘了。
    expect(
      page.contains('Future<int> _pushNestedPopup('),
      isTrue,
      reason: '结果 WebView 内部取词仍需嵌套浮层。',
    );
  });
}
