import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/pages/implementations/home_dictionary_page.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/fake_inappwebview_platform.dart';
import '../helpers/test_platform_services.dart';

/// BUG-4130：查词页结果区点 ✓（这个词以前制过卡）→ 操作单「覆写」，以及 ☆ 收藏，
/// 都要带上源文本条那一句作例句。真 [HomeDictionaryPage] + 注入的假 Anki 后端 /
/// 内存 DB：从结果区 [DictionaryPopupWebView] 上真正接的那几个回调发起，断言落到
/// 后端 / DB 的 sentence。
///
/// 源文本 `_source` 有两句：主查词的命中段锚在条首，所以结果区语境是第一句。
const String _source = 'と言いつつ。次の文';
const String _firstSentence = 'と言いつつ。';

class _AppModel extends AppModel {
  _AppModel() : super(testPlatformServices());

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
  }) async => DictionarySearchResult(
    searchTerm: searchTerm,
    entries: <DictionaryEntry>[DictionaryEntry(word: 'と言いつつ')],
    headwordCount: 1,
  );
}

/// 卡已在 Anki 里（一张 noteId=42）；按 id 覆写成功并记下落卡用的句子。
class _ExistingCardRepo extends BaseAnkiRepository {
  final List<String> overwriteSentences = <String>[];
  final List<Map<String, dynamic>> overwritePayloads = <Map<String, dynamic>>[];

  @override
  Future<List<MinedNoteRef>> findMatchingNotes(
    String expression,
    String reading,
  ) async => const <MinedNoteRef>[MinedNoteRef(noteId: 42, preview: 'と言いつつ')];

  @override
  Future<MineOutcome> updateMinedNote({
    required int noteId,
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    overwriteSentences.add(context.sentence);
    overwritePayloads.add(jsonDecode(rawPayloadJson) as Map<String, dynamic>);
    return MineOutcome.success(noteId: noteId);
  }

  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('unused');
  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async => const MineOutcome.success();
  @override
  Future<bool> isDuplicate(String expression, String reading) async => true;
  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;
  @override
  Future<bool> createDeck(String name) async => false;
}

Widget _wrap(_AppModel appModel, BaseAnkiRepository repo) {
  return ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((ref) => appModel),
      ankiRepositoryProvider.overrideWith((ref) => repo),
    ],
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

Future<void> _search(WidgetTester tester, String term) async {
  final HomeDictionarySearchDebug debug =
      tester.state(find.byType(HomeDictionaryPage))
          as HomeDictionarySearchDebug;
  await tester.runAsync(() => debug.debugSearch(term));
  await tester.pump();
}

/// 结果区那一个 WebView（浮层各层没有「顶部下拉清空」回调，只有结果区接）。
DictionaryPopupWebView _resultWebView(WidgetTester tester) {
  final Finder finder = find.byWidgetPredicate(
    (Widget w) => w is DictionaryPopupWebView && w.onTopPullReleased != null,
  );
  expect(finder, findsOneWidget);
  return tester.widget<DictionaryPopupWebView>(finder);
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

  testWidgets('结果区 ✓ →「覆写」：落卡的 sentence 是源文本条那一句', (WidgetTester tester) async {
    final _AppModel appModel = _AppModel();
    final _ExistingCardRepo repo = _ExistingCardRepo();
    await tester.pumpWidget(_wrap(appModel, repo));
    await tester.pump();
    await _search(tester, _source);

    final DictionaryPopupWebView web = _resultWebView(tester);
    expect(
      web.onMinedCardAction,
      isNotNull,
      reason: '没接时桥回空结果，点 ✓ 静默无反应（BUG-4130 原症状）',
    );

    // popup.js 交给 minedCardAction 桥的字段不带 sentence（查词页没有「当前句」）。
    final Future<MinePopupResult> pending = web.onMinedCardAction!(
      <String, String>{'expression': 'と言いつつ', 'reading': 'といいつつ'},
    );
    await tester.pumpAndSettle();
    // 操作单：每张命中卡一颗「覆写」（编辑图标）。
    await tester.tap(find.byIcon(FushiIcons.edit).last);
    await tester.pumpAndSettle();
    final MinePopupResult result = await pending;

    expect(result.noteId, 42);
    expect(repo.overwriteSentences, <String>[_firstSentence]);
    expect(repo.overwritePayloads.single['sentence'], _firstSentence);
  });

  testWidgets('结果区 ☆：收藏随词落源文本条那一句', (WidgetTester tester) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final _AppModel appModel = _AppModel()..wireDatabaseForTesting(db);
    await tester.pumpWidget(_wrap(appModel, _ExistingCardRepo()));
    await tester.pump();
    await _search(tester, _source);

    final DictionaryPopupWebView web = _resultWebView(tester);
    final bool? added = await tester.runAsync(
      () => web.onFavoriteEntry!(<String, String>{
        'expression': 'と言いつつ',
        'reading': 'といいつつ',
        'glossary': 'while saying',
      }),
    );
    expect(added, isTrue);
    final List<FavoriteWordRow>? rows = await tester.runAsync(
      db.getAllFavoriteWords,
    );
    expect(rows!.single.sentence, _firstSentence);
  });

  testWidgets('结果区接了排队覆写与高级制卡入口（与浮层各层同一套）', (WidgetTester tester) async {
    final _AppModel appModel = _AppModel();
    await tester.pumpWidget(_wrap(appModel, _ExistingCardRepo()));
    await tester.pump();
    await _search(tester, _source);

    final DictionaryPopupWebView web = _resultWebView(tester);
    expect(web.onQueueOverwrite, isNotNull);
    expect(web.onOpenInAnki, isNotNull);
    expect(web.onFavoriteCheck, isNotNull);
    expect(
      web.onOpenAdvancedMining,
      isNotNull,
      reason: '制卡模块默认开：结果区的「高级制卡」按钮要能出现',
    );
  });
}
