import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-751 — on the TRANSLUCENT external lookup surfaces (clipboard panel +
/// transient global-lookup window, both `<html class="global-lookup">`), the
/// header action buttons +/♪/☆ resting `opacity: 0.5` compounds with the card
/// (`cardBgAlpha`) and whole-window (`LWA_ALPHA`) translucency and washes out to
/// near-invisible — the user reported "看不见制卡按钮" / "顶上按钮像全透明".
///
/// Fix: raise the enabled header buttons to full opacity, scoped to
/// `html.global-lookup` so the opaque in-app popup keeps its subtle 0.5 (zero
/// regression). The visible-window pixel proof needs a real translucent panel; this
/// source guard locks the rule so it can't silently regress, and asserts it stays
/// OUT of the extension's content.css (the extension has no global-lookup surface).
void main() {
  String read(String p) => File(p).readAsStringSync();

  test('popup.css raises global-lookup header buttons to full opacity', () {
    final String css = read('assets/popup/popup.css');
    // The exact scoped, enabled-only selectors (disabled/favorited/latest states
    // must keep their own opacity — hence :not(:disabled) and opacity-only).
    for (final String sel in const <String>[
      'html.global-lookup .audio-button:not(:disabled)',
      'html.global-lookup .favorite-button:not(:disabled)',
      'html.global-lookup .mine-button:not(:disabled)',
    ]) {
      expect(css.contains(sel), isTrue,
          reason: 'BUG-751：$sel 必须存在（半透明面板上按钮才可见）');
    }
    // The rule body raises opacity to 1 (was 0.5). Guard the intent, not layout.
    final RegExp rule = RegExp(
      r'html\.global-lookup \.audio-button:not\(:disabled\),\s*'
      r'html\.global-lookup \.favorite-button:not\(:disabled\),\s*'
      r'html\.global-lookup \.mine-button:not\(:disabled\)\s*\{\s*opacity:\s*1;',
    );
    expect(rule.hasMatch(css), isTrue,
        reason: 'BUG-751：三个外部面头部按钮必须整体提到 opacity:1');
  });

  test('the washout fix does NOT leak into the extension content.css', () {
    // generate-content-css.mjs drops every `html.global-lookup …` selector; the
    // extension #entries-container never carries that class, so the rule is inert
    // dead weight there and must be dropped (guards the generator did its job).
    for (final String root in const <String>[
      'assets/browser_extension',
      '../tools/browser-extension',
    ]) {
      final String content = read('$root/vendor/content.css');
      expect(content.contains('.mine-button:not(:disabled)'), isFalse,
          reason: '$root/vendor/content.css 不应含 global-lookup 专属按钮规则');
    }
  });
}
