import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫（BUG-860）：查词弹窗里的超链接 `<a>` 必须能对无空格长 URL 断行，
/// 否则 linkify 的裸链接 / 结构化内容 href（如
/// `itazuraneko.neocities.org/grammar/...#わりに（は）`）在 `.glossary-group`
/// 描边卡（`min-width:0` 的 grid track）里找不到断点，会把卡片撑出右边界「出框」。
///
/// 根因：`popup.css` 的 `a { color }` 规则原来只有颜色、无任何断词规则，
/// 默认 `white-space:normal` 对无空格 URL 找不到断点。修复是在该规则加
/// `overflow-wrap: anywhere`（只在没有其它断点时才任意处折行，正常带空格
/// 文本不受影响，且缩小 min-content 使卡片不被撑宽）。
///
/// 三镜像铁律：popup.css 是查词弹窗真值源，改动必须同步到浏览器扩展两份
/// vendored 镜像，本守卫对三处都断言，防止有人漏改或回退某一份。
void main() {
  String read(String p) => File(p).readAsStringSync();

  /// 提取 popup.css 里顶层 `a { ... }` 规则块（截图问题的裸链接与结构化 href
  /// 都是普通 `<a>`，样式都由这条根规则兜底）。
  String extractBaseAnchorRule(String css) {
    final Match? m =
        RegExp(r'(?:^|\n)a\s*\{([^}]*)\}', multiLine: true).firstMatch(css);
    expect(m, isNotNull, reason: 'popup.css 应有顶层 a { } 规则');
    return m!.group(1)!;
  }

  const List<String> cssMirrors = <String>[
    'assets/popup/popup.css',
    'assets/browser_extension/vendor/popup.css',
    '../tools/browser-extension/vendor/popup.css',
  ];

  test('三镜像 popup.css 的顶层 a 规则都带 overflow-wrap，能给长 URL 断行', () {
    for (final String path in cssMirrors) {
      final String rule = extractBaseAnchorRule(read(path));
      expect(
        RegExp(r'overflow-wrap:\s*anywhere').hasMatch(rule) ||
            RegExp(r'word-break:\s*break-(all|word)').hasMatch(rule),
        isTrue,
        reason: '$path 的 a{} 规则应含 overflow-wrap:anywhere（或等效断词），'
            '否则无空格长 URL 会撑破 .glossary-group 卡片（BUG-860 回归）',
      );
    }
  });

  test('扩展注入用的 content.css 也继承了 a 的断词规则', () {
    // content.css 由 popup.css 经 generate-content-css.mjs 生成，类规则原样保留，
    // 所以断词规则应一并出现（防止只改 popup.css 忘了重新生成 content.css）。
    for (final String path in <String>[
      'assets/browser_extension/vendor/content.css',
      '../tools/browser-extension/vendor/content.css',
    ]) {
      final String css = read(path);
      expect(css, contains('overflow-wrap: anywhere'),
          reason: '$path 应含 a 的 overflow-wrap 断词规则（重跑 generate-content-css.mjs）');
    }
  });
}
