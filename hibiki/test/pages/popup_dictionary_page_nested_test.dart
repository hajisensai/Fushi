import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const String pagePath =
      'lib/src/pages/implementations/popup_dictionary_page.dart';

  test('popup dictionary page keeps the nested lookup stack contract', () {
    final String src = File(pagePath).readAsStringSync();
    expect(src, contains('with DictionaryPageMixin'));
    expect(src, contains('pushNestedPopup('));
    expect(src, contains('popNestedPopupAt('));
    expect(src, contains('buildNestedPopupLayer('));
    expect(src, contains('_stack.removeRange(1, _stack.length)'));
    expect(src, contains('onTextSelected:'));
    expect(src, contains('onLinkClick:'));
    expect(src, contains('PopScope'));
    expect(src, contains('_popAt(_stack.length - 1)'));
    expect(src, contains('PopupChannel.instance.finishPopup()'));
  });
}
