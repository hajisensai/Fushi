import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_lookup_controller.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_lookup_tab.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_shell.dart';
import 'package:fushi/src/utils/adaptive/legacy_design_compat.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:material_ui/material_ui.dart';

import 'companion_panel_harness.dart';

const String _line = '私はその人を常に先生と呼んでいた。';

/// Stand-in for the popup dictionary page (needs the popup AppModel).
Widget _fakeDictionary(
  BuildContext context,
  CompanionLookupEntry entry,
  int generation,
  CompanionLookupController controller,
) => Center(child: Text('dict:${entry.term}:$generation'));

List<CompanionLookupStateMessage> _states(RecordingCompanionSession s) =>
    s.sent.whereType<CompanionLookupStateMessage>().toList();

void main() {
  group('companionLookupTerm', () {
    test('the run from the tapped index; whole text without one', () {
      expect(companionLookupTerm(_line, 8), '先生と呼んでいた');
      expect(companionLookupTerm(_line, 0), '私はその人を常に');
      expect(companionLookupTerm('  先生 ', -1), '先生');
      expect(companionLookupTerm('先生、こんにちは', 0), '先生');
      expect(companionLookupTerm(_line, 99), _line);
    });
  });

  group('CompanionLookupController', () {
    late RecordingCompanionSession rec;
    late CompanionLookupController lookup;

    setUp(() {
      rec = RecordingCompanionSession();
      lookup = CompanionLookupController(session: rec.session);
    });

    tearDown(() => lookup.dispose());

    test('a main-screen lookup is shown, recorded and reported open', () async {
      rec.push(
        const CompanionContextMessage(
          CompanionContext(CompanionContextKind.reader, title: 'こころ'),
        ),
      );
      rec.push(
        const CompanionLookupMessage(
          text: _line,
          charIndex: 8,
          sentence: _line,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(lookup.current!.term, '先生と呼んでいた');
      expect(lookup.current!.source, 'こころ');
      expect(lookup.arrivals, 1);
      expect(lookup.history, hasLength(1));
      expect(_states(rec).single.open, isTrue);
      expect(_states(rec).single.term, '先生と呼んでいた');
    });

    test('the same word again moves to the top; history is capped', () {
      lookup
        ..lookUp(text: '先生')
        ..lookUp(text: '書生')
        ..lookUp(text: '先生');
      expect(lookup.history.map((CompanionLookupEntry e) => e.term), <String>[
        '先生',
        '書生',
      ]);
      for (int i = 0; i < CompanionLookupController.maxHistory + 5; i++) {
        lookup.lookUp(text: 'w$i');
      }
      expect(lookup.history, hasLength(CompanionLookupController.maxHistory));
      expect(
        lookup.history.first.term,
        'w${CompanionLookupController.maxHistory + 4}',
      );
    });

    test('panel lookups do not count as arrivals; replay bumps the '
        'generation', () {
      lookup.lookUp(text: _line, charIndex: 8, sentence: _line);
      expect(lookup.arrivals, 0);
      final int generation = lookup.generation;
      lookup.replay(lookup.history.first);
      expect(lookup.generation, generation + 1);
      expect(lookup.history, hasLength(1));
    });

    test('close reports the panel closed and keeps the history', () async {
      lookup.lookUp(text: '先生');
      lookup.close();
      await Future<void>.delayed(Duration.zero);
      expect(lookup.current, isNull);
      expect(lookup.history, hasLength(1));
      expect(_states(rec).last.open, isFalse);
      lookup.reportMined();
      expect(_states(rec), hasLength(2), reason: 'nothing open, nothing mined');
    });

    test('mined is reported with the term', () async {
      lookup
        ..lookUp(text: '先生')
        ..reportMined();
      await Future<void>.delayed(Duration.zero);
      expect(_states(rec).last.mined, isTrue);
      expect(_states(rec).last.term, '先生');
    });
  });

  group('Lookup tab', () {
    late RecordingCompanionSession rec;

    setUp(() => rec = RecordingCompanionSession());

    testWidgets('empty: the hint; a lookup: dictionary + recent row; close: '
        'history list, tap looks up again', (WidgetTester tester) async {
      await pumpCompanionPanel(
        tester,
        rec.session,
        const CompanionLookupTab(dictionaryBuilder: _fakeDictionary),
      );
      expect(find.text(t.second_screen_lookup_empty), findsOneWidget);

      rec.push(const CompanionLookupMessage(text: '書生'));
      await tester.pumpAndSettle();
      rec.push(
        const CompanionLookupMessage(
          text: _line,
          charIndex: 8,
          sentence: _line,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('dict:先生と呼んでいた:2'), findsOneWidget);
      expect(find.text(t.second_screen_lookup_recent), findsOneWidget);
      // Recent row: the earlier lookup.
      await tester.tap(
        find.byKey(const ValueKey<String>('companion-recent-0')),
      );
      await tester.pumpAndSettle();
      expect(find.text('dict:書生:3'), findsOneWidget);

      await tester.tap(companionButton(t.second_screen_lookup_close));
      await tester.pumpAndSettle();
      expect(find.textContaining('dict:'), findsNothing);
      expect(find.text('書生'), findsOneWidget);
      expect(find.text('先生と呼んでいた'), findsOneWidget);
      await tester.tap(find.text('先生と呼んでいた'));
      await tester.pumpAndSettle();
      expect(find.text('dict:先生と呼んでいた:4'), findsOneWidget);
    });

    testWidgets('a main-screen lookup switches to the Lookup tab; closing it '
        'goes back to where the user was', (WidgetTester tester) async {
      final GlobalKey<CompanionShellState> shell =
          GlobalKey<CompanionShellState>();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(470, 540);
      addTearDown(tester.view.reset);
      rec.push(
        const CompanionSummaryMessage(
          CompanionDailySummary(dayKey: '2026-11-07'),
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            companionPanelSessionProvider.overrideWith(
              (Ref ref) => rec.session,
            ),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              builder: (BuildContext context, Widget? child) =>
                  LegacyDesignCompatibility(
                    child: FushiGlassScope(child: child!),
                  ),
              home: CompanionShell(
                key: shell,
                lookupTab: const CompanionLookupTab(
                  dictionaryBuilder: _fakeDictionary,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      shell.currentState!.select(CompanionTab.library);
      await tester.pumpAndSettle();

      rec.push(const CompanionLookupMessage(text: '先生'));
      await tester.pumpAndSettle();
      expect(shell.currentState!.tab, CompanionTab.lookup);
      expect(find.text('dict:先生:1'), findsOneWidget);

      await tester.tap(companionButton(t.second_screen_lookup_close));
      await tester.pumpAndSettle();
      expect(shell.currentState!.tab, CompanionTab.library);

      // The user picks Lookup themselves: closing keeps them there.
      rec.push(const CompanionLookupMessage(text: '書生'));
      await tester.pumpAndSettle();
      shell.currentState!.select(CompanionTab.lookup);
      await tester.tap(companionButton(t.second_screen_lookup_close));
      await tester.pumpAndSettle();
      expect(shell.currentState!.tab, CompanionTab.lookup);
    });
  });
}
