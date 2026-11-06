import 'dart:io';

import 'package:test/test.dart';

/// BUG-4040（反馈 Xr7RRZ3zjm「新明解 词头【鯉】标注渲染异常」、dyDC7zou8x「【漁る】出现
/// 奇怪符号」，两张截图都是 新明解国語辞典 第八版 的词头）。
///
/// jitenbot 转出的新明解把表外字 / 表外音训标记写成
/// `<ruby>鯉<rt><span style="font-size: 2em">︿</span></rt></ruby>`（作者按原生 ruby
/// 假设 rt 0.5em × 2em = 基字 1em）。弹窗把 ruby 拆成 `.ruby-unit > .ruby-rt > rt`
/// 三层手工模拟：`.ruby-rt` 盒 0.6em、`.ruby-unit` 预留带 0.66em（按一行注音定死），
/// BUG-1897 的 `.ruby-rt rt { font-size: 1em !important }` 只归一了 <rt> 本身，rt 的
/// **后代**仍按 2em 乘上去 = 基字 1.2em，从带顶往下长出 0.54em 压在汉字上。
///
/// 实测（Playwright WebKit webkit-2248 与 Chromium，真 popup.html/css/js，15px 正文）：
/// 修前标记盒下沿压进基字 8.1px（zoom 1.5 时 12.15px），修后与普通振假名同为 -0.9px
/// （在预留带内、离基字 0.9px）。布局只能在真引擎里量，单测环境没有，故这里钉 CSS。
void main() {
  final RegExp descendantRule = RegExp(
    r':where\([^)]*\bglossary-group\b[^)]*,[^)]*\bglossary-content\b[^)]*\)\s*'
    r'\.ruby-rt\s+rt\s+\*\s*\{([^}]*)\}',
  );

  for (final String path in <String>[
    'assets/popup/popup.css',
    'assets/browser_extension/vendor/popup.css',
    '../tools/browser-extension/vendor/popup.css',
  ]) {
    test('$path：注音盒里 <rt> 的后代字号归一到注音字号（!important 压过行内 style）', () {
      final String css = File(path).readAsStringSync();
      final RegExpMatch? match = descendantRule.firstMatch(css);
      expect(
        match,
        isNotNull,
        reason:
            '缺 `.ruby-rt rt * {}` 归一规则：词典在 rt 里套的大字号 span 会长出预留带、'
            '压住基字（新明解表外字标记）',
      );
      final String body = match!.group(1)!;
      expect(
        RegExp(r'font-size\s*:\s*1em\s*!important').hasMatch(body),
        isTrue,
        reason:
            '必须是 1em !important：结构化内容的 fontSize 落在行内 style 上，'
            '不带 !important 压不过',
      );
      // 只归一字号这一项几何；颜色 / 字重等词典意图保留。
      expect(
        RegExp(r'\b(color|font-weight|position|top|bottom)\s*:').hasMatch(body),
        isFalse,
      );
    });
  }
}
