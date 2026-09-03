import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/panel_focus_scope.dart';

/// 手柄重设计 P3：浮层面板焦点圈地的行为测试。
void main() {
  Widget host({
    required bool visible,
    required FocusNode hostNode,
    bool autofocusSecond = false,
    Key? firstKey,
    Key? secondKey,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Column(
          children: <Widget>[
            Focus(focusNode: hostNode, child: const SizedBox(height: 10)),
            PanelFocusScope(
              visible: visible,
              restoreFocus: hostNode.requestFocus,
              child: Column(
                children: <Widget>[
                  TextButton(
                    key: firstKey ?? const Key('panel-row-1'),
                    onPressed: () {},
                    child: const Text('row1'),
                  ),
                  TextButton(
                    key: secondKey ?? const Key('panel-row-2'),
                    autofocus: autofocusSecond,
                    onPressed: () {},
                    child: const Text('row2'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool nodeHasFocus(WidgetTester tester, Key key) =>
      Focus.of(tester.element(find.byKey(key))).hasFocus;

  testWidgets('visible 边沿（常驻挂载形态）：打开领第一个可遍历节点，关闭还宿主',
      (WidgetTester tester) async {
    final FocusNode hostNode = FocusNode(debugLabel: 'host');
    addTearDown(hostNode.dispose);
    await tester.pumpWidget(host(visible: false, hostNode: hostNode));
    hostNode.requestFocus();
    await tester.pump();
    expect(hostNode.hasFocus, isTrue);

    // 打开：后帧认领 → 面板第一行获焦，宿主失焦。
    await tester.pumpWidget(host(visible: true, hostNode: hostNode));
    await tester.pump();
    expect(nodeHasFocus(tester, const Key('panel-row-1')), isTrue);
    expect(hostNode.hasFocus, isFalse);

    // 关闭：焦点还给宿主。
    await tester.pumpWidget(host(visible: false, hostNode: hostNode));
    await tester.pump();
    expect(hostNode.hasFocus, isTrue);
  });

  testWidgets('子节点 autofocus 优先：认领发现焦点已在面板内就不抢', (WidgetTester tester) async {
    final FocusNode hostNode = FocusNode(debugLabel: 'host');
    addTearDown(hostNode.dispose);
    await tester.pumpWidget(
        host(visible: false, hostNode: hostNode, autofocusSecond: true));
    hostNode.requestFocus();
    await tester.pump();

    await tester.pumpWidget(
        host(visible: true, hostNode: hostNode, autofocusSecond: true));
    await tester.pump();
    // autofocus 的第二行拿到焦点，认领不把它抢到第一行。
    expect(nodeHasFocus(tester, const Key('panel-row-2')), isTrue);
  });

  testWidgets('挂载即可见形态（visible 恒 true）：挂载领焦点、卸载还宿主',
      (WidgetTester tester) async {
    final FocusNode hostNode = FocusNode(debugLabel: 'host');
    addTearDown(hostNode.dispose);

    Widget build({required bool mounted}) {
      return MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              Focus(focusNode: hostNode, child: const SizedBox(height: 10)),
              if (mounted)
                PanelFocusScope(
                  visible: true,
                  restoreFocus: hostNode.requestFocus,
                  child: TextButton(
                    key: const Key('panel-row-1'),
                    onPressed: () {},
                    child: const Text('row1'),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    await tester.pumpWidget(build(mounted: false));
    hostNode.requestFocus();
    await tester.pump();
    expect(hostNode.hasFocus, isTrue);

    await tester.pumpWidget(build(mounted: true));
    await tester.pump();
    expect(nodeHasFocus(tester, const Key('panel-row-1')), isTrue);

    await tester.pumpWidget(build(mounted: false));
    await tester.pump();
    expect(hostNode.hasFocus, isTrue);
  });
}
