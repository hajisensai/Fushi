import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/shortcut_settings/global_hotkey_portal_panel.dart';
import 'package:fushi/src/shortcuts/global_hotkey_backend.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_labels.dart';
import 'package:material_ui/material_ui.dart';

/// Linux Wayland shortcut settings: the desktop owns the app-outside keys, so
/// the keyboard view shows what the GlobalShortcuts portal reports and why
/// hotkeys may be unavailable — never a silent dead recorder.
void main() {
  const List<ShortcutAction> actions = <ShortcutAction>[
    ShortcutAction.globalExternalLookup,
    ShortcutAction.globalExternalOpenLookupPage,
    ShortcutAction.globalExternalScreenOcr,
  ];

  late ValueNotifier<GlobalHotKeyStatus?> status;
  late int rebinds;
  late int configures;
  late bool configureResult;

  setUp(() {
    status = ValueNotifier<GlobalHotKeyStatus?>(null);
    rebinds = 0;
    configures = 0;
    configureResult = true;
  });

  tearDown(() => status.dispose());

  Widget host() => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: GlobalHotKeyPortalPanel(
          status: status,
          actions: actions,
          // Screen OCR needs the lookup card overlay, absent on Wayland here.
          availableHere: (ShortcutAction a) =>
              a != ShortcutAction.globalExternalScreenOcr,
          onRebind: () async => rebinds++,
          onConfigure: () async {
            configures++;
            return configureResult;
          },
        ),
      ),
    ),
  );

  testWidgets('bound: the trigger the desktop reports, "no key" for an '
      'unassigned one, unavailable actions say so', (
    WidgetTester tester,
  ) async {
    status.value = const GlobalHotKeyStatus(
      kind: GlobalHotKeyBackendKind.portal,
      bound: true,
      canConfigure: true,
      triggers: <String, String>{
        'global_external_lookup': 'Ctrl+Alt+D',
        'global_external_open_lookup_page': '',
      },
    );
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.text(t.shortcut_portal_note), findsOneWidget);
    expect(find.text('Ctrl+Alt+D'), findsOneWidget);
    expect(find.text(t.shortcut_portal_trigger_unassigned), findsOneWidget);
    expect(find.text(t.shortcut_portal_trigger_unavailable), findsOneWidget);
    for (final ShortcutAction a in actions) {
      expect(find.text(a.label), findsOneWidget);
    }

    await tester.tap(find.text(t.shortcut_portal_configure));
    await tester.pumpAndSettle();
    expect(configures, 1);
  });

  testWidgets('no portal: one explanation, no rows pretending to work', (
    WidgetTester tester,
  ) async {
    status.value = const GlobalHotKeyStatus(
      kind: GlobalHotKeyBackendKind.portal,
      problem: GlobalHotKeyProblem.portalMissing,
    );
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.text(t.shortcut_portal_missing), findsOneWidget);
    expect(find.text(ShortcutAction.globalExternalLookup.label), findsNothing);
    expect(find.text(t.shortcut_portal_configure), findsNothing);
    expect(find.text(t.shortcut_portal_rebind), findsNothing);
  });

  testWidgets('dialog dismissed: "bind again" re-binds', (
    WidgetTester tester,
  ) async {
    status.value = const GlobalHotKeyStatus(
      kind: GlobalHotKeyBackendKind.portal,
      problem: GlobalHotKeyProblem.dialogCancelled,
    );
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.text(t.shortcut_portal_cancelled), findsOneWidget);
    expect(find.text(t.shortcut_portal_trigger_unbound), findsNWidgets(2));
    await tester.tap(find.text(t.shortcut_portal_rebind));
    await tester.pump();
    expect(rebinds, 1);
  });

  testWidgets('portal v1: no editor to open, so say where to change keys; a '
      'failed configure tells the user', (WidgetTester tester) async {
    status.value = const GlobalHotKeyStatus(
      kind: GlobalHotKeyBackendKind.portal,
      bound: true,
      triggers: <String, String>{'global_external_lookup': 'Ctrl+Alt+D'},
    );
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(find.text(t.shortcut_portal_configure_hint), findsOneWidget);
    expect(find.text(t.shortcut_portal_configure), findsNothing);

    status.value = const GlobalHotKeyStatus(
      kind: GlobalHotKeyBackendKind.portal,
      bound: true,
      canConfigure: true,
    );
    configureResult = false;
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.shortcut_portal_configure));
    await tester.pumpAndSettle();
    expect(find.text(t.shortcut_portal_configure_failed), findsOneWidget);
  });

  testWidgets('before the portal answered: "waiting", not "not bound"', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(find.text(t.shortcut_portal_trigger_pending), findsNWidgets(2));
  });
}
