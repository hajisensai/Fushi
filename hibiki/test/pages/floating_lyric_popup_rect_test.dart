import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';

/// TODO-872：app 外悬浮字幕条查词弹窗按被查字屏幕矩形定位的纯函数
/// [computeFloatingLyricPopupRect]。它复用 [calcPopupPosition] 的横排上/下避让 + clamp
/// 逻辑，这里钉死三态契约：被查字在屏幕中上部时弹窗放下方、靠屏幕底部时放上方、
/// 且任何情况下都不与被查字矩形垂直重叠（绝不盖住被查字）、始终留在屏幕内。
void main() {
  group('computeFloatingLyricPopupRect anchors next to the tapped glyph', () {
    const Size screen = Size(400, 800);
    const double maxWidth = 360;
    const double maxHeight = 300;

    test('glyph near the top → card placed below it, never overlapping', () {
      // 被查字在屏幕上部：下方空间充足 → 弹窗应落在字的下方。
      const Rect glyph = Rect.fromLTWH(120, 80, 24, 28);
      final Rect rect = computeFloatingLyricPopupRect(
        glyphRect: glyph,
        screen: screen,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
      );

      expect(rect.top, greaterThanOrEqualTo(glyph.bottom),
          reason: '字在上部时弹窗应在字下方');
      // 不与被查字垂直重叠。
      expect(rect.top, greaterThanOrEqualTo(glyph.bottom));
      _expectInScreen(rect, screen);
    });

    test('glyph near the bottom → card placed above it, never overlapping', () {
      // 被查字贴近屏幕底部：下方放不下整高弹窗 → 弹窗应翻到字的上方。
      const Rect glyph = Rect.fromLTWH(120, 720, 24, 28);
      final Rect rect = computeFloatingLyricPopupRect(
        glyphRect: glyph,
        screen: screen,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
      );

      expect(rect.bottom, lessThanOrEqualTo(glyph.top),
          reason: '字在底部时弹窗应翻到字上方，不被屏幕底裁掉也不盖住字');
      _expectInScreen(rect, screen);
    });

    test('cramped tiny screen → card stays clamped inside bounds', () {
      // 极小屏 + 居中被查字：两侧都放不下整高，弹窗高度被压缩但必须留在屏内。
      const Size tiny = Size(80, 80);
      const Rect glyph = Rect.fromLTWH(38, 38, 4, 4);
      final Rect rect = computeFloatingLyricPopupRect(
        glyphRect: glyph,
        screen: tiny,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
      );

      _expectInScreen(rect, tiny);
      expect(rect.width, greaterThan(0));
      expect(rect.height, greaterThan(0));
    });
  });
}

void _expectInScreen(Rect rect, Size screen) {
  expect(rect.left, greaterThanOrEqualTo(0));
  expect(rect.top, greaterThanOrEqualTo(0));
  expect(rect.right, lessThanOrEqualTo(screen.width + 0.001));
  expect(rect.bottom, lessThanOrEqualTo(screen.height + 0.001));
}
