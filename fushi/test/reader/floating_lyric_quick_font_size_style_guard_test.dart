import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-3389：阅读器快捷设置改悬浮字幕字号时，原实现手拼一次
/// `FloatingLyricChannel.updateStyle(...)` 只带字号与几种颜色，漏了圆角 / 窗宽
/// （以及字体、排版、描边、工具条配色）。原生 `StyleFromArgs` 对缺字段回落结构体
/// 默认值，于是改一次字号圆角就变直角、自设窗宽丢失。修法：与设置页走同一条
/// 整份重推链路 `audiobookSession.applyFloatingLyricStyle()`。
void main() {
  final String src = File(
    'lib/src/pages/implementations/reader_fushi/chrome.part.dart',
  ).readAsStringSync().replaceAll('\r\n', '\n');

  test('快捷设置字号回调整份重推样式，不再手拼 updateStyle', () {
    final int at = src.indexOf('onFloatingLyricFontSizeChanged:');
    expect(at, greaterThan(0));
    final String block = src.substring(
      at,
      src.indexOf('floatingLyricClickLookup:', at),
    );
    expect(block.contains('applyFloatingLyricStyle()'), isTrue);
    expect(
      block.contains('FloatingLyricChannel.updateStyle('),
      isFalse,
      reason: '手拼 updateStyle 会把未传字段打回原生默认值',
    );
  });
}
