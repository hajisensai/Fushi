// 反馈 jmgMk1gHG2 / msySECp2Cy：启动后弹的「上次意外退出」提示条冻在半透明、看着压在
// 界面底下，点按钮报 `Null check operator`（AnimationController.stop ←
// ScaffoldMessengerState.hideCurrentSnackBar），永远关不掉。
//
// 根因：主 MaterialApp 会被整棵重挂（locale KeyedSubtree 等），没有 key 的内部
// ScaffoldMessenger 随之 dispose（连同 SnackBar 动画控制器），而已经挂在 Scaffold 上的
// SnackBar 不会被新 messenger 清掉。修法：给 MaterialApp 钉 `scaffoldMessengerKey`，
// 重挂时 messenger 被 reparent、状态原样保留。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _app(String rootKey, GlobalKey<ScaffoldMessengerState>? messengerKey) =>
    KeyedSubtree(
      key: ValueKey<String>(rootKey),
      child: MaterialApp(
        scaffoldMessengerKey: messengerKey,
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );

void main() {
  testWidgets('没钉 key：根重挂后先前取到的 messenger 已销毁（复现根因）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_app('a', null));
    final ScaffoldMessengerState messenger = tester.state(
      find.byType(ScaffoldMessenger),
    );
    messenger.showSnackBar(const SnackBar(content: Text('prompt')));
    await tester.pump();
    await tester.pumpWidget(_app('b', null));
    expect(messenger.mounted, isFalse);
  });

  testWidgets('钉了 scaffoldMessengerKey：根重挂后提示条仍能正常收起', (
    WidgetTester tester,
  ) async {
    final GlobalKey<ScaffoldMessengerState> key =
        GlobalKey<ScaffoldMessengerState>();
    await tester.pumpWidget(_app('a', key));
    final ScaffoldMessengerState messenger = key.currentState!;
    messenger.showSnackBar(
      const SnackBar(content: Text('prompt'), duration: Duration(minutes: 1)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.pumpWidget(_app('b', key));
    expect(identical(key.currentState, messenger), isTrue);
    expect(messenger.mounted, isTrue);

    messenger.hideCurrentSnackBar(reason: SnackBarClosedReason.action);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('prompt'), findsNothing);
  });

  test('主 MaterialApp 接上了 AppModel 的 scaffoldMessengerKey', () {
    final String main = File('lib/main.dart').readAsStringSync();
    expect(
      main,
      contains('scaffoldMessengerKey: appModel.scaffoldMessengerKey'),
    );
  });
}
