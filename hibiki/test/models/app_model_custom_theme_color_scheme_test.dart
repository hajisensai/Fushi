import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/models.dart';

void main() {
  group('custom theme color scheme', () {
    test('uses explicit Material role colors when provided', () {
      final ColorScheme scheme = buildHibikiColorScheme(
        seedColor: const Color(0xFF006875),
        brightness: Brightness.light,
        primary: const Color(0xFF101010),
        secondary: const Color(0xFF202020),
        tertiary: const Color(0xFF303030),
        primaryContainer: const Color(0xFF404040),
      );

      expect(scheme.primary, const Color(0xFF101010));
      expect(scheme.secondary, const Color(0xFF202020));
      expect(scheme.tertiary, const Color(0xFF303030));
      expect(scheme.primaryContainer, const Color(0xFF404040));
    });

    test('derives secondaryContainer from custom secondary', () {
      final ColorScheme base = buildHibikiColorScheme(
        seedColor: const Color(0xFF006875),
        brightness: Brightness.light,
      );
      final ColorScheme custom = buildHibikiColorScheme(
        seedColor: const Color(0xFF006875),
        brightness: Brightness.light,
        secondary: const Color(0xFFFF0000),
      );

      expect(custom.secondary, const Color(0xFFFF0000));
      expect(custom.secondaryContainer, isNot(base.secondaryContainer));
    });

    test('derives tertiaryContainer from custom tertiary', () {
      final ColorScheme base = buildHibikiColorScheme(
        seedColor: const Color(0xFF006875),
        brightness: Brightness.light,
      );
      final ColorScheme custom = buildHibikiColorScheme(
        seedColor: const Color(0xFF006875),
        brightness: Brightness.light,
        tertiary: const Color(0xFF00FF00),
      );

      expect(custom.tertiary, const Color(0xFF00FF00));
      expect(custom.tertiaryContainer, isNot(base.tertiaryContainer));
    });

    test('leaves containers at seed defaults when role not overridden', () {
      final ColorScheme base = buildHibikiColorScheme(
        seedColor: const Color(0xFF006875),
        brightness: Brightness.light,
      );
      final ColorScheme custom = buildHibikiColorScheme(
        seedColor: const Color(0xFF006875),
        brightness: Brightness.light,
        primary: const Color(0xFFAA0000),
      );

      expect(custom.secondaryContainer, base.secondaryContainer);
      expect(custom.tertiaryContainer, base.tertiaryContainer);
    });
  });
}
