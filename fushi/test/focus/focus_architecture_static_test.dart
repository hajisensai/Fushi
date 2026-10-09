import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/scan_scale.dart';
import '../helpers/source_guard.dart';

final RegExp _rawReveal = RegExp(
  r'(?<![\w$])Scrollable\s*\.\s*ensureVisible(?![\w$])',
);

bool _hasRawReveal(String source) =>
    _rawReveal.hasMatch(maskCommentsAndStrings(source));

void main() {
  test('raw reveal scanner ignores prose and longer identifiers', () {
    expect(
      _hasRawReveal(r"""
      // Scrollable.ensureVisible(context);
      /* Scrollable.ensureVisible(context); */
      final String description = 'Scrollable.ensureVisible';
      FushiScrollable.ensureVisible(context);
      Scrollable.ensureVisibleLater(context);
      $Scrollable.ensureVisible(context);
    """),
      isFalse,
    );
    expect(_hasRawReveal('Scrollable.ensureVisible(context);'), isTrue);
    expect(_hasRawReveal('Scrollable \n . ensureVisible(context);'), isTrue);
    expect(_hasRawReveal('Scrollable.ensureVisible'), isTrue);
  });

  test('focus-driven scrolling is centralized in the focus package', () {
    final Iterable<File> dartFiles = Directory('lib/src')
        .listSync(recursive: true)
        .whereType<File>()
        .where((File file) => file.path.endsWith('.dart'));
    expectScanScale(
      dartFiles.length,
      what: 'lib/src 下的 .dart',
      atLeast: 750,
      measured: 930,
    );

    for (final File file in dartFiles) {
      final String normalized = file.path.replaceAll('\\', '/');
      final String source = file.readAsStringSync();
      if (normalized == 'lib/src/focus/fushi_focus_scroll.dart') {
        expect(_hasRawReveal(source), isTrue);
        continue;
      }
      expect(
        _hasRawReveal(source),
        isFalse,
        reason:
            '$normalized should delegate focus-driven scroll to '
            'FushiFocusScroll instead of owning it locally.',
      );
    }
  });
}
