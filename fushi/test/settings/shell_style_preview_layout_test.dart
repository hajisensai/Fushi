// 外观 › 主题 的外壳样式三行（库页布局 / 色块摆放 / 侧栏样式）与升级弹窗的预览：
// - 设置页三行是「左标题 + 右紧凑选择块」，桌面下选择块在行尾、每行不高于 ~120dp（所有者反馈
//   原来的大卡 + 整块实时预览太占位置）；
// - BUG-4854：封面网格示意的格子在松约束下缩成 0 高、整块空白——这里断言网格单元
//   真的有面积；
// - BUG-4855：侧栏样式示意的几何只按宽度求，宽而矮的盒子里竖向溢出——这里在
//   360 / 800 / 1460 三种宽度下收集 FlutterError，必须为空。
// 选择一律焦点驱动（FocusDriver + Enter），不点坐标。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/shell_layout_choice_dialog.dart';
import 'package:fushi/src/settings/shell_style_preview.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:material_ui/material_ui.dart';

import '../../integration_test/helpers/focus_driver.dart';

/// 与 settings_schema_appearance.dart 的 `_shellChoiceRow` 同一装配：标题 + 说明
/// 在左，紧凑选择块在行尾并声明固有宽度。
Widget _row({
  required String title,
  required Widget tiles,
  required int count,
  String? subtitle,
  Key? key,
}) => AdaptiveSettingsRow(
  key: key,
  title: title,
  subtitle: subtitle,
  trailing: tiles,
  trailingWidth: ShellChoiceTiles.widthFor(count),
);

class _Selections {
  ShellContentLayout layout = ShellContentLayout.collage;
  ShellBlockArrangement arrangement = ShellBlockArrangement.aligned;
  ShellRailStyle rail = ShellRailStyle.notch;
}

Widget _settingsHost(_Selections s) => TranslationProvider(
  child: MaterialApp(
    home: Scaffold(
      body: StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) =>
            SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _row(
                    key: const ValueKey<String>('row-layout'),
                    title: t.library_layout,
                    count: ShellContentLayout.values.length,
                    tiles: ShellLayoutChoiceTiles(
                      selected: s.layout,
                      arrangement: s.arrangement,
                      onSelected: (ShellContentLayout v) =>
                          setState(() => s.layout = v),
                    ),
                  ),
                  _row(
                    key: const ValueKey<String>('row-arrangement'),
                    title: t.library_arrangement,
                    subtitle: t.library_arrangement_hint,
                    count: ShellBlockArrangement.values.length,
                    tiles: ShellArrangementChoiceTiles(
                      selected: s.arrangement,
                      onSelected: (ShellBlockArrangement v) =>
                          setState(() => s.arrangement = v),
                    ),
                  ),
                  _row(
                    key: const ValueKey<String>('row-rail'),
                    title: t.home_nav_rail_style,
                    count: ShellRailStyle.values.length,
                    tiles: ShellRailChoiceTiles(
                      selected: s.rail,
                      onSelected: (ShellRailStyle v) =>
                          setState(() => s.rail = v),
                    ),
                  ),
                ],
              ),
            ),
      ),
    ),
  ),
);

