import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// BUG-077: the popup mine button sets `mineButton.disabled = true` and then
// `await mineEntry(...)`. Before the fix the onclick had no try/catch, so a
// rejected mineEntry (Dart handler threw / JS payload-builder error) left the
// '+' stuck disabled with zero feedback. Guard that the failure path always
// restores the button to a clickable '+', so it can never get permanently
// stuck. Pairs with the Dart-side contract test
// (`packages/hibiki_anki/test/mine_entry_never_throws_test.dart`).
void main() {
  test('popup mine button restores itself when mining throws', () {
    final String source = File('assets/popup/popup.js').readAsStringSync();

    final int onclickIdx = source.indexOf('onclick: async () => {');
    expect(onclickIdx, greaterThanOrEqualTo(0),
        reason: 'mine button onclick handler not found');

    // Inspect the mine button onclick body up to the end of createEntryHeader's
    // mineButton element definition.
    final int end = source.indexOf('buttonsContainer.appendChild(mineButton)');
    expect(end, greaterThan(onclickIdx));
    final String onclickBody = source.substring(onclickIdx, end);

    expect(onclickBody, contains('try {'),
        reason: 'mine onclick must guard the await in a try block');
    expect(onclickBody, contains('} catch (e) {'),
        reason: 'mine onclick must catch a rejected mineEntry');
    expect(onclickBody, contains('mineButton.disabled = false'),
        reason:
            'failure path must re-enable the button (never leave it stuck)');
  });
}
