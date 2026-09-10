import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';

/// 「弹窗全宽」（对齐 Hoshi Reader Android 的 Full Width 开关）：忽略用户设的最大
/// 宽度，让跟随选区的弹窗横向铺满可用宽度，左右仍各留一条 `padding`。
///
/// 存在的理由是「最大宽度」是绝对逻辑像素——换设备、旋屏、改界面缩放后都得重调，
/// 而窄屏（尤其墨水屏阅读器）上用户要的恒定是「占满」。
///
/// 判别力要点：断言必须同时钉住「开了真的变宽」和「关了仍按 maxWidth」，否则把
/// 实现改成恒 true / 恒 false 都能骗过单边断言。
void main() {
  const Size screen = Size(800, 600);
  const Rect sel = Rect.fromLTWH(100, 200, 50, 20);
  const double padding = 6.0;

  group('resolvePopupRect 的 fullWidth', () {
    test('开启后宽度 = 屏宽减两侧 padding，且左缘贴在 padding 上', () {
      final Rect rect = resolvePopupRect(
        selectionRect: sel,
        screen: screen,
        bottomDocked: false,
        fullWidth: true,
        maxWidth: 360,
        maxHeight: 300,
        padding: padding,
      );

      expect(rect.width, screen.width - padding * 2);
      expect(rect.left, padding);
    });

    test('关闭时仍然只有 maxWidth 那么宽（同一组入参，结果必须不同）', () {
      Rect at({required bool fullWidth}) => resolvePopupRect(
            selectionRect: sel,
            screen: screen,
            bottomDocked: false,
            fullWidth: fullWidth,
            maxWidth: 360,
            maxHeight: 300,
            padding: padding,
          );

      expect(at(fullWidth: false).width, 360);
      expect(at(fullWidth: true).width, greaterThan(at(fullWidth: false).width));
    });

    test('默认值为关闭：不传 fullWidth 与显式传 false 逐字节同结果', () {
      expect(
        resolvePopupRect(
          selectionRect: sel,
          screen: screen,
          bottomDocked: false,
          maxWidth: 360,
          maxHeight: 300,
          padding: padding,
        ),
        resolvePopupRect(
          selectionRect: sel,
          screen: screen,
          bottomDocked: false,
          fullWidth: false,
          maxWidth: 360,
          maxHeight: 300,
          padding: padding,
        ),
      );
    });

    test('底部固定不受影响：dock 面板本来就是全宽，开关不改变它', () {
      Rect docked({required bool fullWidth}) => resolvePopupRect(
            selectionRect: sel,
            screen: screen,
            bottomDocked: true,
            fullWidth: fullWidth,
            maxWidth: 360,
            maxHeight: 300,
            padding: padding,
          );

      // 本条钉的不变式是「fullWidth 开关不改变 dock 面板」——它与 dock 到底有多宽
      // 无关。BUG-2439（#1410）把 dock 改成**真正铺满左右**（不再留 padding），
      // 所以下面那句跟着改成 screen.width；钉「等于屏宽」而不是「屏宽减 padding」，
      // 正是 dock 与跟随模式的区别所在。
      expect(docked(fullWidth: true), docked(fullWidth: false));
      expect(docked(fullWidth: false).width, screen.width);
    });

    test('全宽不会溢出屏幕：右缘仍在 padding 之内', () {
      final Rect rect = resolvePopupRect(
        // 选区贴着右缘，最容易把弹窗推出屏外。
        selectionRect: const Rect.fromLTWH(780, 200, 15, 20),
        screen: screen,
        bottomDocked: false,
        fullWidth: true,
        maxWidth: 360,
        maxHeight: 300,
        padding: padding,
      );

      expect(rect.left, greaterThanOrEqualTo(padding));
      expect(rect.right, lessThanOrEqualTo(screen.width - padding));
    });

    test('全宽时 maxWidth 已不再决定任何东西（设成极小值也一样宽）', () {
      Rect withMax(double maxWidth) => resolvePopupRect(
            selectionRect: sel,
            screen: screen,
            bottomDocked: false,
            fullWidth: true,
            maxWidth: maxWidth,
            maxHeight: 300,
            padding: padding,
          );

      expect(withMax(250), withMax(2000));
    });
  });
}
