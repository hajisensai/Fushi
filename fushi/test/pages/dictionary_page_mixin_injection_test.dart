import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_resource_source.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show DictionaryPopupWebViewState;
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../helpers/fake_inappwebview_platform.dart';
import '../helpers/test_platform_services.dart';

/// [DictionaryPageMixin] 的数据源 / 发音 / 词典资源注入点：手机字幕遥控器靠它们把
/// 同一个弹框接到电脑的词典上。三条查词路径（首查 / 加载更多 / 原地跳转）都必须只
/// 走 [DictionaryPageMixin.searchPopupDictionary]，一条漏了就会悄悄查回手机本机。
class _LocalSearchForbiddenAppModel extends AppModel {
  _LocalSearchForbiddenAppModel() : super(testPlatformServices());

  int localSearches = 0;

  @override
  int get maximumTerms => 10;
  @override
  double get popupMaxWidth => 360;
  @override
  double get popupMaxHeight => 360;
  @override
  double get dictionaryFontSize => 16;
  @override
  bool get popupBottomDocked => false;
  @override
  double get appUiScale => 1.0;
  @override
  List<String> get enabledAudioSources => const <String>[];
  @override
  void addToDictionaryHistory({required DictionarySearchResult result}) {}
  @override
  void addToSearchHistory({
    required String historyKey,
    required String searchTerm,
  }) {}

  @override
  Future<DictionarySearchResult> searchDictionary({
    required String searchTerm,
    required bool searchWithWildcards,
    int? overrideMaximumTerms,
    bool useCache = true,
    bool allowRemoteLookup = true,
  }) async {
    localSearches++;
    return DictionarySearchResult(searchTerm: searchTerm);
  }
}

class _StubResources implements DictionaryPopupResourceSource {
  @override
  Map<String, String> get dictionaryStyles => const <String, String>{};
  @override
  Future<DictionaryPopupMedia?> mediaFile(String d, String p) async => null;
  @override
  Future<String?> wordAudioRef(String e, String r) async => null;
}

class _Host extends ConsumerStatefulWidget {
  const _Host({super.key});
  @override
  ConsumerState<_Host> createState() => _HostState();
}

class _HostState extends ConsumerState<_Host> with DictionaryPageMixin {
  final DictionaryPopupController controller = DictionaryPopupController(
    lowMemory: false,
  );
  final List<({String term, int maximumTerms, List<FushiRubySpan> ruby})>
  searches = <({String term, int maximumTerms, List<FushiRubySpan> ruby})>[];
  final List<String> played = <String>[];
  final _StubResources resources = _StubResources();

  @override
  AppModel get mixinAppModel => ref.read(appProvider);
  @override
  ThemeData get mixinTheme => Theme.of(context);
  @override
  DictionaryPopupResourceSource? get popupResourceSource => resources;

  @override
  Future<DictionarySearchResult> searchPopupDictionary({
    required String term,
    required int maximumTerms,
    List<FushiRubySpan> rubySpans = const <FushiRubySpan>[],
  }) async {
    searches.add((term: term, maximumTerms: maximumTerms, ruby: rubySpans));
    // 模拟引擎的读音排序：带了与「せわしい」吻合的来源 ruby 时它排前，否则按频率
    // 「いそがしい」在前。
    final bool rubyRanked = rubySpans.any(
      (FushiRubySpan s) => s.reading == 'せわ',
    );
    final List<String> readings = rubyRanked
        ? const <String>['せわしい', 'いそがしい']
        : const <String>['いそがしい', 'せわしい'];
    return DictionarySearchResult(
      searchTerm: term,
      truncated: true,
      headwordCount: 1,
      entries: <DictionaryEntry>[
        for (final String reading in readings)
          DictionaryEntry(word: term, reading: reading, meaning: 'm'),
      ],
    );
  }

  @override
  Future<bool> playPopupWordAudio(
    String expression,
    String reading,
    DictionaryPopupWebViewState? popupState,
  ) async {
    played.add('$expression/$reading');
    return true;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) {
      final Size screen = Size(constraints.maxWidth, constraints.maxHeight);
      return Stack(
        children: <Widget>[
          for (int i = 0; i < controller.entries.length; i++)
            buildNestedPopupLayer(
              index: i,
              screen: screen,
              controller: controller,
              onPush: (String text, Rect rect, List<FushiRubySpan> _) async =>
                  0,
              onPop: (int index) {},
            ),
        ],
      );
    },
  );
}

