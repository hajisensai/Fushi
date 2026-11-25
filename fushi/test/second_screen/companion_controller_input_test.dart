import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_lookup_controller.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_shell.dart';
import 'package:fushi/src/shortcuts/dictionary_popup_gamepad.dart';
import 'package:fushi/src/utils/adaptive/legacy_design_compat.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:material_ui/material_ui.dart';

/// S6: the top screen's controller drives the companion shell (R1 panel
/// drive, lookup actions), a backlog lookup still opens the Lookup tab, and
/// the panel's lookups are counted by the main engine.
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
    session.receive(const CompanionSummaryMessage(null).encode());
  });

  tearDown(DictionaryPopupGamepadRegistry.debugClear);

  void push(CompanionHostMessage message) => session.receive(message.encode());

  Future<ProviderContainer> pumpShell(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(470, 540);
    addTearDown(tester.view.reset);
    final ProviderContainer container = ProviderContainer(
      overrides: [
        companionPanelSessionProvider.overrideWith((Ref ref) => session),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            builder: (BuildContext context, Widget? child) =>
                LegacyDesignCompatibility(
                  child: FushiGlassScope(child: child!),
                ),
            home: CompanionShell(
              key: shellKey,
              lookupTab: const Center(child: Text('dictionary')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('a lookup waiting in the backlog opens on the Lookup tab', (
    WidgetTester tester,
  ) async {
    push(const CompanionLookupMessage(text: '吾輩は猫である', charIndex: 3));
    await pumpShell(tester);
    expect(shellKey.currentState!.tab, CompanionTab.lookup);
  });

  testWidgets('R1 drive: focus ring mode, moves, hint; release hides it', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    final CompanionShellState shell = shellKey.currentState!;
    expect(shell.driving, isFalse);

    push(const CompanionPanelNavMessage(CompanionPanelNav.begin));
    await tester.pumpAndSettle();
    expect(shell.driving, isTrue);
    expect(
      FocusManager.instance.highlightStrategy,
      FocusHighlightStrategy.alwaysTraditional,
    );
    expect(find.text(t.second_screen_panel_drive_hint), findsOneWidget);
    final FocusNode? first = FocusManager.instance.primaryFocus;
    expect(first, isNotNull);

    push(const CompanionPanelNavMessage(CompanionPanelNav.right));
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, isNot(same(first)));

    push(const CompanionPanelNavMessage(CompanionPanelNav.end));
    await tester.pumpAndSettle();
    expect(shell.driving, isFalse);
    expect(
      FocusManager.instance.highlightStrategy,
      FocusHighlightStrategy.automatic,
    );
  });

  testWidgets('R1 + A activates the focused tab button', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    final CompanionShellState shell = shellKey.currentState!;
    push(const CompanionPanelNavMessage(CompanionPanelNav.begin));
    await tester.pumpAndSettle();
    // Walk right through the bottom bar until a tab other than Now is
    // selected by A.
    for (int i = 0; i < 6 && shell.tab == CompanionTab.now; i++) {
      push(const CompanionPanelNavMessage(CompanionPanelNav.right));
      await tester.pumpAndSettle();
      push(const CompanionPanelNavMessage(CompanionPanelNav.activate));
      await tester.pumpAndSettle();
    }
    expect(shell.tab, isNot(CompanionTab.now));
  });

  testWidgets('lookup actions reach the embedded dictionary; close closes', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await pumpShell(tester);
    final List<String> log = <String>[];
    final DictionaryPopupGamepadHooks hooks = DictionaryPopupGamepadHooks(
      hasVisiblePopup: () => true,
      entryMove: (bool forward) async => log.add(forward ? 'next' : 'prev'),
      mineFirstEntry: () async => log.add('mine'),
      playFirstAudio: () async => log.add('audio'),
      scrollBy: (double dy) async => log.add('scroll$dy'),
    );
    DictionaryPopupGamepadRegistry.push(hooks);

    push(const CompanionLookupMessage(text: '猫', charIndex: 0));
    await tester.pumpAndSettle();
    final CompanionLookupController lookup = container.read(
      companionLookupControllerProvider,
    );
    expect(lookup.current, isNotNull);

    push(const CompanionLookupActionMessage(CompanionLookupActions.mine));
    push(const CompanionLookupActionMessage(CompanionLookupActions.playAudio));
    push(const CompanionLookupActionMessage(CompanionLookupActions.nextEntry));
    push(
      const CompanionLookupActionMessage(
        CompanionLookupActions.scroll,
        args: <String, Object?>{CompanionLookupActions.dy: 24},
      ),
    );
    await tester.pump();
    expect(log, <String>['mine', 'audio', 'next', 'scroll24.0']);

    // Off the Lookup tab, close closes the lookup itself.
    shellKey.currentState!.select(CompanionTab.now);
    await tester.pumpAndSettle();
    push(const CompanionLookupActionMessage(CompanionLookupActions.close));
    await tester.pumpAndSettle();
    expect(lookup.current, isNull);
  });

  testWidgets('each dictionary lookup on the panel is reported for counting', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await pumpShell(tester);
    container.read(companionLookupControllerProvider).countLookup();
    await tester.pump();
    expect(sent.whereType<CompanionLookupCountedMessage>(), hasLength(1));
  });
}
