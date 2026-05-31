import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('focus-driven scrolling is centralized in the focus package', () {
    final Iterable<File> dartFiles = Directory('lib/src')
        .listSync(recursive: true)
        .whereType<File>()
        .where((File file) => file.path.endsWith('.dart'));

    for (final File file in dartFiles) {
      final String normalized = file.path.replaceAll('\\', '/');
      final String source = file.readAsStringSync();
      if (normalized == 'lib/src/focus/hibiki_focus_scroll.dart') {
        expect(source, contains('Scrollable.ensureVisible'));
        continue;
      }
      expect(
        source,
        isNot(contains('Scrollable.ensureVisible')),
        reason: '$normalized should delegate focus-driven scroll to '
            'HibikiFocusScroll instead of owning it locally.',
      );
    }
  });
}