void main() {
  setUpAll(installFakeInAppWebViewPlatform);
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Future<(_HostState, _LocalSearchForbiddenAppModel)> pump(
    WidgetTester tester,
  ) async {
    final GlobalKey<_HostState> key = GlobalKey<_HostState>();
    final _LocalSearchForbiddenAppModel app = _LocalSearchForbiddenAppModel();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appProvider.overrideWith((Ref ref) => app)],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(body: _Host(key: key)),
          ),
        ),
      ),
    );
    return (key.currentState!, app);
  }

  testWidgets('first lookup, load-more and in-place jump all use the injected '
      'source', (WidgetTester tester) async {
    final (_HostState host, _LocalSearchForbiddenAppModel app) = await pump(
      tester,
    );

    await host.pushNestedPopup(
      query: '猫',
      selectionRect: const Rect.fromLTWH(10, 10, 4, 4),
      controller: host.controller,
      replaceStack: true,
    );
    await tester.pump();
    final DictionaryPopupEntry entry = host.controller.entries.single;

    await host.loadMoreForEntry(entry: entry, controller: host.controller);
    await tester.pump();

    await host.navigatePopupInPlace(
      controller: host.controller,
      index: 0,
      entry: entry,
      query: '犬',
    );
    await tester.pump();

    expect(host.searches.map((s) => s.term), <String>['猫', '猫', '犬']);
    // 加载更多按词头递增（BUG-1478），预算照常由 mixin 算好再交给注入点。
    expect(host.searches[1].maximumTerms, 11);
    expect(app.localSearches, 0, reason: '注入后不得再查本机词典');
    // 冷建 WebView 的翻可见兜底计时（1.8s）在测试里没有 popupRendered 来收。
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('load-more 带着首查的来源 ruby 续查：读音排序在整份替换后不丢', (
    WidgetTester tester,
  ) async {
    final (_HostState host, _) = await pump(tester);
    const List<FushiRubySpan> ruby = <FushiRubySpan>[
      FushiRubySpan(start: 0, end: 1, reading: 'せわ'),
    ];
    // 句首空白随查询串 trim 平移：坐标系以 trim 后的「忙しい」为准。
    await host.pushNestedPopup(
      query: ' 忙しい',
      selectionRect: const Rect.fromLTWH(10, 10, 4, 4),
      controller: host.controller,
      replaceStack: true,
      rubySpans: const <FushiRubySpan>[
        FushiRubySpan(start: 1, end: 2, reading: 'せわ'),
      ],
    );
    await tester.pump();
    final DictionaryPopupEntry entry = host.controller.entries.single;
    expect(entry.rubySpans, ruby);
    List<String?> readings() =>
        entry.result!.entries.map((DictionaryEntry e) => e.reading).toList();
    expect(readings(), <String>['せわしい', 'いそがしい']);

    await host.loadMoreForEntry(entry: entry, controller: host.controller);
    await tester.pump();
    expect(host.searches.last.ruby, ruby, reason: '续查必须带首查那组 ruby');
    expect(readings(), <String>['せわしい', 'いそがしい'], reason: '加载更多后顺序不变');

    // 原地跳到别的词（链接点击没有来源 ruby）→ 本层 ruby 清空；后退回原词 → ruby
    // 随历史页恢复，此后加载更多仍按读音排序。
    await host.navigatePopupInPlace(
      controller: host.controller,
      index: 0,
      entry: entry,
      query: '犬',
    );
    await tester.pump();
    expect(entry.searchTerm, '犬');
    expect(entry.rubySpans, isEmpty);
    expect(host.controller.goBack(entry, scrollTop: 0), isTrue);
    expect(entry.searchTerm, '忙しい');
    expect(entry.rubySpans, ruby);
    await host.loadMoreForEntry(entry: entry, controller: host.controller);
    await tester.pump();
    expect(host.searches.last.ruby, ruby);
    expect(readings(), <String>['せわしい', 'いそがしい']);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('auto-read plays through the injected word-audio hook', (
    WidgetTester tester,
  ) async {
    final (_HostState host, _) = await pump(tester);
    await host.autoReadWord('猫', 'ねこ');
    expect(host.played, <String>['猫/ねこ']);
  });

  testWidgets('every popup layer receives the injected resource source', (
    WidgetTester tester,
  ) async {
    final (_HostState host, _) = await pump(tester);
    await host.pushNestedPopup(
      query: '猫',
      selectionRect: const Rect.fromLTWH(10, 10, 4, 4),
      controller: host.controller,
      replaceStack: true,
    );
    await tester.pump();
    final DictionaryPopupLayer layer = tester.widget<DictionaryPopupLayer>(
      find.byType(DictionaryPopupLayer),
    );
    expect(identical(layer.resourceSource, host.resources), isTrue);
    await tester.pump(const Duration(seconds: 2));
  });
}
