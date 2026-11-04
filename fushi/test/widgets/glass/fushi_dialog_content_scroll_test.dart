// FushiAlertDialog 的内容区默认「装得下原样、装不下就滚」（FushiDialogContentScroll）：
// 含输入框的对话框在键盘弹出 / 小窗口里不再 RenderFlex 溢出，调用点不必手包
// SingleChildScrollView；吃满剩余高度的列表内容布局不变（不能直接用
// AlertDialog.scrollable，那会给列表无界高度而断言）。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_dialog_content_scroll.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:material_ui/material_ui.dart';

const Key _lastField = ValueKey<String>('last-field');
const Key _listKey = ValueKey<String>('greedy-list');

Widget _fieldsContent() => Column(
  mainAxisSize: MainAxisSize.min,
  children: <Widget>[
    for (int i = 0; i < 7; i++)
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: TextField(
          key: i == 6 ? _lastField : null,
          decoration: InputDecoration(labelText: 'Field $i'),
        ),
      ),
  ],
);

Widget _greedyListContent() => SizedBox(
  width: 280,
  child: ListView(
    key: _listKey,
    children: <Widget>[
      for (int i = 0; i < 60; i++) ListTile(title: Text('Row $i')),
    ],
  ),
);

Future<void> _pumpDialog(
  WidgetTester tester, {
  required Widget content,
  required Size size,
  bool glass = false,
  double keyboard = 0,
  bool? scrollable,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFushiThemeData(
        scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        textTheme: Typography.material2021().black,
        glass: FushiGlassMaterial.off,
        glassDesign: glass,
      ),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(viewInsets: EdgeInsets.only(bottom: keyboard)),
        child: FushiGlassScope(child: child!),
      ),
      home: Scaffold(
        body: Center(
          child: FushiAlertDialog(
            title: const Text('Edit'),
            content: content,
            scrollable: scrollable,
            actions: <Widget>[
              TextButton(onPressed: () {}, child: const Text('OK')),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 内容区外壳自己的滚动（最外层那个；输入框 / 列表各自还有内部 Scrollable）。
Finder _contentScrollable() => find
    .descendant(
      of: find.byType(FushiDialogContentScroll),
      matching: find.byType(Scrollable),
    )
    .first;

void main() {
  for (final bool glass in <bool>[false, true]) {
    final String ds = glass ? 'Apple' : 'MD3';

    testWidgets('$ds：一列输入框在小窗口里不溢出，内容区可滚到最后一个框', (WidgetTester tester) async {
      await _pumpDialog(
        tester,
        content: _fieldsContent(),
        size: const Size(420, 320),
        glass: glass,
      );
      expect(tester.takeException(), isNull, reason: '内容区不得 RenderFlex 溢出');
      expect(find.byType(FushiDialogContentScroll), findsOneWidget);
      final ScrollableState scroll = tester.state<ScrollableState>(
        _contentScrollable(),
      );
      expect(
        scroll.position.maxScrollExtent,
        greaterThan(0),
        reason: '七个输入框放不进 320 高的窗口，内容区应能滚',
      );
      // 聚焦最后一个框：EditableText.showOnScreen 经内容区的滚动视口把它滚进来。
      await tester.tap(find.byKey(_lastField), warnIfMissed: false);
      await tester.showKeyboard(find.byKey(_lastField));
      await tester.pumpAndSettle();
      expect(scroll.position.pixels, greaterThan(0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('$ds：键盘弹出（viewInsets）时输入框对话框不溢出', (WidgetTester tester) async {
      await _pumpDialog(
        tester,
        content: _fieldsContent(),
        size: const Size(420, 800),
        glass: glass,
      );
      final ScrollableState scroll = tester.state<ScrollableState>(
        _contentScrollable(),
      );
      expect(scroll.position.maxScrollExtent, 0, reason: '没键盘时装得下，不滚');
      await _pumpDialog(
        tester,
        content: _fieldsContent(),
        size: const Size(420, 800),
        glass: glass,
        keyboard: 520,
      );
      expect(tester.takeException(), isNull, reason: '键盘弹出后不得溢出');
      expect(
        tester
            .state<ScrollableState>(_contentScrollable())
            .position
            .maxScrollExtent,
        greaterThan(0),
        reason: '视口变矮后内容区改为可滚（外层探针把内层标脏重排）',
      );
    });

    testWidgets('$ds：吃满剩余高度的列表内容仍给视口高度（不变成无界、不断言）', (
      WidgetTester tester,
    ) async {
      await _pumpDialog(
        tester,
        content: _greedyListContent(),
        size: const Size(420, 600),
        glass: glass,
      );
      expect(tester.takeException(), isNull);
      final double listHeight = tester.getSize(find.byKey(_listKey)).height;
      expect(listHeight, lessThan(600), reason: '列表被约束在对话框视口内');
      expect(
        tester
            .state<ScrollableState>(_contentScrollable())
            .position
            .maxScrollExtent,
        0,
        reason: '吃满型内容由它自己滚，外壳不另起一层滚动',
      );
    });
  }

  testWidgets('显式 scrollable 不套外壳（true 走 AlertDialog.scrollable，false 原样）', (
    WidgetTester tester,
  ) async {
    await _pumpDialog(
      tester,
      content: const Text('Body'),
      size: const Size(420, 600),
      scrollable: false,
    );
    expect(find.byType(FushiDialogContentScroll), findsNothing);
    await _pumpDialog(
      tester,
      content: _fieldsContent(),
      size: const Size(420, 320),
      scrollable: true,
    );
    expect(find.byType(FushiDialogContentScroll), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
