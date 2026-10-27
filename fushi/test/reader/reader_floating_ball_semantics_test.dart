// 悬浮球语义节点不得外泄到页面（BUG-3796）：全局球与页面是根 Stack 的兄弟，球的
// Semantics 若不自成节点，标注会并进包住整个页面的祖先节点——球一显隐，整棵页面
// 语义子树就在两个父节点间搬家。Windows 引擎的 AXTree 吃不下这种搬家（更新失败后
// 一路在坏树上改，最终堆损坏卡死 / 崩溃），所以这里钉住两件事：
// 1. 带球标签的节点只有球自己那么大、不是页面的祖先；
// 2. 球出现 / 消失前后，页面节点的父节点不变。
import 'package:flutter/rendering.dart' show SemanticsNode;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';
import 'package:fushi/src/reader/reader_floating_ball.dart';
import 'package:fushi/utils.dart';

const String _pageLabel = 'semantics-probe-page';

/// 与真实装配同形：`main.dart` 根 builder 的 Stack 里，页面（整个 Navigator）与
/// [AppFloatingBallHost] 是兄弟，球外面包一层 `Overlay.wrap` + Stack。
Widget _app({required bool showBall}) => MaterialApp(
  builder: (BuildContext context, Widget? child) => Stack(
    children: <Widget>[
      RepaintBoundary(child: child),
      if (showBall)
        Overlay.wrap(
          child: Stack(
            children: <Widget>[
              ReaderFloatingBall(
                viewport: const Rect.fromLTWH(0, 0, 400, 600),
                dock: ReaderFloatingBallDock.right,
                verticalFraction: 0.5,
                onDockChanged:
                    (ReaderFloatingBallDock dock, double fraction) {},
                actions: <ReaderHeaderAction>[
                  ReaderHeaderAction(
                    icon: Icons.add,
                    label: 'Action',
                    onPressed: () {},
                  ),
                ],
              ),
            ],
          ),
        ),
    ],
  ),
  home: Semantics(
    container: true,
    label: _pageLabel,
    child: const ColoredBox(color: Colors.white),
  ),
);

SemanticsNode _nodeLabelled(WidgetTester tester, String label) {
  final SemanticsNode root = tester.binding.renderViews.first.debugSemantics!;
  SemanticsNode? found;
  void walk(SemanticsNode node) {
    if (node.label == label) found ??= node;
    node.visitChildren((SemanticsNode child) {
      walk(child);
      return true;
    });
  }

  walk(root);
  expect(found, isNotNull, reason: 'no semantics node labelled "$label"');
  return found!;
}

bool _isAncestor(SemanticsNode ancestor, SemanticsNode node) {
  for (SemanticsNode? n = node.parent; n != null; n = n.parent) {
    if (identical(n, ancestor)) return true;
  }
  return false;
}

void main() {
  testWidgets('ball semantics stay on the ball, not on the page ancestor', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    try {
      await tester.pumpWidget(_app(showBall: true));
      await tester.pumpAndSettle();
      final SemanticsNode ball = _nodeLabelled(tester, t.reader_floating_ball);
      final SemanticsNode page = _nodeLabelled(tester, _pageLabel);
      expect(
        _isAncestor(ball, page),
        isFalse,
        reason: 'the ball label leaked onto an ancestor of the whole page',
      );
      expect(ball.rect.width, lessThan(100));
      expect(ball.rect.height, lessThan(100));
    } finally {
      handle.dispose();
    }
  });

  testWidgets('showing / hiding the ball does not reparent the page node', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    try {
      await tester.pumpWidget(_app(showBall: false));
      await tester.pumpAndSettle();
      final SemanticsNode page = _nodeLabelled(tester, _pageLabel);
      final int? parentWithout = page.parent?.id;

      await tester.pumpWidget(_app(showBall: true));
      await tester.pumpAndSettle();
      final SemanticsNode pageWithBall = _nodeLabelled(tester, _pageLabel);
      expect(pageWithBall.id, page.id);
      expect(
        pageWithBall.parent?.id,
        parentWithout,
        reason: 'the ball appearing moved the page under another parent',
      );

      await tester.pumpWidget(_app(showBall: false));
      await tester.pumpAndSettle();
      expect(_nodeLabelled(tester, _pageLabel).parent?.id, parentWithout);
    } finally {
      handle.dispose();
    }
  });
}
