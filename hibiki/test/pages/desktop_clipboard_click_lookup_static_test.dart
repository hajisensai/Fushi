import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String path) => File(path).readAsStringSync();

  test('HomeDictionaryPage preserves external clipboard text for click lookup',
      () {
    final String src =
        read('lib/src/pages/implementations/home_dictionary_page.dart');

    expect(src, contains('ClipboardLookupTextPanel'));
    expect(src, contains('_externalLookupText'));
    expect(src, contains('_externalLookupText = req.text'));
    expect(src, contains('_pushNestedPopup(query, localRect'));
  });
}
