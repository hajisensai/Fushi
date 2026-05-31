import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hardware-nav resume revalidates the top popup caret surface', () {
    final String source = File(
      'lib/src/pages/implementations/reader_hibiki_page.dart',
    ).readAsStringSync();

    expect(source, contains('void _resumePopupCaretForHardwareNav()'));
    expect(source, contains('if (!identical(state, _caretPopupState))'));
    expect(source, contains('unawaited(_transferCaretToTopPopup(state))'));
    expect(source, contains('_caretSurface = CaretSurface.none'));
  });
}
