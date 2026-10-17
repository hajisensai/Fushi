import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/sync/fushi_api_port_conflict_notice.dart';
import 'package:fushi/utils.dart';

void main() {
  Future<void> pumpApp(
    WidgetTester tester,
    GlobalKey<NavigatorState> navigatorKey,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
  }

  testWidgets('启动前就落下的端口冲突在首帧后弹窗，且只弹一次', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
    // 模拟 initialise() 里自启失败：Navigator 还不存在时冲突已经写进状态。
    final ValueNotifier<int?> conflict = ValueNotifier<int?>(19633);
    installFushiApiPortConflictNotice(
      navigatorKey: navigatorKey,
      conflictPort: conflict,
    );

    await pumpApp(tester, navigatorKey);
    await tester.pumpAndSettle();

    expect(
      find.text(t.browser_extension_yomitan_port_conflict(port: 19633)),
      findsOneWidget,
    );
    expect(conflict.value, isNull);

    await tester.tap(find.text(t.dialog_ok));
    await tester.pumpAndSettle();
    expect(
      find.text(t.browser_extension_yomitan_port_conflict(port: 19633)),
      findsNothing,
    );
  });

  testWidgets('UI 起来之后才落下的冲突（自启是 fire-and-forget）同样弹窗', (
    WidgetTester tester,
  ) async {
    final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
    final ValueNotifier<int?> conflict = ValueNotifier<int?>(null);
    installFushiApiPortConflictNotice(
      navigatorKey: navigatorKey,
      conflictPort: conflict,
    );
    await pumpApp(tester, navigatorKey);
    await tester.pumpAndSettle();
    expect(find.text(t.dialog_ok), findsNothing);

    // 自定义端口走通用「端口被占用」文案。
    conflict.value = 20000;
    await tester.pumpAndSettle();

    expect(find.text(t.sync_server_port_in_use(port: 20000)), findsOneWidget);
    expect(find.text(t.fushi_api_server), findsOneWidget);
  });
}
