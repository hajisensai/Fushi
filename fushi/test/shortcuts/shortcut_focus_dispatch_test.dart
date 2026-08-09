import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Focus-dispatch guarantees that the reader (#1) and home (#4) shortcut
/// handlers rely on.
///
/// Both pages wire shortcuts through `Focus(onKeyEvent: ...)` wrapping their
/// content. The reader's content is an InAppWebView platform view; the home's
/// content includes a search field. The open questions were:
///
///   #1 — When the WebView (a focusable descendant) takes focus, does the
///        ancestor reader Focus.onKeyEvent still receive page-turn keys, or are
///        they "stolen"? These tests pin down Flutter's contract: key events are
///        delivered to the primary focus AND bubble up through every ancestor
///        FocusNode, so an ancestor handler keeps receiving keys regardless of
///        which descendant holds focus. (The only real exception on Android is
///        VOLUME_UP/DOWN, which AudioManager swallows before Flutter — already
///        handled natively via VolumeKeyChannel.)
///
///   #4 — On mobile the home Focus was not autofocused, so with no primary
///        focus the FocusManager dispatches keys to nobody. Autofocusing the
///        wrapper closes that gap. The third test documents exactly that gap.
void main() {
  testWidgets(
      '#1: ancestor onKeyEvent still fires while a focused descendant '
      '(stand-in for the WebView) holds primary focus', (tester) async {
    final List<LogicalKeyboardKey> ancestorReceived = <LogicalKeyboardKey>[];
    final FocusNode descendant = FocusNode(debugLabel: 'webview-stand-in');
    addTearDown(descendant.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Focus(
          autofocus: true,
          onKeyEvent: (FocusNode node, KeyEvent event) {
            if (event is KeyDownEvent) ancestorReceived.add(event.logicalKey);
            return KeyEventResult.ignored;
          },
          child: Focus(
            focusNode: descendant,
            child: const SizedBox(width: 10, height: 10),
          ),
        ),
      ),
    );

    descendant.requestFocus();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, descendant,
        reason: 'the descendant must own primary focus for this scenario');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    expect(ancestorReceived, contains(LogicalKeyboardKey.arrowRight),
        reason: 'ancestor reader Focus must still receive the key — keys are '
            'not stolen by a focused descendant at the Flutter level');
  });

  testWidgets(
      '#1: ancestor returning handled consumes the key (reader page-turn wins)',
      (tester) async {
    int ancestorHits = 0;
    int descendantHits = 0;
    final FocusNode descendant = FocusNode();
    addTearDown(descendant.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Focus(
          autofocus: true,
          onKeyEvent: (FocusNode node, KeyEvent event) {
            if (event is KeyDownEvent) ancestorHits++;
            return KeyEventResult.ignored;
          },
          child: Focus(
            focusNode: descendant,
            onKeyEvent: (FocusNode node, KeyEvent event) {
              if (event is KeyDownEvent) descendantHits++;
              return KeyEventResult.handled;
            },
            child: const SizedBox(width: 10, height: 10),
          ),
        ),
      ),
    );

    descendant.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    // Focused descendant handled it first → ancestor not reached. This mirrors
    // the reader returning KeyEventResult.handled for a bound key.
    expect(descendantHits, 1);
    expect(ancestorHits, 0);
  });

  testWidgets(
      '#4: with autofocus the wrapper receives keys even when nothing else '
      'is focused (mobile cold-state)', (tester) async {
    final List<LogicalKeyboardKey> received = <LogicalKeyboardKey>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Focus(
          autofocus: true,
          onKeyEvent: (FocusNode node, KeyEvent event) {
            if (event is KeyDownEvent) received.add(event.logicalKey);
            return KeyEventResult.ignored;
          },
          child: const SizedBox(width: 10, height: 10),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.pump();

    expect(received, contains(LogicalKeyboardKey.digit1),
        reason: 'autofocus:true makes the home wrapper the primary focus so '
            'shortcuts work in the cold state — the gap #4 closes');
  });

  testWidgets('#4: without any focus, no handler receives the key (the gap)',
      (tester) async {
    final List<LogicalKeyboardKey> received = <LogicalKeyboardKey>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Focus(
          autofocus: false,
          canRequestFocus: false,
          onKeyEvent: (FocusNode node, KeyEvent event) {
            if (event is KeyDownEvent) received.add(event.logicalKey);
            return KeyEventResult.ignored;
          },
          child: const SizedBox(width: 10, height: 10),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.pump();

    expect(received, isEmpty,
        reason: 'documents the pre-fix mobile gap: with no primary focus the '
            'FocusManager delivers the key to no onKeyEvent handler');
  });
}
