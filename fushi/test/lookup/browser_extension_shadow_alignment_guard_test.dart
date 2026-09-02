import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

String _ruleBody(String css, RegExp selector) {
  final RegExpMatch? match = selector.firstMatch(css);
  expect(match, isNotNull, reason: 'missing CSS root rule: $selector');
  return match!.group(1)!;
}

void main() {
  test('shared popup document pins its inherited text alignment to the left',
      () {
    final String css = _read('assets/popup/popup.css');
    final String body = _ruleBody(
      css,
      RegExp(r'html\s*,\s*body\s*\{([^}]*)\}', multiLine: true),
    );

    expect(body, contains('direction: ltr;'));
    expect(body, contains('text-align: left;'),
        reason:
            'Shadow DOM does not block inherited text-align from host pages');
  });

  for (final String path in <String>[
    'assets/browser_extension/vendor/content.css',
    '../tools/browser-extension/vendor/content.css',
  ]) {
    test('$path resets host-page alignment at the shadow popup root', () {
      final String css = _read(path);
      // 生成器把 `:root` 和 `html, body` 都重写成同一个
      // `:where(#entries-container)`，所以这个选择器会出现多次；拿 firstMatch
      // 当锚点，只要前面多出一块（比如变量块）就会抽错规则而恒红。
      // 判据改成「必须存在某一条重挂根规则同时带着两个声明」，与
      // popup.css 那侧 `html, body` 同时断言 direction/text-align 对齐：
      // 两者本就是同一条规则被生成器重写过来的，拆开就是真回归。
      final Iterable<RegExpMatch> rules =
          RegExp(r':where\(#entries-container\)\s*\{([^}]*)\}', multiLine: true)
              .allMatches(css);
      expect(rules, isNotEmpty, reason: 'missing re-rooted popup rule');
      final bool pinned = rules.any((RegExpMatch m) =>
          m.group(1)!.contains('direction: ltr;') &&
          m.group(1)!.contains('text-align: left;'));
      expect(pinned, isTrue,
          reason: 'generated content.css must isolate the inherited alignment: '
              'no :where(#entries-container) rule carries both '
              'direction: ltr; and text-align: left;');
    });
  }

  test('extension still renders the popup inside a shadow root', () {
    final String source = _read('../tools/browser-extension/content.js');
    expect(source, contains("fushiHost.attachShadow({ mode: 'open' })"));
    expect(source, contains("c.id = 'entries-container'"));
  });
}
