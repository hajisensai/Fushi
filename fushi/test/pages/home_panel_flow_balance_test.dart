import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/home_dashboard_widgets.dart';

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
}
