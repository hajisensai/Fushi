import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ocr/ocr_line_layout.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';

OcrRect _r(double l, double t, double r, double b) =>
    OcrRect(left: l, top: t, right: r, bottom: b);

void main() {
  group('mergeOcrLineFragments', () {
    test('竖排：同一列被切成的几段合并，相邻两列保持分开', () {
      final List<OcrRect> merged = mergeOcrLineFragments(<OcrRect>[
        _r(100, 0, 130, 60),
        _r(102, 70, 128, 150), // 同一列下半截（「っ」处被切断）
        _r(60, 0, 90, 150), // 左边一列
      ], vertical: true);
      expect(merged, hasLength(2));
      final OcrRect right = merged.firstWhere((OcrRect r) => r.left >= 100);
      expect(
        <double>[right.left, right.top, right.right, right.bottom],
        <double>[100, 0, 130, 150],
      );
    });

    test('横排：同一行的几段合并，上下两行保持分开', () {
      final List<OcrRect> merged = mergeOcrLineFragments(<OcrRect>[
        _r(0, 0, 80, 30),
        _r(90, 2, 200, 28),
        _r(0, 40, 200, 70),
      ], vertical: false);
      expect(merged, hasLength(2));
    });
  });

  test('orderOcrLinesForReading：竖排从右到左、横排从上到下', () {
    final List<OcrRect> columns = orderOcrLinesForReading(<OcrRect>[
      _r(0, 0, 30, 100),
      _r(80, 0, 110, 100),
      _r(40, 0, 70, 100),
    ], vertical: true);
    expect(columns.map((OcrRect r) => r.left), <double>[80, 40, 0]);
    final List<OcrRect> rows = orderOcrLinesForReading(<OcrRect>[
      _r(0, 50, 100, 70),
      _r(0, 0, 100, 20),
    ], vertical: false);
    expect(rows.map((OcrRect r) => r.top), <double>[0, 50]);
  });

  group('layoutOcrTextOnLines', () {
    test('三列竖排按列长切开，逐字节拼回原文（用户真实页 p5 的气泡）', () {
      // 列宽 30：6 / 6 / 7 字格。
      final OcrLineLayout layout = layoutOcrTextOnLines(
        '母の子守唄で眠ったことは一度もなかった',
        <OcrRect>[
          _r(120, 0, 150, 180),
          _r(80, 0, 110, 180),
          _r(40, 0, 70, 210),
        ],
        vertical: true,
      )!;
      expect(layout.lines, <String>['母の子守唄で', '眠ったことは', '一度もなかった']);
      expect(layout.boxes.map((OcrRect r) => r.left), <double>[120, 80, 40]);
    });

    test('横排按行宽切开', () {
      final OcrLineLayout layout = layoutOcrTextOnLines(
        'episode5「裏方気質」p143',
        <OcrRect>[_r(0, 0, 400, 20), _r(0, 30, 80, 50)],
        vertical: false,
      )!;
      expect(layout.lines.join(), 'episode5「裏方気質」p143');
      expect(layout.lines, hasLength(2));
      expect(layout.lines.first.length, greaterThan(layout.lines.last.length));
    });

    test('字素簇不被切开：浊点组合符跟着基字走', () {
      // 两列各 2 字格；第二个字是 か + 组合浊点（NFD）。
      final OcrLineLayout layout = layoutOcrTextOnLines('あがさし', <OcrRect>[
        _r(40, 0, 60, 40),
        _r(0, 0, 20, 40),
      ], vertical: true)!;
      expect(layout.lines, <String>['あが', 'さし']);
    });

    test('分不到字的列连同框一起丢掉；空白跟着可见字走，拼回仍是原文', () {
      final OcrLineLayout layout = layoutOcrTextOnLines(' は？', <OcrRect>[
        _r(100, 0, 130, 60),
        _r(60, 0, 90, 30),
        _r(20, 0, 50, 30),
      ], vertical: true)!;
      expect(layout.lines.join(), ' は？');
      expect(layout.lines.length, layout.boxes.length);
      expect(layout.lines.length, lessThanOrEqualTo(2));
    });

    test('没有行 / 没有可见字时返回 null（调用方保持整块单行）', () {
      expect(
        layoutOcrTextOnLines('あ', const <OcrRect>[], vertical: true),
        isNull,
      );
      expect(
        layoutOcrTextOnLines('  ', <OcrRect>[_r(0, 0, 10, 10)], vertical: true),
        isNull,
      );
      expect(
        layoutOcrTextOnLines('あ', <OcrRect>[_r(0, 0, 0, 10)], vertical: true),
        isNull,
      );
    });

    test('单列：整串落在这一列上，框是列框而不是块框', () {
      final OcrLineLayout layout = layoutOcrTextOnLines('ありゃ大変', <OcrRect>[
        _r(10, 5, 40, 160),
      ], vertical: true)!;
      expect(layout.lines, <String>['ありゃ大変']);
      expect(layout.boxes.single.top, 5);
    });
  });
}
