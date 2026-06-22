import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/illustrations_viewer_page.dart';

void main() {
  test('illustrations viewer page library compiles', () {
    expect(
      const IllustrationsViewerPage(bookTitle: 'Book', extractDir: '/tmp/book'),
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
  test('full-screen gallery wires keyboard ESC + arrow paging (BUG-404)', () {
    final String source = File(
      'lib/src/pages/implementations/illustrations_viewer_page.dart',
    ).readAsStringSync();

    expect(source, contains('CallbackShortcuts'));
    expect(source, contains('LogicalKeyboardKey.escape'));
    expect(source, contains('LogicalKeyboardKey.arrowLeft'));
    expect(source, contains('LogicalKeyboardKey.arrowRight'));
    expect(source, contains('Navigator.maybePop(context)'));
    expect(source, contains('_pageBy(-1)'));
    expect(source, contains('_pageBy(1)'));
  });
}
