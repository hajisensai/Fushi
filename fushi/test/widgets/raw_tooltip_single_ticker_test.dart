import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-5205：`main.dart` 的 `FlutterError.onError` 以前吞掉同时含
/// `SingleTickerProviderStateMixin` 与 `RawTooltipState` 的错误（老框架里 tooltip
/// 会建第二个 ticker）。Flutter 3.50 的 `RawTooltipState` 只懒建一个
/// `AnimationController`，这条过滤已无对象，反而会把「disposed with an active
/// Ticker」这类真实泄漏断言一起藏掉，所以删掉了。这里在 debug（断言开）下反复
/// 显示 / 隐藏 / 改动画时长 / 动画中销毁 tooltip，确认框架不再报 ticker 断言。
void main() {
  Widget rawHost(Duration show, {bool present = true}) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: present
            ? RawTooltip(
                semanticsTooltip: 'tip',
                triggerMode: TooltipTriggerMode.manual,
                animationStyle: AnimationStyle(
                  duration: show,
                  reverseDuration: show,
                ),
                tooltipBuilder: (BuildContext _, Animation<double> animation) =>
                    FadeTransition(
                      opacity: animation,
                      child: const Text('tip'),
                    ),
                child: const SizedBox(width: 80, height: 40),
              )
            : const SizedBox.shrink(),
      ),
    ),
  );

  Widget materialHost({bool present = true}) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: present
            ? const Tooltip(
                message: 'tip',
                waitDuration: Duration.zero,
                exitDuration: Duration.zero,
                child: SizedBox(width: 80, height: 40),
              )
            : const SizedBox.shrink(),
      ),
    ),
  );

  testWidgets('RawTooltip 反复显隐、动画中改时长、动画中销毁都不报 ticker 断言', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(rawHost(const Duration(milliseconds: 150)));
    RawTooltipState state() =>
        tester.state<RawTooltipState>(find.byType(RawTooltip));

    for (int i = 0; i < 4; i++) {
      state().ensureTooltipVisible();
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.text('tip'), findsOneWidget);
      // 显示动画中途换时长：旧框架这里会再建一个 ticker。
      await tester.pumpWidget(rawHost(Duration(milliseconds: 100 + 40 * i)));
      await tester.pump(const Duration(milliseconds: 40));
      RawTooltip.dismissAllToolTips();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
    }

    // 显示动画进行中直接拆掉 tooltip。
    state().ensureTooltipVisible();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pumpWidget(rawHost(Duration.zero, present: false));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Material Tooltip 悬停显隐与动画中销毁不报 ticker 断言', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(materialHost());
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    for (int i = 0; i < 3; i++) {
      await mouse.moveTo(tester.getCenter(find.byType(Tooltip)));
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('tip'), findsOneWidget);
      await mouse.moveTo(Offset.zero);
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
    }

    await mouse.moveTo(tester.getCenter(find.byType(Tooltip)));
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pumpWidget(materialHost(present: false));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  test('main.dart 不再吞 RawTooltip 的 ticker 错误', () {
    final String main = File('lib/main.dart').readAsStringSync();
    expect(main, isNot(contains("msg.contains('RawTooltipState')")));
  });
}
