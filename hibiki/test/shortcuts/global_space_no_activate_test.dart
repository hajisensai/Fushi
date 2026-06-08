import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/global_navigation.dart';

/// 焦点确认不走空格：[wrapWithGlobalNavigation] 把裸空格中和成 DoNothingIntent，
/// 使焦点落在控件上时空格不再触发激活；Enter（与手柄 A，由框架默认提供）仍激活。
/// 这条行为不受实验性焦点导航开关影响——开/关都成立。
void main() {
  Future<int> pumpAndCountTaps(
    WidgetTester tester, {
    required bool focusNavigationEnabled,
    required LogicalKeyboardKey key,
  }) async {
    int taps = 0;
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final FocusNode focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        home: wrapWithGlobalNavigation(
          navigatorKey: navKey,
          focusNavigationEnabled: focusNavigationEnabled,
          child: Scaffold(
            body: Center(
              child: TextButton(
                focusNode: focusNode,
                onPressed: () => taps++,
                child: const Text('确认'),
              ),
            ),
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();
    expect(focusNode.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(key);
    await tester.pump();
    return taps;
  }

  testWidgets('裸空格不激活焦点控件（焦点导航开/关都成立）', (WidgetTester tester) async {
    expect(
      await pumpAndCountTaps(
        tester,
        focusNavigationEnabled: false,
        key: LogicalKeyboardKey.space,
      ),
      0,
      reason: '焦点导航关闭时，空格也不应确认焦点控件',
    );
    expect(
      await pumpAndCountTaps(
        tester,
        focusNavigationEnabled: true,
        key: LogicalKeyboardKey.space,
      ),
      0,
      reason: '焦点导航开启时，空格同样不应确认焦点控件',
    );
  });

  testWidgets('Enter 仍激活焦点控件', (WidgetTester tester) async {
    expect(
      await pumpAndCountTaps(
        tester,
        focusNavigationEnabled: false,
        key: LogicalKeyboardKey.enter,
      ),
      1,
      reason: '确认键 Enter 必须仍能激活焦点控件',
    );
  });
}
