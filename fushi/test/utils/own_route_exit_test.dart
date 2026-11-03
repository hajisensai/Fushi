import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/own_route_exit.dart';

/// 被动退出（视频页网页档离开观看页回浏览器）关的必须是**本页路由**，不是最顶层：本页上面
/// 压着对话框时，直接 `Navigator.pop` 只会关掉对话框、视频页留在栈里（审查 2026-11-03）。
void main() {
  final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

  Future<Route<void>> pumpPageWithDialog(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        home: const Scaffold(body: Text('home')),
      ),
    );
    final Route<void> page = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('video page')),
    );
    navKey.currentState!.push<void>(page);
    await tester.pumpAndSettle();
    showDialog<void>(
      context: navKey.currentContext!,
      builder: (_) => const AlertDialog(content: Text('mine dialog')),
    );
    await tester.pumpAndSettle();
    expect(find.text('mine dialog'), findsOneWidget);
    expect(page.isCurrent, isFalse);
    return page;
  }

  testWidgets(
    'pop after popRoutesAbove removes the page, not just the dialog',
    (WidgetTester tester) async {
      final Route<void> page = await pumpPageWithDialog(tester);

      expect(popRoutesAbove(navKey.currentState!, page), isTrue);
      navKey.currentState!.pop();
      await tester.pumpAndSettle();

      expect(find.text('mine dialog'), findsNothing);
      expect(find.text('video page'), findsNothing);
      expect(find.text('home'), findsOneWidget);
      expect(page.isActive, isFalse);
      // 已经不在栈里：不弹任何东西（调用方据此不再 pop，首页不会被误弹）。
      expect(popRoutesAbove(navKey.currentState!, page), isFalse);
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);
    },
  );

  testWidgets('pushReplacement after popRoutesAbove swaps the page itself', (
    WidgetTester tester,
  ) async {
    final Route<void> page = await pumpPageWithDialog(tester);

    expect(popRoutesAbove(navKey.currentState!, page), isTrue);
    navKey.currentState!.pushReplacement<void, void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('browser')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('browser'), findsOneWidget);
    expect(find.text('mine dialog'), findsNothing);
    expect(find.text('video page'), findsNothing);
    expect(page.isActive, isFalse);

    // 浏览器下面直接是首页：视频页没有被留在栈里。
    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });
}
