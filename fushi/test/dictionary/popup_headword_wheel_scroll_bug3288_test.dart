import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-3288：查词弹窗词头放得下仍可被滚轮纵向滚动。
///
/// `.expression-scroll` 只为长词头**横向**滚动而设（`overflow-x: auto`），按 CSS
/// 规则另一轴随之 computed 成 `auto`。注音预留只顾得到顶部，行盒（M3E 词头
/// line-height 1.2）仍比字体内容区矮，底部溢出约 2px（Edge 实测 36px 词头
/// scrollHeight 69 / clientHeight 67），于是滚轮能把词头上下拨动 2px。
///
/// 修法：显式 `overflow-y: hidden`——与 `auto` 裁切范围完全相同（两者都是滚动
/// 容器），但用户不可滚，滚轮落回弹窗正文。无头环境渲染不出字体几何，故守卫
/// 规则本身（三镜像逐字节一致由 browser_extension_popup_parity_guard_test 另守）。
void main() {
  final String css = maskCssComments(
    File('assets/popup/popup.css').readAsStringSync(),
  );

  String? ruleBody(String selector) => RegExp(
    '(?:^|\n)${RegExp.escape(selector)}\\s*\\{([^}]*)\\}',
  ).firstMatch(css)?.group(1);

  test('.expression-scroll 横向可滚、纵向不可被用户滚动', () {
    final String? body = ruleBody('.expression-scroll');
    expect(body, isNotNull);
    expect(
      RegExp(r'overflow-x\s*:\s*auto').hasMatch(body!),
      isTrue,
      reason: '长词头仍要能横向滚动',
    );
    expect(
      RegExp(r'overflow-y\s*:\s*hidden').hasMatch(body),
      isTrue,
      reason: '纵向必须 hidden：auto 会让 2px 的字体内容区溢出被滚轮拨动',
    );
  });

  test('没有别的规则把 .expression-scroll 的纵向溢出改回可滚', () {
    final Iterable<RegExpMatch> rules = RegExp(
      r'([^{}]*\.expression-scroll[^{}]*)\{([^}]*)\}',
    ).allMatches(css);
    for (final RegExpMatch m in rules) {
      final String decls = m.group(2)!;
      expect(
        RegExp(r'overflow(-y)?\s*:\s*(auto|scroll)').hasMatch(decls),
        isFalse,
        reason: '规则 `${m.group(1)!.trim()}` 把纵向溢出改回了可滚',
      );
    }
  });
}
