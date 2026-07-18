import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('browser extension requests the compact popup lookup contract', () {
    final String toolBackground =
        File('../tools/browser-extension/background.js').readAsStringSync();
    final String assetBackground =
        File('assets/browser_extension/background.js').readAsStringSync();

    expect(toolBackground, contains('popupOnly: true'));
    expect(assetBackground, contains('popupOnly: true'));
    expect(toolBackground, equals(assetBackground));
  });
}
