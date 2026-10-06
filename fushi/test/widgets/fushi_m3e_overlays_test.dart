import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// M3E 共享浮层（对话框路由 / 标准模板 / 底部弹层自适应）的行为测试。
void main() {
  Future<BuildContext> pumpHost(
    WidgetTester tester, {
    Size size = const Size(420, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late BuildContext hostContext;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              hostContext = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    return hostContext;
  }

  group('FushiSpringCurve', () {
    test('端点钉死、欠阻尼中途回弹越过 1', () {
      const FushiSpringCurve curve = FushiSpringCurve(
        stiffness: 380,
        dampingRatio: 0.72,
        duration: Duration(milliseconds: 450),
      );
      expect(curve.transform(0), 0);
      expect(curve.transform(1), 1);
      double peak = 0;
      for (int i = 1; i < 100; i++) {
        peak = peak < curve.transform(i / 100)
            ? curve.transform(i / 100)
            : peak;
      }
      expect(peak, greaterThan(1.0));
      expect(peak, lessThan(1.1));
    });

    test('临界阻尼单调不过冲', () {
      const FushiSpringCurve curve = FushiSpringCurve(
        stiffness: 380,
        dampingRatio: 1,
        duration: Duration(milliseconds: 420),
      );
      double last = 0;
      for (int i = 1; i < 100; i++) {
        final double v = curve.transform(i / 100);
        expect(v, greaterThanOrEqualTo(last));
        expect(v, lessThanOrEqualTo(1.0));
        last = v;
      }
    });
  });

  testWidgets('showAppDialog 推 FushiDialogRoute，遮罩为 scrim@32%', (
    WidgetTester tester,
  ) async {
    final BuildContext context = await pumpHost(tester);
    showAppDialog<void>(
      context: context,
      builder: (_) => const AlertDialog(title: Text('hello')),
    );
    await tester.pumpAndSettle();
    expect(find.text('hello'), findsOneWidget);
    final ModalRoute<Object?> route = ModalRoute.of(
      tester.element(find.text('hello')),
    )!;
    expect(route, isA<FushiDialogRoute<void>>());
    final ColorScheme cs = Theme.of(context).colorScheme;
    expect(
      (route as FushiDialogRoute<void>).barrierColor,
      cs.scrim.withValues(alpha: 0.32),
    );
  });

  testWidgets('确认模板：取消 → false，确认 → true，Enter 直接确认', (
    WidgetTester tester,
  ) async {
    final BuildContext context = await pumpHost(tester);
    Future<bool> result = showFushiConfirmDialog(
      context: context,
      title: '删除？',
      message: '不可撤销',
      confirmLabel: 'DEL',
      cancelLabel: 'NO',
      icon: Icons.delete_outline,
      destructive: true,
    );
    await tester.pumpAndSettle();
    expect(find.byType(FushiDialogHeroIcon), findsOneWidget);
    await tester.tap(find.text('NO'));
    await tester.pumpAndSettle();
    expect(await result, isFalse);

    result = showFushiConfirmDialog(
      context: context,
      title: '删除？',
      confirmLabel: 'DEL',
      cancelLabel: 'NO',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('DEL'));
    await tester.pumpAndSettle();
    expect(await result, isTrue);

    result = showFushiConfirmDialog(
      context: context,
      title: '删除？',
      confirmLabel: 'DEL',
      cancelLabel: 'NO',
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(await result, isTrue);
  });

  testWidgets('确认模板：Esc 关闭返回 false', (WidgetTester tester) async {
    final BuildContext context = await pumpHost(tester);
    final Future<bool> result = showFushiConfirmDialog(
      context: context,
      title: 'Esc',
      confirmLabel: 'OK',
      cancelLabel: 'NO',
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(await result, isFalse);
  });

  testWidgets('文本输入模板：空值禁止提交、Enter 提交 trim 后文本', (WidgetTester tester) async {
    final BuildContext context = await pumpHost(tester);
    final Future<String?> result = showFushiTextInputDialog(
      context: context,
      title: '命名',
      confirmLabel: 'OK',
      cancelLabel: 'NO',
    );
    await tester.pumpAndSettle();
    final Finder ok = find.widgetWithText(FilledButton, 'OK');
    expect(tester.widget<FilledButton>(ok).onPressed, isNull);
    await tester.enterText(find.byType(TextField), '  abc  ');
    await tester.pump();
    expect(tester.widget<FilledButton>(ok).onPressed, isNotNull);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(await result, 'abc');
  });

  testWidgets('单选模板：点一项返回其值；当前项带对勾', (WidgetTester tester) async {
    final BuildContext context = await pumpHost(tester);
    final Future<int?> result = showFushiChoiceDialog<int>(
      context: context,
      title: '选择',
      selected: 2,
      options: const <FushiChoiceOption<int>>[
        FushiChoiceOption<int>(value: 1, label: 'one'),
        FushiChoiceOption<int>(value: 2, label: 'two'),
      ],
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(FushiIcons.check), findsOneWidget);
    await tester.tap(find.text('one'));
    await tester.pumpAndSettle();
    expect(await result, 1);
  });

  testWidgets('多选模板：切换后确认返回集合', (WidgetTester tester) async {
    final BuildContext context = await pumpHost(tester);
    final Future<Set<String>?> result = showFushiMultiChoiceDialog<String>(
      context: context,
      title: '多选',
      initial: const <String>{'a'},
      confirmLabel: 'OK',
      cancelLabel: 'NO',
      options: const <FushiChoiceOption<String>>[
        FushiChoiceOption<String>(value: 'a', label: 'A'),
        FushiChoiceOption<String>(value: 'b', label: 'B'),
      ],
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('A'));
    await tester.tap(find.text('B'));
    await tester.pump();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(await result, <String>{'b'});
  });

  testWidgets('进度模板：handle.close 关闭对话框并完成 done', (WidgetTester tester) async {
    final BuildContext context = await pumpHost(tester);
    final FushiProgressDialogHandle handle = showFushiProgressDialog(
      context: context,
      title: '导入中',
      initialProgress: 0.25,
    );
    await tester.pumpAndSettle();
    expect(find.text('导入中'), findsOneWidget);
    expect(find.text('25%'), findsOneWidget);
    handle.progress.value = 0.5;
    await tester.pump();
    expect(find.text('50%'), findsOneWidget);
    handle.close();
    await tester.pumpAndSettle();
    expect(find.text('导入中'), findsNothing);
    await handle.done;
  });

  testWidgets('底部弹层：窄屏是带拖动条的 BottomSheet，宽屏是居中浮动面板', (
    WidgetTester tester,
  ) async {
    BuildContext context = await pumpHost(tester);
    adaptiveModalSheet<void>(
      context: context,
      builder: (_) => const Text('sheet body'),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(FushiM3eSheetBody), findsOneWidget);
    Navigator.of(tester.element(find.text('sheet body'))).pop();
    await tester.pumpAndSettle();

    context = await pumpHost(tester, size: const Size(1600, 900));
    adaptiveModalSheet<void>(
      context: context,
      builder: (_) => const Text('sheet body'),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(FushiM3eFloatingSheet), findsOneWidget);
  });

  testWidgets('底部弹层两档：点拖动条在半屏与 92% 之间切换', (WidgetTester tester) async {
    final BuildContext context = await pumpHost(tester);
    adaptiveModalSheet<void>(
      context: context,
      expandable: true,
      builder: (_) => ListView(
        children: <Widget>[
          for (int i = 0; i < 80; i++) SizedBox(height: 40, child: Text('$i')),
        ],
      ),
    );
    await tester.pumpAndSettle();
    final double collapsed = tester.getSize(find.byType(BottomSheet)).height;
    expect(collapsed, closeTo(900 * kFushiSheetHalfFraction, 1));
    await tester.tapAt(
      tester.getTopLeft(find.byType(BottomSheet)) + const Offset(210, 24),
    );
    await tester.pumpAndSettle();
    final double expanded = tester.getSize(find.byType(BottomSheet)).height;
    expect(expanded, closeTo(900 * kFushiSheetFullFraction, 1));
  });
}
