import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/helpers/focus_driver.dart';

void main() {
  testWidgets('reachAll traverses every focusable button via Tab',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: <Widget>[
          for (int i = 0; i < 3; i++)
            TextButton(
              onPressed: () {},
              child: Text('btn$i'),
            ),
        ]),
      ),
    ));
    await tester.pump();

    final FocusDriver driver = FocusDriver(tester);
    final List<FocusNode> visited = await driver.reachAll(maxSteps: 20);

    expect(visited.length, greaterThanOrEqualTo(3),
        reason: '方向/Tab 键必须能遍历到每个可聚焦控件');
  });

  testWidgets('activate fires the focused button', (tester) async {
    int activatedIndex = -1;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: <Widget>[
          for (int i = 0; i < 3; i++)
            TextButton(
              onPressed: () => activatedIndex = i,
              child: Text('btn$i'),
            ),
        ]),
      ),
    ));
    await tester.pump();

    final FocusDriver driver = FocusDriver(tester);
    final bool ok = await driver.focusWidget(find.text('btn1'), maxSteps: 20);
    expect(ok, isTrue, reason: 'btn1 必须可达');
    await driver.activate();
    expect(activatedIndex, 1, reason: 'Space 必须激活当前焦点按钮');
  });

  testWidgets(
      'focusWidget recovers traversal when a native-view boundary leaves only '
      'the route FocusScope focused', (tester) async {
    final FocusScopeNode routeScope = FocusScopeNode(debugLabel: 'route scope');
    addTearDown(routeScope.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Shortcuts(
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.tab):
                DoNothingAndStopPropagationIntent(),
          },
          child: FocusScope(
            node: routeScope,
            autofocus: true,
            child: Scaffold(
              body: TextButton(
                onPressed: () {},
                child: const Text('after native view'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    routeScope.requestFocus();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, same(routeScope));

    final FocusDriver driver = FocusDriver(tester);
    expect(
      await driver.focusWidget(find.text('after native view'), maxSteps: 3),
      isTrue,
      reason: 'macOS native WebView can hand Flutter back only its route scope; '
          'semantic Tab traversal must resume at the first concrete control',
    );
  });
}
