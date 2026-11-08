import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/modules/manga_companion_schema.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_lookup_controller.dart';
import 'package:fushi/src/second_screen/panel/companion/modules/manga_companion_panel.dart';
import 'package:material_ui/material_ui.dart';

import 'companion_panel_harness.dart';

const String _line1 = 'なんだって！？';
const String _line2 = 'ちょっと待ってくれ、話を聞いてほしい。';

Map<String, Object?> _sample({
  MangaCompanionOcrState ocr = MangaCompanionOcrState.done,
  List<String> lines = const <String>[_line1, _line2],
  String? ocrError,
}) => <String, Object?>{
  MangaCompanionKeys.title: 'Series',
  MangaCompanionKeys.chapter: 'Chapter 9',
  MangaCompanionKeys.author: 'Author',
  MangaCompanionKeys.genres: <String>['Comedy', 'Slice of life'],
  MangaCompanionKeys.description: 'A long description of the series.',
  MangaCompanionKeys.page: 36,
  MangaCompanionKeys.pageCount: 182,
  MangaCompanionKeys.rtl: true,
  MangaCompanionKeys.chapters: <Map<String, Object?>>[
    for (int r = 0; r < 24; r++)
      <String, Object?>{
        MangaCompanionKeys.chapterIndex: 23 - r,
        MangaCompanionKeys.chapterName: 'Chapter ${r + 1}',
      },
  ],
  MangaCompanionKeys.chapterCount: 24,
  MangaCompanionKeys.currentChapter: 15,
  MangaCompanionKeys.chapterPosition: 9,
  MangaCompanionKeys.ocr: ocr.name,
  if (ocrError != null) MangaCompanionKeys.ocrError: ocrError,
  if (lines.isNotEmpty) MangaCompanionKeys.lines: lines,
};

Future<RecordingCompanionSession> _pump(
  WidgetTester tester,
  Map<String, Object?> snapshot, {
  bool settle = true,
}) async {
  final RecordingCompanionSession rec = RecordingCompanionSession();
  rec.show(CompanionContextKind.manga, snapshot, title: 'Series');
  await pumpCompanionPanel(
    tester,
    rec.session,
    MangaCompanionPanel(session: rec.session),
    settle: settle,
  );
  return rec;
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(MangaCompanionPanel)));

