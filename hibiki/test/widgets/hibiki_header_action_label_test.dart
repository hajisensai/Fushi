import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/hibiki_icon_button.dart';

/// 统一合集 UI v2 Phase A：页头动作按钮的可展开文字标签。
///
/// [FushiIconButton.label] 非空时——宽窗（真实视口非 compact，≥600）渲染
/// 「图标 + 文字」药丸；窄窗（<600）自动回落纯图标；label 为 null 永远纯图标。
/// busy/enabled/onTap 两种形态共享同一路径（这里锁 onTap 在展开态可用）。
void main() {
  Future<void> pump(
    WidgetTester tester, {
    required Size viewSize,
    required Widget child,
  }) async {
    tester.view.physicalSize = viewSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: Center(child: child))),
    );
  }

  testWidgets('宽窗（≥600）label 非空 → 渲染文字并可点击', (WidgetTester tester) async {
    int taps = 0;
    await pump(
      tester,
      viewSize: const Size(1000, 800),
      child: FushiIconButton(
        tooltip: 'Import video',
        label: 'Import video',
        icon: Icons.add,
        onTap: () => taps++,
      ),
    );
    expect(find.text('Import video'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
    await tester.tap(find.text('Import video'));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('窄窗（<600）label 非空 → 回落纯图标（无文字）', (WidgetTester tester) async {
    await pump(
      tester,
      viewSize: const Size(400, 800),
      child: FushiIconButton(
        tooltip: 'Import video',
        label: 'Import video',
        icon: Icons.add,
        onTap: () {},
      ),
    );
    expect(find.text('Import video'), findsNothing);
    expect(find.byIcon(Icons.add), findsOneWidget);
  });

  testWidgets('label 为 null → 宽窗也保持纯图标（零行为变化）', (WidgetTester tester) async {
    await pump(
      tester,
      viewSize: const Size(1000, 800),
      child: FushiIconButton(
        tooltip: 'Stats',
        icon: Icons.bar_chart_outlined,
        onTap: () {},
      ),
    );
    expect(find.text('Stats'), findsNothing);
    expect(find.byIcon(Icons.bar_chart_outlined), findsOneWidget);
  });

  testWidgets('展开态 enabled=false → 不触发 onTap', (WidgetTester tester) async {
    int taps = 0;
    await pump(
      tester,
      viewSize: const Size(1000, 800),
      child: FushiIconButton(
        tooltip: 'Import video',
        label: 'Import video',
        icon: Icons.add,
        enabled: false,
        onTap: () => taps++,
      ),
    );
    await tester.tap(find.text('Import video'));
    await tester.pump();
    expect(taps, 0);
  });
}
