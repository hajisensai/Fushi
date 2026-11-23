import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/lookup/lookup_refine.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

/// 拍板台 Um72dWD9Cz（方案 B）：查词浮层「查不到」时把查询词拆成可点的词块 +
/// 「修改」输入框，点词块 / 改词后在同一层原地重查。
///
/// 三层守：① 切分（英文按空格 / 标点、CJK 交给词典最长匹配切、标点碎片丢弃、切分器
/// 失败整段兜底）；② 层（空态出词块与修改框、点 / 改的回调参数、结果页上方的词块行、
/// 不支持的宿主保持旧空态）；③ 控制器（词块来源随历史页保存 / 恢复、顶层换词清空）
/// 与三个建层宿主的接线。

/// 测试用切分器：按预置表切，表外整段一块；记下被调用的片段。
class _FakeTokenizer {
  _FakeTokenizer(this.table);

  final Map<String, List<String>> table;
  final List<List<String>> calls = <List<String>>[];

  Future<List<List<String>>> call(List<String> texts) async {
    calls.add(texts);
    return <List<String>>[
      for (final String t in texts) table[t] ?? <String>[t],
    ];
  }
}

Future<List<List<String>>> _throwingTokenizer(List<String> texts) async =>
    throw StateError('engine retired');

class _LayerAppModel extends AppModel {
  _LayerAppModel() : super(testPlatformServices());

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

Widget _host(Widget layer) {
  return ProviderScope(
    overrides: <Override>[appProvider.overrideWith((ref) => _LayerAppModel())],
    child: TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: Center(child: SizedBox(width: 360, height: 360, child: layer)),
        ),
      ),
    ),
  );
}

DictionaryPopupLayer _layer({
  required DictionarySearchResult result,
  void Function(String query, String refineSource)? onRefineQuery,
  String refineSource = '',
  LookupRefineTokenizer? tokenizer,
  bool keepWebViewWarm = false,
}) {
  return DictionaryPopupLayer(
    result: result,
    keepWebViewWarm: keepWebViewWarm,
    webViewKey: GlobalKey<DictionaryPopupWebViewState>(),
    onDismiss: () {},
    onTextSelected: (String _, Rect __, List<Object?> ___, String ____) {},
    onLinkClick: (String _, Rect __) {},
    onMineEntry: (Map<String, String> _) async => const MinePopupResult(),
    onDuplicateCheck: (String _, String __) async => false,
    onRefineQuery: onRefineQuery,
    refineSource: refineSource,
    refineTokenizer: tokenizer ?? _FakeTokenizer(const {}).call,
  );
}

Finder _chip(String text) =>
    find.byKey(ValueKey<String>('lookup-refine-chip-$text'));