void main() {
  testWidgets('renders where the reader is, the text and the chapters', (
    WidgetTester tester,
  ) async {
    await _pump(tester, _sample());
    expect(find.text(t.second_screen_manga_header), findsOneWidget);
    expect(
      find.text(t.second_screen_manga_page(current: 37, total: 182)),
      findsOneWidget,
    );
    expect(find.text('Series · Chapter 9'), findsOneWidget);
    expect(find.text('Author · Comedy, Slice of life'), findsOneWidget);
    expect(find.text(t.second_screen_manga_text_label), findsOneWidget);
    expect(find.text(_line1), findsOneWidget);
    expect(find.text(_line2), findsOneWidget);
    expect(
      find.text(
        '${t.second_screen_manga_chapter_position(current: 9, total: 24)} ›',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty snapshot: no page, no chapters, OCR offered', (
    WidgetTester tester,
  ) async {
    final RecordingCompanionSession rec = RecordingCompanionSession();
    rec.push(
      const CompanionContextMessage(
        CompanionContext(CompanionContextKind.manga, title: 'Vol. 1'),
      ),
    );
    await pumpCompanionPanel(
      tester,
      rec.session,
      MangaCompanionPanel(session: rec.session),
    );
    expect(find.text(t.second_screen_manga_header), findsOneWidget);
    expect(find.text('Vol. 1'), findsOneWidget);
    expect(find.text(t.mihon_chapters_title), findsNothing);
    expect(find.text(t.second_screen_manga_about), findsNothing);
    expect(find.text(t.second_screen_manga_ocr_hint), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('local volume: no chapter row, no series info', (
    WidgetTester tester,
  ) async {
    await _pump(tester, <String, Object?>{
      MangaCompanionKeys.title: 'Vol. 2',
      MangaCompanionKeys.page: 0,
      MangaCompanionKeys.pageCount: 10,
      MangaCompanionKeys.ocr: MangaCompanionOcrState.idle.name,
    });
    expect(find.text('Vol. 2'), findsOneWidget);
    expect(find.text(t.mihon_chapters_title), findsNothing);
    expect(companionButton(t.manga_series_next_chapter), findsNothing);
    expect(find.text(t.second_screen_manga_ocr_hint), findsOneWidget);
  });

  testWidgets('each control sends its command', (WidgetTester tester) async {
    final RecordingCompanionSession rec = await _pump(
      tester,
      _sample(ocr: MangaCompanionOcrState.idle, lines: const <String>[]),
    );
    final Map<String, String> controls = <String, String>{
      t.manga_previous_page: MangaCompanionActions.previousPage,
      t.manga_next_page: MangaCompanionActions.nextPage,
      t.manga_series_previous_chapter: MangaCompanionActions.previousChapter,
      t.manga_series_next_chapter: MangaCompanionActions.nextChapter,
      t.second_screen_manga_ocr_action: MangaCompanionActions.ocrPage,
    };
    for (final MapEntry<String, String> c in controls.entries) {
      final Finder button = companionButton(c.key);
      expect(button, findsOneWidget, reason: c.key);
      await tester.tap(button);
      await tester.pump();
      expect(rec.commands.last.kind, CompanionContextKind.manga);
      expect(rec.commands.last.action, c.value, reason: c.key);
    }
    expect(rec.commands, hasLength(controls.length));
  });

  testWidgets('controls are at least 48 dp tall', (WidgetTester tester) async {
    await _pump(tester, _sample(lines: const <String>[]));
    for (final String tooltip in <String>[
      t.manga_previous_page,
      t.manga_next_page,
      t.manga_series_previous_chapter,
      t.manga_series_next_chapter,
      t.second_screen_manga_ocr_action,
    ]) {
      expect(
        tester.getSize(companionButton(tooltip)).height,
        greaterThanOrEqualTo(48),
        reason: tooltip,
      );
    }
  });

  testWidgets('OCR busy state', (WidgetTester tester) async {
    final RecordingCompanionSession rec = await _pump(
      tester,
      _sample(ocr: MangaCompanionOcrState.running, lines: const <String>[]),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text(t.second_screen_manga_ocr_running), findsOneWidget);
    // No second request while one runs.
    await tester.tap(companionButton(t.second_screen_manga_ocr_action));
    await tester.pump();
    expect(rec.commands, isEmpty);
  });

  testWidgets('OCR empty, failed, no engine and unsupported states', (
    WidgetTester tester,
  ) async {
    final RecordingCompanionSession rec = await _pump(
      tester,
      _sample(ocr: MangaCompanionOcrState.empty, lines: const <String>[]),
    );
    expect(find.text(t.second_screen_manga_ocr_empty), findsOneWidget);

    rec.push(
      CompanionSnapshotMessage(
        kind: CompanionContextKind.manga,
        data: _sample(
          ocr: MangaCompanionOcrState.failed,
          lines: const <String>[],
          ocrError: 'model missing',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('${t.second_screen_manga_ocr_failed}\nmodel missing'),
      findsOneWidget,
    );

    rec.push(
      CompanionSnapshotMessage(
        kind: CompanionContextKind.manga,
        data: _sample(
          ocr: MangaCompanionOcrState.noEngine,
          lines: const <String>[],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.manga_reader_ocr_unavailable), findsOneWidget);

    rec.push(
      CompanionSnapshotMessage(
        kind: CompanionContextKind.manga,
        data: _sample(
          ocr: MangaCompanionOcrState.unsupported,
          lines: const <String>[],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.second_screen_manga_ocr_unsupported), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('OCR button is off when the page already has text', (
    WidgetTester tester,
  ) async {
    final RecordingCompanionSession rec = await _pump(tester, _sample());
    await tester.tap(companionButton(t.second_screen_manga_ocr_action));
    await tester.pump();
    expect(rec.commands, isEmpty);
  });

  testWidgets('tapping a word looks it up on the panel', (
    WidgetTester tester,
  ) async {
    final RecordingCompanionSession rec = await _pump(tester, _sample());
    final Finder text = find.text(_line2);

    // First character.
    await tester.tapAt(tester.getTopLeft(text) + const Offset(3, 8));
    await tester.pump();
    CompanionLookupEntry? entry = _container(
      tester,
    ).read(companionLookupControllerProvider).current;
    expect(entry, isNotNull);
    expect(entry!.text, _line2);
    expect(entry.sentence, _line2);
    expect(entry.charIndex, 0);

    // A character further along the line.
    final Rect box = tester.getRect(text);
    await tester.tapAt(Offset(box.left + box.width * 0.5, box.top + 8));
    await tester.pump();
    entry = _container(tester).read(companionLookupControllerProvider).current;
    expect(entry!.charIndex, greaterThan(0));
    expect(entry.charIndex, lessThan(_line2.length));

    // Looked up on the panel itself: nothing goes to the main screen.
    expect(rec.commands, isEmpty);
  });

  testWidgets('chapter list: pushed, tap opens that chapter', (
    WidgetTester tester,
  ) async {
    final RecordingCompanionSession rec = await _pump(tester, _sample());
    await tester.tap(find.text(t.mihon_chapters_title));
    await tester.pumpAndSettle();
    expect(find.text('Chapter 9'), findsOneWidget);
    await tester.tap(find.text('Chapter 9'));
    await tester.pumpAndSettle();
    // The current chapter: nothing to send, the list closes.
    expect(rec.commands, isEmpty);
    expect(find.text(t.second_screen_manga_header), findsOneWidget);

    await tester.tap(find.text(t.mihon_chapters_title));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chapter 10'));
    await tester.pumpAndSettle();
    expect(rec.commands.single.action, MangaCompanionActions.goToChapter);
    // Reading order position 10 = source index 24 - 10.
    expect(rec.commands.single.args[MangaCompanionActions.argIndex], 14);
    expect(find.text(t.second_screen_manga_header), findsOneWidget);
  });

  testWidgets('description opens in full', (WidgetTester tester) async {
    await _pump(tester, _sample());
    await tester.scrollUntilVisible(
      find.text('A long description of the series.'),
      100,
    );
    await tester.tap(find.text('A long description of the series.'));
    await tester.pumpAndSettle();
    expect(find.text(t.second_screen_manga_about), findsOneWidget);
    expect(find.text('Series'), findsOneWidget);
  });
}
