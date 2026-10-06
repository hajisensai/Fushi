import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// 输入框包装契约：MD3 下就是原 TextField / TextFormField；玻璃设计系统下是 iOS
// 26 实色输入框（tertiarySystemFill 底、圆角 10；搜索框全胶囊高 36，**不是
// 玻璃**）+ 无边框 CupertinoTextField，界面里没有 Material TextField，且输入、
// controller、onChanged / onSubmitted、inputFormatters、FocusNode、Form 校验与
// 原控件一致。

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
        child: Scaffold(
          body: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('FushiTextFieldControl', () {
    testWidgets('MD3 builds the original TextField', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const FushiTextFieldControl(
          decoration: InputDecoration(labelText: 'Name'),
        ),
        glass: false,
      );
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byType(GlassContainer), findsNothing);
      expect(find.byType(CupertinoTextField), findsNothing);
    });

    // BUG-2958：设置页 MD3 胶囊搜索栏给放大镜包了一层 Padding（自配留白），
    // 搜索判据只认裸 Icon，把调用方写好的胶囊边框压成 12 圆角方框。
    for (final bool wrapped in <bool>[false, true]) {
      testWidgets(
        'MD3 search field stays a capsule (prefix wrapped in Padding: $wrapped)',
        (WidgetTester tester) async {
          const Widget icon = Icon(Icons.search);
          await _pump(
            tester,
            FushiTextFieldControl(
              decoration: InputDecoration(
                hintText: 'Search',
                prefixIcon: wrapped
                    ? const Padding(
                        padding: EdgeInsetsDirectional.only(start: 16, end: 8),
                        child: icon,
                      )
                    : icon,
                border: const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(28)),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            glass: false,
          );
          final TextField field = tester.widget<TextField>(
            find.byType(TextField),
          );
          for (final InputBorder? border in <InputBorder?>[
            field.decoration!.border,
            field.decoration!.enabledBorder,
            field.decoration!.focusedBorder,
          ]) {
            expect(border, isA<OutlineInputBorder>());
            expect(
              (border! as OutlineInputBorder).borderRadius,
              BorderRadius.circular(999),
            );
          }
        },
      );
    }

    testWidgets('glass builds an iOS search capsule in one clear-glass bezel', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const FushiTextFieldControl(
          decoration: InputDecoration(
            labelText: 'Name',
            hintText: 'Type here',
            helperText: 'Helper line',
            prefixIcon: Icon(Icons.search),
            suffixIcon: Icon(Icons.clear),
          ),
        ),
        glass: true,
      );
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(InputDecorator), findsNothing);
      // 搜索胶囊是控件层（用户 2026-10-04「往液态玻璃靠」）：恰好一枚无色透明
      // 玻璃 bezel，不再在里面另套玻璃。
      expect(find.byType(GlassContainer), findsOneWidget);
      expect(find.byType(CupertinoTextField), findsOneWidget);
      expect(find.text('Name'), findsOneWidget);
      expect(find.text('Type here'), findsOneWidget);
      expect(find.text('Helper line'), findsOneWidget);
      // 放大镜前缀 = 搜索框：SF 放大镜、全胶囊（圆角 18）、高 36。浅色下胶囊
      // 底交给玻璃（不叠灰），深色才在玻璃里自绘 tertiarySystemFill。
      expect(find.byIcon(Icons.search), findsNothing);
      expect(find.byIcon(CupertinoIcons.search), findsOneWidget);
      expect(find.byIcon(Icons.clear), findsOneWidget);
      final Finder shell = find.ancestor(
        of: find.byType(CupertinoTextField),
        matching: find.byWidgetPredicate(
          (Widget w) =>
              w is AnimatedContainer &&
              w.decoration is BoxDecoration &&
              (w.decoration! as BoxDecoration).borderRadius ==
                  BorderRadius.circular(18),
        ),
      );
      expect(shell, findsOneWidget);
      expect(tester.getSize(shell).height, 36);
      expect(
        (tester.widget<AnimatedContainer>(shell).decoration! as BoxDecoration)
            .color,
        Colors.transparent,
      );
    });

    testWidgets('glass plain field is a rounded-10 tertiaryFill box', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const FushiTextFieldControl(
          decoration: InputDecoration(hintText: 'Plain'),
        ),
        glass: true,
      );
      final BuildContext ctx = tester.element(find.byType(CupertinoTextField));
      final AnimatedContainer shell = tester.widget<AnimatedContainer>(
        find
            .ancestor(
              of: find.byType(CupertinoTextField),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      final BoxDecoration deco = shell.decoration! as BoxDecoration;
      expect(deco.color, appleColorsOf(ctx).tertiaryFill);
      expect(deco.borderRadius, BorderRadius.circular(10));
      expect(deco.border, isNull);
    });

    testWidgets(
      'glass forwards controller, onChanged, onSubmitted, formatters',
      (WidgetTester tester) async {
        final TextEditingController controller = TextEditingController();
        addTearDown(controller.dispose);
        final List<String> changed = <String>[];
        String? submitted;
        bool editingComplete = false;
        await _pump(
          tester,
          FushiTextFieldControl(
            controller: controller,
            textInputAction: TextInputAction.search,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
            ],
            onChanged: changed.add,
            onSubmitted: (String v) => submitted = v,
            onEditingComplete: () => editingComplete = true,
            decoration: const InputDecoration(hintText: 'digits'),
          ),
          glass: true,
        );
        await tester.enterText(find.byType(EditableText), 'a1b2');
        await tester.pump();
        expect(controller.text, '12');
        expect(changed.last, '12');

        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pump();
        expect(submitted, '12');
        expect(editingComplete, isTrue);
      },
    );

    testWidgets('glass field is keyboard-focusable and accepts typing', (
      WidgetTester tester,
    ) async {
      final FocusNode node = FocusNode();
      addTearDown(node.dispose);
      await _pump(
        tester,
        Column(
          children: <Widget>[
            FushiTextFieldControl(
              focusNode: node,
              decoration: const InputDecoration(labelText: 'Field'),
            ),
          ],
        ),
        glass: true,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(node.hasFocus, isTrue);
      tester.testTextInput.enterText('hello');
      await tester.pump();
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        'hello',
      );
    });

    testWidgets('glass maps errorText and maxLength counter', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const FushiTextFieldControl(
          maxLength: 10,
          decoration: InputDecoration(errorText: 'Bad value'),
        ),
        glass: true,
      );
      expect(find.text('Bad value'), findsOneWidget);
      expect(find.text('0/10'), findsOneWidget);
      await tester.enterText(find.byType(EditableText), 'abc');
      await tester.pump();
      expect(find.text('3/10'), findsOneWidget);
    });

    testWidgets('glass keeps hintLocales via a decoration-free inner field', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const FushiTextFieldControl(
          hintLocales: <Locale>[Locale('ja')],
          decoration: InputDecoration(hintText: 'lookup'),
        ),
        glass: true,
      );
      expect(find.byType(GlassContainer), findsNothing);
      expect(find.byType(InputDecorator), findsNothing);
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).hintLocales,
        const <Locale>[Locale('ja')],
      );
    });

    testWidgets('disabled glass field does not take focus', (
      WidgetTester tester,
    ) async {
      final FocusNode node = FocusNode();
      addTearDown(node.dispose);
      await _pump(
        tester,
        FushiTextFieldControl(focusNode: node, enabled: false),
        glass: true,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(node.hasFocus, isFalse);
    });
  });

  group('FushiTextFormFieldControl', () {
    testWidgets('MD3 builds the original TextFormField', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        FushiTextFormFieldControl(initialValue: 'x'),
        glass: false,
      );
      expect(find.byType(TextFormField), findsOneWidget);
      expect(find.byType(GlassContainer), findsNothing);
    });

    testWidgets('glass validates, saves and resets through the Form', (
      WidgetTester tester,
    ) async {
      final GlobalKey<FormState> formKey = GlobalKey<FormState>();
      String? saved;
      final List<String> changed = <String>[];
      String? submitted;
      await _pump(
        tester,
        Form(
          key: formKey,
          child: FushiTextFormFieldControl(
            initialValue: 'start',
            decoration: const InputDecoration(labelText: 'Port'),
            validator: (String? v) => (v ?? '').isEmpty ? 'Required' : null,
            onSaved: (String? v) => saved = v,
            onChanged: changed.add,
            onFieldSubmitted: (String v) => submitted = v,
          ),
        ),
        glass: true,
      );
      expect(find.byType(TextFormField), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(GlassContainer), findsNothing);
      expect(find.text('start'), findsOneWidget);

      await tester.enterText(find.byType(EditableText), '');
      await tester.pump();
      expect(formKey.currentState!.validate(), isFalse);
      await tester.pump();
      expect(find.text('Required'), findsOneWidget);

      await tester.enterText(find.byType(EditableText), '8080');
      await tester.pump();
      expect(changed.last, '8080');
      expect(formKey.currentState!.validate(), isTrue);
      formKey.currentState!.save();
      expect(saved, '8080');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(submitted, '8080');

      formKey.currentState!.reset();
      await tester.pump();
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        'start',
      );
    });

    testWidgets('glass syncs an external controller with the form value', (
      WidgetTester tester,
    ) async {
      final TextEditingController controller = TextEditingController(
        text: 'abc',
      );
      addTearDown(controller.dispose);
      final GlobalKey<FormState> formKey = GlobalKey<FormState>();
      String? saved;
      await _pump(
        tester,
        Form(
          key: formKey,
          child: FushiTextFormFieldControl(
            controller: controller,
            onSaved: (String? v) => saved = v,
          ),
        ),
        glass: true,
      );
      controller.text = 'changed';
      await tester.pump();
      formKey.currentState!.save();
      expect(saved, 'changed');
    });
  });

  testWidgets('isGlassDesign is true under the glass test theme', (
    WidgetTester tester,
  ) async {
    late bool glass;
    await _pump(
      tester,
      Builder(
        builder: (BuildContext context) {
          glass = isGlassDesign(context);
          return const SizedBox.shrink();
        },
      ),
      glass: true,
    );
    expect(glass, isTrue);
  });
}
