import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/src/anki/anki_mined_card_action_sheet.dart';
import 'package:hibiki/utils.dart';

/// TODO-1007/1008：点 ✓ 操作选择 + note viewer 的 widget 行为守卫。
///
/// 决策②：命中多张时列出全部供选择（不默默取最近一张）。
/// 决策③：每次点 ✓ 都让用户选——至少 [覆写] / [新增重复卡] / [查看·在 Anki 中打开]。
/// 决策⑤：note viewer 只读展示字段 + 覆写 + 在 Anki 中打开。

/// 受控假 repo：findMatchingNotes / noteFields / openNoteInAnki 走内存数据。
class _FakeRepo extends BaseAnkiRepository {
  _FakeRepo(this.matches, {this.fields = const {}});

  final List<MinedNoteRef> matches;
  final Map<String, String> fields;
  int openedNoteId = -1;

  @override
  Future<List<MinedNoteRef>> findMatchingNotes(
          String expression, String reading) async =>
      matches;

  @override
  Future<Map<String, String>?> noteFields(int noteId) async => fields;

  @override
  Future<bool> openNoteInAnki(int noteId) async {
    openedNoteId = noteId;
    return true;
  }

  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('unused');
  @override
  Future<MineOutcome> mineEntry(
          {required String rawPayloadJson,
          required AnkiMiningContext context}) async =>
      const MineOutcome.success();
  @override
  Future<bool> isDuplicate(String expression, String reading) async => true;
  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;
  @override
  Future<bool> createDeck(String name) async => false;
}

Widget _host(Future<void> Function(BuildContext) onTapBody) {
  return TranslationProvider(
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => onTapBody(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('lists every matching card (decision 2) + three options',
      (tester) async {
    final repo = _FakeRepo(const [
      MinedNoteRef(noteId: 300, preview: '日本語 A'),
      MinedNoteRef(noteId: 200, preview: '日本語 B'),
    ]);
    AnkiCardMutationResult? result;

    await tester.pumpWidget(_host((context) async {
      result = await runAnkiMinedCardAction(
        context: context,
        repo: repo,
        expression: '日本語',
        reading: 'にほんご',
        mineNew: () async => (ankiConnect: true, noteId: 999),
        overwrite: (noteId) async => (ankiConnect: true, noteId: noteId),
      );
    }));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Both matching cards are listed (multi-match selection).
    expect(find.text('日本語 A'), findsOneWidget);
    expect(find.text('日本語 B'), findsOneWidget);
    // The "add as a new card" option is always present (decision 3).
    expect(find.text(t.anki_mined_action_add_duplicate), findsOneWidget);
    // Per-card overwrite + view affordances exist (two cards -> two each).
    expect(find.byIcon(Icons.edit_outlined), findsNWidgets(2));
    expect(find.byIcon(Icons.open_in_new), findsNWidgets(2));

    // Choosing "add as a new card" runs mineNew.
    await tester.tap(find.text(t.anki_mined_action_add_duplicate));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.noteId, 999);
    expect(result!.ankiConnect, isTrue);
  });

  testWidgets('overwriting a specific card targets that note id',
      (tester) async {
    final repo = _FakeRepo(const [
      MinedNoteRef(noteId: 300, preview: 'A'),
      MinedNoteRef(noteId: 200, preview: 'B'),
    ]);
    AnkiCardMutationResult? result;
    await tester.pumpWidget(_host((context) async {
      result = await runAnkiMinedCardAction(
        context: context,
        repo: repo,
        expression: 'x',
        reading: '',
        mineNew: () async => (ankiConnect: true, noteId: 999),
        overwrite: (noteId) async => (ankiConnect: true, noteId: noteId),
      );
    }));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Overwrite the SECOND card (note 200) via its edit icon.
    await tester.tap(find.byIcon(Icons.edit_outlined).last);
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.noteId, 200,
        reason: 'overwrite targets the user-chosen card, not the newest');
  });

  testWidgets('no matches falls back to mineNew (deleted since detection)',
      (tester) async {
    final repo = _FakeRepo(const []);
    AnkiCardMutationResult? result;
    await tester.pumpWidget(_host((context) async {
      result = await runAnkiMinedCardAction(
        context: context,
        repo: repo,
        expression: 'gone',
        reading: '',
        mineNew: () async => (ankiConnect: true, noteId: 42),
        overwrite: (noteId) async => (ankiConnect: false, noteId: null),
      );
    }));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // No sheet shown; mined fresh directly.
    expect(result, isNotNull);
    expect(result!.noteId, 42);
  });

  testWidgets('note viewer shows fields read-only + open in Anki (decision 5)',
      (tester) async {
    final repo = _FakeRepo(
      const [MinedNoteRef(noteId: 300, preview: 'A')],
      fields: const {'Expression': '日本語', 'Meaning': 'language'},
    );
    await tester.pumpWidget(_host((context) async {
      await runAnkiMinedCardAction(
        context: context,
        repo: repo,
        expression: '日本語',
        reading: '',
        mineNew: () async => (ankiConnect: true, noteId: 999),
        overwrite: (noteId) async => (ankiConnect: true, noteId: noteId),
      );
    }));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Open the viewer via the view icon.
    await tester.tap(find.byIcon(Icons.open_in_new));
    await tester.pumpAndSettle();
    // Field names + values are shown read-only.
    expect(find.text('Expression'), findsOneWidget);
    expect(find.text('日本語'), findsWidgets);
    expect(find.text('Meaning'), findsOneWidget);
    expect(find.text('language'), findsOneWidget);
    // "Open in Anki" triggers repo.openNoteInAnki for this note.
    await tester.tap(find.text(t.anki_note_viewer_open_in_anki));
    await tester.pumpAndSettle();
    expect(repo.openedNoteId, 300);
  });
}
