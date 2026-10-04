import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// 标签包装契约：MD3 下是原 Material chip；玻璃下是 GlassChip（可 Tab 聚焦、
// Enter 激活），界面里没有 RawChip。

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required bool glass,
}) async {
  final ThemeData theme = buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    glass: glass ? FushiGlassMaterial.liquid : FushiGlassMaterial.off,
    glassDesign: glass,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: FushiGlassScope(
        child: Scaffold(body: Center(child: child)),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _tabThenEnter(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  group('MD3 builds the original chips', () {
    testWidgets('ChoiceChip / FilterChip / ActionChip / InputChip / Chip', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        Wrap(
          children: <Widget>[
            FushiChoiceChip(
              label: const Text('choice'),
              selected: true,
              onSelected: (_) {},
            ),
            FushiFilterChip(label: const Text('filter'), onSelected: (_) {}),
            FushiActionChipControl(
              label: const Text('action'),
              onPressed: () {},
            ),
            FushiInputChip(label: const Text('input'), onPressed: () {}),
            const FushiChip(label: Text('plain')),
          ],
        ),
        glass: false,
      );
      expect(find.byType(ChoiceChip), findsOneWidget);
      expect(find.byType(FilterChip), findsOneWidget);
      expect(find.byType(ActionChip), findsOneWidget);
      expect(find.byType(InputChip), findsOneWidget);
      expect(find.byType(Chip), findsOneWidget);
      expect(find.byType(GlassChip), findsNothing);
    });
  });

  group('glass', () {
    testWidgets('renders GlassChip and no Material chip', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        Wrap(
          children: <Widget>[
            FushiChoiceChip(
              label: const Text('choice'),
              selected: true,
              onSelected: (_) {},
            ),
            FushiFilterChip(label: const Text('filter'), onSelected: (_) {}),
            FushiActionChipControl(
              label: const Text('action'),
              onPressed: () {},
            ),
            FushiInputChip(label: const Text('input'), onPressed: () {}),
            const FushiChip(label: Text('plain')),
          ],
        ),
        glass: true,
      );
      expect(find.byType(RawChip), findsNothing);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.byType(GlassChip), findsNWidgets(4));
      // 纯展示 Chip 是不可交互的玻璃胶囊。
      expect(
        find.ancestor(
          of: find.text('plain'),
          matching: find.byType(GlassContainer),
        ),
        findsOneWidget,
      );
      // 选中的 ChoiceChip 默认显示对勾。
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('ChoiceChip toggles on tap and on Tab + Enter', (
      WidgetTester tester,
    ) async {
      final List<bool> events = <bool>[];
      await _pump(
        tester,
        FushiChoiceChip(
          label: const Text('choice'),
          selected: false,
          onSelected: events.add,
        ),
        glass: true,
      );
      await tester.tap(find.text('choice'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(events, <bool>[true]);

      await _tabThenEnter(tester);
      expect(events, <bool>[true, true]);
    });

    testWidgets('FilterChip reports !selected and ActionChip presses', (
      WidgetTester tester,
    ) async {
      final List<bool> filter = <bool>[];
      int pressed = 0;
      await _pump(
        tester,
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiFilterChip(
              label: const Text('filter'),
              selected: true,
              onSelected: filter.add,
            ),
            FushiActionChipControl(
              label: const Text('action'),
              avatar: const Icon(Icons.add),
              onPressed: () => pressed++,
            ),
          ],
        ),
        glass: true,
      );
      await tester.tap(find.text('filter'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(filter, <bool>[false]);

      // Tab 依次经过 filter、action；第二个 Tab 落到 action 后 Enter。
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await _tabThenEnter(tester);
      expect(pressed, 1);
    });

    testWidgets('InputChip toggles selection then presses, and deletes', (
      WidgetTester tester,
    ) async {
      final List<String> log = <String>[];
      await _pump(
        tester,
        FushiInputChip(
          label: const Text('input'),
          onSelected: (bool v) => log.add('select:$v'),
          onPressed: () => log.add('press'),
          onDeleted: () => log.add('delete'),
        ),
        glass: true,
      );
      await tester.tap(find.text('input'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(log, <String>['select:true', 'press']);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump(const Duration(milliseconds: 300));
      expect(log.last, 'delete');
    });

    testWidgets('disabled ChoiceChip is not focusable', (
      WidgetTester tester,
    ) async {
      final FocusNode node = FocusNode();
      addTearDown(node.dispose);
      await _pump(
        tester,
        FushiChoiceChip(
          label: const Text('off'),
          selected: false,
          focusNode: node,
          onSelected: null,
        ),
        glass: true,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(node.hasFocus, isFalse);
    });

    testWidgets('non-Text label falls back to a glass button chip', (
      WidgetTester tester,
    ) async {
      int pressed = 0;
      await _pump(
        tester,
        FushiActionChipControl(
          label: const Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[Text('a'), Text('b')],
          ),
          onPressed: () => pressed++,
        ),
        glass: true,
      );
      expect(find.byType(RawChip), findsNothing);
      expect(find.byType(GlassButton), findsOneWidget);
      await _tabThenEnter(tester);
      expect(pressed, 1);
    });
  });
}
