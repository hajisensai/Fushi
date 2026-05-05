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
  });
}
