import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/popup_main.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/popup_dictionary_page.dart';
import 'package:fushi/src/utils/components/clipboard_lookup_text_panel.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../helpers/test_platform_services.dart';

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

  @override
  bool get isInitialised => true;

  @override
  Future<void> refreshPrefCacheIfChanged() async {}

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
}) {
  return ProviderScope(
    overrides: [
      appProvider.overrideWith((ref) => appModel),
      ankiRepositoryProvider.overrideWithValue(repo),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: appModel.navigatorKey,
        home: PopupDictionaryPage(
          searchTerm: text,
          sourceCharIndex: charIndex,
          closeInApp: () {},
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
    'BUG-2899: PopupDictApp hands the whole line from the native channel to '
    'the page without cutting it into a word',
    (WidgetTester tester) async {
      final _SourceLineAppModel appModel = _SourceLineAppModel();
      const MethodChannel channel = FushiChannels.popup;
      final TestDefaultBinaryMessengerBinding binding =
          TestDefaultBinaryMessengerBinding.instance;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (MethodCall call) async => null,
      );
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appProvider.overrideWith((ref) => appModel)],
          child: const PopupDictApp(),
        ),
      );
      await _settle(tester);

      Future<void> nativePush(String text, int charIndex) async {
        final ByteData message = const StandardMethodCodec().encodeMethodCall(
          MethodCall('onNewProcessText', <String, Object>{
            'text': text,
            'charIndex': charIndex,
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
    },
  );
}
