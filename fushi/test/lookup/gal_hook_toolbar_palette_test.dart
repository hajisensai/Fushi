import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/gal_hook_text_overlay_controller.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';
import 'package:fushi/utils.dart';

void main() {
  test('no theme falls back to the legacy toolbar colours', () {
    final GalHookToolbarPalette palette = galHookToolbarPalette(null);
    expect(palette.buttonTextColor, kGalHookToolbarLegacyButtonTextColor);
    expect(palette.buttonBgColor, kGalHookToolbarLegacyButtonBgColor);
    expect(palette.activeColor, kGalHookToolbarLegacyActiveColor);
    // toolbarBgColor alpha 0 = native 走历史外观。
    expect(palette.toolbarBgColor, 0);
    expect(palette.highlightColor, kGalHookTextLegacyHighlightColor);
  });

  test('M3E palette follows the fixed theme roles with legacy alpha', () {
    final ThemeData theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00897B)),
    );
    final GalHookToolbarPalette palette = galHookToolbarPalette(theme);
    final ColorScheme scheme = theme.colorScheme;
    expect(
      palette.activeColor,
      0xFF000000 | (scheme.primaryFixedDim.toARGB32() & 0x00FFFFFF),
    );
    // 悬停底 alpha 与历史值一致：不改变分层窗口的逐像素命中区。
    expect(
      palette.buttonBgColor >>> 24,
      kGalHookToolbarLegacyButtonBgColor >>> 24,
    );
    expect(
      palette.buttonBgColor & 0x00FFFFFF,
      scheme.secondaryFixedDim.toARGB32() & 0x00FFFFFF,
    );
  });

  test('standalone toolbar is an M3E floating toolbar in theme roles', () {
    for (final Brightness brightness in Brightness.values) {
      final ThemeData theme = ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE65100),
          brightness: brightness,
        ),
      );
      final ColorScheme scheme = theme.colorScheme;
      final GalHookToolbarPalette palette = galHookToolbarPalette(theme);
      expect(palette.toolbarBgColor, scheme.surfaceContainer.toARGB32());
      expect(palette.toolbarIconColor, scheme.onSurfaceVariant.toARGB32());
      expect(
        palette.toolbarActiveBgColor,
        scheme.secondaryContainer.toARGB32(),
      );
      expect(
        palette.toolbarActiveIconColor,
        scheme.onSecondaryContainer.toARGB32(),
      );
      expect(
        palette.toolbarHoverColor & 0x00FFFFFF,
        scheme.onSurfaceVariant.toARGB32() & 0x00FFFFFF,
      );
    }
  });

  test('lookup highlight contrasts with the caption fill colour', () {
    final ThemeData theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00897B)),
    );
    final ColorScheme scheme = theme.colorScheme;
    expect(
      galHookToolbarPalette(theme).highlightColor & 0x00FFFFFF,
      scheme.onPrimaryFixedVariant.toARGB32() & 0x00FFFFFF,
    );
    expect(
      galHookToolbarPalette(theme, textColor: 0xFF101010).highlightColor &
          0x00FFFFFF,
      scheme.primaryFixed.toARGB32() & 0x00FFFFFF,
    );
  });

  test('e-ink palette is monochrome', () {
    final ThemeData theme = ThemeData(
      extensions: const <ThemeExtension<dynamic>>[FushiEinkTheme(true)],
    );
    final GalHookToolbarPalette palette = galHookToolbarPalette(theme);
    expect(palette.activeColor, 0xFFFFFFFF);
    expect(palette.buttonTextColor, 0xFFFFFFFF);
    expect(palette.buttonBgColor, 0x55FFFFFF);
    expect(palette.toolbarBgColor, 0xFFFFFFFF);
    expect(palette.toolbarIconColor, 0xFF000000);
    expect(palette.toolbarActiveBgColor, 0xFF000000);
    expect(palette.toolbarActiveIconColor, 0xFFFFFFFF);
  });
}
