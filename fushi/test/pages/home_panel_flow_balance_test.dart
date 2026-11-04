import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/home_dashboard_widgets.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  group('HomePanelFlow.balance', () {
    test('puts the tallest panels into the shortest column first', () {
      final ({List<List<int>> columns, List<double> heights}) r =
          HomePanelFlow.balance(<double>[400, 100, 100, 100, 100], 2, 10);
      // 400 单独一列；四个 100 叠在另一列（4×100 + 3×10 = 430）。
      expect(r.columns, <List<int>>[
        <int>[0],
        <int>[1, 2, 3, 4],
      ]);
      expect(r.heights, <double>[400, 430]);
    });

    test('keeps original order inside a column and leads with panel 0', () {
      final ({List<List<int>> columns, List<double> heights}) r =
          HomePanelFlow.balance(<double>[100, 300, 200], 2, 0);
      expect(r.columns.first.first, 0);
      for (final List<int> col in r.columns) {
        expect(col, List<int>.of(col)..sort());
      }
      expect(r.columns.expand((List<int> c) => c).toSet(), <int>{0, 1, 2});
    });

    test('drops empty columns when there are fewer panels than columns', () {
      final ({List<List<int>> columns, List<double> heights}) r =
          HomePanelFlow.balance(<double>[120], 3, 12);
      expect(r.columns, <List<int>>[
        <int>[0],
      ]);
      expect(r.heights, <double>[120]);
    });
  });

  group('HomePanelFlow layout', () {
    Widget panel(int i, double height, {VoidCallback? onTap}) =>
        GestureDetector(
          key: ValueKey<String>('panel-$i'),
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(height: height),
        );

    Future<void> pumpFlow(
      WidgetTester tester,
      double width,
      List<Widget> children,
    ) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: HomePanelFlow(gap: 10, children: children),
            ),
          ),
        ),
      );
    }

    Offset at(WidgetTester tester, int i) =>
        tester.getTopLeft(find.byKey(ValueKey<String>('panel-$i')));

    testWidgets('一高四矮：高的独占一列，四个矮的按原顺序叠在另一列', (WidgetTester tester) async {
      final List<int> tapped = <int>[];
      await pumpFlow(tester, 700, <Widget>[
        panel(0, 400),
        for (int i = 1; i <= 4; i++) panel(i, 100, onTap: () => tapped.add(i)),
      ]);
      // 700 宽、最小列宽 320 → 两列，列宽 (700 - 10) / 2 = 345。
      expect(at(tester, 0), Offset.zero);
      for (int i = 1; i <= 4; i++) {
        expect(at(tester, i), Offset(355, (i - 1) * 110.0));
        expect(
          tester.getSize(find.byKey(ValueKey<String>('panel-$i'))).width,
          345,
        );
      }
      expect(tester.getSize(find.byType(HomePanelFlow)), const Size(700, 430));
      await tester.tap(find.byKey(const ValueKey<String>('panel-3')));
      expect(tapped, <int>[3]);
    });

    testWidgets('窄到放不下两列：单列按原顺序竖排', (WidgetTester tester) async {
      await pumpFlow(tester, 500, <Widget>[
        panel(0, 50),
        panel(1, 80),
        panel(2, 30),
      ]);
      expect(at(tester, 0), Offset.zero);
      expect(at(tester, 1), const Offset(0, 60));
      expect(at(tester, 2), const Offset(0, 150));
    });

    testWidgets('面板内部 relayout 但尺寸不变：不再逐列数试排；尺寸变了才重选', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<double> tall = ValueNotifier<double>(400);
      addTearDown(tall.dispose);
      final ValueNotifier<int> tick = ValueNotifier<int>(0);
      addTearDown(tick.dispose);
      await pumpFlow(tester, 1100, <Widget>[
        ValueListenableBuilder<double>(
          valueListenable: tall,
          builder: (BuildContext _, double h, Widget? __) => panel(0, h),
        ),
        // 高度随宽度 / 内容变，但内容变化不改高度：触发 flow relayout。
        ValueListenableBuilder<int>(
          valueListenable: tick,
          builder: (BuildContext _, int v, Widget? __) =>
              Text('tick $v', style: const TextStyle(fontSize: 20, height: 1)),
        ),
        panel(2, 100),
        panel(3, 100),
      ]);
      final int before = HomePanelFlow.debugColumnChoices;
      tick.value++;
      await tester.pump();
      expect(find.text('tick 1'), findsOneWidget);
      expect(HomePanelFlow.debugColumnChoices, before);

      tall.value = 60;
      await tester.pump();
      expect(HomePanelFlow.debugColumnChoices, before + 1);
    });
  });
}
