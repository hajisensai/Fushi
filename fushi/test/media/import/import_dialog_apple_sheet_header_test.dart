// 导入对话框 Apple iOS 档的 sheet 导航栏（用户 2026-11-24）：窄屏（iOS 档，
// `!fushiAppleUsesMacMetrics`）顶部是 iOS 27 sheet 导航栏——左取消、中标题、
// 右主操作，没有底部按钮区；宽屏（macOS 档）仍是标题在上、按钮右下；M3E 不变。
// 动作按 [FushiSheetAction] 标的角色分位，多出来的排进内容区；分组标题只在
// Apple 下出现；ImportPickTile 的 focusId 在 Apple 分支照常注册。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/media/import/import_dialog_blocks.dart';
import 'package:fushi/src/media/import/import_dialog_frame.dart';
import 'package:fushi/src/media/import/import_surface_spec.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_sheet_header.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassButton;

ThemeData _theme({required bool glass, TargetPlatform? platform}) {
  final ThemeData theme = buildFushiThemeData(
    scheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF6750A4),
      brightness: Brightness.dark,
    ),
    textTheme: const TextTheme(),
    glassDesign: glass,
  );
  return platform == null ? theme : theme.copyWith(platform: platform);
}

const FushiFocusId _tileFocus = FushiFocusId('import-test-tile');

Widget _frame({
  VoidCallback? onCancel,
  VoidCallback? onImport,
  List<Widget> extra = const <Widget>[],
}) => ImportDialogFrame(
  tone: ImportTone.coral,
  title: 'Import book',
  subtitle: 'Pick a book',
  body: ImportPickTileGrid(
    groupTitle: 'Files',
    children: <Widget>[
      ImportPickTile(
        tone: ImportTone.coral,
        icon: FushiIcons.audio,
        title: 'Pick audio',
        focusId: _tileFocus,
        onTap: () {},
      ),
    ],
  ),
  actions: <Widget>[
    FushiSheetAction.cancel(
      child: FushiTextButton(onPressed: onCancel, child: const Text('Cancel')),
    ),
    ...extra,
    FushiSheetAction.confirm(
      child: FushiFilledButton(
        onPressed: onImport,
        child: const Text('Import'),
      ),
    ),
  ],
);