DictionarySearchResult _found(String term) => DictionarySearchResult(
  searchTerm: term,
  entries: <DictionaryEntry>[
    DictionaryEntry(dictionaryName: 'd', word: term, reading: '', meaning: 'x'),
  ],
);

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('lookupRefineChips 切分', () {
    test('英文按空格拆，OCR 多带的词与认错的词各成一块', () async {
      final _FakeTokenizer tok = _FakeTokenizer(const {});
      expect(await lookupRefineChips('an vnusual case', tokenizer: tok.call), [
        'an',
        'vnusual',
        'case',
      ]);
      expect(tok.calls, isEmpty, reason: '纯拉丁片段不进词典切分');
    });

    test('标点 / 符号是分隔；词内撇号、连字符保留；去重保序', () async {
      expect(
        await lookupRefineChips(
          '「case」, don\'t—well-known case.',
          tokenizer: _FakeTokenizer(const {}).call,
        ),
        ['case', 'don\'t', 'well-known'],
      );
    });

    test('CJK 片段交给词典最长匹配切，切出的助词 / 标点碎片按词字符过滤', () async {
      final _FakeTokenizer tok = _FakeTokenizer(<String, List<String>>{
        'の東京タワーへ': <String>['の', '東京タワー', 'へ'],
      });
      expect(await lookupRefineChips('の東京タワーへ。', tokenizer: tok.call), [
        'の',
        '東京タワー',
        'へ',
      ]);
      expect(tok.calls, [
        ['の東京タワーへ'],
      ], reason: '所有 CJK 片段一次批量切（后台 isolate 一次往返）');
    });

    test('切分器失败：CJK 片段整段当一块，不丢词块', () async {
      expect(
        await lookupRefineChips('食べ物 case', tokenizer: _throwingTokenizer),
        ['食べ物', 'case'],
      );
    });

    test('块数封顶 kLookupRefineMaxChips', () async {
      final String many = List<String>.generate(40, (int i) => 'w$i').join(' ');
      expect(
        await lookupRefineChips(many, tokenizer: _FakeTokenizer(const {}).call),
        hasLength(kLookupRefineMaxChips),
      );
    });
  });

  group('DictionaryPopupLayer 空态', () {
    final DictionarySearchResult empty = DictionarySearchResult(
      searchTerm: 'an vnusual case',
    );

    testWidgets('宿主支持换词：出词块 + 修改；点词块回调（词块, 来源）', (WidgetTester tester) async {
      final List<(String, String)> calls = <(String, String)>[];
      await tester.pumpWidget(
        _host(
          _layer(
            result: empty,
            onRefineQuery: (String q, String s) => calls.add((q, s)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(_chip('an'), findsOneWidget);
      expect(_chip('vnusual'), findsOneWidget);
      expect(_chip('case'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('lookup-refine-edit')),
        findsOne,
      );
      expect(find.text(t.dictionary_popup_refine_hint), findsOneWidget);

      await tester.tap(_chip('case'));
      await tester.pump();
      expect(calls, [('case', 'an vnusual case')]);
    });

    testWidgets('修改：展开预填输入框，提交 = （改后的词, 改后的词）', (WidgetTester tester) async {
      final List<(String, String)> calls = <(String, String)>[];
      await tester.pumpWidget(
        _host(
          _layer(
            result: empty,
            onRefineQuery: (String q, String s) => calls.add((q, s)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('lookup-refine-edit')),
      );
      await tester.pumpAndSettle();
      final Finder field = find.byType(EditableText);
      expect(field, findsOneWidget);
      expect(
        tester.widget<EditableText>(field).controller.text,
        empty.searchTerm,
      );

      await tester.enterText(field, '  unusual ');
      await tester.tap(
        find.byKey(const ValueKey<String>('lookup-refine-submit')),
      );
      await tester.pumpAndSettle();
      expect(calls, [('unusual', 'unusual')]);
      expect(find.byType(EditableText), findsNothing, reason: '提交后收回成词块');
    });

    testWidgets('从词块点进来、仍查不到：词块仍按来源拆，当前词高亮', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          _layer(
            result: DictionarySearchResult(searchTerm: 'vnusual'),
            refineSource: 'an vnusual case',
            onRefineQuery: (String _, String __) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_chip('an'), findsOneWidget);
      expect(_chip('case'), findsOneWidget);
      expect(tester.widget<FushiChoiceChip>(_chip('vnusual')).selected, isTrue);
      expect(tester.widget<FushiChoiceChip>(_chip('case')).selected, isFalse);
    });

    testWidgets('宿主不支持换词（onRefineQuery 为 null）：空态与旧行为一致', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_host(_layer(result: empty)));
      await tester.pumpAndSettle();
      expect(find.byType(LookupRefinePanel), findsNothing);
      expect(find.text(t.settings_search_empty_hint), findsOneWidget);
    });
  });

  group('DictionaryPopupLayer 结果页词块行', () {
    testWidgets('有词块来源的结果页：上方一行词块，点进来的词高亮，可接着换词', (WidgetTester tester) async {
      final List<(String, String)> calls = <(String, String)>[];
      await tester.pumpWidget(
        _host(
          _layer(
            result: _found('case'),
            refineSource: 'an vnusual case',
            keepWebViewWarm: true,
            onRefineQuery: (String q, String s) => calls.add((q, s)),
          ),
        ),
      );
      // 词块异步切完 → AnimatedSize 长开 → 错峰进场：逐帧推到动画落定（WebView
      // 层有常驻动画，不能 pumpAndSettle）。
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.byKey(const ValueKey<String>('lookup-refine-bar')), findsOne);
      expect(tester.widget<FushiChoiceChip>(_chip('case')).selected, isTrue);
      await tester.tap(_chip('case'));
      await tester.pump();
      expect(calls, isEmpty, reason: '点当前词不重查');
      await tester.tap(_chip('an'));
      await tester.pump();
      expect(calls, [('an', 'an vnusual case')]);
    });

    testWidgets('普通结果页（无词块来源）：不画词块行，WebView 树深度不变', (
      WidgetTester tester,
    ) async {
      final GlobalKey<DictionaryPopupWebViewState> key =
          GlobalKey<DictionaryPopupWebViewState>();
      DictionaryPopupLayer layer(String source) => DictionaryPopupLayer(
        result: _found('case'),
        keepWebViewWarm: true,
        webViewKey: key,
        onDismiss: () {},
        onTextSelected: (String _, Rect __, List<Object?> ___, String ____) {},
        onLinkClick: (String _, Rect __) {},
        onMineEntry: (Map<String, String> _) async => const MinePopupResult(),
        onDuplicateCheck: (String _, String __) async => false,
        onRefineQuery: (String _, String __) {},
        refineSource: source,
        refineTokenizer: _FakeTokenizer(const {}).call,
      );
      await tester.pumpWidget(_host(layer('')));
      await tester.pump();
      expect(find.byType(LookupRefinePanel), findsNothing);
      final State<DictionaryPopupWebView>? before = key.currentState;
      expect(before, isNotNull);

      await tester.pumpWidget(_host(layer('an vnusual case')));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(LookupRefinePanel), findsOneWidget);
      expect(
        identical(key.currentState, before),
        isTrue,
        reason: '词块行出现 / 消失不得让 WebView 搬家重建',
      );
    });
  });

  group('DictionaryPopupController 词块来源', () {
    test('换词记来源与原句；后退回到空态页、前进再回来都带着各自的来源', () {
      final DictionaryPopupController c = DictionaryPopupController(
        lowMemory: true,
      );
      final DictionaryPopupEntry e = c.beginTop(
        term: 'an vnusual case',
        rect: Rect.zero,
        reuseWarmSlot: false,
        replaceStack: true,
        visible: true,
        contextSentence: 'It was an vnusual case of the disease.',
      );
      c.fillResult(
        e,
        result: DictionarySearchResult(searchTerm: 'an vnusual case'),
        allLoaded: true,
      );

      expect(
        c.navigateInPlace(
          e,
          term: 'case',
          result: _found('case'),
          allLoaded: true,
          scrollTop: 0,
          refineSource: 'an vnusual case',
          contextSentence: e.contextSentence,
        ),
        isTrue,
      );
      expect(e.refineSource, 'an vnusual case');
      expect(e.contextSentence, 'It was an vnusual case of the disease.');

      expect(c.goBack(e, scrollTop: 0), isTrue);
      expect(e.searchTerm, 'an vnusual case');
      expect(e.refineSource, isEmpty);

      expect(c.goForward(e, scrollTop: 0), isTrue);
      expect(e.searchTerm, 'case');
      expect(e.refineSource, 'an vnusual case');

      c.beginTop(
        term: '別',
        rect: Rect.zero,
        reuseWarmSlot: false,
        replaceStack: true,
        visible: true,
      );
      expect(c.entries.single.refineSource, isEmpty, reason: '顶层换词不带旧来源');
    });
  });

  group('宿主接线源码守卫', () {
    String read(String path) =>
        File(path).readAsStringSync().replaceAll('\r\n', '\n');

    test('三个建层宿主都接 onRefineQuery + refineSource', () {
      const Map<String, String> hosts = <String, String>{
        'base_source_page': 'lib/src/pages/base_source_page.dart',
        'dictionary_page_mixin':
            'lib/src/pages/implementations/dictionary_page_mixin.dart',
        'popup_dictionary_page':
            'lib/src/pages/implementations/popup_dictionary_page.dart',
      };
      hosts.forEach((String name, String path) {
        final String src = read(path);
        expect(
          RegExp(
            r'onRefineQuery:\s*\(String query, String source\)\s*=>[\s\S]{0,320}?'
            r'refineSource: source',
          ).hasMatch(src),
          isTrue,
          reason: '$name 必须把词块换词接到原地跳转并带上来源',
        );
        expect(
          src.contains('refineSource: entry.refineSource') ||
              src.contains('refineSource: item.refineSource'),
          isTrue,
          reason: '$name 必须把本页词块来源传进层',
        );
      });
    });

    test('两份 navigatePopupInPlace：换词时空结果也换、沿用原句', () {
      for (final String path in <String>[
        'lib/src/pages/base_source_page.dart',
        'lib/src/pages/implementations/dictionary_page_mixin.dart',
      ]) {
        final String src = read(path);
        final int start = src.indexOf('Future<void> navigatePopupInPlace(');
        final String fn = src.substring(start, src.indexOf('\n  }\n', start));
        expect(
          fn.contains('if (empty && refineSource == null) return;'),
          isTrue,
        );
        expect(fn.contains("refineSource: refineSource ?? ''"), isTrue);
        expect(fn.contains('.contextSentence,'), isTrue, reason: path);
      }
    });
  });
}
