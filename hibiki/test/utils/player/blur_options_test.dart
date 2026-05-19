import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/player/blur_options.dart';

void main() {
  group('defaultBlurRect', () {
    test('centers horizontally from screen width on desktop-shaped windows',
        () {
      final Rect rect = defaultBlurRect(
        const Size(1200, 600),
      );

      expect(rect.width, 150);
      expect(rect.height, 150);
      expect(rect.left, 525);
      expect(rect.top, 75);
    });
  });
}
