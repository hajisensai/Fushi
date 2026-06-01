import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/illustrations_viewer_page.dart';

void main() {
  test('illustrations viewer page library compiles', () {
    expect(
      const IllustrationsViewerPage(bookTitle: 'Book', bookId: 1),
      isA<IllustrationsViewerPage>(),
    );
  });

  test('full-screen gallery handles gamepad paging and zoom', () {
    final String source = File(
      'lib/src/pages/implementations/illustrations_viewer_page.dart',
    ).readAsStringSync();

    expect(source, contains('GamepadButtonIntent'));
    expect(source, contains('GamepadButton.rb'));
    expect(source, contains('GamepadButton.lb'));
    expect(source, contains('GamepadButton.thumbRight'));
    expect(source, contains('TransformationController'));
    expect(source, contains('_toggleZoom'));
  });
}
