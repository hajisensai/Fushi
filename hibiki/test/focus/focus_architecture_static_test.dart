import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../helpers/scan_scale.dart';

void main() {
  test('focus-driven scrolling is centralized in the focus package', () {
    final Iterable<File> dartFiles = Directory('lib/src')
        .listSync(recursive: true)
        .whereType<File>()
        .where((File file) => file.path.endsWith('.dart'));
    expectScanScale(dartFiles.length,
        what: 'lib/src 下的 .dart', atLeast: 750, measured: 930);

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
            'FushiFocusScroll instead of owning it locally.',
      );
    }
  });
}
