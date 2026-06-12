import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/pages/implementations/media_item_dialog_page.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

/// BUG-221: 长按书架书籍弹出的「书籍设置」弹窗，一行三个 quick-action 按钮
/// （查看插画 / 导入有声书 / 标签）原先用 intrinsic-width 的 [Wrap]，标签长度
/// 不等 → 按内容宽换行参差。修复后必须等宽布局：宽屏等宽横排、窄屏降级竖排整行。
void main() {
  // 三个长度差异明显的中文标签，复刻真实 view_illustrations /
  // audiobook_import / tag_label 的参差触发条件。
  final List<DialogQuickAction> threeActions = <DialogQuickAction>[
    DialogQuickAction(
      label: '查看插画',
      icon: Icons.image_outlined,
      onPressed: () {},
    ),
    DialogQuickAction(
      label: '导入有声书',
      icon: Icons.headphones_outlined,
      onPressed: () {},
    ),
    DialogQuickAction(
      label: '标签',
      icon: Icons.sell_outlined,
      onPressed: () {},
    ),
  ];

  Future<void> pumpFrame(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MediaItemDialogFrame(
              title: 'こころ',
              launchLabel: 'Read',
              onLaunch: () {},
              quickActions: threeActions,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<double> chipWidths(WidgetTester tester) {
    final Iterable<Element> elements = find.byType(HibikiActionChip).evaluate();
    return elements
        .map((Element e) => e.size?.width ?? double.nan)
        .toList(growable: false);
  }

  testWidgets(
      'quick actions use an equal-width layout, never an intrinsic Wrap',
      (WidgetTester tester) async {
    await pumpFrame(tester);

    // 回归守卫：禁止退回 intrinsic-width 的 Wrap（参差根因）。
    expect(find.byType(Wrap), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide dialog lays the three chips equal-width in a single row',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpFrame(tester);

    final List<double> widths = chipWidths(tester);
    expect(widths.length, 3);
    // 等宽：三个 chip 宽度差 < 1px（Expanded 平分）。
    final double maxW = widths.reduce((double a, double b) => a > b ? a : b);
    final double minW = widths.reduce((double a, double b) => a < b ? a : b);
    expect(maxW - minW, lessThan(1.0),
        reason: '宽屏三个 quick-action 应等宽平分一行，实际=$widths');
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow dialog falls back to full-width stacked chips',
      (WidgetTester tester) async {
    // 窄到一行平分后单格 < _quickActionMinChipWidth，触发竖排降级。
    tester.view.physicalSize = const Size(360, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpFrame(tester);

    final List<double> widths = chipWidths(tester);
    expect(widths.length, 3);
    // 竖排整行：三个 chip 等宽（都等于内容区宽度）。
    final double maxW = widths.reduce((double a, double b) => a > b ? a : b);
    final double minW = widths.reduce((double a, double b) => a < b ? a : b);
    expect(maxW - minW, lessThan(1.0),
        reason: '窄屏降级竖排后三个 chip 应整行等宽，实际=$widths');
    // 竖排时 chip 沿水平方向铺满整行，远宽于横排平分（available/3）的单格宽。
    expect(minW, greaterThan(widths.length * 60.0),
        reason: '竖排 chip 应占满整行宽（远宽于横排平分），实际=$widths');
    expect(tester.takeException(), isNull);
  });
}
