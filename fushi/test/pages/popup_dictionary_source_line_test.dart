import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/lookup/effective_lookup_size.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/popup_main.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/popup_dictionary_page.dart';
import 'package:fushi/src/utils/components/clipboard_lookup_text_panel.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../helpers/test_platform_services.dart';
import '../helpers/popup_mining_target_overrides.dart';

/// BUG-2899 / BUG-2900：截屏识字 / 悬浮字幕点字把「被点字所在的整行 + 被点字下标」
/// 交给 app 外查词窗。查词窗必须：
///   - 源文本条保留整行（此前宿主先切成单词，整行就此丢失，条上只剩那个词）；
///   - 首查从被点字起做扫描查词，高亮锚在被点字上；
///   - 制卡时用整行补 `{sentence}`（此前句子恒空）。
/// 真页面 + 假词典 + 假 Anki 仓库跑，查词与制卡两段真实代码都在测试路径上。
class _SourceLineAppModel extends AppModel {
  _SourceLineAppModel() : super(testPlatformServices());

  final List<String> searched = <String>[];

  /// 这些查询串返回一条汉字结果（其余一律空结果）：原地跳转（[navigatePopupInPlace]）
  /// 只在有结果时才换词，汉字结果不触发自动朗读，测试路径最短。
  final Set<String> kanjiHits = <String>{};

  /// Query -> headword of the one term entry it returns.
  final Map<String, String> wordHits = <String, String>{};

  /// A term entry triggers auto-read on lookup: no audio sources here.
  @override
  List<AudioSourceConfig> get audioSourceConfigs => const <AudioSourceConfig>[];

  @override
  bool get isInitialised => true;

  @override
  Future<bool> refreshPrefCacheIfChanged() async => false;

  @override
  Future<bool> refreshForWarmDictionaryPopup() async => false;

  @override
  ThemeData get theme => ThemeData.light();

  @override
  ThemeData get darkTheme => ThemeData.dark();

  @override
  ThemeMode get themeMode => ThemeMode.light;

  @override
  bool get lowMemoryMode => false;

  @override
  int get maximumTerms => 10;

  @override
  double get popupMaxWidth => 400;

  // 外部查词卡宽高读「app 外覆盖窗有效最大宽高」（K9YPrjtZE1），本桩没有 prefsRepo。
  @override
  LookupSize get overlayLookupEffectiveSize =>
      LookupSize(popupMaxWidth, kLookupPopupDefaultHeight);

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
    searched.add(searchTerm);
    final String? word = wordHits[searchTerm];
    if (word != null) {
      return DictionarySearchResult(
        searchTerm: searchTerm,
        entries: <DictionaryEntry>[
          DictionaryEntry(word: word, reading: '', meaning: 'm'),
        ],
      );
    }
    if (kanjiHits.contains(searchTerm)) {
      return DictionarySearchResult(
        searchTerm: searchTerm,
        kanjiResults: <FushiKanjiResult>[
          FushiKanjiResult(
            character: searchTerm,
            onyomi: '',
            kunyomi: '',
            radical: '',
            strokes: 0,
            meanings: const <String>[],
            dictName: 'test',
          ),
        ],
      );
    }
    return DictionarySearchResult(searchTerm: searchTerm);
  }
}

class _RecordingAnkiRepo extends BaseAnkiRepository {
  final List<AnkiMiningContext> contexts = <AnkiMiningContext>[];
  final List<Map<String, dynamic>> payloads = <Map<String, dynamic>>[];

  @override
  Future<AnkiSettings> loadSettings() async => AnkiSettings();

  @override
  Future<void> saveSettings(AnkiSettings s) async {}

  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('unused');

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    contexts.add(context);
    payloads.add(jsonDecode(rawPayloadJson) as Map<String, dynamic>);
    return MineOutcome.failure('recorded');
  }

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;

  @override
  Future<bool> createDeck(String name) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;
}

