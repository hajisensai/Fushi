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
    expect(src, contains('onTextSelected:'));
    expect(src, contains('onLinkClick:'));
    expect(src, contains('PopScope'));
    expect(src, contains('_popAt(_popup.entries.length - 1)'));
    expect(src, contains('PopupChannel.instance.finishPopup()'));
    // 重选/链接下钻时截断当前层之后的栈（按层 index 截断，base/nested 统一）。
    expect(src, contains('_popup.truncateTo(index + 1)'));
  });

  test(
      'BUG-051: nested popup layers render full-size (not the reader '
      'float-near-selection sub-card)', () {
    final String src = File(pagePath).readAsStringSync();
    // app 外查词窗口已是约束卡片：下钻层必须满卡渲染（Positioned.fill），
    // 不能再用全屏阅读器语义的 buildNestedPopupLayer / calcPopupPosition
    // 把子弹窗压成小窗。
    expect(src, contains('Positioned.fill'));
    expect(src, isNot(contains('buildNestedPopupLayer(')),
        reason: '下钻层改为满卡渲染，不再复用阅读器的贴选区小浮卡');
    expect(src, isNot(contains('calcPopupPosition')), reason: '满卡渲染无需按选区定位');
    // 嵌套层不透明铺满盖住下层（base 透明，nested 用词典色/页面色）。
    expect(src, contains('swipeDismissible: !isBase'));
    expect(src, contains('? Colors.transparent'));
  });

  test(
      'TODO-496: popup host swipe-to-close stays on chrome, not the WebView body',
      () {
    final String src = File(pagePath).readAsStringSync();
    // The old outer-card wrapper put the WebView body under the same Listener
    // as swipe-to-close. That made text selection indistinguishable from a
    // dismiss gesture. The popup host may wrap its search/chrome row, while
    // DictionaryPopupLayer handles child layer chrome separately.
    expect(src, contains('_buildSwipeChrome'));
    expect(src, isNot(contains('child: card')));
    expect(src, contains('ReaderHibikiSource.instance.enableSwipeToClose'));
    expect(src, contains('() => _popAt(index)'));
  });
}
