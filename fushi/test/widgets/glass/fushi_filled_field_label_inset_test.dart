import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';

// 反馈 jIlpJV-xW4（BUG：「文字显示不全」）：MD3 带标题的填充式字段，浮起的标题
// 必须落在填充块**内**、离上沿有 M3 的顶距——
//
// - 桌面主题默认 VisualDensity.compact（dy -8）：InputDecorator 把标题画在
//   contentPadding.top + dy/2，dense 字段顶在 0、字形被填充块上沿切掉
//   （字幕合集面板的「Jimaku API 密钥」「番剧名」「偏好版本」）；
// - FushiDropdownMenu 走全局主题的无描边 OutlineInputBorder，标题按描边式骑在
//   边框线上（-6），一半露在框外。
//
// 所有经 fushiMd3FieldDecoration 的字段工厂（文本框 / 表单下拉 / 下拉菜单）都在
// 这里量，桌面与移动两种密度各一遍。

Future<void> _pump(
  WidgetTester tester, {
  required VisualDensity density,
  required Widget child,
}) async {
  final ThemeData theme = buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
  ).copyWith(visualDensity: density);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: FushiGlassScope(
        child: Scaffold(
          body: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  final Map<String, Widget Function(bool dense)> fields =
      <String, Widget Function(bool dense)>{
        'FushiTextFieldControl': (bool dense) => FushiTextFieldControl(
          controller: TextEditingController(text: 'value'),
          decoration: InputDecoration(
            labelText: 'Label',
            helperText: 'helper',
            isDense: dense,
          ),
        ),
        'FushiTextFieldControl + OutlineInputBorder': (bool dense) =>
            FushiTextFieldControl(
              controller: TextEditingController(text: 'value'),
              decoration: InputDecoration(
                labelText: 'Label',
                isDense: dense,
                border: const OutlineInputBorder(),
              ),
            ),
        'FushiDropdownButtonFormField': (bool dense) =>
            FushiDropdownButtonFormField<int>(
              initialValue: 1,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'Label',
                isDense: dense,
                border: const OutlineInputBorder(),
              ),
              items: const <DropdownMenuItem<int>>[
                DropdownMenuItem<int>(value: 1, child: Text('one')),
              ],
              onChanged: (_) {},
            ),
        'FushiDropdownMenu': (bool dense) => FushiDropdownMenu<int>(
          label: const Text('Label'),
          initialSelection: 1,
          inputDecorationTheme: dense
              ? const InputDecorationThemeData(isDense: true)
              : null,
          dropdownMenuEntries: const <DropdownMenuEntry<int>>[
            DropdownMenuEntry<int>(value: 1, label: 'one'),
          ],
        ),
      };

  for (final VisualDensity density in <VisualDensity>[
    VisualDensity.compact,
    VisualDensity.standard,
  ]) {
    for (final MapEntry<String, Widget Function(bool)> field
        in fields.entries) {
      for (final bool dense in <bool>[false, true]) {
        testWidgets('${field.key} floating label stays inside the fill '
            '(density ${density.vertical}, dense $dense)', (
          WidgetTester tester,
        ) async {
          await _pump(tester, density: density, child: field.value(dense));
          final Rect fill = tester.getRect(find.byType(InputDecorator).first);
          final Rect label = tester.getRect(find.text('Label').first);
          // M3 填充式字段的标题顶距：常规 8、dense 4（InputDecorator 默认）。
          final double inset = dense ? 4 : 8;
          expect(
            label.top - fill.top,
            greaterThanOrEqualTo(inset - 0.01),
            reason:
                'floating label must sit inside the filled container with '
                'the M3 top inset, not on / above its top edge',
          );
          expect(label.bottom, lessThan(fill.bottom));
        });
      }
    }
  }
}
