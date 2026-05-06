import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('vertical continuous highlight scrolls when crossing the safe zone edge',
      () {
    final String source =
        File('lib/src/media/audiobook/audiobook_bridge.dart').readAsStringSync();

    expect(source, contains('rect.left < safeL || rect.right > safeR'));
    expect(source, isNot(contains('rect.right < safeL || rect.left > safeR')));
  });
}
