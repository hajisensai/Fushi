import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：WebView 查词弹窗内部 card 表面的圆角走 Dart token 单一真相源。
///
/// 机制：Dart 侧把 `HibikiRadii.cardValue` 作为 `--hibiki-radius-card` CSS 变量
/// 注入 popup WebView（与 `--md-*` 颜色变量同一注入点），popup.css 的卡片表面
/// （`.kanji-card` / `.global-lookup-sentence`）用 `var(--hibiki-radius-card, 10px)`
/// 而不是硬编码，从而与 Dart 侧 `HibikiPopupSurface`（card=10）统一。
///
/// 这条防止：有人把卡片圆角改回硬编码 `8px`（回到「弹窗不统一」），或删掉注入。
void main() {
  String read(String p) => File(p).readAsStringSync();

  test('两个注入点都把 --hibiki-radius-card 从 HibikiRadii.cardValue 注入', () {
    for (final String path in <String>[
      'lib/src/pages/implementations/popup_settings_injection.dart',
      'lib/src/pages/implementations/dictionary_popup_webview.dart',
    ]) {
      final String src = read(path);
      expect(src, contains("'--hibiki-radius-card'"),
          reason: '$path 应注入 --hibiki-radius-card');
      expect(src, contains('HibikiRadii.cardValue'),
          reason: '$path 的圆角值应取自 token HibikiRadii.cardValue，非硬编码');
    }
  });

  test('popup.css 的卡片表面用 var(--hibiki-radius-card)，不硬编码', () {
    final String css = read('assets/popup/popup.css');
    expect(css, contains('var(--hibiki-radius-card'),
        reason: '弹窗卡片表面应引用注入的圆角 token');
    // .kanji-card / .global-lookup-sentence 块不应再出现硬编码 8px 圆角。
    expect(RegExp(r'\.kanji-card\s*\{[^}]*border-radius:\s*8px').hasMatch(css),
        isFalse,
        reason: '.kanji-card 不应硬编码 border-radius: 8px');
    expect(
        RegExp(r'\.global-lookup-sentence\s*\{[^}]*border-radius:\s*8px')
            .hasMatch(css),
        isFalse,
        reason: '.global-lookup-sentence 不应硬编码 border-radius: 8px');
  });
}
