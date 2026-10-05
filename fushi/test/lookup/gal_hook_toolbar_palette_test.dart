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

  test('e-ink palette is monochrome', () {
    final ThemeData theme = ThemeData(
      extensions: const <ThemeExtension<dynamic>>[FushiEinkTheme(true)],
    );
    final GalHookToolbarPalette palette = galHookToolbarPalette(theme);
    expect(palette.activeColor, 0xFFFFFFFF);
    expect(palette.buttonTextColor, 0xFFFFFFFF);
    expect(palette.buttonBgColor, 0x55FFFFFF);
  });
}
