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

    test('竖排：斜体并排两列横向互相压进一半以上也不合并（用户真实页）', () {
      // 「パステルカラーで / 女子力アップ♡」两列字是斜着写的，PP 行检测给出的轴对齐
      // 列框横向重叠 41 px（较窄者 76 px 的 54%）。旧口径只看跨轴重叠，把两列并成
      // 一条宽列，逐列 CTC 只读出一列（还把「パ」认成「バ」），另一列整列丢失。
      final List<OcrRect> merged = mergeOcrLineFragments(<OcrRect>[
        _r(449, 30, 525, 292), // 女子力アップ♡
        _r(484, 36, 566, 339), // パステルカラーで
      ], vertical: true);
      expect(merged, hasLength(2));
    });

    test('竖排：同一列被检出两次（跨轴几乎重合）仍合并', () {
      final List<OcrRect> merged = mergeOcrLineFragments(<OcrRect>[
        _r(100, 0, 130, 150),
        _r(102, 10, 131, 140),
      ], vertical: true);
      expect(merged, hasLength(1));
    });

    test('横排：字距大的标题逐字断开的碎片仍并成一行', () {
      final List<OcrRect> merged = mergeOcrLineFragments(<OcrRect>[
        _r(874, 1046, 940, 1115), // モ
        _r(1051, 1040, 1115, 1120),
        _r(1120, 1037, 1209, 1125),
        _r(1288, 1058, 1344, 1117), // の
      ], vertical: false);
      expect(merged, hasLength(1));
      expect(merged.single.left, 874);
      expect(merged.single.right, 1344);
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

  group('字格权重', () {
    test('「!?」两个一组占一格：不会把下一列首字挤进上一列（用户真实页 p10）', () {
      final OcrLineLayout layout = layoutOcrTextOnLines('鳴った!なんで!?', <OcrRect>[
        _r(40, 0, 70, 120),
        _r(0, 0, 30, 120),
      ], vertical: true)!;
      expect(layout.lines, <String>['鳴った!', 'なんで!?']);
    });

    test('点号串合占一格：省略号不把后面整列推后（用户真实页 p6）', () {
      final OcrLineLayout layout = layoutOcrTextOnLines(
        'それはあの子も一緒だったみたいで...',
        <OcrRect>[_r(80, 0, 110, 210), _r(40, 0, 70, 150), _r(0, 0, 30, 150)],
        vertical: true,
      )!;
      expect(layout.lines, <String>['それはあの子も', '一緒だった', 'みたいで...']);
    });
  });

  group('voteOcrLineOrientation', () {
    test('三条竖列 + 四个近横的小碎片：按长度投票仍是竖排', () {
      expect(
        voteOcrLineOrientation(<OcrRect>[
          _r(100, 0, 130, 200),
          _r(60, 0, 90, 180),
          _r(20, 0, 50, 160),
          _r(0, 210, 40, 230),
          _r(50, 210, 90, 230),
          _r(100, 210, 140, 230),
          _r(0, 240, 40, 260),
        ]),
        isTrue,
      );
    });

    test('横排段落投横排；只有近方形的行（合并成一团的几列）不表态', () {
      expect(
        voteOcrLineOrientation(<OcrRect>[
          _r(0, 0, 300, 30),
          _r(0, 40, 280, 70),
        ]),
        isFalse,
      );
      expect(voteOcrLineOrientation(<OcrRect>[_r(0, 0, 210, 235)]), isNull);
      expect(voteOcrLineOrientation(const <OcrRect>[]), isNull);
    });
  });

  group('dropOcrRubyLines', () {
    test('贴在正文列右侧、厚 0.65 倍的注音列被去掉（0.6 阈值会漏掉它）', () {
      final List<OcrRect> kept = dropOcrRubyLines(<OcrRect>[
        _r(98, 14, 134, 111), // 正文列（厚 36）
        _r(82, 73, 104, 201), // 注音：厚 22，贴着左边那列的右侧
        _r(54, 14, 88, 230), // 正文列（厚 34）
        _r(17, 20, 50, 326), // 正文列（厚 33）
      ], vertical: true);
      expect(kept.map((OcrRect r) => r.left), <double>[98, 54, 17]);
    });

    test('不贴着更粗的行的窄列保留（单独一列「!!」之类）；远低于 0.6 的一律去掉', () {
      final List<OcrRect> kept = dropOcrRubyLines(<OcrRect>[
        _r(100, 0, 134, 200),
        _r(60, 0, 94, 200),
        _r(0, 0, 24, 40), // 厚 24（0.7 倍）但不在任何正文列注音侧
        _r(140, 0, 150, 30), // 厚 10：细线
      ], vertical: true);
      expect(kept.map((OcrRect r) => r.left), <double>[100, 60, 0]);
    });

    test('横排：注音在正文行上方', () {
      final List<OcrRect> kept = dropOcrRubyLines(<OcrRect>[
        _r(0, 20, 300, 56), // 正文行（厚 36）
        _r(40, 0, 120, 22), // 注音：厚 22，在正文上方
        _r(0, 70, 300, 106), // 正文行
      ], vertical: false);
      expect(kept.map((OcrRect r) => r.top), <double>[20, 70]);
    });
  });
}
