import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/modules/library_companion_schema.dart';
import 'package:fushi/src/second_screen/companion/modules/settings_companion_schema.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_lookup_controller.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_lookup_tab.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_shell.dart';
import 'package:fushi/src/second_screen/panel/companion/library/companion_library_tab.dart';
import 'package:fushi/src/utils/adaptive/legacy_design_compat.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:material_ui/material_ui.dart';

import 'companion_panel_harness.dart';

Widget _fakeDictionary(
  BuildContext context,
  CompanionLookupEntry entry,
  int generation,
  CompanionLookupController controller,
) => Center(child: Text('dict:${entry.term}'));

/// Pumps a whole companion panel (a fresh one per call, like a relaunch).
Future<GlobalKey<CompanionShellState>> _pumpPanel(
  WidgetTester tester,
  RecordingCompanionSession rec,
) async {
  final GlobalKey<CompanionShellState> shell = GlobalKey<CompanionShellState>();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(470, 540);
  addTearDown(tester.view.reset);
  // The Now tab's summary (its loading indicator never settles).
  rec.push(
    const CompanionSummaryMessage(CompanionDailySummary(dayKey: '2026-11-08')),
  );
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [
        companionPanelSessionProvider.overrideWith((Ref ref) => rec.session),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          builder: (BuildContext context, Widget? child) =>
              LegacyDesignCompatibility(child: FushiGlassScope(child: child!)),
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
  return shell;
}

List<CompanionPanelUiState> _reports(RecordingCompanionSession rec) =>
    <CompanionPanelUiState>[
      for (final CompanionUiStateMessage m
          in rec.sent.whereType<CompanionUiStateMessage>())
        m.state,
    ];

Finder _chip(CompanionLibrarySection s) =>
    find.byKey(ValueKey<String>('companion-library-section-${s.wire}'));

Finder _field(String key) => find.descendant(
  of: find.byKey(ValueKey<String>(key)),
  matching: find.byType(EditableText),
);

String _text(WidgetTester tester, String key) =>
    tester.widget<EditableText>(_field(key)).controller.text;

const CompanionSettingsCategory _reading = CompanionSettingsCategory(
  id: 'reading',
  title: 'Reading',
);

/// Answers every settings request not answered yet (an empty overview /
/// category page / search), so no loading indicator keeps spinning.
void _answerSettings(RecordingCompanionSession rec, Set<int> answered) {
  for (final CompanionRequestMessage r
      in rec.sent.whereType<CompanionRequestMessage>().toList()) {
    if (r.method != CompanionRequestMethods.settingsList ||
        !answered.add(r.id)) {
      continue;
    }
    final Map<String, Object?> value =
        r.args[CompanionSettingsArgs.category] != null
        ? const CompanionSettingsPage(
            category: _reading,
            rows: <CompanionSettingRow>[],
          ).toJson()
        : r.args[CompanionSettingsArgs.query] != null
        ? const CompanionSettingsPage(rows: <CompanionSettingRow>[]).toJson()
        : const CompanionSettingsOverview(
            categories: <CompanionSettingsCategory>[_reading],
          ).toJson();
    rec.push(CompanionReplyMessage(id: r.id, value: value));
  }
}

void main() {
  test('the UI state and its messages survive the wire; unknown / missing '
      'values come back as defaults', () {
    const CompanionPanelUiState state = CompanionPanelUiState(
      tab: 'library',
      libraryMode: 'browse',
      librarySection: 'manga',
      libraryQuery: 'ナルト',
      settingsCategory: 'reading',
      settingsQuery: 'font',
    );
    final CompanionPanelMessage up = CompanionPanelMessage.decode(
      const CompanionUiStateMessage(state).encode(),
    );
    expect((up as CompanionUiStateMessage).state, state);
    final CompanionHostMessage down = CompanionHostMessage.decode(
      const CompanionUiRestoreMessage(state).encode(),
    );
    expect((down as CompanionUiRestoreMessage).state, state);
    expect(
      CompanionPanelUiState.fromJson(const <String, Object?>{'tab': 3}),
      const CompanionPanelUiState(),
    );
    expect(const CompanionPanelUiState().toJson(), isEmpty);
    expect(CompanionTab.fromWire('nope'), isNull);
    expect(
      CompanionLibraryMode.fromWire('browse'),
      CompanionLibraryMode.browse,
    );
  });

  testWidgets('a relaunched panel opens where the last one was: tab, '
      'Library mode, Browse section and search', (WidgetTester tester) async {
    // The first panel: the user moves around; every change is reported.
    final RecordingCompanionSession first = RecordingCompanionSession();
    final GlobalKey<CompanionShellState> shell1 = await _pumpPanel(
      tester,
      first,
    );
    shell1.currentState!.select(CompanionTab.library);
    await tester.pumpAndSettle();
    tester
        .state<CompanionLibraryTabState>(find.byType(CompanionLibraryTab))
        .selectMode(CompanionLibraryMode.browse);
    await tester.pumpAndSettle();
    await tester.tap(_chip(CompanionLibrarySection.manga));
    await tester.pumpAndSettle();
    await tester.enterText(_field('companion-library-search'), 'ナルト');
    await tester.pumpAndSettle();

    final CompanionPanelUiState last = _reports(first).last;
    expect(
      last,
      const CompanionPanelUiState(
        tab: 'library',
        libraryMode: 'browse',
        librarySection: 'manga',
        libraryQuery: 'ナルト',
      ),
    );

    // The top activity stopped (file picker): the panel finished. The main
    // engine kept the last report and hands it to the new panel on ready.
    final RecordingCompanionSession second = RecordingCompanionSession();
    final GlobalKey<CompanionShellState> shell2 = await _pumpPanel(
      tester,
      second,
    );
    expect(shell2.currentState!.tab, CompanionTab.now);
    second.push(CompanionUiRestoreMessage(last));
    await tester.pumpAndSettle();

    expect(shell2.currentState!.tab, CompanionTab.library);
    expect(
      tester
          .widget<FushiChoiceChip>(_chip(CompanionLibrarySection.manga))
          .selected,
      isTrue,
    );
    expect(_text(tester, 'companion-library-search'), 'ナルト');
    // The Browse list got the restored query.
    expect(
      second.sent.whereType<CompanionRequestMessage>().where(
        (CompanionRequestMessage r) =>
            r.method == CompanionRequestMethods.libraryList &&
            r.args[CompanionLibraryArgs.section] == 'manga',
      ),
      isNotEmpty,
    );
    // Restoring is not a change: nothing is reported back.
    expect(_reports(second), isEmpty);
  });

  testWidgets('the Settings tab gets its category page and search back; '
      'leaving the page is reported', (WidgetTester tester) async {
    final RecordingCompanionSession rec = RecordingCompanionSession();
    final GlobalKey<CompanionShellState> shell = await _pumpPanel(tester, rec);
    rec.push(
      const CompanionUiRestoreMessage(
        CompanionPanelUiState(
          tab: 'settings',
          settingsCategory: 'reading',
          settingsQuery: 'font',
        ),
      ),
    );
    final Set<int> answered = <int>{};
    await tester.pump();
    _answerSettings(rec, answered);
    await tester.pumpAndSettle();
    expect(shell.currentState!.tab, CompanionTab.settings);
    expect(
      find.byKey(const ValueKey<String>('companion-settings-category-open')),
      findsOneWidget,
    );
    expect(
      rec.sent.whereType<CompanionRequestMessage>().where(
        (CompanionRequestMessage r) =>
            r.method == CompanionRequestMethods.settingsList &&
            r.args[CompanionSettingsArgs.category] == 'reading',
      ),
      isNotEmpty,
    );
    expect(_reports(rec), isEmpty);

    // Settings again: back to the tab's root, the page is gone.
    shell.currentState!.select(CompanionTab.settings);
    await tester.pump();
    _answerSettings(rec, answered);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('companion-settings-category-open')),
      findsNothing,
    );
    expect(_text(tester, 'companion-settings-search'), 'font');
    expect(
      _reports(rec).last,
      const CompanionPanelUiState(tab: 'settings', settingsQuery: 'font'),
    );
  });

  testWidgets('a lookup showing on the new panel keeps the Lookup tab; '
      'closing it returns to the restored tab', (WidgetTester tester) async {
    final RecordingCompanionSession rec = RecordingCompanionSession();
    final GlobalKey<CompanionShellState> shell = await _pumpPanel(tester, rec);
    rec.push(const CompanionLookupMessage(text: '先生'));
    await tester.pumpAndSettle();
    expect(shell.currentState!.tab, CompanionTab.lookup);
    rec.push(
      const CompanionUiRestoreMessage(CompanionPanelUiState(tab: 'library')),
    );
    await tester.pumpAndSettle();
    expect(shell.currentState!.tab, CompanionTab.lookup);
    await tester.tap(companionButton(t.second_screen_lookup_close));
    await tester.pumpAndSettle();
    expect(shell.currentState!.tab, CompanionTab.library);
  });
}