Widget _buildApp({
  required AppModel appModel,
  required BaseAnkiRepository repo,
  required String text,
  required int charIndex,
  String? sourceBlock,
  int sourceBlockOffset = -1,
  ValueChanged<String>? onHeadword,
  bool sourceTextCollapsed = false,
  bool embedded = false,
}) {
  return ProviderScope(
    overrides: [
      appProvider.overrideWith((ref) => appModel),
      ankiRepositoryProvider.overrideWithValue(repo),
      ...popupMiningTargetTestOverrides(anki: false),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: appModel.navigatorKey,
        home: PopupDictionaryPage(
          searchTerm: text,
          sourceCharIndex: charIndex,
          sourceBlock: sourceBlock,
          sourceBlockOffset: sourceBlockOffset,
          sourceTextCollapsed: sourceTextCollapsed,
          embedded: embedded,
          closeInApp: () {},
          onHeadword: onHeadword,
        ),
      ),
    ),
  );
}

/// 宿主推来的一次查词（整行 + 被点字下标），与 popup_main 透传给页面的字段同形。
class _Push {
  const _Push(this.text, this.charIndex, this.generation);

  final String text;
  final int charIndex;
  final int generation;
}

/// 常驻同一个 [PopupDictionaryPage] State、经 didUpdateWidget 反复推新词——与 :popup
/// 引擎常驻时第二次及以后的查词同一条路径。
Widget _buildHostedApp({
  required AppModel appModel,
  required BaseAnkiRepository repo,
  required ValueNotifier<_Push> push,
}) {
  return ProviderScope(
    overrides: [
      appProvider.overrideWith((ref) => appModel),
      ankiRepositoryProvider.overrideWithValue(repo),
      ...popupMiningTargetTestOverrides(anki: false),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: appModel.navigatorKey,
        home: ValueListenableBuilder<_Push>(
          valueListenable: push,
          builder: (BuildContext context, _Push value, Widget? _) =>
              PopupDictionaryPage(
                searchTerm: value.text,
                searchGeneration: value.generation,
                sourceCharIndex: value.charIndex,
                closeInApp: () {},
              ),
        ),
      ),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

/// 原文条里的那个字。查不到结果时空态会把查询词拆成可点的词块
/// （`LookupRefinePanel`，拍板台 Um72dWD9Cz），同一个字会在词块里再出现一次，
/// 所以按字找必须限定在原文条 [SourceLookupTextPanel] 里。
Finder _sourceGlyph(String glyph) => find.descendant(
  of: find.byType(SourceLookupTextPanel),
  matching: find.text(glyph),
);

DictionaryPopupLayer _baseLayer(WidgetTester tester) =>
    tester.widget(find.byType(DictionaryPopupLayer).first);

Future<String?> _mineSentence(
  WidgetTester tester,
  _RecordingAnkiRepo repo,
) async {
  final DictionaryPopupLayer base = _baseLayer(tester);
  final int before = repo.contexts.length;
  await tester.runAsync(
    () =>
        base.onMineEntry!(<String, String>{'expression': 'x', 'sentence': ''}),
  );
  expect(repo.contexts.length, before + 1);
  return repo.contexts.last.sentence;
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets(
    'embedded dictionary bounds the source like the external popup and keeps '
    'definitions at a fixed size',
    (tester) async {
      final String text = List<String>.generate(
        1600,
        (int i) => String.fromCharCode(0x4e00 + i),
      ).join();
      final _SourceLineAppModel appModel = _SourceLineAppModel();
      await tester.pumpWidget(
        _buildApp(
          appModel: appModel,
          repo: _RecordingAnkiRepo(),
          text: text,
          charIndex: 0,
          embedded: true,
        ),
      );
      await _settle(tester);
      final Finder viewport = find.byKey(
        const ValueKey<String>('popup_source_scroll'),
      );
      expect(viewport, findsOneWidget);
      final Finder scrollable = find
          .descendant(of: viewport, matching: find.byType(Scrollable))
          .first;
      final ScrollableState state = tester.state<ScrollableState>(scrollable);
      final double viewportHeight = tester.getSize(viewport).height;
      expect(viewportHeight, greaterThan(0));
      expect(
        tester.getSize(find.byType(SourceLookupTextPanel)).height,
        greaterThan(viewportHeight),
      );
      final Finder definitions = find.byType(DictionaryPopupLayer).first;
      final Rect definitionsBefore = tester.getRect(definitions);
      expect(definitionsBefore.height, greaterThan(0));
      expect(
        definitionsBefore.top,
        greaterThanOrEqualTo(tester.getRect(viewport).bottom),
      );
      await tester.scrollUntilVisible(
        find.text(text[1599]),
        250,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(state.position.pixels, greaterThan(0));
      expect(tester.getRect(definitions), definitionsBefore);
      await tester.tap(find.text(text[1599]));
      await _settle(tester);
      expect(appModel.searched.last, text.substring(1599));
      expect(
        tester
            .widget<SourceLookupTextPanel>(find.byType(SourceLookupTextPanel))
            .text,
        text,
      );
      expect(tester.getRect(definitions), definitionsBefore);
      final double scrolled = state.position.pixels;
      await tester.drag(viewport, const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(state.position.pixels, lessThan(scrolled));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'source selection stays visible when the external window shrinks',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(500, 700);
      addTearDown(tester.view.reset);
      final String text = List<String>.generate(
        400,
        (int i) => String.fromCharCode(0x4e00 + i),
      ).join();
      await tester.pumpWidget(
        _buildApp(
          appModel: _SourceLineAppModel(),
          repo: _RecordingAnkiRepo(),
          text: text,
          charIndex: 360,
        ),
      );
      await _settle(tester);
      tester.view.physicalSize = const Size(700, 300);
      await tester.pumpAndSettle();
      final Finder viewport = find.byKey(
        const ValueKey<String>('popup_source_scroll'),
      );
      expect(
        tester
            .getRect(viewport)
            .contains(tester.getCenter(_sourceGlyph(text[360]))),
        isTrue,
      );
      expect(
        tester.getSize(find.byType(DictionaryPopupLayer).first).height,
        greaterThan(0),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'collapsed source keeps the complete mining sentence and can reopen',
    (tester) async {
      final _SourceLineAppModel appModel = _SourceLineAppModel();
      final _RecordingAnkiRepo repo = _RecordingAnkiRepo();
      const String text = '今日は良い天気ですね';
      await tester.pumpWidget(
        _buildApp(
          appModel: appModel,
          repo: repo,
          text: text,
          charIndex: 5,
          sourceTextCollapsed: true,
        ),
      );
      await _settle(tester);
      expect(find.byType(SourceLookupTextPanel), findsNothing);
      expect(await _mineSentence(tester, repo), text);
      await tester.tap(
        find.byKey(const ValueKey<String>('popup_source_toggle')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SourceLookupTextPanel>(find.byType(SourceLookupTextPanel))
            .text,
        text,
      );
    },
  );

  testWidgets(
    'changing only the collapse flag toggles the source without a new lookup',
    (tester) async {
      final _SourceLineAppModel appModel = _SourceLineAppModel();
      final ValueNotifier<bool> collapsed = ValueNotifier<bool>(false);
      addTearDown(collapsed.dispose);
      const String text = '今日は良い天気ですね';
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appProvider.overrideWith((ref) => appModel),
            ankiRepositoryProvider.overrideWithValue(_RecordingAnkiRepo()),
            ...popupMiningTargetTestOverrides(anki: false),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              navigatorKey: appModel.navigatorKey,
              home: ValueListenableBuilder<bool>(
                valueListenable: collapsed,
                builder: (BuildContext context, bool value, Widget? _) =>
                    PopupDictionaryPage(
                      searchTerm: text,
                      sourceCharIndex: 5,
                      sourceTextCollapsed: value,
                      closeInApp: () {},
                    ),
              ),
            ),
          ),
        ),
      );
      await _settle(tester);
      expect(find.byType(SourceLookupTextPanel), findsOneWidget);
      final int lookups = appModel.searched.length;
      collapsed.value = true;
      await tester.pumpAndSettle();
      expect(find.byType(SourceLookupTextPanel), findsNothing);
      expect(
        appModel.searched.length,
        lookups,
        reason: 'the collapse flag changes visibility only, not the query',
      );
    },
  );

  testWidgets(
    'long external source is bounded and leaves a definition viewport',
    (tester) async {
      final String text = List<String>.generate(
        400,
        (int i) => String.fromCharCode(0x4e00 + i),
      ).join();
      await tester.pumpWidget(
        _buildApp(
          appModel: _SourceLineAppModel(),
          repo: _RecordingAnkiRepo(),
          text: text,
          charIndex: 360,
        ),
      );
      await _settle(tester);
      final Finder viewport = find.byKey(
        const ValueKey<String>('popup_source_scroll'),
      );
      final double height = tester.getSize(viewport).height;
      expect(height, greaterThan(0));
      expect(height, lessThan(200));
      final Rect selected = tester.getRect(_sourceGlyph(text[360]));
      expect(tester.getRect(viewport).contains(selected.center), isTrue);
      expect(
        tester.getSize(find.byType(DictionaryPopupLayer).first).height,
        greaterThan(height),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'BUG-2899: tapped-glyph entry keeps the whole line on the source strip '
    'and scans from the tapped glyph',
    (WidgetTester tester) async {
      final _SourceLineAppModel appModel = _SourceLineAppModel();
      // 截屏识字的行文本是原生字符串；被点的是「天」（UTF-16 下标 5）。
      await tester.pumpWidget(
        _buildApp(
          appModel: appModel,
          repo: _RecordingAnkiRepo(),
          text: '今日は良い天気ですね',
          charIndex: 5,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(appModel.searched, <String>[
        '天気ですね',
      ], reason: '首查是从被点字到行尾的后缀，与在条上点「天」同一条扫描路径。');
      final SourceLookupTextPanel panel = tester.widget(
        find.byType(SourceLookupTextPanel),
      );
      expect(panel.text, '今日は良い天気ですね', reason: '条上必须是整行，不是切出来的那个词。');
      expect(panel.highlight?.start, 5, reason: '高亮锚在被点的那个字上。');

      // 条上仍能点同一行的别的字（此前整行丢了，左边的字根本不在条上）。
      await tester.tap(find.text('今'));
      await tester.pump();
      await tester.pump();
      expect(appModel.searched.last, '今日は良い天気ですね');
    },
  );

  testWidgets(
    'the host lookup reports its matched headword once; a re-scan on the '
    'strip does not',
    (WidgetTester tester) async {
      final _SourceLineAppModel appModel = _SourceLineAppModel()
        ..wordHits['呼んでいた'] = '呼ぶ'
        ..wordHits['私は'] = '私';
      final List<String> headwords = <String>[];
      await tester.pumpWidget(
        _buildApp(
          appModel: appModel,
          repo: _RecordingAnkiRepo(),
          text: '先生と呼んでいた',
          charIndex: 3,
          onHeadword: headwords.add,
        ),
      );
      await _settle(tester);
      expect(appModel.searched.first, '呼んでいた');
      expect(headwords, <String>['呼ぶ']);

      await tester.tap(find.text('先'));
      await _settle(tester);
      expect(headwords, <String>['呼ぶ']);
    },
  );

  testWidgets(
    'BUG-2899: whole-string entries (system PROCESS_TEXT) still look up the '
    'whole string',
    (WidgetTester tester) async {
      final _SourceLineAppModel appModel = _SourceLineAppModel();
      await tester.pumpWidget(
        _buildApp(
          appModel: appModel,
          repo: _RecordingAnkiRepo(),
          text: '天気',
          charIndex: -1,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(appModel.searched, <String>['天気']);
      final SourceLookupTextPanel panel = tester.widget(
        find.byType(SourceLookupTextPanel),
      );
      expect(panel.highlight?.start, 0);
    },
  );

  testWidgets(
    'BUG-2900: mining from the base layer fills {sentence} with the source '
    'line',
    (WidgetTester tester) async {
      final _SourceLineAppModel appModel = _SourceLineAppModel();
      final _RecordingAnkiRepo repo = _RecordingAnkiRepo();
      await tester.pumpWidget(
        _buildApp(
          appModel: appModel,
          repo: repo,
          text: '  今日は良い天気ですね ',
          charIndex: 7,
        ),
      );
      await tester.pump();
      await tester.pump();

      final DictionaryPopupLayer base = tester.widget(
        find.byType(DictionaryPopupLayer).first,
      );
      await tester.runAsync(
        () => base.onMineEntry!(<String, String>{
          'expression': '天気',
          'sentence': '',
        }),
      );

      expect(repo.contexts.single.sentence, '今日は良い天気ですね');
      expect(repo.payloads.single['sentence'], '今日は良い天気ですね');

      // JS 送来的非空句子仍然优先。
      await tester.runAsync(
        () => base.onMineEntry!(<String, String>{
          'expression': '天気',
          'sentence': '別の文',
        }),
      );
      expect(repo.contexts.last.sentence, '別の文');
    },
  );

  testWidgets('BUG-2900: whole-string entries do not invent a sentence', (
    WidgetTester tester,
  ) async {
    final _SourceLineAppModel appModel = _SourceLineAppModel();
    final _RecordingAnkiRepo repo = _RecordingAnkiRepo();
    await tester.pumpWidget(
      _buildApp(appModel: appModel, repo: repo, text: '天気', charIndex: -1),
    );
    await tester.pump();
    await tester.pump();

    final DictionaryPopupLayer base = tester.widget(
      find.byType(DictionaryPopupLayer).first,
    );
    await tester.runAsync(
      () => base.onMineEntry!(<String, String>{
        'expression': '天気',
        'sentence': '',
      }),
    );
    expect(repo.contexts.single.sentence, '');
  });

  testWidgets(
    'BUG-2899: the resident page re-looks-up every pushed line through '
    'didUpdateWidget (second and later lookups)',
    (WidgetTester tester) async {
      final _SourceLineAppModel appModel = _SourceLineAppModel();
      final _RecordingAnkiRepo repo = _RecordingAnkiRepo();
      final ValueNotifier<_Push> push = ValueNotifier<_Push>(
        const _Push('今日は良い天気ですね', 5, 1),
      );
      addTearDown(push.dispose);
      await tester.pumpWidget(
        _buildHostedApp(appModel: appModel, repo: repo, push: push),
      );
      await _settle(tester);
      final State first = tester.state(find.byType(PopupDictionaryPage));
      expect(appModel.searched, <String>['天気ですね']);

      // 第二次：同一 State，宿主推来另一行、点的是「雨」（UTF-16 下标 3）。
      push.value = const _Push('明日は雨が降る', 3, 2);
      await _settle(tester);
      expect(
        tester.state(find.byType(PopupDictionaryPage)),
        same(first),
        reason: '常驻热页：第二次查词必须走 didUpdateWidget，不是重建',
      );
      expect(appModel.searched.last, '雨が降る');
      final SourceLookupTextPanel panel = tester.widget(
        find.byType(SourceLookupTextPanel),
      );
      expect(panel.text, '明日は雨が降る');
      expect(panel.highlight?.start, 3);
      expect(await _mineSentence(tester, repo), '明日は雨が降る');

      // 第三次：同一行同一字（只有 generation 变）也要重查。
      push.value = const _Push('明日は雨が降る', 3, 3);
      await _settle(tester);
      expect(appModel.searched.last, '雨が降る');
      expect(appModel.searched.where((String q) => q == '雨が降る').length, 2);
    },
  );

  testWidgets(
    'BUG-2900: a whole-string push after a line push does not keep the '
    'previous line as the sentence',
    (WidgetTester tester) async {
      final _SourceLineAppModel appModel = _SourceLineAppModel();
      final _RecordingAnkiRepo repo = _RecordingAnkiRepo();
      final ValueNotifier<_Push> push = ValueNotifier<_Push>(
        const _Push('今日は良い天気ですね', 5, 1),
      );
      addTearDown(push.dispose);
      await tester.pumpWidget(
        _buildHostedApp(appModel: appModel, repo: repo, push: push),
      );
      await _settle(tester);
      expect(await _mineSentence(tester, repo), '今日は良い天気ですね');

      // 系统划词复用常驻窗：查询串「天気」恰好也是上一行的子串，句子仍不得残留。
      push.value = const _Push('天気', -1, 2);
      await _settle(tester);
      expect(appModel.searched.last, '天気');
      expect(await _mineSentence(tester, repo), '');
    },
  );

  testWidgets(
    'BUG-2900: mining after a search-bar submit carries no source sentence',
    (WidgetTester tester) async {
      final _SourceLineAppModel appModel = _SourceLineAppModel();
      final _RecordingAnkiRepo repo = _RecordingAnkiRepo();
      await tester.pumpWidget(
        _buildApp(
          appModel: appModel,
          repo: repo,
          text: '今日は良い天気ですね',
          charIndex: 5,
        ),
      );
      await _settle(tester);

      final PopupDictionarySearchBar bar = tester.widget(
        find.byType(PopupDictionarySearchBar),
      );
      // 用户在搜索栏另查一个词：结果与那一行无关（即便它恰是行的子串）。
      bar.onSubmit('天気');
      await _settle(tester);
      expect(appModel.searched.last, '天気');
      expect(await _mineSentence(tester, repo), '');
    },
  );

  testWidgets(
    'BUG-2900: in-place navigation to a link whose term is a substring of '
    'the line does not fill the line as the sentence',
    (WidgetTester tester) async {
      final _SourceLineAppModel appModel = _SourceLineAppModel()
        ..kanjiHits.add('天');
      final _RecordingAnkiRepo repo = _RecordingAnkiRepo();
      await tester.pumpWidget(
        _buildApp(
          appModel: appModel,
          repo: repo,
          text: '今日は良い天気ですね',
          charIndex: 5,
        ),
      );
      await _settle(tester);
      expect(await _mineSentence(tester, repo), '今日は良い天気ですね');

      // 基础层点释义里的汉字链接「天」：原地跳转，基础层查询串变成「天」。
      _baseLayer(tester).onLinkClick('天', Rect.zero);
      await _settle(tester);
      expect(appModel.searched.last, '天');
      expect(
        await _mineSentence(tester, repo),
        '',
        reason: '「天」是行的子串，但这条词条出自释义链接，不出自这一行',
      );

      // 再在源文本条上点行里的字：词条重新出自这一行，句子回来。
      await tester.tap(find.text('今'));
      await _settle(tester);
      expect(appModel.searched.last, '今日は良い天気ですね');
      expect(await _mineSentence(tester, repo), '今日は良い天気ですね');
    },
  );

  testWidgets(
    'BUG-3487: a screen-OCR line mines the whole sentence from its text block',
    (WidgetTester tester) async {
      final _SourceLineAppModel appModel = _SourceLineAppModel();
      final _RecordingAnkiRepo repo = _RecordingAnkiRepo();
      // 竖排：一句被 ML Kit 拆成三行；用户点的是第二行「良」。
      const String block = '今日は\n良い天気ですね。\n散歩に行こう。';
      const String line = '良い天気ですね。';
      await tester.pumpWidget(
        _buildApp(
          appModel: appModel,
          repo: repo,
          text: line,
          charIndex: 0,
          sourceBlock: block,
          sourceBlockOffset: block.indexOf(line),
        ),
      );
      await _settle(tester);

      final SourceLookupTextPanel panel = tester.widget(
        find.byType(SourceLookupTextPanel),
      );
      // 反馈 8Su1XoCjtl：源文本条也是跨行拼回的整句，被点的「良」在条上第 3 个字。
      expect(panel.text, '今日は良い天気ですね。');
      expect(panel.initialCharIndex, 3);
      expect(appModel.searched.first, '良い天気ですね。散歩に行こう。');
      expect(
        await _mineSentence(tester, repo),
        '今日は良い天気ですね。',
        reason: '句子是块里含被点字的整句，跨行拼回，不含下一句',
      );
    },
  );

  testWidgets(
    'BUG-3487: tapping another glyph on the strip re-picks its sentence',
    (WidgetTester tester) async {
      final _SourceLineAppModel appModel = _SourceLineAppModel();
      final _RecordingAnkiRepo repo = _RecordingAnkiRepo();
      const String block = 'まだ早い。\nもう行く。今日は雨';
      const String line = 'もう行く。今日は雨';
      await tester.pumpWidget(
        _buildApp(
          appModel: appModel,
          repo: repo,
          text: line,
          charIndex: 0,
          sourceBlock: block,
          sourceBlockOffset: block.indexOf(line),
        ),
      );
      await _settle(tester);
      expect(await _mineSentence(tester, repo), 'もう行く。');

      // 同一行上点「雨」：它在块里的下一句。
      await tester.tap(_sourceGlyph('雨'));
      await _settle(tester);
      expect(appModel.searched.last, '雨');
      expect(await _mineSentence(tester, repo), '今日は雨');
    },
  );

  testWidgets(
    'feedback 8Su1XoCjtl: the source strip shows the whole sentence across '
    'OCR line breaks, not only the tapped line',
    (WidgetTester tester) async {
      final _SourceLineAppModel appModel = _SourceLineAppModel();
      final _RecordingAnkiRepo repo = _RecordingAnkiRepo();
      // 「スタンプ」被折成「…スタン」/「プが…」两行，句首还在上一行。点的是「ス」。
      const String block = 'さっき\n新しいコラボLINEスタン\nプが映りました。次は';
      const String line = '新しいコラボLINEスタン';
      await tester.pumpWidget(
        _buildApp(
          appModel: appModel,
          repo: repo,
          text: line,
          charIndex: line.indexOf('ス'),
          sourceBlock: block,
          sourceBlockOffset: block.indexOf(line),
        ),
      );
      await _settle(tester);

      final SourceLookupTextPanel panel = tester.widget(
        find.byType(SourceLookupTextPanel),
      );
      expect(panel.text, 'さっき新しいコラボLINEスタンプが映りました。');
      expect(
        panel.initialCharIndex,
        'さっき新しいコラボLINE'.length,
        reason: '被点的「ス」换算到整句里的位置',
      );
      expect(appModel.searched.first, 'スタンプが映りました。次は');
      expect(await _mineSentence(tester, repo), 'さっき新しいコラボLINEスタンプが映りました。');

      // 下一行折过来的字也在条上，能直接点。
      await tester.tap(_sourceGlyph('映'));
      await _settle(tester);
      expect(appModel.searched.last, '映りました。次は');
      expect(await _mineSentence(tester, repo), 'さっき新しいコラボLINEスタンプが映りました。');
    },
  );

  testWidgets(
    'BUG-4707: a word wrapped onto the next OCR line is looked up across the '
    'line break, from the host and from the strip',
    (WidgetTester tester) async {
      final _SourceLineAppModel appModel = _SourceLineAppModel();
      final _RecordingAnkiRepo repo = _RecordingAnkiRepo();
      // 「天気」被折成两行：第一行末尾「天」、第二行开头「気」。用户点的是「天」。
      const String block = '今日は良い天\n気ですね。\n散歩に行こう。';
      const String line = '今日は良い天';
      await tester.pumpWidget(
        _buildApp(
          appModel: appModel,
          repo: repo,
          text: line,
          charIndex: 5,
          sourceBlock: block,
          sourceBlockOffset: block.indexOf(line),
        ),
      );
      await _settle(tester);

      expect(
        appModel.searched.first,
        '天気ですね。散歩に行こう。',
        reason: '查词串从被点字起跨过折行接上块里的后续行，不在行尾截断',
      );
      final SourceLookupTextPanel panel = tester.widget(
        find.byType(SourceLookupTextPanel),
      );
      // 反馈 8Su1XoCjtl：条上是跨行拼回的整句，被点的「天」在条上第 5 个字。
      expect(panel.text, '今日は良い天気ですね。');
      expect(panel.initialCharIndex, 5);
      expect(await _mineSentence(tester, repo), '今日は良い天気ですね。');

      // 条上再点「良」：后缀同样接上下一行。
      await tester.tap(find.text('良'));
      await _settle(tester);
      expect(appModel.searched.last, '良い天気ですね。散歩に行こう。');
      expect(await _mineSentence(tester, repo), '今日は良い天気ですね。');
    },
  );

  testWidgets(
    'BUG-4707: a Latin line with trailing whitespace still joins the next '
    'line with one space',
    (WidgetTester tester) async {
      final _SourceLineAppModel appModel = _SourceLineAppModel();
      // 行内后缀是 trim 后的行，续文的空格要按去掉行尾空白后的末字判断。
      const String block = 'I like the \nweather today';
      const String line = 'I like the ';
      await tester.pumpWidget(
        _buildApp(
          appModel: appModel,
          repo: _RecordingAnkiRepo(),
          text: line,
          charIndex: 7,
          sourceBlock: block,
          sourceBlockOffset: 0,
        ),
      );
      await _settle(tester);
      expect(appModel.searched.first, 'the weather today');
    },
  );

  testWidgets(
    'BUG-3487: a block that does not contain the line at the given offset '
    'falls back to the whole line',
    (WidgetTester tester) async {
      final _RecordingAnkiRepo repo = _RecordingAnkiRepo();
      await tester.pumpWidget(
        _buildApp(
          appModel: _SourceLineAppModel(),
          repo: repo,
          text: 'もう行く。今日は雨',
          charIndex: 0,
          sourceBlock: 'まだ早い。もう行く。今日は雨',
          sourceBlockOffset: 1,
        ),
      );
      await _settle(tester);
      expect(
        await _mineSentence(tester, repo),
        'もう行く。今日は雨',
        reason: '偏移错位时绝不截错位的句子',
      );
    },
  );

  testWidgets(
    'BUG-2899: PopupDictApp hands the whole line from the native channel to '
    'the page without cutting it into a word',
    (WidgetTester tester) async {
      final _SourceLineAppModel appModel = _SourceLineAppModel();
      const MethodChannel channel = FushiChannels.popup;
      final TestDefaultBinaryMessengerBinding binding =
          TestDefaultBinaryMessengerBinding.instance;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (MethodCall call) async => call.method == 'getInitialProcessText'
            ? <String, Object>{
                'text': 'initial sentence',
                'charIndex': 0,
                'sourceTextCollapsed': true,
              }
            : null,
      );
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appProvider.overrideWith((ref) => appModel),
            ...popupMiningTargetTestOverrides(),
          ],
          child: const PopupDictApp(),
        ),
      );
      await _settle(tester);

      expect(
        find.byType(SourceLookupTextPanel),
        findsNothing,
        reason: 'the cold request can initially collapse the source',
      );
      expect(
        tester
            .widget<PopupDictionaryPage>(find.byType(PopupDictionaryPage))
            .sourceTextCollapsed,
        isTrue,
      );
      appModel.searched.clear();

      Future<void> nativePush(
        String text,
        int charIndex, {
        String? block,
        int blockOffset = -1,
        bool? sourceTextCollapsed,
      }) async {
        final ByteData message = const StandardMethodCodec().encodeMethodCall(
          MethodCall('onNewProcessText', <String, Object>{
            'text': text,
            'charIndex': charIndex,
            if (block != null) 'sourceBlock': block,
            if (block != null) 'sourceBlockOffset': blockOffset,
            if (sourceTextCollapsed != null)
              'sourceTextCollapsed': sourceTextCollapsed,
          }),
        );
        unawaited(
          binding.defaultBinaryMessenger.handlePlatformMessage(
            channel.name,
            message,
            (ByteData? _) {},
          ),
        );
        await _settle(tester);
      }

      await nativePush('今日は良い天気ですね', 5);
      expect(appModel.searched, <String>[
        '天気ですね',
      ], reason: '宿主不再切词：首查是整行里被点字起的后缀，由查词页做扫描');
      SourceLookupTextPanel panel = tester.widget(
        find.byType(SourceLookupTextPanel),
      );
      expect(panel.text, '今日は良い天気ですね');

      // 热页第二次推词：仍是整行进页面。
      await nativePush('明日は雨が降る', 3);
      expect(appModel.searched.last, '雨が降る');
      panel = tester.widget(find.byType(SourceLookupTextPanel));
      expect(panel.text, '明日は雨が降る');

      await nativePush('明日は雨が降る', 3, sourceTextCollapsed: true);
      expect(find.byType(SourceLookupTextPanel), findsNothing);
      await nativePush('明日は雨が降る', 3);
      expect(
        find.byType(SourceLookupTextPanel),
        findsOneWidget,
        reason:
            'omitted visibility on an identical warm request restores the default',
      );

      // BUG-3487：截屏识字带上所属块，页面拿到块全文与本行起点。
      const String block = '朝から\n明日は雨が降る\nらしい。';
      await nativePush('明日は雨が降る', 3, block: block, blockOffset: 4);
      PopupDictionaryPage page = tester.widget(
        find.byType(PopupDictionaryPage),
      );
      expect(page.sourceBlock, block);
      expect(page.sourceBlockOffset, 4);

      // 再推一个不带块的（悬浮字幕 / 系统划词）：块不得残留。
      await nativePush('明日は雨が降る', 3);
      page = tester.widget(find.byType(PopupDictionaryPage));
      expect(page.sourceBlock, isNull);
      expect(page.sourceBlockOffset, -1);
    },
  );
}
