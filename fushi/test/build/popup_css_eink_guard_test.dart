import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 墨水屏模式弹窗 CSS 守卫：
///  1. popup.css 必须含 `html.eink` 覆盖块（纯黑白变量 + 方角/去阴影/关动效的
///     通配压平规则），且生成的 content.css 里被正确重挂为
///     `:where(#entries-container).eink`（扩展侧同样生效）。
///  2. 花括号配平守卫——回归自真实 bug：`.ctx-adjust-button` 规则曾缺闭合 `}`，
///     CSS 错误恢复把紧随其后的整条高亮规则（当时的 `.global-lookup-ext-hit`，
///     已随剪贴板面板删除）当无效声明吞掉（高亮从未生效）。配平检查让这一类
///     「少个括号、静默吞掉后续规则」在测试层直接翻红。
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

  // BUG-2434 ②：墨水屏块此前只压了圆角 / 阴影 / 过渡 / 顶部按钮那几个 opacity，
  // **正文侧**十几处静息 opacity（0.4~0.9）与一处亚像素 transform 全部漏网。
  // 半透明黑字在墨水屏上就是抖动灰——10px 的 `.dict-label` 尤其糊；0.5px 位移则把
  // 字形推到半个物理像素上，墨水屏没有灰阶去表现，只能糊成两行。这两条都是「看起来
  // 只是不够锐利」的静默失效，没有任何报错，故用守卫钉死。
  test('html.eink flattens resting body opacity and subpixel transforms', () {
    for (final String path in <String>[
      popupCssPath,
      'assets/browser_extension/vendor/popup.css',
      '../tools/browser-extension/vendor/popup.css',
    ]) {
      final String css = File(path).readAsStringSync();
      // 正文/标签的静息半透明压平（抽查两条最典型的：10px 词典名标签、
      // 折叠三角伪元素）。
      expect(css, contains('html.eink .dict-label'),
          reason: '$path 缺少词典名标签的 eink opacity 压平');
      expect(css, contains('html.eink .glossary-group > summary::before'),
          reason: '$path 缺少折叠三角的 eink opacity 压平');
      // 亚像素位移归零。
      expect(css, contains('html.eink .mine-button.duplicate'),
          reason: '$path 缺少 0.5px 亚像素位移的 eink 归零');
      // 状态反馈刻意不压平：:disabled 的弱化本身就是它要传达的信息，
      // 若哪天被一条通配 opacity 规则连坐，这里应当有人重新审。
      expect(css, isNot(contains('html.eink * { opacity')),
          reason: '$path 不应用通配规则压平 opacity（会连坐 disabled / 隐藏态）');
    }
  });

  test('generated content.css re-roots html.eink for the extension', () {
    final String css = File(contentCssPath).readAsStringSync();
    expect(css, contains(':where(#entries-container).eink'));
    expect(css, contains(':where(#entries-container).eink[data-theme="dark"]'));
  });
}
