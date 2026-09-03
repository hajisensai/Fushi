import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  test('BUG-1945：退出全屏 pop 后不得再用已失活 context 查祖先', () {
    final String source = File(
      'lib/src/pages/implementations/video_fushi/fullscreen.part.dart',
    ).readAsStringSync();
    final String body = methodBody(
      source,
      'Future<void> _exitVideoFullscreen(BuildContext context) async',
    );

    final int navigatorCapture = body.indexOf(
      'final NavigatorState navigator = Navigator.of(context);',
    );
    final int parentCapture = body.indexOf(
      'final VideoState parent = FullscreenInheritedWidget.of(context).parent;',
    );
    final int pop = body.indexOf('await navigator.maybePop();');

    expect(navigatorCapture, greaterThanOrEqualTo(0));
    expect(parentCapture, greaterThanOrEqualTo(0));
    expect(pop, greaterThan(parentCapture));
    expect(pop, greaterThan(navigatorCapture));
    expect(body, contains('if (parent.mounted) {'));
    expect(body, contains('parent.refreshView();'));

    // `methodBody` 返回的是**含注释的原文**，而下面是一条查标识符的负向断言：
    // 不剥注释的话，本方法里那句解释「不能再从旧 context 查祖先」的中文注释会
    // 自己把断言命中，守卫恒红（本仓「顺序守卫必剥注释」的老坑）。`maskComments`
    // 等长掩码，`pop` 这个在原串上算出的下标可以直接拿来切掩码串。
    final String afterPop = maskComments(body).substring(pop);
    expect(
      afterPop,
      isNot(contains('context')),
      reason: 'maybePop 会卸载全屏路由；await 后 context 可能仍 mounted 但已 deactivated',
    );
  });
}
