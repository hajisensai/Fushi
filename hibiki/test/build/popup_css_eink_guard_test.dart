import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 墨水屏模式弹窗 CSS 守卫：
///  1. popup.css 必须含 `html.eink` 覆盖块（纯黑白变量 + 方角/去阴影/关动效的
///     通配压平规则），且生成的 content.css 里被正确重挂为
///     `:where(#entries-container).eink`（扩展侧同样生效）。
///  2. 花括号配平守卫——回归自真实 bug：`.ctx-adjust-button` 规则曾缺闭合 `}`，
///     CSS 错误恢复把下一条 `.global-lookup-ext-hit` 整条高亮规则当无效声明
///     吞掉（高亮从未生效）。配平检查让这一类「少个括号、静默吞掉后续规则」
///     在测试层直接翻红。
///
/// flutter test cwd 是 hibiki 包根。
void main() {
  const String popupCssPath = 'assets/popup/popup.css';
  const String contentCssPath = 'assets/browser_extension/vendor/content.css';

  test('popup.css braces are balanced (swallowed-rule guard)', () {
    final String css = maskCssComments(File(popupCssPath).readAsStringSync());
    final int open = '{'.allMatches(css).length;
    final int close = '}'.allMatches(css).length;
    expect(open, close,
        reason: 'popup.css 花括号不配平（$open 个 { vs $close 个 }）——缺闭合的'
            '规则会静默吞掉下一条规则（见 .ctx-adjust-button 历史 bug）');
  });

  test('popup.css carries the html.eink override block', () {
    final String css = File(popupCssPath).readAsStringSync();
    expect(css, contains('html.eink'));
    // 方角/去阴影/关动效的通配压平。
    expect(css, contains('border-radius: 0 !important'));
    // 纯黑白两向变量块。
    expect(css, contains('html.eink[data-theme="light"]'));
    expect(css, contains('html.eink[data-theme="dark"]'));
    // 线式查词高亮 + 反色原生选区。
    expect(css, contains('html.eink ::selection'));
  });

  test('generated content.css re-roots html.eink for the extension', () {
    final String css = File(contentCssPath).readAsStringSync();
    expect(css, contains(':where(#entries-container).eink'));
    expect(css, contains(':where(#entries-container).eink[data-theme="dark"]'));
  });
}
