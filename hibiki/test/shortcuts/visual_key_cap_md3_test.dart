import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-942：立体键帽 MD3 守卫。
///
/// 立体键帽换皮后，visual/* 仍不在 md3 静态守卫白名单内，故新键帽必须维持
/// 「全走 token」纪律：圆角用 `tokens.radii.*`，颜色用 `colorScheme` / `tokens.surfaces.*`，
/// 字号用 `textTheme`。本地再钉一道，禁出现 `BorderRadius.circular(` / `fontSize:` /
/// `surfaceContainerXxx` 字面量，并断言确实用了 token 入口。
void main() {
  final String keyCapSrc = File(
    'lib/src/shortcuts/visual/key_cap_widget.dart',
  ).readAsStringSync();
  final String layoutSrc = File(
    'lib/src/shortcuts/visual/keyboard_layout_view.dart',
  ).readAsStringSync();

  const List<String> forbidden = <String>[
    'BorderRadius.circular(',
    'fontSize:',
    'surfaceContainerLow',
    'surfaceContainerHigh',
    'surfaceContainerHighest',
  ];

  test('key cap stereoscopic skin stays free of bare MD3 literals', () {
    for (final String token in forbidden) {
      expect(keyCapSrc.contains(token), isFalse,
          reason: 'KeyCapWidget must not reopen MD3 decision via "$token"');
    }
  });

  test('keyboard layout view stays free of bare MD3 literals', () {
    for (final String token in forbidden) {
      expect(layoutSrc.contains(token), isFalse,
          reason:
              'KeyboardLayoutView must not reopen MD3 decision via "$token"');
    }
  });

  test('key cap routes radii/surfaces through HibikiDesignTokens', () {
    expect(keyCapSrc.contains('HibikiDesignTokens.of(context)'), isTrue);
    expect(keyCapSrc.contains('tokens.radii.chipRadius'), isTrue,
        reason: 'corner radius must come from the token, not a literal');
    expect(keyCapSrc.contains('tokens.surfaces.'), isTrue,
        reason: 'surface roles must come from semantic tokens');
  });

  test('modifier caps use the secondaryContainer partition color', () {
    // 修饰键分区色：用 secondaryContainer 与字母键区分（决策 3 的视觉表达）。
    expect(keyCapSrc.contains('secondaryContainer'), isTrue,
        reason: 'modifier partition must use the secondaryContainer role');
  });
}
