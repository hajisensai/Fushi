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

  // TODO-720 / BUG-403: 点弹窗外（barrier onTap + 弹窗 onTapOutside）只关最顶层一层
  // （逐层退回父层），不一次清整栈。这些路径必须接逐层关原语，不能写死 index 0 /
  // 调清整栈的 clearDictionaryResult。
  test(
      'reader tap-outside routes through dismissTopPopup, not whole-stack clear',
      () {
    final String base = read('lib/src/pages/base_source_page.dart');

    // barrier 全屏 onTap 与弹窗 onTapOutside 都走逐层关原语。
    expect(base, contains('onTap: dismissTopPopup'),
        reason: 'barrier 点外只关最顶层一层');
    expect(base, contains('onTapOutside: dismissTopPopup'), reason: '弹窗点外只关本层');
    // 不再用清整栈的会话级路径接「点外」。
    expect(base, isNot(contains('onTap: clearDictionaryResult')),
        reason: '点外不应清整栈');
    expect(base, isNot(contains('onTapOutside: clearDictionaryResult')),
        reason: '点外不应清整栈');
    // 逐层关原语本体仍在（只关最顶层、保留父层）。
    expect(base,
        contains('final int index = _lastVisiblePopupIndex(_popup.entries);'),
        reason: 'dismissTopPopup 取最顶层可见层下标');
    expect(base, contains('if (index >= 0) _dismissPopupAt(index);'),
        reason: 'dismissTopPopup 只关最顶层（-1 时安全 no-op）');
  });

  test('video tap-outside barrier dismisses only the top visible layer', () {
    final String video =
        read('lib/src/pages/implementations/video_hibiki_page.dart');

    expect(video, contains('_popNestedPopupAt(_topVisiblePopupIndex);'),
        reason: '点外只关最顶层可见层');
    expect(video, isNot(contains('_popNestedPopupAt(0);')),
        reason: '不再写死 index 0 清整栈');
  });

  test('mixin tap-outside pops only the top visible layer', () {
    final String mixin =
        read('lib/src/pages/implementations/dictionary_page_mixin.dart');

    expect(mixin,
        contains('onTapOutside: () => onPop(controller.lastVisibleIndex)'),
        reason: '点外只关最顶层可见层');
    expect(mixin, isNot(contains('onTapOutside: () => onPop(0)')),
        reason: '不再写死 index 0 清整栈');
  });
}
