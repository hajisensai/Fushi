import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/advanced_mining/manga_crop_geometry.dart';
import 'package:fushi/src/mining/advanced_mining/manga_crop_selector.dart';
import 'package:material_ui/material_ui.dart';

/// [MangaCropSelector] 的指针 / 键盘交互。页图 400×400、控件 400×400、dpr 1，
/// 所以归一化坐标 = 像素 / 400，断言直接按像素心算。
void main() {
  late List<(Rect, MangaCropEdit)> edits;
  late int submits;
  late FocusNode focusNode;

  setUp(() {
    edits = <(Rect, MangaCropEdit)>[];
    submits = 0;
    focusNode = FocusNode();
  });

  void expectRect(Rect actual, Rect expected) {
    expect(actual.left, closeTo(expected.left, 1e-6), reason: 'left');
    expect(actual.top, closeTo(expected.top, 1e-6), reason: 'top');
    expect(actual.right, closeTo(expected.right, 1e-6), reason: 'right');
    expect(actual.bottom, closeTo(expected.bottom, 1e-6), reason: 'bottom');
  }

  const List<Rect> panels = <Rect>[
    Rect.fromLTRB(0, 0, 1, 0.3),
    Rect.fromLTRB(0, 0.3, 0.5, 0.6),
  ];
  const double s = kMangaCropNudgeStep;

  Future<void> pump(WidgetTester tester, {bool enabled = true}) async {
    tester.view.physicalSize = const Size(400, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // 先卸载控件再释放节点：带着焦点直接 dispose 会去通知已经拆掉的 FocusManager。
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      focusNode.dispose();
    });
    Rect? selection = const Rect.fromLTRB(0.5, 0.5, 0.75, 0.75);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) => Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 400,
                height: 400,
                child: MangaCropSelector(
                  pageBytes: null,
                  pageSize: const Size(400, 400),
                  selection: selection,
                  panels: panels,
                  textRect: const Rect.fromLTRB(0.1, 0.1, 0.2, 0.2),
                  enabled: enabled,
                  focusNode: focusNode,
                  onSubmit: () => submits++,
                  onChanged: (Rect r, MangaCropEdit e) {
                    edits.add((r, e));
                    setState(() => selection = r);
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> focus(WidgetTester tester) async {
    focusNode.requestFocus();
    await tester.pump();
  }

  testWidgets('框外拖动画出新框（draw）', (WidgetTester tester) async {
    await pump(tester);
    await tester.dragFrom(const Offset(20, 20), const Offset(100, 80));
    await tester.pumpAndSettle();
    expect(edits, isNotEmpty);
    expect(
      edits.every(((Rect, MangaCropEdit) e) => e.$2 == MangaCropEdit.draw),
      isTrue,
    );
    expectRect(edits.last.$1, const Rect.fromLTRB(0.05, 0.05, 0.3, 0.25));
  });

  testWidgets('框外单击不冲掉原选择', (WidgetTester tester) async {
    await pump(tester);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(edits, isEmpty);
  });

  testWidgets('框内拖动平移（move）', (WidgetTester tester) async {
    await pump(tester);
    await tester.dragFrom(const Offset(250, 250), const Offset(40, 0));
    await tester.pumpAndSettle();
    expect(edits.last.$2, MangaCropEdit.move);
    expectRect(edits.last.$1, const Rect.fromLTRB(0.6, 0.5, 0.85, 0.75));
  });

  testWidgets('拖右下角手柄缩放（resize）', (WidgetTester tester) async {
    await pump(tester);
    await tester.dragFrom(const Offset(300, 300), const Offset(20, 40));
    await tester.pumpAndSettle();
    expect(edits.last.$2, MangaCropEdit.resize);
    expectRect(edits.last.$1, const Rect.fromLTRB(0.5, 0.5, 0.8, 0.85));
  });

  testWidgets('方向键平移一步（nudge）', (WidgetTester tester) async {
    await pump(tester);
    await focus(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(edits.map(((Rect, MangaCropEdit) e) => e.$2), <MangaCropEdit>[
      MangaCropEdit.nudge,
      MangaCropEdit.nudge,
    ]);
    expectRect(
      edits.last.$1,
      const Rect.fromLTRB(0.5 + s, 0.5 - s, 0.75 + s, 0.75 - s),
    );
  });

  testWidgets('Shift+右 扩右边、Shift+上 收下边', (WidgetTester tester) async {
    await pump(tester);
    await focus(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expectRect(
      edits.last.$1,
      const Rect.fromLTRB(0.5, 0.5, 0.75 + s, 0.75 - s),
    );
  });

  testWidgets('Tab 依次切分镜，末尾放行给焦点遍历', (WidgetTester tester) async {
    await pump(tester);
    await focus(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(edits.map(((Rect, MangaCropEdit) e) => e.$1), panels);
    expect(
      edits.every(((Rect, MangaCropEdit) e) => e.$2 == MangaCropEdit.panel),
      isTrue,
    );
    // 第三下越过末尾：不再切分镜，事件交给外层焦点遍历。
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(edits, hasLength(2));
  });

  testWidgets('Shift+Tab 从最后一个分镜往回切', (WidgetTester tester) async {
    await pump(tester);
    await focus(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(edits.single.$1, panels.last);
  });

  testWidgets('Enter 提交', (WidgetTester tester) async {
    await pump(tester);
    await focus(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(submits, 1);
  });

  testWidgets('按下即拿焦点', (WidgetTester tester) async {
    await pump(tester);
    expect(focusNode.hasFocus, isFalse);
    await tester.dragFrom(const Offset(250, 250), const Offset(10, 0));
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);
  });

  testWidgets('enabled=false 时手势与键盘都不回调', (WidgetTester tester) async {
    await pump(tester, enabled: false);
    await tester.dragFrom(const Offset(20, 20), const Offset(100, 80));
    await tester.dragFrom(const Offset(250, 250), const Offset(40, 0));
    focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(edits, isEmpty);
    expect(submits, 0);
  });
}
