import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Stream cards are mined for another device, so they must follow the host's
/// mining target (Anki or Fushi review) like interconnect forwarding and the
/// browser extension. A bare Anki backend failed every card on hosts that
/// mine into Fushi review without an Anki deck.
void main() {
  test('game-stream mining uses the host-mining repository', () {
    final String source = File(
      'lib/src/models/app_model.dart',
    ).readAsStringSync();
    final int start = source.indexOf(
      'FushiGameStreamMiningAdapter createGameStreamMiningAdapter()',
    );
    expect(start, isNonNegative);
    final String body = source.substring(start, source.indexOf('\n  }', start));
    expect(body, contains('repository: () => hostMiningAnkiRepository'));
    expect(body, isNot(contains('createAnkiRepository')));
  });
}
