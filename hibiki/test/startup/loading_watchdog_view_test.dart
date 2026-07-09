import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/startup/loading_watchdog_view.dart';
import 'package:hibiki/utils.dart' show t;

/// TODO-1260：启动加载逃生口渲染契约。裸 loading 分支此前只有无超时的转圈；看门狗超时
/// 后必须给出可点的「重试」出口，消除「无 escape」结构缺陷（Layer 3）。
void main() {
  final ColorScheme cs =
      ColorScheme.fromSeed(seedColor: const Color(0xFF1F4959));

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('未超时 → 只显示转圈，无重试按钮', (WidgetTester tester) async {
    await tester.pumpWidget(wrap(LoadingWatchdogView(
      timedOut: false,
      colorScheme: cs,
      onRetry: () {},
    )));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text(t.retry), findsNothing);
    expect(find.text(t.loading_slow_title), findsNothing);
  });

  testWidgets('超时 → 显示说明 + 重试按钮（逃生口出现）', (WidgetTester tester) async {
    bool retried = false;
    await tester.pumpWidget(wrap(LoadingWatchdogView(
      timedOut: true,
      colorScheme: cs,
      onRetry: () => retried = true,
    )));

    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: '超时后不再无限转圈');
    expect(find.text(t.loading_slow_title), findsOneWidget);
    expect(find.text(t.loading_slow_message), findsOneWidget);
    expect(find.text(t.retry), findsOneWidget);

    await tester.tap(find.text(t.retry));
    await tester.pump();
    expect(retried, isTrue, reason: '点重试须触发 onRetry（复位看门狗 + retryInitialise）');
  });
}
