import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

void main() {
  testWidgets('clickable FushiListItem registers with the focus root',
      (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: FushiFocusRoot(
        child: Column(
          children: <Widget>[
            FushiListItem(
              focusId: const FushiFocusId('first-row'),
              title: const Text('First'),
              onTap: () => taps += 1,
            ),
            FushiListItem(
              focusId: const FushiFocusId('second-row'),
              title: const Text('Second'),
              onTap: () => taps += 1,
            ),
          ],
        ),
      ),
    ));
    await tester.pump();

    final FushiFocusController controller = FushiFocusRoot.controllerOf(
      tester.element(find.text('First')),
    );

    expect(controller.requestById(const FushiFocusId('first-row')), isTrue);
    await tester.pump();
    expect(controller.activeId, const FushiFocusId('first-row'));

    Actions.maybeInvoke<ActivateIntent>(
      controller.activeContext!,
      const ActivateIntent(),
    );
    expect(taps, 1);
  });

  // BUG-1425：把 texthooker 窗口选择器的裸 ListTile 收口到本组件时，唯一没有对应物的
  // 就是 `autofocus`。它不是装饰——BUG-1049 的「打开对话框即落在正确的那一行，回车直接
  // 确认」全靠它。这条锁住：带 autofocus 的行开屏就持有键盘焦点，且 Enter 直接触发
  // onTap（对话框里没有 FushiFocusRoot，走的是 InkWell 自己的焦点节点）。
  testWidgets('autofocus FushiListItem takes keyboard focus on open',
      (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: <Widget>[
            FushiListItem(
              title: const Text('Other window'),
              onTap: () => taps += 1,
            ),
            FushiListItem(
              autofocus: true,
              title: const Text('The game window'),
              onTap: () => taps += 1,
            ),
          ],
        ),
      ),
    ));
    await tester.pump();

    final InkWell focused = tester.widget<InkWell>(
      find
          .descendant(
            of: find.ancestor(
              of: find.text('The game window'),
              matching: find.byType(FushiListItem),
            ),
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(focused.autofocus, isTrue);

    // 焦点真的落在这一行上：Enter 直接确认，不需要先 Tab 过去。
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('passive FushiListItem is not a focus target',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: FushiFocusRoot(
        child: Column(
          children: <Widget>[
            FushiListItem(title: Text('Passive')),
          ],
        ),
      ),
    ));
    await tester.pump();

    final FushiFocusController controller = FushiFocusRoot.controllerOf(
      tester.element(find.text('Passive')),
    );

    controller.move(FushiFocusDirection.down);
    await tester.pump();
    expect(controller.activeId, isNull);
    expect(controller.fallbackNode.hasPrimaryFocus, isTrue);
  });
}
