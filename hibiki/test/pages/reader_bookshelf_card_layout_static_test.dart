import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bookshelf cards use footer layout instead of title cover overlay', () {
    final String source =
        File('lib/src/pages/implementations/reader_hibiki_history_page.dart')
            .readAsStringSync();

    expect(
      source,
      isNot(contains('_titleOverlay(')),
      reason:
          'titles for local, SRT, video, and remote books must not overlay covers',
    );
    expect(
      source,
      isNot(contains('constraints.maxHeight * 0.38')),
      reason: 'the old bottom overlay occupied a large part of the cover',
    );
    expect(
      RegExp(r'(?:child:|return) _bookCardLayout\(').allMatches(source).length,
      greaterThanOrEqualTo(4),
      reason: 'all bookshelf card variants should share the footer layout',
    );
  });
}
