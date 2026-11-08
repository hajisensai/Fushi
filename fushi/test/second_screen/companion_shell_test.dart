import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/modules/settings_companion_schema.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_now_tab.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_shell.dart';
import 'package:fushi/src/utils/adaptive/legacy_design_compat.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:material_ui/material_ui.dart';

const CompanionDailySummary _summary = CompanionDailySummary(
  dayKey: '2026-11-07',
  readingMs: 52 * 60000,
  watchingMs: 24 * 60000,
  listeningMs: 18 * 60000,
  srsDue: CompanionSrsDue(newCount: 12, learnCount: 4, reviewCount: 47),
  continueItem: CompanionContinueItem(
    kind: CompanionContinueKind.book,
    title: 'こころ',
    progress: 0.34,
    link: 'fushi://widget/continue?kind=book&id=abc',
  ),
);

void main() {
  late List<CompanionPanelMessage> sent;
  late CompanionPanelSession session;
  final GlobalKey<CompanionShellState> shellKey =
      GlobalKey<CompanionShellState>();

  setUp(() {
    sent = <CompanionPanelMessage>[];
    session = CompanionPanelSession(
      send: (String raw) async => sent.add(CompanionPanelMessage.decode(raw)),
    );
  });

  void push(CompanionHostMessage message) => session.receive(message.encode());

  /// [summary]: what the main engine sent before the shell came up; null =
  /// nothing yet (the summary is loading and its spinner never settles).
  Future<void> pumpShell(
    WidgetTester tester, {
    CompanionSummaryMessage? summary = const CompanionSummaryMessage(_summary),
  }) async {
    if (summary != null) push(summary);
    // The bottom screen of a dual-screen handheld: ~470 x 540 dp.
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(470, 540);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          companionPanelSessionProvider.overrideWith((Ref ref) => session),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            builder: (BuildContext context, Widget? child) =>
                LegacyDesignCompatibility(
                  child: FushiGlassScope(child: child!),
                ),
            home: CompanionShell(key: shellKey),
          ),
        ),
      ),
    );
    if (summary == null) {
      await tester.pump();
    } else {
      await tester.pumpAndSettle();
    }
  }

  /// A bottom-bar destination (the design system's tooltip; the minimised
  /// capsule's hidden copy of the current one is not hit-testable).
  Finder tabButton(String label) => find
      .byWidgetPredicate((Widget w) => w is Tooltip && w.message == label)
      .hitTestable();

  testWidgets('four icon-only tabs: tooltip and semantics label, no '
      'visible text, a wide tap target each', (WidgetTester tester) async {
    await pumpShell(tester);
    for (final String label in <String>[
      t.second_screen_tab_now,
      t.second_screen_tab_library,
      t.second_screen_tab_lookup,
      t.second_screen_tab_settings,
    ]) {
      final Finder button = tabButton(label);
      expect(button, findsOneWidget, reason: label);
      // The destination's tap area (the shared MD3 floating bar's InkWell).
      final Finder target = find
          .ancestor(of: button, matching: find.byType(GestureDetector))
          .first;
      expect(tester.getSize(target).width, greaterThanOrEqualTo(48));
      expect(find.bySemanticsLabel(label), findsWidgets, reason: label);
      // Icon only: no visible text label in the bar.
      expect(find.text(label).hitTestable(), findsNothing, reason: label);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('loading, then the daily summary with data', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester, summary: null);
    expect(
      find.byKey(const ValueKey<String>('companion-summary-loading')),
      findsOneWidget,
    );

    push(const CompanionSummaryMessage(_summary));
    await tester.pumpAndSettle();
    expect(find.text(t.second_screen_summary_title), findsOneWidget);
    expect(find.text(t.second_screen_context_home), findsNothing);
    expect(find.text(t.second_screen_context_none), findsOneWidget);
    expect(find.text(t.widget_label_reading), findsOneWidget);
    expect(find.text(t.widget_label_watching), findsOneWidget);
    expect(find.text(t.widget_label_listening), findsOneWidget);
    expect(find.text(t.second_screen_summary_cards_due(n: 63)), findsOneWidget);
    expect(find.text('こころ'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text(t.second_screen_summary_review_on_top));
    await tester.pump();
    expect(
      sent.whereType<CompanionOpenOnMainMessage>().single.link,
      kCompanionReviewLink,
    );

    sent.clear();
    await tester.tap(tabButton(t.second_screen_continue_on_top(title: 'こころ')));
    await tester.pump();
    expect(
      sent.whereType<CompanionOpenOnMainMessage>().single.link,
      _summary.continueItem!.link,
    );
  });

  testWidgets('a summary without any data shows the empty state', (
    WidgetTester tester,
  ) async {
    await pumpShell(
      tester,
      summary: const CompanionSummaryMessage(
        CompanionDailySummary(dayKey: 'd'),
      ),
    );
    expect(find.text(t.second_screen_summary_empty), findsOneWidget);
    expect(find.text(t.second_screen_summary_review_on_top), findsNothing);
    expect(find.text(t.second_screen_summary_continue), findsNothing);
  });

  testWidgets('a failed summary offers a retry that asks the main engine', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester, summary: const CompanionSummaryMessage(null));
    expect(find.text(t.second_screen_summary_error), findsOneWidget);
    await tester.tap(find.text(t.retry));
    await tester.pump();
    expect(
      sent.whereType<CompanionRequestMessage>().single.method,
      CompanionRequestMethods.refreshSummary,
    );
    expect(
      find.byKey(const ValueKey<String>('companion-summary-loading')),
      findsOneWidget,
    );
  });

  testWidgets('media on top replaces the summary but keeps the tab', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    await tester.tap(tabButton(t.second_screen_tab_library));
    await tester.pumpAndSettle();
    push(
      const CompanionContextMessage(
        CompanionContext(CompanionContextKind.reader, title: '吾輩は猫である'),
      ),
    );
    await tester.pumpAndSettle();
    expect(shellKey.currentState!.tab, CompanionTab.library);

    await tester.tap(tabButton(t.second_screen_tab_now));
    await tester.pumpAndSettle();
    expect(find.text(t.second_screen_context_reader), findsOneWidget);
    expect(find.text('吾輩は猫である'), findsOneWidget);
    expect(find.text(t.second_screen_summary_title), findsNothing);
  });

  testWidgets('each tab keeps its own back history; Back pops only the '
      'current tab and does nothing at its root', (WidgetTester tester) async {
    await pumpShell(tester);
    final CompanionShellState shell = shellKey.currentState!;

    await tester.tap(tabButton(t.second_screen_tab_library));
    await tester.pumpAndSettle();
    shell
        .navigatorOf(CompanionTab.library)!
        .push(
          MaterialPageRoute<void>(
            builder: (BuildContext _) =>
                const Scaffold(body: Text('library detail')),
          ),
        );
    await tester.pumpAndSettle();
    expect(find.text('library detail'), findsOneWidget);

    // Lookup's root: Back does nothing, the panel stays, Library keeps its
    // page.
    await tester.tap(tabButton(t.second_screen_tab_lookup));
    await tester.pumpAndSettle();
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(shell.tab, CompanionTab.lookup);
    expect(find.text(t.second_screen_lookup_empty), findsOneWidget);

    await tester.tap(tabButton(t.second_screen_tab_library));
    await tester.pumpAndSettle();
    expect(find.text('library detail'), findsOneWidget);
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('library detail'), findsNothing);
    expect(shell.tab, CompanionTab.library);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selecting the current tab again goes back to its root', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    final CompanionShellState shell = shellKey.currentState!;
    shell
        .navigatorOf(CompanionTab.now)!
        .push(
          MaterialPageRoute<void>(
            builder: (BuildContext _) => const Scaffold(body: Text('deep')),
          ),
        );
    await tester.pumpAndSettle();
    expect(find.text('deep'), findsOneWidget);
    await tester.tap(tabButton(t.second_screen_tab_now));
    await tester.pumpAndSettle();
    expect(find.text('deep'), findsNothing);
  });

  testWidgets('library tab: Main only while the top shows a library', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    await tester.tap(tabButton(t.second_screen_tab_library));
    await tester.pumpAndSettle();
    expect(find.text(t.second_screen_library_browse_empty), findsOneWidget);
    // Main is disabled: tapping it changes nothing.
    await tester.tap(find.text(t.second_screen_library_mode_main));
    await tester.pumpAndSettle();
    expect(find.text(t.second_screen_library_browse_empty), findsOneWidget);

    push(
      const CompanionContextMessage(
        CompanionContext(
          CompanionContextKind.library,
          library: CompanionLibraryKind.books,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.second_screen_library_main_hint), findsOneWidget);
    expect(
      find.text(t.second_screen_library_main_filtering(library: t.books)),
      findsOneWidget,
    );
    await tester.tap(find.text(t.second_screen_library_mode_browse));
    await tester.pumpAndSettle();
    expect(find.text(t.second_screen_library_browse_empty), findsOneWidget);
  });

  testWidgets('the now-playing bar shows what plays and toggles it', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    await tester.tap(tabButton(t.second_screen_tab_library));
    await tester.pumpAndSettle();
    push(
      const CompanionNowPlayingMessage(
        CompanionNowPlaying(
          kind: CompanionNowPlayingKind.music,
          title: 'song',
          playing: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(t.second_screen_now_playing_on_top(title: 'song')),
      findsOneWidget,
    );
    await tester.tap(tabButton(t.second_screen_now_playing_pause));
    await tester.pump();
    expect(
      sent.whereType<CompanionPlaybackMessage>().single.action,
      CompanionPlaybackAction.toggle,
    );
    push(const CompanionNowPlayingMessage(null));
    await tester.pumpAndSettle();
    expect(tabButton(t.second_screen_now_playing_pause), findsNothing);
  });

  testWidgets('lookup shows its empty state; settings loads when opened', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    await tester.tap(tabButton(t.second_screen_tab_lookup));
    await tester.pumpAndSettle();
    expect(find.text(t.second_screen_lookup_empty), findsOneWidget);
    // The hidden Settings tab asks nothing until it is shown.
    expect(sent.whereType<CompanionRequestMessage>(), isEmpty);
    await tester.tap(tabButton(t.second_screen_tab_settings));
    await tester.pump();
    final CompanionRequestMessage list = sent
        .whereType<CompanionRequestMessage>()
        .single;
    expect(list.method, CompanionRequestMethods.settingsList);
    push(
      CompanionReplyMessage(
        id: list.id,
        value: const CompanionSettingsOverview(
          categories: <CompanionSettingsCategory>[
            CompanionSettingsCategory(id: 'appearance', title: 'Appearance'),
          ],
        ).toJson(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.second_screen_settings_all), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);
  });
}
