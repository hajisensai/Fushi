import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';
import 'package:hibiki/src/utils/components/hibiki_text_selection_controls.dart';

// BUG-119 守卫：日志页（错误日志 / 调试日志）按住鼠标拖拽选区想往上滑复制时，
// 视口会被「拽回」。根因是旧实现把整段 log 渲染成非滚动 SelectableText（全高），
// 外层套 SingleChildScrollView；拖拽选区时内层 EditableText 对祖先 Scrollable
// 调 bringIntoView 把视口拉回选区光标 → 与手动滚动打架。修复改用只读 TextField，
// 让 EditableText 自己当唯一滚动器，消除嵌套滚动冲突。
//
// 真实的选区+滚动几何需要设备/真 EditableText 拖拽，headless 难以稳定复现，
// 故这里在「最强可落地层」守住两条结构不变式：① widget 行为——面板渲染一个只读
// TextField 且不再有 SelectableText / 包内容的 SingleChildScrollView；② 源码守卫
// 防止有人改回 SingleChildScrollView+SelectableText 的旧结构。
void main() {
  Widget buildSubject(Widget child) {
    return MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 400,
          child: child,
        ),
      ),
    );
  }

  testWidgets(
      'HibikiLogPanel renders a read-only TextField (single scroller, no '
      'SelectableText/SingleChildScrollView pull-back)',
      (WidgetTester tester) async {
    const String log = 'line-1\nline-2\nline-3';
    await tester.pumpWidget(
      buildSubject(
        HibikiLogPanel(log: log, shareAction: (_) {}),
      ),
    );
    await tester.pump();

    final Finder fieldFinder = find.descendant(
      of: find.byType(HibikiLogPanel),
      matching: find.byType(TextField),
    );
    expect(fieldFinder, findsOneWidget);

    final TextField field = tester.widget<TextField>(fieldFinder);
    expect(field.readOnly, isTrue);
    expect(field.controller?.text, log);
    expect(field.selectionControls, isA<HibikiTextSelectionControls>());

    // 旧的会被「拽回」的结构必须消失。
    expect(
      find.descendant(
        of: find.byType(HibikiLogPanel),
        matching: find.byType(SelectableText),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(HibikiLogPanel),
        matching: find.byType(SingleChildScrollView),
      ),
      findsNothing,
    );
  });

  test('HibikiLogPanel source no longer nests SelectableText in a scroll view',
      () {
    final String source = File(
      'lib/src/utils/components/hibiki_material_components.dart',
    ).readAsStringSync();
    final String panel = source.substring(
      source.indexOf('class HibikiLogPanel'),
      source.indexOf('class HibikiEditorPanel'),
    );

    expect(panel, contains('readOnly: true'));
    // 断言旧的「会被拽回」结构的构造调用消失（用 ASCII 括号形避免误伤说明注释里
    // 提及这两个类名的文字）。
    expect(panel, isNot(contains('SelectableText(')));
    expect(panel, isNot(contains('SingleChildScrollView(')));
  });
}
