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

  group('closeOwnRoute', () {
    /// 首页上开一个「导入框」，返回 (框的 context, 框的 result future)。
    Future<(BuildContext, Future<bool?>)> openImportDialog(
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navKey,
          home: const Scaffold(body: Text('home')),
        ),
      );
      late BuildContext dialogContext;
      final Future<bool?> result = showDialog<bool>(
        context: navKey.currentContext!,
        builder: (BuildContext ctx) {
          dialogContext = ctx;
          return const AlertDialog(content: Text('import dialog'));
        },
      );
      await tester.pumpAndSettle();
      return (dialogContext, result);
    }

    testWidgets('on top: closes itself with the result', (
      WidgetTester tester,
    ) async {
      final (BuildContext ctx, Future<bool?> result) = await openImportDialog(
        tester,
      );

      expect(closeOwnRoute<bool>(ctx, true), isTrue);
      await tester.pumpAndSettle();

      expect(find.text('import dialog'), findsNothing);
      expect(find.text('home'), findsOneWidget);
      expect(await result, isTrue);
    });

    // 反馈 zorhfwRcz- 分诊：导入进行中用户从悬浮反馈球推出反馈页，导入完成时裸
    // `Navigator.pop(context, true)` 关掉的是反馈页（且把 true 当成反馈页的返回值）。
    testWidgets(
      'page pushed above: removes only itself, the page above stays',
      (WidgetTester tester) async {
        final (BuildContext ctx, Future<bool?> result) = await openImportDialog(
          tester,
        );
        final Route<String> feedbackPage = MaterialPageRoute<String>(
          builder: (_) => const Scaffold(body: Text('feedback page')),
        );
        final Future<String?> feedbackResult = navKey.currentState!.push(
          feedbackPage,
        );
        await tester.pumpAndSettle();

        expect(closeOwnRoute<bool>(ctx, true), isTrue);
        await tester.pumpAndSettle();

        expect(find.text('feedback page'), findsOneWidget);
        expect(feedbackPage.isCurrent, isTrue);
        expect(await result, isTrue);

        // 反馈页关掉后下面直接是首页：导入框没有留成孤儿。
        navKey.currentState!.pop('sent');
        await tester.pumpAndSettle();
        expect(await feedbackResult, 'sent');
        expect(find.text('import dialog'), findsNothing);
        expect(find.text('home'), findsOneWidget);
      },
    );

    testWidgets('already closed: does nothing and returns false', (
      WidgetTester tester,
    ) async {
      final (BuildContext ctx, Future<bool?> _) = await openImportDialog(
        tester,
      );
      expect(closeOwnRoute<bool>(ctx, false), isTrue);
      // 退场动画还没跑完时 context 仍挂着，但路由已不在栈里：不许再弹首页。
      expect(closeOwnRoute<bool>(ctx, false), isFalse);
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);
    });
  });
}
