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

    test('横排：左右两栏同一高度的两行（栏距约 5 倍行厚）不并成跨栏长行', () {
      // 人物资料页两栏：行厚 30，栏间空白 150。旧口径只看跨轴重叠，两行并成一条
      // 0~550 的长行，逐行识别读出串栏的句子。
      final List<OcrRect> merged = mergeOcrLineFragments(<OcrRect>[
        _r(0, 0, 200, 30),
        _r(350, 2, 550, 31),
      ], vertical: false);
      expect(merged, hasLength(2));
    });

    test('横排：左栏一行被切成两段、右栏同高还有一行——左栏两段仍合并', () {
      // 按跨轴中心排序后右栏那行会夹在左栏两段之间，只和最后一条比会把左栏拆开。
      final List<OcrRect> merged = mergeOcrLineFragments(<OcrRect>[
        _r(0, 0, 90, 30),
        _r(350, 1, 550, 31),
        _r(100, 2, 200, 30),
      ], vertical: false);
      expect(merged, hasLength(2));
      final OcrRect left = merged.firstWhere((OcrRect r) => r.left == 0);
      expect(left.right, 200);
    });

    test('竖排：同一 x 上下两段列之间空白约 5 倍列宽，不并成一列', () {
      final List<OcrRect> merged = mergeOcrLineFragments(<OcrRect>[
        _r(0, 0, 30, 100),
        _r(1, 250, 30, 350),
      ], vertical: true);
      expect(merged, hasLength(2));
    });

    test('空隙上限按较厚行厚的 kOcrFragmentMaxGapRatio 倍：刚好在线内仍合并', () {
      final List<OcrRect> within = mergeOcrLineFragments(<OcrRect>[
        _r(0, 0, 100, 30),
        _r(100 + kOcrFragmentMaxGapRatio * 30, 0, 300, 30),
      ], vertical: false);
      expect(within, hasLength(1));
      final List<OcrRect> beyond = mergeOcrLineFragments(<OcrRect>[
        _r(0, 0, 100, 30),
        _r(101 + kOcrFragmentMaxGapRatio * 30, 0, 300, 30),
      ], vertical: false);
      expect(beyond, hasLength(2));
    });

    // 同一行三段 A[0..100]、B[110..400]、C[410..500]，行厚 40，按跨轴中心排序后
    // 到达顺序是 A、C、B：C 与 A 隔着 310 > 3×40 单独成条，B 并进 C，A 与 B+C 之间
    // 只有 10 却再不比较——单趟贪心把一行拆成两条。合并必须做到不动点。
    test('横排：同一行三段乱序到达（A、C、B）仍并成一行', () {
      final List<OcrRect> merged = mergeOcrLineFragments(<OcrRect>[
        _r(0, 0, 100, 40), // A，跨轴中心 20
        _r(410, 1, 500, 41), // C，跨轴中心 21
        _r(110, 2, 400, 42), // B，跨轴中心 22
      ], vertical: false);
      expect(merged, hasLength(1));
      expect(
        <double>[
          merged.single.left,
          merged.single.top,
          merged.single.right,
          merged.single.bottom,
        ],
        <double>[0, 0, 500, 42],
      );
    });

    test('竖排：同一列三段乱序到达（A、C、B）仍并成一列', () {
      final List<OcrRect> merged = mergeOcrLineFragments(<OcrRect>[
        _r(0, 0, 40, 100), // A
        _r(1, 410, 41, 500), // C
        _r(2, 110, 42, 400), // B
      ], vertical: true);
      expect(merged, hasLength(1));
      expect(
        <double>[
          merged.single.left,
          merged.single.top,
          merged.single.right,
          merged.single.bottom,
        ],
        <double>[0, 0, 42, 500],
      );
    });

    test('合并结果与碎片输入顺序无关（三段的全部 6 种排列）', () {
      final List<OcrRect> parts = <OcrRect>[
        _r(0, 0, 100, 40),
        _r(110, 2, 400, 42),
        _r(410, 1, 500, 41),
      ];
      const List<List<int>> permutations = <List<int>>[
        <int>[0, 1, 2],
        <int>[0, 2, 1],
        <int>[1, 0, 2],
        <int>[1, 2, 0],
        <int>[2, 0, 1],
        <int>[2, 1, 0],
      ];
      for (final List<int> order in permutations) {
        final List<OcrRect> merged = mergeOcrLineFragments(<OcrRect>[
          for (final int i in order) parts[i],
        ], vertical: false);
        expect(merged, hasLength(1), reason: 'order $order');
        expect(merged.single.left, 0, reason: 'order $order');
        expect(merged.single.right, 500, reason: 'order $order');
      }
    });

    test('竖排三列各被切成三段、碎片全乱序：合并后仍是三列、阅读序从右到左', () {
      // 列宽 40、列距 20；每列都是 A[0..100] / B[110..400] / C[410..500] 的切法，
      // 跨轴中心按 A、C、B 递增，单趟合并会把每一列都拆成两条。
      List<OcrRect> column(double left) => <OcrRect>[
        _r(left, 0, left + 40, 100),
        _r(left + 2, 110, left + 42, 400),
        _r(left + 1, 410, left + 41, 500),
      ];
      final List<OcrRect> right = column(120);
      final List<OcrRect> middle = column(60);
      final List<OcrRect> left = column(0);
      final List<OcrRect> lines = orderOcrLinesForReading(
        mergeOcrLineFragments(<OcrRect>[
          middle[2],
          left[1],
          right[0],
          left[2],
          middle[0],
          right[1],
          left[0],
          right[2],
          middle[1],
        ], vertical: true),
        vertical: true,
      );
      expect(lines, hasLength(3));
      expect(lines.map((OcrRect r) => r.left), <double>[120, 60, 0]);
      for (final OcrRect line in lines) {
        expect(line.top, 0);
        expect(line.bottom, 500);
      }
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

    // BUG-3314：以下行框都是《新・のび太の海底鬼岩城》蓝光 PGS 位图上 PP 行检测的
    // 真实输出（字幕注音约为正文行高的 0.6~0.65，正好卡在旧的 0.6 阈值上方）。
    test('横排：双行字幕第二行的注音标在字下方，同样去掉', () {
      final List<OcrRect> kept = dropOcrRubyLines(<OcrRect>[
        _r(21, 49, 249, 115), // （のび太）
        _r(42, 113, 796, 177), // キャンプ行くなら山がいい！
        _r(517, 176, 585, 216), // やま：在「山」下方
      ], vertical: false);
      expect(kept.map((OcrRect r) => r.top), <double>[49, 113]);
    });

    test('一行正文配四段注音：典型行厚按行长计，注音段数再多也不把基准拉低', () {
      final List<OcrRect> kept = dropOcrRubyLines(<OcrRect>[
        _r(436, 15, 500, 52), // あさ
        _r(21, 16, 80, 53), // とり
        _r(134, 16, 201, 51), // こえ
        _r(264, 16, 306, 50), // お
        _r(22, 53, 496, 111), // 鳥の声で起きる朝
      ], vertical: false);
      expect(kept.map((OcrRect r) => r.top), <double>[53]);
    });

    // 审查回归：英文双行字幕第二行全是 x 高度小写字母（「can we see」），行高只有
    // 第一行的 ~0.7 倍、紧贴其下——第一行上方没有别的正文行，下方注音不成立。
    test('横排：英文双行字幕第二行矮而紧贴第一行，不当下方注音删掉', () {
      final List<OcrRect> kept = dropOcrRubyLines(<OcrRect>[
        _r(40, 40, 620, 104), // What do you mean?（厚 64）
        _r(180, 106, 480, 150), // can we see（厚 44，0.69 倍）
      ], vertical: false);
      expect(kept.map((OcrRect r) => r.top), <double>[40, 106]);
    });

    test('横排：下方注音只在正文行上方已被另一行正文占住时才认', () {
      // 同一组几何，正文行上方再压一行：第三行这时才是被挤到下方的注音。
      final List<OcrRect> kept = dropOcrRubyLines(<OcrRect>[
        _r(40, 0, 500, 64), // 上一行正文
        _r(40, 62, 620, 126), // 正文行（厚 64）
        _r(180, 126, 260, 166), // 下方注音（厚 40）
      ], vertical: false);
      expect(kept.map((OcrRect r) => r.top), <double>[0, 62]);
    });

    test('没有注音的双行字幕两行都保留', () {
      final List<OcrRect> kept = dropOcrRubyLines(<OcrRect>[
        _r(20, 45, 468, 113), // （のび太）んっ!?
        _r(42, 115, 529, 177), // ち…ちがうわい！
      ], vertical: false);
      expect(kept, hasLength(2));
    });
  });
}
