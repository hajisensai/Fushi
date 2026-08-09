import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 合并守卫：popup.css 静态样式一致性。原来 popup_header_button_spacing_guard_test.dart
/// 与 popup_pitch_frequency_spacing_guard_test.dart 各自钉死 popup.css 里不同规则块的
/// 差异化约束（.header-buttons 弹性 gap / freq→pitch 间距），断言无法用共享列表替代。
/// 此文件把每个源文件的全部 test() 块**逐字**搬进来，用 group() 按源文件包裹以保失败隔离，
/// 断言与 reason 文案一律原样保留。
void main() {
  // TODO-846: 查词弹窗顶部按钮（发音/制卡/句子上下文步进器）间距加大，且窗口宽度不够时
  // 自动缩小。间距必须由 .header-buttons 的弹性 gap 单一来源提供（clamp(min, vw, max)），
  // 不再让 .mine-button / .sentence-context-picker 各自的 margin-left 与 gap 叠加造成
  // 不均匀间距。弹窗在 WebView 里跑不了 headless，故用源码守卫锁住这两条 CSS 约束。
  group('popup_header_button_spacing', () {
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
  });

  // BUG-178 (part 2): in the dictionary popup, the pitch-accent section sits
  // directly under the frequency section (buildEntryElement appends freqSection
  // then pitchSection). Both are `.category-section`s with only a 2px top gap.
  // The first pitch mora's high/low overline (.pronunciation-mora-line, top:-2px)
  // pokes above its line box, so with the tight 2px gap it butts up against /
  // overlaps the frequency tag on the line above — the user reported the pitch
  // accent being covered. Pitch rendering can't run headless in a WebView, so
  // guard the CSS spacing rule's presence and that it actually widens the gap.
  group('popup_pitch_frequency_spacing', () {
    test(
        'popup.css gives the pitch section that follows the frequency section '
        'extra top margin so the pitch overline does not overlap the frequency '
        'tag (BUG-178)', () {
      final String css = File('assets/popup/popup.css').readAsStringSync();

      final RegExp rule = RegExp(
        r'\.frequency-section\s*\+\s*\.pitch-section\s*\{([^}]*)\}',
      );
      final RegExpMatch? match = rule.firstMatch(css);
      expect(
        match,
        isNotNull,
        reason: 'popup.css must target the freq→pitch adjacency '
            '(.frequency-section + .pitch-section) to add breathing room so the '
            'pitch accent is not covered by the frequency values above (BUG-178).',
      );

      final String body = match!.group(1)!;
      final RegExpMatch? marginMatch =
          RegExp(r'margin-top\s*:\s*(\d+(?:\.\d+)?)\s*px').firstMatch(body);
      expect(
        marginMatch,
        isNotNull,
        reason: 'the freq→pitch rule must set an explicit px margin-top.',
      );

      final double margin = double.parse(marginMatch!.group(1)!);
      // The default .category-section gap is 2px; the fix must be strictly larger
      // so the pitch section actually gains separation from the frequency tags.
      expect(
        margin,
        greaterThan(2),
        reason:
            'the freq→pitch margin-top ($margin px) must exceed the default '
            '2px category-section gap to clear the overlap (BUG-178).',
      );
    });
  });
}
