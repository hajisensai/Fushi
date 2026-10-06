import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';

/// 顶部悬浮条按宽度自适应溢出（2026-10-06）：宽时全部平铺、不画「⋯」；骤缩到
/// 窄宽时**第一帧**就收进「⋯」且不溢出（HBK034：AnimatedSize 收缩时保留旧宽度
/// 一帧，760 → 320 右侧溢出 276px）。
void main() {
  final List<FushiToolbarItem> actions = List<FushiToolbarItem>.generate(
    10,
    (int index) => FushiToolbarItem(
      icon: Icons.settings,
      label: 'Action $index',
      onPressed: () {},
    ),
  );

  Widget host(double width) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: FushiFloatingTopBar(
            leading: <FushiToolbarItem>[
              FushiToolbarItem(
                icon: Icons.arrow_back,
                label: 'Back',
                onPressed: () {},
              ),
            ],
            title: 'Book',
            actions: <List<FushiToolbarItem>>[actions],
          ),
        ),
      ),
    ),
  );

  final Finder more = find.byKey(
    const ValueKey<String>('fushi_floating_toolbar_overflow'),
  );

  testWidgets('HBK034: 760 → 320 骤缩第一帧即收进 ⋯ 且不溢出', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(760));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(more, findsNothing, reason: '宽度够时全部平铺，不画 ⋯');

    await tester.pumpWidget(host(320));
    expect(more, findsOneWidget);
    expect(tester.takeException(), isNull, reason: '收缩的第一帧不得溢出');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  test('拆分：按优先级平铺前 k 颗，其余（含 overflow）进 ⋯', () {
    final FushiToolbarItem a = FushiToolbarItem(
      icon: Icons.add,
      label: 'a',
      onPressed: () {},
    );
    final FushiToolbarItem b = FushiToolbarItem(
      icon: Icons.add,
      label: 'b',
      onPressed: () {},
    );
    final FushiToolbarItem c = FushiToolbarItem(
      icon: Icons.add,
      label: 'c',
      onPressed: () {},
    );
    final split = fushiTopBarSplitActions(
      <List<FushiToolbarItem>>[
        <FushiToolbarItem>[a, b],
      ],
      <FushiToolbarItem>[c],
      1,
    );
    expect(split.groups, <List<FushiToolbarItem>>[
      <FushiToolbarItem>[a],
    ]);
    expect(split.overflow, <FushiToolbarItem>[b, c]);
  });
}
