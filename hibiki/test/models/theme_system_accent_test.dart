import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/theme_notifier.dart';

/// BUG-090: on Windows (and macOS/Linux) `getCorePalette()` is null, so
/// `system-theme` must seed its ColorScheme from the OS accent color rather
/// than silently collapsing to the hardcoded teal fallback. These tests pin the
/// pure resolver that `buildColorScheme` delegates to, plus a source guard so
/// the `getAccentColor` fallback can't be dropped again.
void main() {
  const Color fallbackTeal = Color(0xFF1F4959);
  const Color osAccent = Color(0xFFE67E22); // distinctly non-teal orange

  group('buildSystemThemeColorScheme', () {
    test('accent seeds the scheme when the core palette is null (Windows path)',
        () {
      final ColorScheme accentScheme = buildSystemThemeColorScheme(
        brightness: Brightness.light,
        fallbackSeed: fallbackTeal,
        palette: null,
        accent: osAccent,
      );
      final ColorScheme fallbackScheme = buildSystemThemeColorScheme(
        brightness: Brightness.light,
        fallbackSeed: fallbackTeal,
        palette: null,
        accent: null,
      );

      // The accent must actually drive the colors, not the teal fallback.
      expect(accentScheme.primary, isNot(equals(fallbackScheme.primary)));
      expect(
        accentScheme.primary,
        equals(
          ColorScheme.fromSeed(
            seedColor: osAccent,
            brightness: Brightness.light,
          ).primary,
        ),
      );
    });

    test('falls back to the seed only when the OS exposes nothing', () {
      final ColorScheme scheme = buildSystemThemeColorScheme(
        brightness: Brightness.dark,
        fallbackSeed: fallbackTeal,
        palette: null,
        accent: null,
      );
      expect(scheme.brightness, Brightness.dark);
      expect(
        scheme.primary,
        equals(
          ColorScheme.fromSeed(
            seedColor: fallbackTeal,
            brightness: Brightness.dark,
          ).primary,
        ),
      );
    });

    test('honours the requested brightness', () {
      expect(
        buildSystemThemeColorScheme(
          brightness: Brightness.light,
          fallbackSeed: fallbackTeal,
          accent: osAccent,
        ).brightness,
        Brightness.light,
      );
      expect(
        buildSystemThemeColorScheme(
          brightness: Brightness.dark,
          fallbackSeed: fallbackTeal,
          accent: osAccent,
        ).brightness,
        Brightness.dark,
      );
    });
  });

  group('refreshSystemPalette source guard', () {
    test('falls back to getAccentColor when the core palette is absent', () {
      final String src = File(
        'lib/src/models/theme_notifier.dart',
      ).readAsStringSync();

      final int start = src.indexOf('Future<void> refreshSystemPalette()');
      expect(start, isNonNegative, reason: 'refreshSystemPalette must exist');
      final int end = src.indexOf('\n  }', start);
      final String body = src.substring(start, end);

      expect(body.contains('getCorePalette'), isTrue);
      expect(
        body.contains('getAccentColor'),
        isTrue,
        reason: 'Windows/macOS/Linux expose the system color only via '
            'getAccentColor; dropping it reintroduces BUG-090.',
      );
    });

    test('buildColorScheme routes system-theme through the resolver', () {
      final String src = File(
        'lib/src/models/theme_notifier.dart',
      ).readAsStringSync();
      expect(
        src.contains('buildSystemThemeColorScheme('),
        isTrue,
        reason: 'system-theme must delegate to the accent-aware resolver.',
      );
    });
  });
}
