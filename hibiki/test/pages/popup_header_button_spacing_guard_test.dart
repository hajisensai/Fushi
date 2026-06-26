import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// TODO-846: 查词弹窗顶部按钮（发音/制卡/句子上下文步进器）间距加大，且窗口宽度不够时
// 自动缩小。间距必须由 .header-buttons 的弹性 gap 单一来源提供（clamp(min, vw, max)），
// 不再让 .mine-button / .sentence-context-picker 各自的 margin-left 与 gap 叠加造成
// 不均匀间距。弹窗在 WebView 里跑不了 headless，故用源码守卫锁住这两条 CSS 约束。
void main() {
  late String css;

  setUpAll(() {
    css = File('assets/popup/popup.css').readAsStringSync();
  });

  String? ruleBody(String selector) {
    final RegExp rule = RegExp(
      RegExp.escape(selector) + r'\s*\{([^}]*)\}',
    );
    return rule.firstMatch(css)?.group(1);
  }

  test(
      '.header-buttons uses a responsive clamp() gap so the spacing widens but '
      'shrinks when the popup is too narrow (TODO-846)', () {
    final String? body = ruleBody('.header-buttons');
    expect(
      body,
      isNotNull,
      reason: 'popup.css must declare a .header-buttons rule.',
    );

    final RegExp gapClamp = RegExp(
      r'gap\s*:\s*clamp\(\s*[^,]+,\s*[^,]+,\s*[^)]+\)',
    );
    expect(
      gapClamp.hasMatch(body!),
      isTrue,
      reason: 'the header button spacing must be a single-source responsive '
          'clamp() gap (min, fluid vw, max) so it grows yet shrinks on narrow '
          'popups (TODO-846).',
    );
  });

  test(
      '.mine-button no longer carries its own margin-left (gap is the single '
      'source of spacing) (TODO-846)', () {
    // 只看 .mine-button 这一条规则块（不含 .mine-button.duplicate/.latest 等修饰块）。
    final String? body = ruleBody('.mine-button');
    expect(body, isNotNull,
        reason: 'popup.css must keep the .mine-button rule.');
    expect(
      RegExp(r'margin-left\s*:').hasMatch(body!),
      isFalse,
      reason:
          'the .mine-button block must not add its own margin-left; spacing '
          'now flows from the .header-buttons gap (TODO-846).',
    );
  });

  test(
      '.sentence-context-picker no longer carries its own margin-left '
      '(TODO-846)', () {
    final String? body = ruleBody('.sentence-context-picker');
    expect(
      body,
      isNotNull,
      reason: 'popup.css must keep the .sentence-context-picker rule.',
    );
    expect(
      RegExp(r'margin-left\s*:').hasMatch(body!),
      isFalse,
      reason: 'the .sentence-context-picker block must not add its own '
          'margin-left; spacing now flows from the .header-buttons gap '
          '(TODO-846).',
    );
  });
}
