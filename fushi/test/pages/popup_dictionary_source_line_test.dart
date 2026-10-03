import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/popup_dictionary_page.dart';
import 'package:fushi/src/utils/components/clipboard_lookup_text_panel.dart';
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

  @override
  bool get isInitialised => true;

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
}
