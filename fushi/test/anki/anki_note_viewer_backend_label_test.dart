import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_mined_card_action_sheet.dart';
import 'package:fushi_anki/fushi_anki.dart';

// BUG-3790：「已存在的卡片」对话框按卡真正住的地方说话——卡在 Fushi 复习里时
// 不能出现「在 Anki 中打开」；后端打不开笔记时不出打开按钮。

class _Repo extends BaseAnkiRepository {
  _Repo({required this.home, required this.canOpen});

  final MinedNoteHome home;
  final bool canOpen;

  @override
  MinedNoteHome get minedNoteHome => home;

  @override
  bool get canOpenMinedNote => canOpen;

  @override
  Future<Map<String, String>?> noteFields(int noteId) async => <String, String>{
    'Expression': 'めげる',
  };

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
  }) async => MineOutcome.failure('unused');

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => true;

  @override
  Future<bool> createDeck(String name) async => true;
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  Future<void> openViewer(WidgetTester tester, BaseAnkiRepository repo) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showAnkiNoteViewer(
                    context: context,
                    repo: repo,
                    noteId: 1,
                    overwrite: (int id) async =>
                        (ankiConnect: false, noteId: id),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('卡在 Fushi 复习：按钮说「在 Fushi 复习中打开」，不出现 Anki', (
    WidgetTester tester,
  ) async {
    await openViewer(
      tester,
      _Repo(home: MinedNoteHome.fushiReview, canOpen: true),
    );
    expect(find.text(t.anki_note_viewer_open_in_review), findsOneWidget);
    expect(find.text(t.anki_note_viewer_open_in_anki), findsNothing);
  });

  testWidgets('卡在 Anki：仍是「在 Anki 中打开」', (WidgetTester tester) async {
    await openViewer(tester, _Repo(home: MinedNoteHome.anki, canOpen: true));
    expect(find.text(t.anki_note_viewer_open_in_anki), findsOneWidget);
  });

  testWidgets('后端打不开笔记：不出打开按钮（只剩关闭 / 覆写）', (WidgetTester tester) async {
    await openViewer(tester, _Repo(home: MinedNoteHome.anki, canOpen: false));
    expect(find.text(t.anki_note_viewer_open_in_anki), findsNothing);
    expect(find.text(t.anki_note_viewer_open_in_review), findsNothing);
    expect(find.text(t.anki_mined_action_overwrite), findsOneWidget);
  });
}
