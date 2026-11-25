import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/modules/srs_companion_schema.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_now_tab.dart'
    show kCompanionReviewLink;
import 'package:fushi/src/second_screen/panel/companion/modules/srs_companion_panel.dart';
import 'package:material_ui/material_ui.dart';

import 'companion_panel_harness.dart';

Map<String, Object?> _sample({
  String phase = SrsCompanionPhases.answer,
  bool canUndo = true,
  bool busy = false,
  bool twoButtons = false,
}) => <String, Object?>{
  SrsCompanionKeys.deck: 'Mined words',
  SrsCompanionKeys.phase: phase,
  SrsCompanionKeys.newCount: 12,
  SrsCompanionKeys.learnCount: 4,
  SrsCompanionKeys.reviewCount: 57,
  SrsCompanionKeys.intervals: <String>['<10 min', '1 day', '3 days', '8 days'],
  SrsCompanionKeys.canUndo: canUndo,
  SrsCompanionKeys.busy: busy,
  SrsCompanionKeys.twoButtons: twoButtons,
};

Future<RecordingCompanionSession> _pump(
  WidgetTester tester,
  Map<String, Object?>? snapshot, {
  CompanionDailySummary? summary,
  bool settle = true,
}) async {
  final RecordingCompanionSession rec = RecordingCompanionSession();
  if (summary != null) rec.push(CompanionSummaryMessage(summary));
  if (snapshot == null) {
    rec.push(
      const CompanionContextMessage(CompanionContext(CompanionContextKind.srs)),
    );
  } else {
    rec.show(CompanionContextKind.srs, snapshot, title: 'Mined words');
  }
  await pumpCompanionPanel(
    tester,
    rec.session,
    SrsCompanionPanel(session: rec.session),
    settle: settle,
  );
  return rec;
}

Finder _key(String key) => find.byKey(ValueKey<String>(key));

void main() {
  testWidgets('answer side: deck, counts, hint, four buttons with intervals', (
    WidgetTester tester,
  ) async {
    await _pump(tester, _sample());
    expect(
      find.text(t.second_screen_srs_reviewing(deck: 'Mined words')),
      findsOneWidget,
    );
    expect(find.text('12'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    expect(find.text('57'), findsOneWidget);
    expect(find.text(t.second_screen_srs_answer_hint), findsOneWidget);
    for (final String s in <String>[
      t.srs_rating_again,
      t.srs_rating_hard,
      t.srs_rating_good,
      t.srs_rating_easy,
      '<10 min',
      '1 day',
      '3 days',
      '8 days',
    ]) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
    for (int r = 1; r <= 4; r++) {
      final Size size = tester.getSize(_key('srs-companion-answer-$r'));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(size.width, greaterThanOrEqualTo(48));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('answer buttons and undo send their commands', (
    WidgetTester tester,
  ) async {
    final RecordingCompanionSession rec = await _pump(tester, _sample());
    for (int r = 1; r <= 4; r++) {
      await tester.tap(_key('srs-companion-answer-$r'));
      await tester.pump();
    }
    await tester.tap(_key('srs-companion-undo'));
    await tester.pump();
    final List<CompanionCommandMessage> c = rec.commands;
    expect(c, hasLength(5));
    for (int r = 1; r <= 4; r++) {
      expect(c[r - 1].kind, CompanionContextKind.srs);
      expect(c[r - 1].action, SrsCompanionActions.answer);
      expect(c[r - 1].args[SrsCompanionKeys.rating], r);
    }
    expect(c[4].action, SrsCompanionActions.undo);
  });

  testWidgets('answer buttons are controller-focusable with labels', (
    WidgetTester tester,
  ) async {
    final RecordingCompanionSession rec = await _pump(tester, _sample());
    final SemanticsHandle semantics = tester.ensureSemantics();
    expect(
      find.bySemanticsLabel('${t.srs_rating_good}, 3 days'),
      findsOneWidget,
    );
    semantics.dispose();
    // Keyboard / controller focus traversal reaches the buttons; Enter
    // activates.
    Focus.of(tester.element(find.text(t.srs_rating_again))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(rec.commands.single.args[SrsCompanionKeys.rating], 1);
  });

  testWidgets('question side: Show answer', (WidgetTester tester) async {
    final RecordingCompanionSession rec = await _pump(
      tester,
      _sample(phase: SrsCompanionPhases.question),
    );
    expect(find.text(t.second_screen_srs_question_hint), findsOneWidget);
    expect(_key('srs-companion-answer-1'), findsNothing);
    await tester.tap(_key('srs-companion-show-answer'));
    await tester.pump();
    expect(rec.commands.single.action, SrsCompanionActions.showAnswer);
  });

  testWidgets('busy / no undo: buttons disabled, nothing sent', (
    WidgetTester tester,
  ) async {
    final RecordingCompanionSession rec = await _pump(
      tester,
      _sample(busy: true, canUndo: false),
    );
    await tester.tap(_key('srs-companion-answer-3'), warnIfMissed: false);
    await tester.tap(_key('srs-companion-undo'), warnIfMissed: false);
    await tester.pump();
    expect(rec.commands, isEmpty);
  });

  testWidgets('two-button decks show Again and Good only', (
    WidgetTester tester,
  ) async {
    await _pump(tester, _sample(twoButtons: true));
    expect(_key('srs-companion-answer-1'), findsOneWidget);
    expect(_key('srs-companion-answer-2'), findsNothing);
    expect(_key('srs-companion-answer-3'), findsOneWidget);
    expect(_key('srs-companion-answer-4'), findsNothing);
  });

  testWidgets('done / unavailable / missing data render without crashing', (
    WidgetTester tester,
  ) async {
    await _pump(tester, _sample(phase: SrsCompanionPhases.done));
    expect(find.text(t.srs_review_done), findsOneWidget);
    await _pump(tester, _sample(phase: SrsCompanionPhases.unavailable));
    expect(find.text(t.second_screen_now_on_top), findsOneWidget);
    // No phase reads as loading (a spinner: do not settle).
    await _pump(tester, const <String, Object?>{}, settle: false);
    expect(find.text(t.second_screen_context_srs), findsOneWidget);
    expect(find.text('0'), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('not reviewing: due counts and Review on top', (
    WidgetTester tester,
  ) async {
    final RecordingCompanionSession rec = await _pump(
      tester,
      null,
      summary: const CompanionDailySummary(
        dayKey: 'd',
        srsDue: CompanionSrsDue(newCount: 3, learnCount: 1, reviewCount: 9),
      ),
    );
    expect(find.text(t.second_screen_summary_cards_due(n: 13)), findsOneWidget);
    await tester.tap(_key('srs-companion-review-on-top'));
    await tester.pump();
    final CompanionOpenOnMainMessage open = rec.sent
        .whereType<CompanionOpenOnMainMessage>()
        .single;
    expect(open.link, kCompanionReviewLink);
  });

  testWidgets('not reviewing, no summary yet: Review on top only', (
    WidgetTester tester,
  ) async {
    await _pump(tester, null);
    expect(_key('srs-companion-review-on-top'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
