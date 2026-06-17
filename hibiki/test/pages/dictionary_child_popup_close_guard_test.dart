import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-485 guard: when swipe-to-close is disabled, nested dictionary popups
/// still need a visible, focusable way to return to their parent layer.
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('shared popup layer has a separate child-back affordance', () {
    final String layer =
        read('lib/src/pages/implementations/dictionary_popup_layer.dart');

    expect(layer, contains('final VoidCallback? onBack;'));
    expect(layer, contains('Icons.arrow_back'));
    expect(
        layer, contains('MaterialLocalizations.of(context).backButtonTooltip'));
    expect(layer, contains('onTap: onBack'));
    expect(layer, contains('onTap: onClose'));
  });

  test('reader host keeps top close but gives nested layers a back action', () {
    final String base = read('lib/src/pages/base_source_page.dart');

    expect(base,
        contains('onClose: index == 0 ? () => _dismissPopupAt(0) : null'));
    expect(base,
        contains('onBack: index > 0 ? () => _dismissPopupAt(index) : null'));
  });

  test('mixin hosts keep top close but give nested layers a back action', () {
    final String mixin =
        read('lib/src/pages/implementations/dictionary_page_mixin.dart');

    expect(mixin, contains('onClose: index == 0 ? () => onPop(0) : null'));
    expect(mixin, contains('onBack: index > 0 ? () => onPop(index) : null'));
  });

  test(
      'standalone popup avoids duplicate top close and only backs child layers',
      () {
    final String popup =
        read('lib/src/pages/implementations/popup_dictionary_page.dart');

    expect(popup, contains('onClose: null'));
    expect(popup, contains('onBack: isBase ? null : () => _popAt(index)'));
    expect(popup, contains('swipeDismissible: !isBase'));
  });
}
