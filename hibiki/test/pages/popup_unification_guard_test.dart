import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Unification guard (docs/specs/2026-06-07-dictionary-popup-unification-plan.md):
/// both popup-stack owners — base_source_page (reader / audiobook) and the
/// dictionary_page_mixin hosts (video / home / standalone) — must delegate their
/// stack to the single shared [DictionaryPopupController], and the two old
/// duplicate entry types must be gone (collapsed into one DictionaryPopupEntry).
void main() {
  String read(String p) => File(p).readAsStringSync();

  test('both stack owners delegate to the shared DictionaryPopupController', () {
    final base = read('lib/src/pages/base_source_page.dart');
    final mixin =
        read('lib/src/pages/implementations/dictionary_page_mixin.dart');
    expect(base.contains('DictionaryPopupController'), isTrue,
        reason: 'base_source_page must use the shared controller');
    expect(mixin.contains('DictionaryPopupController'), isTrue,
        reason: 'the mixin must use the shared controller');
  });

  test('old duplicate entry types are collapsed into one', () {
    final base = read('lib/src/pages/base_source_page.dart');
    final mixin =
        read('lib/src/pages/implementations/dictionary_page_mixin.dart');
    expect(base.contains('class _PopupStackItem'), isFalse,
        reason: '_PopupStackItem must be removed (unified DictionaryPopupEntry)');
    expect(mixin.contains('class NestedPopupEntry'), isFalse,
        reason: 'NestedPopupEntry must be removed (unified DictionaryPopupEntry)');
  });

  test('the single entry type lives in the controller file', () {
    final controller =
        read('lib/src/pages/implementations/dictionary_popup_controller.dart');
    expect(controller.contains('class DictionaryPopupEntry'), isTrue);
    expect(controller.contains('class DictionaryPopupController'), isTrue);
  });
}
