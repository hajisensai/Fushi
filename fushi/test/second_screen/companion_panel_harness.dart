import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:fushi/src/utils/adaptive/legacy_design_compat.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:material_ui/material_ui.dart';

/// A panel session that records what the panel sends.
class RecordingCompanionSession {
  RecordingCompanionSession() {
    session = CompanionPanelSession(
      send: (String raw) async => sent.add(CompanionPanelMessage.decode(raw)),
    );
  }

  late final CompanionPanelSession session;
  final List<CompanionPanelMessage> sent = <CompanionPanelMessage>[];

  /// Feeds a host message (context, snapshot, lookup ...).
  void push(CompanionHostMessage message) => session.receive(message.encode());

  /// Sets the context and its snapshot in one go.
  void show(
    CompanionContextKind kind,
    Map<String, Object?> snapshot, {
    String? title,
  }) {
    push(CompanionContextMessage(CompanionContext(kind, title: title)));
    push(CompanionSnapshotMessage(kind: kind, data: snapshot));
  }

  /// The module commands sent so far.
  List<CompanionCommandMessage> get commands =>
      sent.whereType<CompanionCommandMessage>().toList();
}

/// Pumps [child] the way the companion panel runs it, on the bottom screen
/// of a dual-screen handheld (~470 x 540 dp).
Future<void> pumpCompanionPanel(
  WidgetTester tester,
  CompanionPanelSession session,
  Widget child, {
  Size size = const Size(470, 540),
  bool settle = true,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        companionPanelSessionProvider.overrideWith((Ref ref) => session),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          builder: (BuildContext context, Widget? child) =>
              LegacyDesignCompatibility(child: FushiGlassScope(child: child!)),
          home: Scaffold(body: child),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

/// A control found by its tooltip / semantics label (icon-only buttons).
Finder companionButton(String tooltip) => find
    .byWidgetPredicate((Widget w) => w is Tooltip && w.message == tooltip)
    .hitTestable();
