import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/startup/loading_watchdog_view.dart';
import 'package:fushi/utils.dart' show t;

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

  testWidgets('超时(桌面) → 显示掉线盘说明 + 重试按钮（逃生口出现）', (WidgetTester tester) async {
    bool retried = false;
    await tester.pumpWidget(wrap(LoadingWatchdogView(
      timedOut: true,
      colorScheme: cs,
      onRetry: () => retried = true,
      isMobile: false,
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

  // BUG-815：移动端没有自定义数据根（AppPaths._resolveDataRoot 非桌面恒 null），
  // 桌面那套「数据存储位置设在未连接网络盘 / 用默认位置启动」文案在手机上既不适用
  // 又吓人（重试根本不换位置）。移动端必须改显不提「默认位置」的安心文案。
  testWidgets('超时(移动端) → 显示移动端安心文案，不含桌面『默认位置』说明 (BUG-815)',
      (WidgetTester tester) async {
    await tester.pumpWidget(wrap(LoadingWatchdogView(
      timedOut: true,
      colorScheme: cs,
      onRetry: () {},
      isMobile: true,
    )));

    expect(find.text(t.loading_slow_title), findsOneWidget);
    expect(find.text(t.loading_slow_message_mobile), findsOneWidget,
        reason: '移动端须显示 loading_slow_message_mobile');
    expect(find.text(t.loading_slow_message), findsNothing,
        reason: '移动端不得再显示桌面掉线盘 / 默认位置文案');
    expect(find.text(t.retry), findsOneWidget);
  });
}
