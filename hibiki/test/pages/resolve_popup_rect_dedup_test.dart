import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';

/// resolvePopupRect 是查词弹窗位置分流（底部固定 dock vs 跟随选区）的单一收口，
/// 收口自 base_source_page._calculatePopupPosition 与
/// dictionary_page_mixin._calcMixinPopupPosition 两份等价包装器。
///
/// ⚠️ 两者语义同构但参数不同（base 传 padding/reserve/verticalWriting，mixin 全用
/// 默认），故 resolvePopupRect 参数化 reserves；本测试断言：mixin 风格调用 ==
/// 直接用默认参数调底层，base 风格调用 == 直接传相应参数调底层（两套行为各自不变）。
void main() {
  const Size screen = Size(800, 600);
  const Rect sel = Rect.fromLTWH(100, 200, 50, 20);

  group('resolvePopupRect 收口两套位置包装器', () {
    test('mixin 风格(默认 padding/reserves): docked == dockedPopupRect 默认', () {
      expect(
        resolvePopupRect(
          selectionRect: sel,
          screen: screen,
          bottomDocked: true,
          maxWidth: 360,
          maxHeight: 300,
        ),
        dockedPopupRect(screen: screen, dockedHeight: 300),
      );
    });

    test('mixin 风格: 非 docked == calcPopupPosition 默认', () {
      expect(
        resolvePopupRect(
          selectionRect: sel,
          screen: screen,
          bottomDocked: false,
          maxWidth: 360,
          maxHeight: 300,
        ),
        calcPopupPosition(
          selectionRect: sel,
          screen: screen,
          maxWidth: 360,
          maxHeight: 300,
        ),
      );
    });

    test('base 风格(传 padding/reserves): docked 等价', () {
      expect(
        resolvePopupRect(
          selectionRect: sel,
          screen: screen,
          bottomDocked: true,
          maxWidth: 360,
          maxHeight: 300,
          padding: 8,
          bottomReserve: 40,
          topReserve: 12,
        ),
        dockedPopupRect(
          screen: screen,
          inset: 8,
          dockedHeight: 300,
          bottomReserve: 40,
          topReserve: 12,
        ),
      );
    });

    test('base 风格: 非 docked 等价(含 verticalWriting)', () {
      expect(
        resolvePopupRect(
          selectionRect: sel,
          screen: screen,
          bottomDocked: false,
          maxWidth: 360,
          maxHeight: 300,
          padding: 8,
          bottomReserve: 40,
          topReserve: 12,
          verticalWriting: true,
        ),
        calcPopupPosition(
          selectionRect: sel,
          screen: screen,
          padding: 8,
          maxWidth: 360,
          maxHeight: 300,
          bottomReserve: 40,
          topReserve: 12,
          verticalWriting: true,
        ),
      );
    });

    test('两包装器都转调 resolvePopupRect', () {
      final String base =
          File('lib/src/pages/base_source_page.dart').readAsStringSync();
      final String mixin = File(
        'lib/src/pages/implementations/dictionary_page_mixin.dart',
      ).readAsStringSync();
      expect(base, contains('resolvePopupRect('),
          reason: 'base._calculatePopupPosition 应转调 resolvePopupRect');
      expect(mixin, contains('resolvePopupRect('),
          reason: 'mixin._calcMixinPopupPosition 应转调 resolvePopupRect');
    });
  });
}