Future<void> _pump(
  WidgetTester tester, {
  required bool glass,
  required Widget child,
  TargetPlatform? platform,
  Size size = const Size(420, 900),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: _theme(glass: glass, platform: platform),
      home: Scaffold(body: child),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _inHeader(String text) => find.descendant(
  of: find.byType(FushiAppleSheetHeader),
  matching: find.text(text),
);

void main() {
  testWidgets('iOS 档：导航栏左取消、中标题、右主操作，没有底部按钮区', (WidgetTester tester) async {
    await _pump(
      tester,
      glass: true,
      child: _frame(onCancel: () {}, onImport: () {}),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(FushiAppleSheetHeader), findsOneWidget);
    expect(_inHeader('Import book'), findsOneWidget);
    expect(_inHeader('Cancel'), findsOneWidget);
    expect(_inHeader('Import'), findsOneWidget);
    // 说明在导航栏下方居中一行。
    expect(_inHeader('Pick a book'), findsOneWidget);
    // 没有 sheet 底部动作区。
    expect(find.byType(FushiDialogActionScope), findsNothing);
    // 左右按钮几何：取消在标题左、主操作在标题右。
    final double titleX = tester.getCenter(find.text('Import book')).dx;
    expect(tester.getCenter(find.text('Cancel')).dx, lessThan(titleX));
    expect(tester.getCenter(find.text('Import')).dx, greaterThan(titleX));
    // 分组标题（Apple 才有）。
    expect(find.text('Files'), findsOneWidget);
  });

  testWidgets('iOS 档：主操作不可用时导航栏按钮禁用并褪灰', (WidgetTester tester) async {
    await _pump(tester, glass: true, child: _frame(onCancel: () {}));
    final Finder importButton = find.ancestor(
      of: _inHeader('Import'),
      matching: find.byType(GlassButton),
    );
    expect(importButton, findsOneWidget);
    expect(tester.widget<GlassButton>(importButton).enabled, isFalse);
    final FushiAppleColors apple = appleColorsOf(
      tester.element(find.text('Import')),
    );
    expect(
      DefaultTextStyle.of(tester.element(find.text('Import'))).style.color,
      apple.tertiaryLabel,
    );
  });

  testWidgets('iOS 档：第三个及以后的动作排进内容区', (WidgetTester tester) async {
    await _pump(
      tester,
      glass: true,
      child: _frame(
        onCancel: () {},
        onImport: () {},
        extra: <Widget>[
          FushiSheetAction.other(
            child: FushiTextButton(
              onPressed: () {},
              child: const Text('Delete'),
            ),
          ),
        ],
      ),
    );
    expect(find.text('Delete'), findsOneWidget);
    expect(_inHeader('Delete'), findsNothing);
  });

  testWidgets('macOS 档：标题在上、按钮右下，不用导航栏头部', (WidgetTester tester) async {
    await _pump(
      tester,
      glass: true,
      platform: TargetPlatform.macOS,
      size: const Size(1280, 900),
      child: _frame(onCancel: () {}, onImport: () {}),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(FushiAppleSheetHeader), findsNothing);
    expect(find.byType(FushiDialogActionScope), findsOneWidget);
    final double cancelX = tester.getCenter(find.text('Cancel')).dx;
    expect(tester.getCenter(find.text('Import')).dx, greaterThan(cancelX));
    expect(
      tester.getCenter(find.text('Import')).dy,
      greaterThan(tester.getCenter(find.text('Import book')).dy),
    );
  });

  testWidgets('M3E：不用导航栏头部，也不画分组标题', (WidgetTester tester) async {
    await _pump(
      tester,
      glass: false,
      child: _frame(onCancel: () {}, onImport: () {}),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(FushiAppleSheetHeader), findsNothing);
    expect(find.text('Files'), findsNothing);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Import'), findsOneWidget);
  });

  testWidgets('iOS 档：Esc 关闭对话框；Tab 先到导航栏取消，Enter 激活', (
    WidgetTester tester,
  ) async {
    int cancels = 0;
    await _pump(
      tester,
      glass: true,
      child: Builder(
        builder: (BuildContext context) => Center(
          child: FushiTextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (BuildContext ctx) => _frame(
                onCancel: () {
                  cancels++;
                  Navigator.of(ctx).pop();
                },
                onImport: () {},
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(FushiAppleSheetHeader), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(FushiAppleSheetHeader), findsNothing);

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
    expect(focused, isNotNull);
    expect(
      focused!.findAncestorWidgetOfExactType<FushiAppleSheetHeader>(),
      isNotNull,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(cancels, 1);
    expect(find.byType(FushiAppleSheetHeader), findsNothing);
  });

  testWidgets('Apple：ImportPickTile 的 focusId 照常注册成焦点目标', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      glass: true,
      child: _frame(onCancel: () {}, onImport: () {}),
    );
    expect(
      find.byWidgetPredicate(
        (Widget w) => w is FushiFocusTarget && w.id == _tileFocus,
      ),
      findsOneWidget,
    );
  });

  test('FushiSheetActionLayout.split：按角色分位，未标角色按位置', () {
    const Widget a = Text('a');
    const Widget b = Text('b');
    const Widget c = Text('c');
    final FushiSheetActionLayout unmarked = FushiSheetActionLayout.split(
      const <Widget>[a, b, c],
    );
    expect(unmarked.cancel, a);
    expect(unmarked.confirm, c);
    expect(unmarked.others, <Widget>[b]);
    expect(FushiSheetActionLayout.split(const <Widget>[a]).confirm, isNull);
    const Widget close = FushiSheetAction.cancel(child: Text('close'));
    const Widget all = FushiSheetAction.other(child: Text('all'));
    const Widget sel = FushiSheetAction.confirm(child: Text('sel'));
    // mokuro 选卷阶段：「关闭」在最右也仍是取消。
    final FushiSheetActionLayout marked = FushiSheetActionLayout.split(
      const <Widget>[all, sel, close],
    );
    expect(marked.cancel, close);
    expect(marked.confirm, sel);
    expect(marked.others, <Widget>[all]);
  });
}
