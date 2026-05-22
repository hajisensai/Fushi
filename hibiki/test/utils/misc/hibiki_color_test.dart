import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/Hibiki_color.dart';

void main() {
  group('HibikiColor.darken', () {
    test('reduces lightness by default 10%', () {
      const color = Color(0xFF808080);

      final darker = HibikiColor.darken(color);

      final hslOriginal = HSLColor.fromColor(color);
      final hslDarker = HSLColor.fromColor(darker);
      expect(hslDarker.lightness, closeTo(hslOriginal.lightness - 0.1, 0.01));
    });

    test('amount 0 returns same color', () {
      const color = Color(0xFF4488CC);

      final result = HibikiColor.darken(color, 0);

      expect(result, color);
    });

    test('amount 1 returns black', () {
      const color = Color(0xFF4488CC);

      final result = HibikiColor.darken(color, 1.0);

      final hsl = HSLColor.fromColor(result);
      expect(hsl.lightness, 0.0);
    });

    test('clamps to zero lightness instead of going negative', () {
      const nearBlack = Color(0xFF0A0A0A);

      final result = HibikiColor.darken(nearBlack, 0.5);

      final hsl = HSLColor.fromColor(result);
      expect(hsl.lightness, greaterThanOrEqualTo(0.0));
    });
  });

  group('HibikiColor.lighten', () {
    test('increases lightness by default 10%', () {
      const color = Color(0xFF808080);

      final lighter = HibikiColor.lighten(color);

      final hslOriginal = HSLColor.fromColor(color);
      final hslLighter = HSLColor.fromColor(lighter);
      expect(hslLighter.lightness, closeTo(hslOriginal.lightness + 0.1, 0.01));
    });

    test('amount 0 returns same color', () {
      const color = Color(0xFF4488CC);

      final result = HibikiColor.lighten(color, 0);

      expect(result, color);
    });

    test('amount 1 returns white', () {
      const color = Color(0xFF4488CC);

      final result = HibikiColor.lighten(color, 1.0);

      final hsl = HSLColor.fromColor(result);
      expect(hsl.lightness, 1.0);
    });

    test('clamps to 1.0 lightness instead of exceeding', () {
      const nearWhite = Color(0xFFF5F5F5);

      final result = HibikiColor.lighten(nearWhite, 0.5);

      final hsl = HSLColor.fromColor(result);
      expect(hsl.lightness, lessThanOrEqualTo(1.0));
    });
  });
}
