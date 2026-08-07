import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ocr/ocr_types.dart';
import 'package:fushi/src/ocr/reading_order.dart';

OcrRect rect(double left, double top, double width, double height) =>
    OcrRect(left: left, top: top, right: left + width, bottom: top + height);

void main() {
  group('clusterPanels', () {
    test('远距块分属不同面板，近距块合并', () {
      final List<OcrRect> boxes = <OcrRect>[
        rect(0, 0, 30, 30),
        rect(35, 0, 30, 30), // 与 0 间距 5 < 0.75*30 → 同面板
        rect(200, 0, 30, 30), // 远 → 另一面板
      ];
      final List<List<int>> panels = clusterPanels(boxes);
      expect(panels, hasLength(2));
      final List<int> big = panels.firstWhere((List<int> p) => p.length == 2);
      expect(big.toSet(), <int>{0, 1});
    });
  });

  group('computeReadingOrder', () {
    test('单页 4 气泡 2x2（RTL）：右上 → 左上 → 右下 → 左下', () {
      // 4 个独立面板（间距远大于块尺寸）。
      final List<OcrRect> boxes = <OcrRect>[
        rect(10, 10, 25, 30), // 0: 左上
        rect(160, 10, 25, 30), // 1: 右上
        rect(10, 160, 25, 30), // 2: 左下
        rect(160, 160, 25, 30), // 3: 右下
      ];
      expect(computeReadingOrder(boxes), <int>[1, 0, 3, 2]);
    });

    test('单面板双栏（竖排列主序）：右栏上下 → 左栏上下', () {
      // 4 块靠得近（同面板），两列各两块。
      final List<OcrRect> boxes = <OcrRect>[
        rect(40, 0, 20, 40), // 0: 左栏上
        rect(40, 45, 20, 40), // 1: 左栏下
        rect(70, 0, 20, 40), // 2: 右栏上
        rect(70, 45, 20, 40), // 3: 右栏下
      ];
      expect(computeReadingOrder(boxes), <int>[2, 3, 0, 1]);
    });

    test('LTR 时列序反转', () {
      final List<OcrRect> boxes = <OcrRect>[
        rect(40, 0, 20, 40),
        rect(70, 0, 20, 40),
      ];
      expect(computeReadingOrder(boxes, rightToLeft: false), <int>[0, 1]);
      expect(computeReadingOrder(boxes), <int>[1, 0]);
    });

    test('webtoon 纵排长条：纯上下序（x 抖动不影响）', () {
      final List<OcrRect> boxes = <OcrRect>[
        rect(60, 300, 40, 30), // 2
        rect(10, 0, 40, 30), // 0
        rect(30, 600, 40, 30), // 3
        rect(80, 150, 40, 30), // 1
      ];
      expect(computeReadingOrder(boxes), <int>[1, 3, 0, 2]);
    });

    test('空输入', () {
      expect(computeReadingOrder(<OcrRect>[]), isEmpty);
    });

    test('混合版式：上半整宽面板在先，下半左右两面板 RTL', () {
      final List<OcrRect> boxes = <OcrRect>[
        rect(10, 200, 30, 30), // 0: 下带左面板
        rect(200, 200, 30, 30), // 1: 下带右面板
        rect(80, 10, 40, 30), // 2: 上带整宽面板
      ];
      expect(computeReadingOrder(boxes), <int>[2, 1, 0]);
    });
  });

  group('orderWithinPanel', () {
    test('横向重叠聚成同列并按 top 排序', () {
      final List<OcrRect> boxes = <OcrRect>[
        rect(50, 50, 20, 30), // 与 1 同列（x 重叠）
        rect(55, 0, 20, 30),
        rect(0, 0, 20, 80), // 独立左列
      ];
      expect(
        orderWithinPanel(boxes, <int>[0, 1, 2]),
        <int>[1, 0, 2],
      );
    });
  });
}
