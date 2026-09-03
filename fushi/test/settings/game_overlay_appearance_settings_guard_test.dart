import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String game =
      File('lib/src/settings/settings_schema_game.dart').readAsStringSync();
  final String lookup =
      File('lib/src/settings/settings_schema_lookup.dart').readAsStringSync();

  test('game settings owns the complete hook overlay appearance section', () {
    for (final String id in <String>[
      'game.gal_hook_text_font',
      'game.gal_hook_text_font_size',
      'game.gal_hook_text_letter_spacing',
      'game.gal_hook_text_line_height',
      'game.gal_hook_text_bold',
      'game.gal_hook_text_alignment',
      'game.gal_hook_text_color',
      'game.gal_hook_text_background_color',
      'game.gal_hook_text_background_opacity',
      'game.gal_hook_text_outline_color',
      'game.gal_hook_text_outline_width',
      'game.gal_hook_text_padding',
      'game.gal_hook_text_corner_radius',
    ]) {
      expect(game.contains("'$id'"), isTrue, reason: '$id 不在游戏模块设置页');
    }
    expect(
      game.contains('CustomFontsPage(target: FontTarget.gameLookup)'),
      isTrue,
    );
    expect(game.contains('applyAppearanceFromPreferences()'), isTrue);
  });

  test('legacy lookup destination no longer owns the overlay appearance UI', () {
    expect(lookup.contains("'lookup.gal_hook_text_font_size'"), isFalse);
    expect(lookup.contains('t.settings_section_gal_hook_overlay'), isFalse);
  });
}
