import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

/// BUG-048: An [AdaptiveSettingsTextField] with no explicit focusId must still
/// register as a geometric focus anchor. Otherwise, when an arrow key escapes
/// the focused single-line field, [HibikiFocusController.move] cannot find the
/// active entry and dead-reckons to the FIRST registered row — which can sit
/// ABOVE the field (e.g. the AnkiConnect Host field below the "从 AnkiDroid 获取"
/// row), so Down jumps UP.
void main() {
  testWidgets(
      'AnkiConnect-style settings text fields navigate Down to the next field, '
      'not up to the row above (BUG-048)', (WidgetTester tester) async {
    final FocusNode hostNode = FocusNode(debugLabel: 'host');
    final FocusNode portNode = FocusNode(debugLabel: 'port');
    final FocusNode apiNode = FocusNode(debugLabel: 'api');
    int fetchTaps = 0;
    addTearDown(hostNode.dispose);
    addTearDown(portNode.dispose);
    addTearDown(apiNode.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HibikiFocusRoot(
          child: Column(
            children: <Widget>[
              // A registered, tappable row ABOVE the fields — this is the row
              // the broken reading-order fallback wrongly jumped to.
              AdaptiveSettingsRow(
                title: 'Fetch',
                onTap: () => fetchTaps += 1,
              ),
              AdaptiveSettingsTextField(focusNode: hostNode, hintText: 'host'),
              AdaptiveSettingsTextField(focusNode: portNode, hintText: 'port'),
              AdaptiveSettingsTextField(focusNode: apiNode, hintText: 'api'),
            ],
          ),
        ),
      ),
    ));
    // Two frames: the focus-target anchors register in a post-frame callback.
    await tester.pump();
    await tester.pump();

    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.text('Fetch')),
    );

    // Focus the Host field directly, as a tap/keyboard would.
    hostNode.requestFocus();
    await tester.pump();
    expect(hostNode.hasPrimaryFocus, isTrue);

    // Down must step to Port (the field directly below) — NOT the Fetch row.
    controller.move(HibikiFocusDirection.down);
    await tester.pump();
    expect(portNode.hasPrimaryFocus, isTrue,
        reason: 'Down from Host must move to Port, not jump up to the row '
            'above (BUG-048).');
    expect(fetchTaps, 0);

    // Down again steps to the API key field.
    controller.move(HibikiFocusDirection.down);
    await tester.pump();
    expect(apiNode.hasPrimaryFocus, isTrue);

    // Up walks back to Port.
    controller.move(HibikiFocusDirection.up);
    await tester.pump();
    expect(portNode.hasPrimaryFocus, isTrue);
  });
}
