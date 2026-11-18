import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart';

import 'widget_test_helpers.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

// FushiTextField 的 M3E 状态契约：filled / outlined 两类、尺寸三档（单行最小
// 高度 + 文字竖直居中）、帮助 / 错误 / 计数文本、清空钮、密码显隐、悬停状态层。
// （竖直居中的 BUG-2973 守卫在 fushi_text_field_vertical_center_test.dart，
// 这里不重复。）

Future<void> _pump(WidgetTester tester, Widget field) async {
  await tester.pumpWidget(
    buildTestApp(
      Padding(
        padding: const EdgeInsets.all(16),
        child: SizedBox(width: 360, child: field),
      ),
    ),
  );
  await tester.pump();
}

InputDecoration _decoration(WidgetTester tester) =>
    tester.widget<InputDecorator>(find.byType(InputDecorator)).decoration;

void main() {
  testWidgets(
    'filled（默认）：M3 填充式——上圆下方、下沿指示线静止 1dp onSurfaceVariant、聚焦 2dp 主色、悬停 8% 状态层',
    (WidgetTester tester) async {
      await _pump(tester, const FushiTextField(hintText: 'Name'));
      final InputDecoration d = _decoration(tester);
      final ColorScheme cs = Theme.of(
        tester.element(find.byType(InputDecorator)),
      ).colorScheme;
      expect(d.filled, isTrue);
      expect(d.enabledBorder!.borderSide.color, cs.onSurfaceVariant);
      expect(d.enabledBorder!.borderSide.width, 1);
      // 指示线只画在下沿：边框只占底部尺寸。
      expect(d.enabledBorder!.dimensions, const EdgeInsets.only(bottom: 1));
      expect(d.focusedBorder!.borderSide.color, cs.primary);
      expect(d.focusedBorder!.borderSide.width, 2);
      expect(
        d.hoverColor,
        cs.onSurface.withValues(alpha: kFushiFieldHoverStateOpacity),
      );
    },
  );

  testWidgets('outlined：透明底 + 1px outline，聚焦 2px 主色，标题骑线', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      const FushiTextField(
        labelText: 'Server',
        variant: FushiTextFieldVariant.outlined,
      ),
    );
    final InputDecoration d = _decoration(tester);
    final ColorScheme cs = Theme.of(
      tester.element(find.byType(InputDecorator)),
    ).colorScheme;
    expect(d.filled, isFalse);
    expect(d.enabledBorder, isA<FushiOutlinedFieldBorder>());
    expect(d.enabledBorder!.isOutline, isTrue);
    expect(d.enabledBorder!.borderSide.color, cs.outline);
    expect(d.focusedBorder!.borderSide.color, cs.primary);
    expect(d.focusedBorder!.borderSide.width, 2);
  });

  for (final (FushiInputSize size, double height) in <(FushiInputSize, double)>[
    (FushiInputSize.small, 40),
    (FushiInputSize.medium, 48),
    (FushiInputSize.large, 56),
  ]) {
    testWidgets('尺寸档 ${size.name}：单行高 $height，文字竖直居中', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        FushiTextField(hintText: '自定义 1', size: size, suffixIcon: null),
      );
      final Rect box = tester.getRect(find.byType(InputDecorator));
      expect(box.height, moreOrLessEquals(height, epsilon: 0.5));
      final Rect hint = tester.getRect(find.text('自定义 1'));
      expect((hint.center.dy - box.center.dy).abs(), lessThanOrEqualTo(1.5));
    });
  }

  testWidgets('多行 + 尺寸档：只给下限，随内容长高', (WidgetTester tester) async {
    final TextEditingController c = TextEditingController(text: '一\n二\n三\n四');
    addTearDown(c.dispose);
    await _pump(
      tester,
      FushiTextField(
        controller: c,
        size: FushiInputSize.small,
        minLines: 1,
        maxLines: 6,
      ),
    );
    expect(tester.getSize(find.byType(InputDecorator)).height, greaterThan(80));
  });

  testWidgets('帮助 / 错误 / 计数文本', (WidgetTester tester) async {
    await _pump(
      tester,
      const FushiTextField(
        hintText: 'Name',
        helperText: 'Shown on cards',
        maxLength: 20,
      ),
    );
    expect(find.text('Shown on cards'), findsOneWidget);
    expect(find.text('0/20'), findsOneWidget);

    await _pump(
      tester,
      const FushiTextField(hintText: 'Name', errorText: 'Required'),
    );
    expect(find.text('Required'), findsOneWidget);
    final ColorScheme cs = Theme.of(
      tester.element(find.byType(InputDecorator)),
    ).colorScheme;
    expect(_decoration(tester).errorBorder!.borderSide.color, cs.error);
  });

  testWidgets('clearable：有字出清空钮，清空后回调', (WidgetTester tester) async {
    final TextEditingController c = TextEditingController();
    addTearDown(c.dispose);
    final List<String> changes = <String>[];
    int cleared = 0;
    await _pump(
      tester,
      FushiTextField(
        controller: c,
        clearable: true,
        onChanged: changes.add,
        onClear: () => cleared++,
      ),
    );
    expect(find.byIcon(FushiIcons.cancel), findsNothing);
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump();
    await tester.tap(find.byIcon(FushiIcons.cancel));
    await tester.pump();
    expect(c.text, isEmpty);
    expect(changes.last, '');
    expect(cleared, 1);
    expect(find.byIcon(FushiIcons.cancel), findsNothing);
  });

  testWidgets('密码框：显隐切换', (WidgetTester tester) async {
    await _pump(tester, const FushiTextField(obscureText: true));
    expect(
      tester.widget<TextField>(find.byType(TextField)).obscureText,
      isTrue,
    );
    await tester.tap(find.byIcon(FushiIcons.visibility));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).obscureText,
      isFalse,
    );
    expect(find.byIcon(FushiIcons.visibilityOff), findsOneWidget);
  });

  testWidgets('禁用态', (WidgetTester tester) async {
    await _pump(tester, const FushiTextField(hintText: 'x', enabled: false));
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
  });

  testWidgets('活动指示线：聚焦后按 FushiMotion 补间 1dp → 2dp 主色', (
    WidgetTester tester,
  ) async {
    await _pump(tester, const FushiTextField(labelText: 'Title'));
    final ColorScheme cs = Theme.of(
      tester.element(find.byType(InputDecorator)),
    ).colorScheme;
    BorderSide line() => FushiFieldIndicatorHost.maybeOf(
      tester.element(find.byType(InputDecorator)),
    )!.side();

    expect(line().width, 1);
    expect(line().color, cs.onSurfaceVariant);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    // 补间中途：既不是静止 1dp，也还没到聚焦 2dp（不是瞬切）。
    expect(line().width, inExclusiveRange(1, 2));

    await tester.pumpAndSettle();
    expect(line().width, 2);
    expect(line().color, cs.primary);
  });

  testWidgets('活动指示线：错误态补间到 error 色', (WidgetTester tester) async {
    await _pump(tester, const FushiTextField(labelText: 'Title'));
    await _pump(
      tester,
      const FushiTextField(labelText: 'Title', errorText: 'Required'),
    );
    final ColorScheme cs = Theme.of(
      tester.element(find.byType(InputDecorator)),
    ).colorScheme;
    await tester.pumpAndSettle();
    expect(
      FushiFieldIndicatorHost.maybeOf(
        tester.element(find.byType(InputDecorator)),
      )!.side().color,
      cs.error,
    );
  });
}
