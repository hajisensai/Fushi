// 墨水屏「选中态可见性」守卫。
//
// eink ColorScheme 是纯黑白：每个容器角色都塌缩成页面底色。凡是**只靠容器填充
// 色**表达选中的控件，墨水屏下选中与未选中就是逐像素相同——分段选择器（M3 只
// 用 secondaryContainer 填充选中段，而全仓调用点一律 showSelectedIcon: false，
// 连勾选形状这条兜底都没有）和字体库那排「用途」FilterChip 都栽在这。
//
// 这里钉三件事：
//   1. eink 下选中态与未选中态的填充/前景**必须不同**（可见性本身）；
//   2. 反色方向正确（选中 = 前景色填充 + 底色文字），对齐上游 Hoshi-Reader-Android
//      ——它的 eink scheme 直接把 secondaryContainer 定义成前景色；
//   3. 非 eink 下零行为变化。
//
// 刻意不走边框/字重：分段条的宽度估算（settings_shared.estimateSegmentedStripWidth）
// 与 overflow 守卫吃固有宽度，改几何会把它们一起带红。填充与前景不改几何。
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

Color? _resolve(
  WidgetStateProperty<Color?>? property,
  Set<WidgetState> states,
) {
  return property?.resolve(states);
}

void main() {
  late FushiDatabase db;
  late ThemeNotifier notifier;

  TextTheme textThemeBuilder() => const TextTheme();

  setUp(() async {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    notifier = ThemeNotifier(db, textThemeBuilder);
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() async {
    notifier.dispose();
    await db.close();
  });

  group('segmentedButtonTheme', () {
    test('eink：选中段反色填充，与未选中段不同色', () async {
      await notifier.setEinkMode(true);
      final ThemeData theme = notifier.theme;
      final ColorScheme cs = theme.colorScheme;
      final ButtonStyle? style = theme.segmentedButtonTheme.style;
      expect(style, isNotNull, reason: 'eink 必须提供分段按钮主题，否则选中不可见');

      final Color? selectedBg = _resolve(style!.backgroundColor, <WidgetState>{
        WidgetState.selected,
      });
      final Color? plainBg = _resolve(style.backgroundColor, <WidgetState>{});
      final Color? selectedFg = _resolve(style.foregroundColor, <WidgetState>{
        WidgetState.selected,
      });
      final Color? plainFg = _resolve(style.foregroundColor, <WidgetState>{});

      // 这条才是 bug 本身：塌缩前两者都是 cs.surface。
      expect(selectedBg, isNot(plainBg));
      expect(selectedFg, isNot(plainFg));
      expect(selectedBg, cs.onSurface);
      expect(plainBg, cs.surface);
      expect(selectedFg, cs.surface);
      expect(plainFg, cs.onSurface);
      // 图标跟着文字翻，否则黑底上的黑图标照样消失。
      expect(
        _resolve(style.iconColor, <WidgetState>{WidgetState.selected}),
        cs.surface,
      );
    });

    test('eink：失效态回落 M3 默认（不接管失效观感）', () async {
      await notifier.setEinkMode(true);
      final ButtonStyle style = notifier.theme.segmentedButtonTheme.style!;
      expect(
        _resolve(style.backgroundColor, <WidgetState>{WidgetState.disabled}),
        isNull,
      );
      expect(
        _resolve(style.foregroundColor, <WidgetState>{WidgetState.disabled}),
        isNull,
      );
    });

    test('非 eink：零行为变化（不挂任何分段按钮主题）', () async {
      expect(notifier.einkMode, isFalse);
      expect(notifier.theme.segmentedButtonTheme.style, isNull);
    });
  });

  group('chipTheme', () {
    test('eink：选中 chip 反色填充 + 配对 label 色', () async {
      await notifier.setEinkMode(true);
      final ThemeData theme = notifier.theme;
      final ColorScheme cs = theme.colorScheme;

      expect(theme.chipTheme.selectedColor, cs.onSurface);
      expect(
        theme.chipTheme.selectedColor,
        isNot(cs.surface),
        reason: '塌缩前 selectedColor == secondaryContainer == 页面底色',
      );

      // label 色必须按 selected 分流，否则黑底黑字。
      final Color? labelColor = theme.chipTheme.labelStyle?.color;
      expect(labelColor, isA<WidgetStateColor>());
      final WidgetStateColor stateColor = labelColor! as WidgetStateColor;
      expect(
        stateColor.resolve(<WidgetState>{WidgetState.selected}),
        cs.surface,
      );
      expect(stateColor.resolve(<WidgetState>{}), cs.onSurface);
    });

    test('eink：label 样式仍从 labelLarge 派生（不吞字号字族）', () async {
      await notifier.setEinkMode(true);
      final ThemeNotifier typed = ThemeNotifier(
        db,
        () => const TextTheme(
          labelLarge: TextStyle(fontSize: 17, fontFamily: 'Sentinel'),
        ),
      );
      addTearDown(typed.dispose);
      // 新 notifier 必须真的把 eink 偏好读进来，否则 labelStyle 恒为 null，
      // 这条断言会变成永远绿的空壳。
      await typed.refreshFromDb();
      expect(typed.einkMode, isTrue);
      final TextStyle? label = typed.theme.chipTheme.labelStyle;
      expect(label?.fontSize, 17);
      expect(label?.fontFamily, 'Sentinel');
    });

    test('非 eink：零行为变化', () async {
      final ThemeData theme = notifier.theme;
      expect(
        theme.chipTheme.selectedColor,
        theme.colorScheme.secondaryContainer,
      );
      expect(theme.chipTheme.labelStyle, isNull);
    });
  });

  group('FushiSelectableChip', () {
    Widget app({required bool eink, required bool selected}) {
      return MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: eink
              ? buildEinkColorScheme(Brightness.light)
              : ColorScheme.fromSeed(seedColor: Colors.indigo),
          extensions: <ThemeExtension<dynamic>>[FushiEinkTheme(eink)],
        ),
        home: Scaffold(
          body: Center(
            child: FushiSelectableChip(
              label: 'Theme',
              leadingIcon: Icons.star,
              selected: selected,
              onSelected: (_) {},
            ),
          ),
        ),
      );
    }

    testWidgets('eink：选中 chip 反色填充，边框不再消失', (WidgetTester tester) async {
      await tester.pumpWidget(app(eink: true, selected: true));
      final ChoiceChip chip = tester.widget<ChoiceChip>(
        find.byType(ChoiceChip),
      );

      // 塌缩前：填充 = primaryContainer = 白 = 页面底色，且边框也是白——选中的
      // chip 比未选中的更没有边，是个负信号。
      expect(chip.selectedColor, Colors.black);
      expect(chip.labelStyle?.color, Colors.white);
      expect(chip.side!.color, Colors.black);
    });

    testWidgets('eink：leading 图标跟着前景翻色', (WidgetTester tester) async {
      await tester.pumpWidget(app(eink: true, selected: true));
      final ChoiceChip chip = tester.widget<ChoiceChip>(
        find.byType(ChoiceChip),
      );
      final Icon avatar = chip.avatar! as Icon;
      expect(
        avatar.color,
        Colors.white,
        reason: 'avatar 不着色就会取 chip 默认 onSurfaceVariant（黑），黑底黑图标',
      );
    });

    testWidgets('非 eink：仍用 primaryContainer（零行为变化）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(app(eink: false, selected: true));
      final Element context = tester.element(find.byType(ChoiceChip));
      final ChoiceChip chip = tester.widget<ChoiceChip>(
        find.byType(ChoiceChip),
      );
      final ColorScheme cs = Theme.of(context).colorScheme;
      expect(chip.selectedColor, cs.primaryContainer);
      expect(chip.side!.color, cs.primaryContainer);
    });
  });
}
