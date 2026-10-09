import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// 选择类控件包装的契约：
// ① MD3 设计系统下树里是原 Material 控件；
// ② 玻璃设计系统下是 iOS 26 形态、没有原 Material 控件（开关 / 滑块 / 分段用
//    liquid_glass_widgets，复选 / 单选是实色内容层控件、不是玻璃）；
// ③ 玻璃下点击与「焦点 + Enter」都能触发回调，滑块能用方向键调值。
void main() {
  late bool Function() originalShaderSupport;
  setUp(() {
    originalShaderSupport = debugShaderFilterSupported;
    debugShaderFilterSupported = () => true;
  });
  tearDown(() => debugShaderFilterSupported = originalShaderSupport);

  ThemeData theme({required bool glass, FushiGlassMaterial? material}) =>
      buildFushiThemeData(
        scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        textTheme: Typography.material2021().black,
        glass:
            material ??
            (glass ? FushiGlassMaterial.liquid : FushiGlassMaterial.off),
        glassDesign: glass,
      );

  Future<void> pumpHost(
    WidgetTester tester,
    Widget Function(StateSetter setState) builder, {
    required bool glass,
    FushiGlassMaterial? material,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme(glass: glass, material: material),
        home: FushiGlassScope(
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 480,
                child: StatefulBuilder(
                  builder: (BuildContext context, StateSetter setState) =>
                      builder(setState),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> pressEnter(WidgetTester tester, FocusNode node) async {
    node.requestFocus();
    await tester.pump();
    expect(node.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 500));
  }

  // 玻璃下复选 / 单选的可交互外壳（iOS 圆形勾选，不是玻璃按钮）。
  Finder toggleHits() => find.byWidgetPredicate(
    (Widget w) => w.runtimeType.toString() == '_AppleToggleHit',
  );

  group('FushiSwitch', () {
    testWidgets('MD3 renders Material Switch / Switch.adaptive', (
      WidgetTester tester,
    ) async {
      await pumpHost(
        tester,
        (_) => Column(
          children: <Widget>[
            FushiSwitch(value: true, onChanged: (_) {}),
            FushiSwitch.adaptive(value: false, onChanged: (_) {}),
          ],
        ),
        glass: false,
      );
      expect(find.byType(Switch), findsNWidgets(2));
      expect(find.byType(FushiAppleSwitch), findsNothing);
    });

    testWidgets('glass renders FushiAppleSwitch, toggles on tap and Enter', (
      WidgetTester tester,
    ) async {
      final FocusNode node = FocusNode();
      addTearDown(node.dispose);
      bool value = false;
      final List<bool> focusChanges = <bool>[];
      await pumpHost(
        tester,
        (StateSetter setState) => FushiSwitch.adaptive(
          value: value,
          focusNode: node,
          onFocusChange: focusChanges.add,
          onChanged: (bool v) => setState(() => value = v),
        ),
        glass: true,
      );
      expect(find.byType(FushiAppleSwitch), findsOneWidget);
      expect(find.byType(Switch), findsNothing);

      await tester.tap(find.byType(FushiAppleSwitch));
      await settle(tester);
      expect(value, isTrue);

      await pressEnter(tester, node);
      await settle(tester);
      expect(value, isFalse);
      expect(focusChanges, contains(true));
    });

    testWidgets('glass disabled switch is not focusable', (
      WidgetTester tester,
    ) async {
      final FocusNode node = FocusNode();
      addTearDown(node.dispose);
      await pumpHost(
        tester,
        (_) => FushiSwitch(value: false, onChanged: null, focusNode: node),
        glass: true,
      );
      expect(find.byType(FushiAppleSwitch), findsOneWidget);
      node.requestFocus();
      await tester.pump();
      expect(node.hasFocus, isFalse);
    });
  });

  group('FushiSlider', () {
    testWidgets('MD3 renders Material Slider', (WidgetTester tester) async {
      await pumpHost(
        tester,
        (_) => FushiSlider(value: 0.5, onChanged: (_) {}),
        glass: false,
      );
      expect(find.byType(Slider), findsOneWidget);
      expect(find.byType(FushiAppleSlider), findsNothing);
    });

    testWidgets('glass renders FushiAppleSlider and arrow keys adjust the value', (
      WidgetTester tester,
    ) async {
      final FocusNode node = FocusNode();
      addTearDown(node.dispose);
      double value = 5;
      final List<double> starts = <double>[];
      final List<double> ends = <double>[];
      await pumpHost(
        tester,
        (StateSetter setState) => FushiSlider(
          value: value,
          min: 0,
          max: 10,
          divisions: 10,
          focusNode: node,
          onChangeStart: starts.add,
          onChangeEnd: ends.add,
          onChanged: (double v) => setState(() => value = v),
        ),
        glass: true,
      );
      expect(find.byType(FushiAppleSlider), findsOneWidget);
      expect(find.byType(Slider), findsNothing);

      node.requestFocus();
      await tester.pump();
      expect(node.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(value, 6);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(value, 4);
      // 传统导航模式下 ↑/↓ 也调值（与 Material Slider 同键位）。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(value, 5);
      expect(starts, <double>[5, 6, 5, 4]);
      expect(ends, <double>[6, 5, 4, 5]);
    });

    testWidgets('glass slider responds to a tap on the track', (
      WidgetTester tester,
    ) async {
      double value = 0;
      await pumpHost(
        tester,
        (StateSetter setState) => FushiSlider(
          value: value,
          onChanged: (double v) => setState(() => value = v),
        ),
        glass: true,
      );
      final Rect rect = tester.getRect(find.byType(FushiAppleSlider));
      await tester.tapAt(rect.centerRight - const Offset(30, 0));
      await settle(tester);
      expect(value, greaterThan(0.5));
    });

    testWidgets('glass disabled slider ignores arrow keys', (
      WidgetTester tester,
    ) async {
      final FocusNode node = FocusNode();
      addTearDown(node.dispose);
      await pumpHost(
        tester,
        (_) => FushiSlider(value: 0.5, onChanged: null, focusNode: node),
        glass: true,
      );
      node.requestFocus();
      await tester.pump();
      expect(node.hasFocus, isFalse);
    });
  });

  group('FushiRangeSlider', () {
    testWidgets('MD3 renders Material RangeSlider', (
      WidgetTester tester,
    ) async {
      await pumpHost(
        tester,
        (_) => FushiRangeSlider(
          values: const RangeValues(0.2, 0.8),
          onChanged: (_) {},
        ),
        glass: false,
      );
      expect(find.byType(RangeSlider), findsOneWidget);
    });

    testWidgets('glass renders iOS white thumbs; keys and drag adjust', (
      WidgetTester tester,
    ) async {
      RangeValues values = const RangeValues(2, 8);
      await pumpHost(
        tester,
        (StateSetter setState) => FushiRangeSlider(
          values: values,
          min: 0,
          max: 10,
          divisions: 10,
          onChanged: (RangeValues v) => setState(() => values = v),
        ),
        glass: true,
      );
      expect(find.byType(RangeSlider), findsNothing);
      expect(find.byType(GlassContainer), findsNothing);
      final Finder thumbs = find.byWidgetPredicate(
        (Widget w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).shape == BoxShape.circle &&
            (w.decoration as BoxDecoration).color == Colors.white,
      );
      expect(thumbs, findsNWidgets(2));

      // Tab 进第一个拇指（起点），→ 加一格。
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(values, const RangeValues(3, 8));
      // 再 Tab 到终点拇指，← 减一格。
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(values, const RangeValues(3, 7));

      // 拖动终点拇指到最右。
      final Rect endThumb = tester.getRect(thumbs.last);
      await tester.dragFrom(endThumb.center, const Offset(400, 0));
      await tester.pump();
      expect(values.end, 10);
      expect(values.start, 3);
    });
  });

  group('FushiCheckbox', () {
    testWidgets('MD3 renders Material Checkbox', (WidgetTester tester) async {
      await pumpHost(
        tester,
        (_) => FushiCheckbox(value: true, onChanged: (_) {}),
        glass: false,
      );
      expect(find.byType(Checkbox), findsOneWidget);
      expect(toggleHits(), findsNothing);
    });

    testWidgets('glass renders an iOS round check, cycles tristate', (
      WidgetTester tester,
    ) async {
      final FocusNode node = FocusNode();
      addTearDown(node.dispose);
      bool? value = false;
      await pumpHost(
        tester,
        (StateSetter setState) => FushiCheckbox(
          value: value,
          tristate: true,
          focusNode: node,
          onChanged: (bool? v) => setState(() => value = v),
        ),
        glass: true,
      );
      expect(find.byType(Checkbox), findsNothing);
      expect(find.byType(GlassButton), findsNothing);
      expect(toggleHits(), findsOneWidget);

      await tester.tap(toggleHits());
      await settle(tester);
      expect(value, isTrue);
      expect(find.byIcon(CupertinoIcons.checkmark), findsOneWidget);

      await pressEnter(tester, node);
      await settle(tester);
      expect(value, isNull);
      // 部分选中画白色短横，不是对勾。
      expect(find.byIcon(CupertinoIcons.checkmark), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(value, isFalse);
    });
  });

  group('FushiRadio', () {
    testWidgets('MD3 renders Material Radio', (WidgetTester tester) async {
      await pumpHost(
        tester,
        (_) => RadioGroup<int>(
          groupValue: 1,
          onChanged: (_) {},
          child: const Row(
            children: <Widget>[
              FushiRadio<int>(value: 1),
              FushiRadio<int>(value: 2),
            ],
          ),
        ),
        glass: false,
      );
      await tester.pump();
      expect(find.byType(Radio<int>), findsNWidgets(2));
      expect(toggleHits(), findsNothing);
    });

    testWidgets('glass radios select via tap and Enter (RadioGroup API)', (
      WidgetTester tester,
    ) async {
      final FocusNode second = FocusNode();
      final FocusNode third = FocusNode();
      addTearDown(second.dispose);
      addTearDown(third.dispose);
      int? group = 1;
      await pumpHost(
        tester,
        (StateSetter setState) => RadioGroup<int>(
          groupValue: group,
          onChanged: (int? v) => setState(() => group = v),
          child: Row(
            children: <Widget>[
              const FushiRadio<int>(value: 1),
              FushiRadio<int>(value: 2, focusNode: second),
              FushiRadio<int>(value: 3, focusNode: third),
            ],
          ),
        ),
        glass: true,
      );
      await tester.pump();
      expect(find.byType(Radio<int>), findsNothing);
      expect(toggleHits(), findsNWidgets(3));

      await tester.tap(toggleHits().at(1));
      await settle(tester);
      expect(group, 2);

      await pressEnter(tester, third);
      await settle(tester);
      expect(group, 3);
    });

    testWidgets('glass radio supports deprecated groupValue / onChanged', (
      WidgetTester tester,
    ) async {
      int? group = 1;
      await pumpHost(
        tester,
        (StateSetter setState) => Row(
          children: <Widget>[
            for (final int v in <int>[1, 2])
              FushiRadio<int>(
                value: v,
                groupValue: group,
                toggleable: true,
                onChanged: (int? n) => setState(() => group = n),
              ),
          ],
        ),
        glass: true,
      );
      await tester.tap(toggleHits().at(1));
      await settle(tester);
      expect(group, 2);
      // toggleable：点已选项取消选择。
      await tester.tap(toggleHits().at(1));
      await settle(tester);
      expect(group, isNull);
    });
  });

  group('FushiCheckboxListTile', () {
    testWidgets('MD3 renders Material CheckboxListTile', (
      WidgetTester tester,
    ) async {
      await pumpHost(
        tester,
        (_) => FushiCheckboxListTile(
          value: false,
          onChanged: (_) {},
          title: const Text('Row'),
        ),
        glass: false,
      );
      expect(find.byType(CheckboxListTile), findsOneWidget);
      expect(find.byType(GlassListTile), findsNothing);
    });

    testWidgets('glass row toggles on tap and Enter, inner box not focusable', (
      WidgetTester tester,
    ) async {
      final FocusNode node = FocusNode();
      addTearDown(node.dispose);
      bool? value = false;
      await pumpHost(
        tester,
        (StateSetter setState) => FushiCheckboxListTile(
          value: value,
          focusNode: node,
          title: const Text('Row'),
          subtitle: const Text('Sub'),
          onChanged: (bool? v) => setState(() => value = v),
        ),
        glass: true,
      );
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.byType(Checkbox), findsNothing);
      expect(find.byType(ListTile), findsNothing);
      expect(find.byType(GlassListTile), findsOneWidget);
      expect(find.byType(GlassButton), findsNothing);
      expect(toggleHits(), findsNothing);

      await tester.tap(find.text('Row'));
      await settle(tester);
      expect(value, isTrue);

      await pressEnter(tester, node);
      await settle(tester);
      expect(value, isFalse);
    });
  });

  group('FushiRadioListTile', () {
    testWidgets('MD3 renders Material RadioListTile', (
      WidgetTester tester,
    ) async {
      await pumpHost(
        tester,
        (_) => FushiRadioListTile<int>(
          value: 1,
          groupValue: 1,
          onChanged: (_) {},
          title: const Text('One'),
        ),
        glass: false,
      );
      expect(find.byType(RadioListTile<int>), findsOneWidget);
      expect(find.byType(GlassListTile), findsNothing);
    });

    testWidgets('glass rows select on tap and Enter', (
      WidgetTester tester,
    ) async {
      final FocusNode node = FocusNode();
      addTearDown(node.dispose);
      int? group = 1;
      await pumpHost(
        tester,
        (StateSetter setState) => Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiRadioListTile<int>(
              value: 1,
              groupValue: group,
              onChanged: (int? v) => setState(() => group = v),
              title: const Text('One'),
            ),
            FushiRadioListTile<int>(
              value: 2,
              groupValue: group,
              focusNode: node,
              onChanged: (int? v) => setState(() => group = v),
              title: const Text('Two'),
            ),
          ],
        ),
        glass: true,
      );
      expect(find.byType(RadioListTile<int>), findsNothing);
      expect(find.byType(Radio<int>), findsNothing);
      expect(find.byType(GlassListTile), findsNWidgets(2));
      expect(find.byIcon(CupertinoIcons.checkmark), findsOneWidget);
      // 对勾在行尾（标题右侧）。
      expect(
        tester.getCenter(find.byIcon(CupertinoIcons.checkmark)).dx,
        greaterThan(tester.getCenter(find.text('One')).dx),
      );

      await pressEnter(tester, node);
      await settle(tester);
      expect(group, 2);

      await tester.tap(find.text('One'));
      await settle(tester);
      expect(group, 1);
    });

    testWidgets('glass rows work with a RadioGroup ancestor', (
      WidgetTester tester,
    ) async {
      int? group = 1;
      await pumpHost(
        tester,
        (StateSetter setState) => RadioGroup<int>(
          groupValue: group,
          onChanged: (int? v) => setState(() => group = v),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FushiRadioListTile<int>(value: 1, title: Text('One')),
              FushiRadioListTile<int>(value: 2, title: Text('Two')),
            ],
          ),
        ),
        glass: true,
      );
      await tester.pump();
      await tester.tap(find.text('Two'));
      await settle(tester);
      expect(group, 2);
    });
  });

  group('FushiSwitchListTile', () {
    testWidgets('MD3 renders Material SwitchListTile', (
      WidgetTester tester,
    ) async {
      await pumpHost(
        tester,
        (_) => FushiSwitchListTile.adaptive(
          value: true,
          onChanged: (_) {},
          title: const Text('Wifi'),
        ),
        glass: false,
      );
      expect(find.byType(SwitchListTile), findsOneWidget);
      expect(find.byType(FushiAppleSwitch), findsNothing);
    });

    testWidgets('glass row toggles on tap and Enter', (
      WidgetTester tester,
    ) async {
      final FocusNode node = FocusNode();
      addTearDown(node.dispose);
      bool value = false;
      await pumpHost(
        tester,
        (StateSetter setState) => FushiSwitchListTile.adaptive(
          value: value,
          focusNode: node,
          secondary: const Icon(Icons.wifi),
          title: const Text('Wifi'),
          onChanged: (bool v) => setState(() => value = v),
        ),
        glass: true,
      );
      expect(find.byType(SwitchListTile), findsNothing);
      expect(find.byType(Switch), findsNothing);
      expect(find.byType(FushiAppleSwitch), findsOneWidget);
      expect(find.byType(GlassListTile), findsOneWidget);

      await tester.tap(find.text('Wifi'));
      await settle(tester);
      expect(value, isTrue);

      await pressEnter(tester, node);
      await settle(tester);
      expect(value, isFalse);
    });
  });

  group('FushiSegmentedButton', () {
    const List<ButtonSegment<String>> segments = <ButtonSegment<String>>[
      ButtonSegment<String>(value: 'a', label: Text('Alpha')),
      ButtonSegment<String>(value: 'b', label: Text('Beta')),
      ButtonSegment<String>(value: 'c', label: Text('Gamma')),
    ];

    // MD3 = M3 Expressive 连接式按钮组（墨水屏才保留 Material 原件）。
    testWidgets('MD3 renders the M3 Expressive connected button group', (
      WidgetTester tester,
    ) async {
      final List<Set<String>> calls = <Set<String>>[];
      await pumpHost(
        tester,
        (_) => FushiSegmentedButton<String>(
          segments: segments,
          selected: const <String>{'a'},
          onSelectionChanged: calls.add,
        ),
        glass: false,
      );
      expect(find.byType(FushiConnectedButtonGroup<String>), findsOneWidget);
      expect(find.byType(FushiAppleSegmentedControl), findsNothing);
      expect(find.byType(SegmentedButton<String>), findsNothing);
      await tester.tap(find.text('Beta'));
      await tester.pump();
      expect(calls, <Set<String>>[
        <String>{'b'},
      ]);
    });

    testWidgets('glass single select uses FushiAppleSegmentedControl', (
      WidgetTester tester,
    ) async {
      Set<String> selected = <String>{'a'};
      final List<Set<String>> calls = <Set<String>>[];
      await pumpHost(
        tester,
        (StateSetter setState) => FushiSegmentedButton<String>(
          segments: segments,
          selected: selected,
          onSelectionChanged: (Set<String> s) {
            calls.add(s);
            setState(() => selected = s);
          },
        ),
        glass: true,
      );
      expect(find.byType(SegmentedButton<String>), findsNothing);
      expect(find.byType(FushiAppleSegmentedControl), findsOneWidget);

      await tester.tap(find.text('Beta'));
      await settle(tester);
      expect(selected, <String>{'b'});
      expect(calls, hasLength(1));

      // Tab 遍历到第三段，Enter 选中。
      final Finder gamma = find.text('Gamma');
      final FocusNode gammaNode = Focus.of(tester.element(gamma));
      await pressEnter(tester, gammaNode);
      await settle(tester);
      expect(selected, <String>{'c'});
    });

    testWidgets('glass multi select uses an iOS segmented row', (
      WidgetTester tester,
    ) async {
      Set<String> selected = <String>{'a'};
      await pumpHost(
        tester,
        (StateSetter setState) => FushiSegmentedButton<String>(
          segments: segments,
          selected: selected,
          multiSelectionEnabled: true,
          emptySelectionAllowed: true,
          onSelectionChanged: (Set<String> s) => setState(() => selected = s),
        ),
        glass: true,
      );
      expect(find.byType(SegmentedButton<String>), findsNothing);
      expect(find.byType(FushiAppleSegmentedControl), findsNothing);
      expect(find.byType(GlassButton), findsNothing);
      // 选中段显示 SF 对勾。
      expect(find.byIcon(CupertinoIcons.checkmark), findsOneWidget);

      await tester.tap(find.text('Gamma'));
      await settle(tester);
      expect(selected, <String>{'a', 'c'});

      final FocusNode alphaNode = Focus.of(tester.element(find.text('Alpha')));
      await pressEnter(tester, alphaNode);
      await settle(tester);
      expect(selected, <String>{'c'});

      await tester.tap(find.text('Gamma'));
      await settle(tester);
      expect(selected, isEmpty);
    });

    testWidgets('glass disabled segmented button ignores taps', (
      WidgetTester tester,
    ) async {
      await pumpHost(
        tester,
        (_) => const FushiSegmentedButton<String>(
          segments: segments,
          selected: <String>{'a'},
        ),
        glass: true,
      );
      expect(find.byType(FushiAppleSegmentedControl), findsOneWidget);
      await tester.tap(find.text('Beta'), warnIfMissed: false);
      await settle(tester);
    });

    test('styleFrom forwards to SegmentedButton.styleFrom', () {
      final ButtonStyle style = FushiSegmentedButton.styleFrom(
        selectedBackgroundColor: Colors.red,
      );
      expect(
        style.backgroundColor?.resolve(<WidgetState>{WidgetState.selected}),
        Colors.red,
      );
    });
  });
  // 玻璃设计系统与表面材质正交：毛玻璃档与「降低透明度」（材质 off，玻璃变
  // 实心）下组件族不变，仍是玻璃组件。
  for (final FushiGlassMaterial material in <FushiGlassMaterial>[
    FushiGlassMaterial.frosted,
    FushiGlassMaterial.off,
  ]) {
    testWidgets('glass design under ${material.name} surfaces stays glass', (
      WidgetTester tester,
    ) async {
      await pumpHost(
        tester,
        (_) => SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FushiSwitch(value: true, onChanged: (_) {}),
              FushiSlider(value: 0.3, onChanged: (_) {}),
              FushiRangeSlider(
                values: const RangeValues(0.2, 0.6),
                onChanged: (_) {},
              ),
              FushiCheckbox(value: null, tristate: true, onChanged: (_) {}),
              FushiRadio<int>(value: 1, groupValue: 1, onChanged: (_) {}),
              FushiSwitchListTile(
                value: false,
                onChanged: (_) {},
                title: const Text('S'),
              ),
              FushiCheckboxListTile(
                value: true,
                onChanged: (_) {},
                title: const Text('C'),
              ),
              FushiRadioListTile<int>(
                value: 2,
                groupValue: 1,
                onChanged: (_) {},
                title: const Text('R'),
              ),
              FushiSegmentedButton<int>(
                segments: const <ButtonSegment<int>>[
                  ButtonSegment<int>(value: 1, label: Text('One')),
                  ButtonSegment<int>(
                    value: 2,
                    icon: Icon(Icons.star),
                    label: Text('Two'),
                  ),
                ],
                selected: const <int>{1},
                onSelectionChanged: (_) {},
              ),
            ],
          ),
        ),
        glass: true,
        material: material,
      );
      expect(tester.takeException(), isNull);
      for (final Type type in <Type>[
        Switch,
        Slider,
        RangeSlider,
        Checkbox,
        Radio<int>,
        SwitchListTile,
        CheckboxListTile,
        RadioListTile<int>,
        SegmentedButton<int>,
        ListTile,
      ]) {
        expect(find.byType(type), findsNothing, reason: '$type');
      }
      expect(find.byType(FushiAppleSwitch), findsNWidgets(2));
      expect(find.byType(FushiAppleSlider), findsOneWidget);
      expect(find.byType(GlassListTile), findsNWidgets(3));
      expect(find.byType(FushiAppleSegmentedControl), findsOneWidget);
    });
  }
}