/// 在 [width] × [height] 的窗口里 pump [app]，返回期间收集到的全部 FlutterError
/// （布局溢出走 FlutterError.reportError）。
Future<List<FlutterErrorDetails>> _pumpCollectingErrors(
  WidgetTester tester,
  Widget app, {
  required double width,
  double height = 1400,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  addTearDown(tester.view.reset);
  final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
  final void Function(FlutterErrorDetails)? previous = FlutterError.onError;
  FlutterError.onError = errors.add;
  try {
    await tester.pumpWidget(app);
    await tester.pump(const Duration(milliseconds: 800));
  } finally {
    FlutterError.onError = previous;
  }
  return errors;
}

bool _selectedOf(WidgetTester tester, String key) {
  final Semantics semantics = tester.widget<Semantics>(
    find
        .descendant(
          of: find.byKey(ValueKey<String>(key)),
          matching: find.byType(Semantics),
        )
        .first,
  );
  return semantics.properties.selected ?? false;
}

void _expectGridCellsPainted(WidgetTester tester) {
  final Finder cells = find.byKey(
    const ValueKey<String>('shell-preview-grid-cell-0'),
  );
  expect(cells, findsWidgets, reason: '封面网格示意必须画出网格单元');
  for (final Element cell in cells.evaluate()) {
    final Size size = (cell.renderObject! as RenderBox).size;
    expect(size.width, greaterThan(2), reason: 'BUG-4854：网格单元宽为 0');
    expect(size.height, greaterThan(2), reason: 'BUG-4854：网格单元高为 0（空白）');
  }
}

void main() {
  for (final double width in <double>[360, 800, 1460]) {
    testWidgets('设置页三行在 ${width.toInt()} 宽下不溢出、网格示意非空', (
      WidgetTester tester,
    ) async {
      final _Selections s = _Selections();
      final List<FlutterErrorDetails> errors = await _pumpCollectingErrors(
        tester,
        _settingsHost(s),
        width: width,
      );
      expect(
        errors.map((FlutterErrorDetails e) => e.exceptionAsString()).toList(),
        isEmpty,
      );
      _expectGridCellsPainted(tester);
      expect(find.byType(ShellRailPreview), findsNWidgets(2));

      if (width >= 800) {
        // 紧凑：选择块在行尾、与标题同一行（不再整行铺大卡），每行不高于 120dp
        // （原来的大卡行 175～220dp，外加 ~230dp 的实时预览；说明文字折行会让
        // 「色块摆放」行略高）。
        for (final (String row, String tile) in <(String, String)>[
          ('row-layout', 'shell-layout-grid'),
          ('row-arrangement', 'shell-arrangement-scattered'),
          ('row-rail', 'shell-rail-spine'),
        ]) {
          final Rect rowRect = tester.getRect(
            find.byKey(ValueKey<String>(row)),
          );
          final Rect tileRect = tester.getRect(
            find.byKey(ValueKey<String>(tile)),
          );
          expect(
            rowRect.height,
            lessThanOrEqualTo(120),
            reason: '$row 应是紧凑的一行',
          );
          expect(
            tileRect.left,
            greaterThan(rowRect.center.dx),
            reason: '$tile 应在行尾（与标题同一行）',
          );
          expect(tileRect.height, lessThanOrEqualTo(90), reason: '$tile 是迷你块');
        }
      }
    });
  }

  testWidgets('选择块焦点可达：Enter 选中，语义带选中态与互斥组', (WidgetTester tester) async {
    final _Selections s = _Selections();
    await _pumpCollectingErrors(tester, _settingsHost(s), width: 1460);
    expect(_selectedOf(tester, 'shell-rail-notch'), isTrue);
    expect(_selectedOf(tester, 'shell-rail-spine'), isFalse);

    final FocusDriver driver = FocusDriver(tester);
    expect(
      await driver.focusWidget(
        find.byKey(const ValueKey<String>('shell-rail-spine')),
      ),
      isTrue,
    );
    await driver.activate();
    await tester.pump(const Duration(milliseconds: 400));
    expect(s.rail, ShellRailStyle.spine);
    expect(_selectedOf(tester, 'shell-rail-spine'), isTrue);
    expect(_selectedOf(tester, 'shell-rail-notch'), isFalse);

    expect(
      await driver.focusWidget(
        find.byKey(const ValueKey<String>('shell-layout-grid')),
      ),
      isTrue,
    );
    await driver.activate();
    await tester.pump(const Duration(milliseconds: 400));
    expect(s.layout, ShellContentLayout.grid);

    final Semantics tile = tester.widget<Semantics>(
      find
          .descendant(
            of: find.byKey(const ValueKey<String>('shell-layout-grid')),
            matching: find.byType(Semantics),
          )
          .first,
    );
    expect(tile.properties.inMutuallyExclusiveGroup, isTrue);
    expect(tile.properties.label, contains(t.library_layout_grid));
  });

  // BUG-4855 的原始失败形状：侧栏示意放进宽而矮的盒子（旧设置页大卡 ~680 × 58）。
  for (final Size box in <Size>[
    const Size(680, 58),
    const Size(1400, 40),
    const Size(66, 38),
    const Size(240, 120),
  ]) {
    testWidgets('侧栏样式示意在 ${box.width.toInt()}×${box.height.toInt()} 盒子里不溢出', (
      WidgetTester tester,
    ) async {
      final List<FlutterErrorDetails> errors = await _pumpCollectingErrors(
        tester,
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                for (final ShellRailStyle style in ShellRailStyle.values)
                  SizedBox.fromSize(
                    size: box,
                    child: ShellRailPreview(style: style),
                  ),
              ],
            ),
          ),
        ),
        width: 1460,
      );
      expect(
        errors.map((FlutterErrorDetails e) => e.exceptionAsString()).toList(),
        isEmpty,
      );
    });
  }

  for (final double width in <double>[360, 800, 1460]) {
    testWidgets('升级弹窗大卡在 ${width.toInt()} 宽下不溢出、网格示意非空', (
      WidgetTester tester,
    ) async {
      final List<FlutterErrorDetails> errors = await _pumpCollectingErrors(
        tester,
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: ShellLayoutChoiceDialog(
                  arrangement: ShellBlockArrangement.scattered,
                  onConfirm: (ShellContentLayout _) {},
                  onLater: () {},
                ),
              ),
            ),
          ),
        ),
        width: width,
        height: 900,
      );
      expect(
        errors.map((FlutterErrorDetails e) => e.exceptionAsString()).toList(),
        isEmpty,
      );
      _expectGridCellsPainted(tester);
      // 弹窗保持可读：大卡带说明文字。
      expect(find.text(t.library_layout_grid_hint), findsOneWidget);
    });
  }
}
