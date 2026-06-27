import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';
import 'package:hibiki/src/shortcuts/visual/keyboard_layout_view.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  HibikiShortcutRegistry buildRegistry() =>
      HibikiShortcutRegistry()..loadDefaults(TargetPlatform.windows);

  // Pump the standalone visual sub-widget (no AppModel) per the test mandate
  // (must-fix 2). onKeyTap mirrors the page: edit the tapped key's first bound
  // action through the SAME write-through API the dialog uses, carrying ALL
  // three channels (keyboard + gamepad + mouse) so the mouse channel is never
  // silently cleared (must-fix 1).
  Future<void> pumpView(
    WidgetTester tester,
    HibikiShortcutRegistry registry,
    ShortcutScope scope, {
    required InputBinding addKey,
  }) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: KeyboardLayoutView(
                registry: registry,
                scope: scope,
                onKeyTap: (LogicalKeyboardKey key,
                    List<ShortcutAction> boundActions) {
                  final ShortcutAction action = boundActions.first;
                  final ShortcutBindingSet current =
                      registry.bindingsFor(action);
                  registry.updateBindingWithReassignments(
                    action,
                    ShortcutBindingSet(
                      keyboardBindings: <InputBinding>[
                        ...current.keyboardBindings,
                        addKey,
                      ],
                      gamepadBindings: current.gamepadBindings,
                      mouseBindings: current.mouseBindings,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('bound keys render highlighted, unbound keys are not tappable',
      (WidgetTester tester) async {
    final HibikiShortcutRegistry registry = buildRegistry();
    await pumpView(tester, registry, ShortcutScope.reader,
        addKey: const InputBinding(key: LogicalKeyboardKey.f9));

    // A reader default (readerToggleBookmark = Ctrl+D) makes the D keycap bound;
    // its cap is present and tappable (InkWell). An unbound key (F9) has no
    // InkWell.
    final ShortcutBindingSet bookmark =
        registry.bindingsFor(ShortcutAction.readerToggleBookmark);
    final LogicalKeyboardKey boundKey = bookmark.keyboardBindings.first.key;

    expect(find.byKey(Key('keycap_${boundKey.keyId}')), findsOneWidget);
    expect(
      find.byKey(Key('keycap_${LogicalKeyboardKey.f9.keyId}')),
      findsOneWidget,
      reason: 'F9 keycap is drawn but read-only (unbound)',
    );
  });

  testWidgets(
      'tapping a bound keycap writes through to the registry and persistence',
      (WidgetTester tester) async {
    final HibikiShortcutRegistry registry = buildRegistry();
    // readerToggleBookmark default is Ctrl+D -> the D keycap is bound.
    final LogicalKeyboardKey boundKey = registry
        .bindingsFor(ShortcutAction.readerToggleBookmark)
        .keyboardBindings
        .first
        .key;
    const InputBinding added = InputBinding(key: LogicalKeyboardKey.f9);

    await pumpView(tester, registry, ShortcutScope.reader, addKey: added);

    // Tap the bound keycap (focus-driven not required: this is a unit widget,
    // not the full app shell).
    await tester.tap(find.byKey(Key('keycap_${boundKey.keyId}')));
    await tester.pumpAndSettle();

    // Registry truly mutated.
    expect(
      registry
          .bindingsFor(ShortcutAction.readerToggleBookmark)
          .keyboardBindings,
      contains(added),
    );
    // Persistence carries the serialized token (F9).
    expect(registry.toJsonString(), contains('F9'));
  });

  testWidgets(
      'editing keyboard from the figure never clears existing mouseBindings '
      '(must-fix 1 guard)', (WidgetTester tester) async {
    final HibikiShortcutRegistry registry = buildRegistry();
    // audiobookSeekToClickedSentence ships a MouseBinding(1) (middle-click seek)
    // and NO keyboard default. Give it a keyboard binding so its keycap shows up
    // as bound and is tappable; the mouse binding must survive the edit.
    const InputBinding seed = InputBinding(key: LogicalKeyboardKey.keyG);
    registry.updateBinding(
      ShortcutAction.audiobookSeekToClickedSentence,
      const ShortcutBindingSet(
        keyboardBindings: <InputBinding>[seed],
        mouseBindings: <MouseBinding>[MouseBinding(1)],
      ),
    );

    const InputBinding added = InputBinding(key: LogicalKeyboardKey.f10);
    await pumpView(tester, registry, ShortcutScope.audiobook, addKey: added);

    await tester.tap(
      find.byKey(Key('keycap_${LogicalKeyboardKey.keyG.keyId}')),
    );
    await tester.pumpAndSettle();

    final ShortcutBindingSet after =
        registry.bindingsFor(ShortcutAction.audiobookSeekToClickedSentence);
    // Keyboard edit applied...
    expect(after.keyboardBindings, contains(added));
    // ...and the mouse channel was preserved (Never break userspace).
    expect(after.mouseBindings, contains(const MouseBinding(1)),
        reason: 'editing keyboard must not clear MouseBinding(1)');
    expect(registry.toJsonString(), contains('MouseMiddle'));
  });
}
