import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_ttu_source_page.dart';

void main() {
  group('TTU custom theme', () {
    test('writes a dark custom theme without requiring custom font color', () {
      final definition = buildTtuCustomThemeDefinition(dark: true);

      expect(definition['backgroundColor'], 'rgba(35,39,42,1)');
      expect(definition['fontColor'], 'rgba(255,255,255,0.87)');
    });

    test('uses explicit custom font color when provided', () {
      final definition = buildTtuCustomThemeDefinition(
        dark: false,
        fontColor: const Color(0xCC112233),
      );

      expect(definition['backgroundColor'], 'rgba(255,255,255,1)');
      expect(definition['fontColor'], 'rgba(17,34,51,0.80)');
      expect(definition['hintFuriganaFontColor'], 'rgba(17,34,51,0.38)');
    });

    test('serializes customThemes for TTU localStorage', () {
      final js = buildTtuCustomThemeJs(dark: true);

      expect(js, contains('window.localStorage.setItem("customThemes"'));
      expect(js, contains('custom-theme'));
      expect(js, contains('rgba(35,39,42,1)'));
    });
  });
}
