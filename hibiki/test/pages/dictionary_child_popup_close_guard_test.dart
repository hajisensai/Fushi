import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-501 guard: when swipe-to-close is disabled, nested dictionary popups
/// still need a visible, focusable X that pops only the current layer.
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('shared popup layer sizes action affordances consistently', () {
    final String layer =
        read('lib/src/pages/implementations/dictionary_popup_layer.dart');

    expect(layer, contains('final VoidCallback? onBack;'));
    expect(layer, contains('Icons.close'));
    expect(layer, contains('BoxConstraints.tightFor(width: 36, height: 36)'));
    expect(layer, contains('size: 20'));
    expect(layer, contains('onTap: onBack'));
    expect(layer, contains('onTap: onClose'));
  });

  test('reader host routes nested layers through right-side close', () {
    final String base = read('lib/src/pages/base_source_page.dart');

    expect(base, contains('onClose: () => _dismissPopupAt(index)'));
    expect(base, contains('onBack: null'));
  });

  test('mixin hosts route nested layers through right-side close', () {
    final String mixin =
        read('lib/src/pages/implementations/dictionary_page_mixin.dart');

    expect(mixin, contains('onClose: () => onPop(index)'));
    expect(mixin, contains('onBack: null'));
  });

  test('standalone popup keeps search close for base and X-pops child layers',
      () {
    final String popup =
        read('lib/src/pages/implementations/popup_dictionary_page.dart');

    expect(popup, contains('onClose: isBase ? null : () => _popAt(index)'));
    expect(popup, contains('onBack: null'));
    expect(popup, contains('swipeDismissible: !isBase'));
  });

  test('swipe dismiss keeps host layer routing separate from onBack', () {
    final String base = read('lib/src/pages/base_source_page.dart');
    final String mixin =
        read('lib/src/pages/implementations/dictionary_page_mixin.dart');
    final String popup =
        read('lib/src/pages/implementations/popup_dictionary_page.dart');

    expect(base, contains('onDismiss: () => _dismissPopupAt(index)'));
    expect(base, contains('onClose: () => _dismissPopupAt(index)'));

    expect(mixin, contains('onDismiss: () => onPop(index)'));
    expect(mixin, contains('onClose: () => onPop(index)'));

    expect(popup, contains('onDismiss: isBase ? _close : () => _popAt(index)'));
    expect(popup, contains('onClose: isBase ? null : () => _popAt(index)'));
  });
}
