import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：弹窗层的 BUG-135 parking（隐藏热槽停屏外 `screen.width + 8`）+ Visibility
/// (maintainState/Animation/Size) 几何只有一份（[parkedPopupLayer] in
/// dictionary_popup_layer.dart）。base_source_page._buildPopupLayer 与
/// dictionary_page_mixin.buildNestedPopupLayer 此前各写一份，改一处忘另一处即漂移。
void main() {
  final String layer = File(
    'lib/src/pages/implementations/dictionary_popup_layer.dart',
  ).readAsStringSync();
  final String base =
      File('lib/src/pages/base_source_page.dart').readAsStringSync();
  final String mixin = File(
    'lib/src/pages/implementations/dictionary_page_mixin.dart',
  ).readAsStringSync();

  group('弹窗层 parking 几何单一真相 parkedPopupLayer', () {
    test('parkedPopupLayer 定义存在且实现 BUG-135 停屏外 + Visibility 保活', () {
      expect(layer, contains('Widget parkedPopupLayer('));
      expect(layer, contains('visible ? pos.left : screen.width + 8'),
          reason: '隐藏层停到屏幕右外侧（BUG-135）');
      expect(layer, contains('maintainState: true'),
          reason: '隐藏热槽 WebView 保活预热（BUG-094）');
    });

    test('base 与 mixin 都转调 parkedPopupLayer，不再各自内联 parking', () {
      for (final String src in <String>[base, mixin]) {
        expect(src, contains('parkedPopupLayer('),
            reason: '弹窗层渲染必须经 parkedPopupLayer');
        expect(src.contains('parked ? screen.width + 8'), isFalse,
            reason: '不应再内联 BUG-135 parking 偏移');
      }
    });
  });
}
