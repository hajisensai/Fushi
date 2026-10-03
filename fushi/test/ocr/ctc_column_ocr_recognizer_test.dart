import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ocr/ctc_column_ocr_recognizer.dart';
import 'package:fushi_engine/ocr/manga_ocr_pipeline.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/ppocr_line_detector.dart';
import 'package:fushi_engine/ocr/ppocr_line_recognizer.dart';
import 'package:fushi_engine/ocr/routing_ocr_recognizer.dart';
import 'package:image/image.dart' as img;

class _DeadSession implements OcrSession {
  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) =>
      throw StateError('fake must not run a session');

  @override
  Future<void> close() async {}
}

/// 固定吐出 [lines]（裁图坐标）的行检测器，记下每次收到的裁图。
class _FakeLineDetector extends PpOcrLineDetector {
  _FakeLineDetector(this.lines) : super(_DeadSession());

  final List<PpTextLine> lines;
  final List<img.Image> crops = <img.Image>[];

  @override
  Future<List<PpTextLine>> detect(img.Image crop) async {
    crops.add(crop);
    return lines;
  }
}

/// 按行图正中像素的红通道认出收到的是哪一列（测试页上每列涂了自己的红值），
/// 回 [replies] 里对应的文本；记下收到的每张行图。
class _ColorReadingRecognizer extends PpOcrLineRecognizer {
  _ColorReadingRecognizer(this.replies)
    : super(_DeadSession(), vocab: const <String>['']);

  final Map<int, String> replies;
  final List<img.Image> lines = <img.Image>[];

  // 生产路径调的是 recognizeLineScored（recognizeLine 转调它），假件重写这一个。
  @override
  Future<({String text, double? confidence})> recognizeLineScored(
    img.Image line,
  ) async {
    lines.add(line);
    final int red = line.getPixel(line.width ~/ 2, line.height ~/ 2).r.toInt();
    return (text: replies[red] ?? '?', confidence: null);
  }
}

class _ConstLineRecognizer extends PpOcrLineRecognizer {
  _ConstLineRecognizer(this.reply)
    : super(_DeadSession(), vocab: const <String>['']);

  final String reply;

  @override
  Future<({String text, double? confidence})> recognizeLineScored(
    img.Image line,
  ) async => (text: reply, confidence: null);
}

typedef _LineCall = ({OcrRect box, bool vertical, List<OcrRect>? lineHints});

/// 逐行识别的主识别器替身：固定交回 [reply]，记下每次逐行调用的参数。
class _FakeLinePrimary implements LineOcrRecognizer {
  final List<_LineCall> calls = <_LineCall>[];
  int plainCalls = 0;
  final OcrRecognition reply = const OcrRecognition(
    text: 'ab',
    vertical: true,
    lines: <String>['a', 'b'],
    lineBoxes: <OcrRect>[
      OcrRect(left: 1, top: 2, right: 3, bottom: 4),
      OcrRect(left: 5, top: 6, right: 7, bottom: 8),
    ],
  );

  @override
  Future<String> recognize(img.Image page, OcrRect box) async {
    plainCalls++;
    return 'plain';
  }

  @override
  Future<OcrRecognition> recognizeWithLines(
    img.Image page,
    OcrRect box, {
    required bool vertical,
    List<OcrRect>? lineHints,
  }) async {
    calls.add((box: box, vertical: vertical, lineHints: lineHints));
    return reply;
  }
}

class _FakeBatchLinePrimary extends _FakeLinePrimary
    implements BatchOcrRecognizer {
  final List<List<OcrRect>> batches = <List<OcrRect>>[];

  @override
  Future<List<String>> recognizeBatch(
    img.Image page,
    List<OcrRect> boxes,
  ) async {
    batches.add(List<OcrRect>.of(boxes));
    return <String>[for (final OcrRect _ in boxes) 'batch'];
  }
}

/// 固定吐出给定区域的页面检测器（pipeline 落库用）。
class _FixedRegionDetector implements OcrDetector {
  _FixedRegionDetector(this.rects);

  final List<OcrRect> rects;

  @override
  Future<PageDetections> detect(img.Image page) async => PageDetections(
    textRegions: <DetectedTextRegion>[
      for (final OcrRect rect in rects)
        DetectedTextRegion(
          rect: rect,
          score: 0.9,
          classId: 1,
          insideBubble: true,
        ),
    ],
    bubbles: const <OcrRect>[],
  );
}

PpTextLine _line(double l, double t, double r, double b) => PpTextLine(
  rect: OcrRect(left: l, top: t, right: r, bottom: b),
  score: 1,
);

List<double> _ltrb(OcrRect r) => <double>[r.left, r.top, r.right, r.bottom];

List<int> _rgb(img.Image image, int x, int y) {
  final img.Pixel pixel = image.getPixel(x, y);
  return <int>[pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt()];
}

/// 把页面上的半开区间 [rect] 涂成 (r, g, b)。
void _paint(img.Image page, OcrRect rect, int r, int g, int b) {
  for (int y = rect.top.toInt(); y < rect.bottom.toInt(); y++) {
    for (int x = rect.left.toInt(); x < rect.right.toInt(); x++) {
      page.setPixelRgb(x, y, r, g, b);
    }
  }
}

/// 各列在测试页上涂的红值。
const int _rightRed = 10;
const int _middleRed = 20;
const int _leftRed = 30;
const int _rubyRed = 90;

const Map<int, String> _columnText = <int, String>{
  _rightRed: '右列',
  _middleRed: '中列',
  _leftRed: '左列',
  _rubyRed: 'るび',
};

/// 三列竖排气泡：块 130×220，左上角在页面 (200,40)。
const OcrRect _bubble = OcrRect(left: 200, top: 40, right: 330, bottom: 260);

/// 气泡里检出的行（裁图坐标，故意打乱顺序）：三列正文（列宽 30）+ 贴在右列注音
/// 侧、厚 20 的振假名 + 一条厚 4 的细振假名。
List<PpTextLine> _bubbleLines() => <PpTextLine>[
  _line(10, 0, 40, 210), // 左列 → 页面 (210,40)-(240,250)
  _line(102, 10, 122, 90), // 右列注音侧的振假名（0.67 倍厚）
  _line(70, 0, 100, 180), // 右列 → 页面 (270,40)-(300,220)
  _line(124, 100, 128, 160), // 细振假名
  _line(40, 0, 70, 180), // 中列 → 页面 (240,40)-(270,220)
];

/// 按 [_bubbleLines] 在 400×300 的页面上把每列（换到页面坐标）涂上自己的红值。
img.Image _bubblePage() {
  final img.Image page = img.Image(width: 400, height: 300);
  const Map<int, OcrRect> regions = <int, OcrRect>{
    _leftRed: OcrRect(left: 210, top: 40, right: 240, bottom: 250),
    _rightRed: OcrRect(left: 270, top: 40, right: 300, bottom: 220),
    _middleRed: OcrRect(left: 240, top: 40, right: 270, bottom: 220),
  };
  regions.forEach((int red, OcrRect rect) => _paint(page, rect, red, 0, 0));
  _paint(
    page,
    const OcrRect(left: 302, top: 50, right: 322, bottom: 130),
    _rubyRed,
    0,
    0,
  );
  _paint(
    page,
    const OcrRect(left: 324, top: 140, right: 328, bottom: 200),
    _rubyRed,
    0,
    0,
  );
  return page;
}

void main() {
  group('CtcColumnOcrRecognizer', () {
    test('多列竖排：去掉振假名后从右到左逐列识别，列框是页面坐标', () async {
      final _FakeLineDetector det = _FakeLineDetector(_bubbleLines());
      final _ColorReadingRecognizer rec = _ColorReadingRecognizer(_columnText);
      final OcrRecognition out = await CtcColumnOcrRecognizer(
        lineDetector: det,
        lineRecognizer: rec,
      ).recognizeWithLines(_bubblePage(), _bubble, vertical: true);

      expect(out.vertical, isTrue);
      expect(out.lines, <String>['右列', '中列', '左列']);
      expect(out.text, '右列中列左列');
      expect(out.lineBoxes!.map(_ltrb), <List<double>>[
        <double>[270, 40, 300, 220],
        <double>[240, 40, 270, 220],
        <double>[210, 40, 240, 250],
      ]);
      // 检测只在整块裁图上跑一次；两条振假名一条都没交给识别器。
      expect(det.crops.single.width, 130);
      expect(det.crops.single.height, 220);
      expect(rec.lines, hasLength(3));
    });

    test('竖列逆时针转 90° 再交识别器：列顶落在转后图的左边', () async {
      final img.Image page = img.Image(width: 400, height: 300);
      // 列在页面 (104,24)-(136,276)：顶端 20 行涂绿、底端 20 行涂蓝、其余涂红。
      _paint(
        page,
        const OcrRect(left: 104, top: 24, right: 136, bottom: 276),
        200,
        0,
        0,
      );
      _paint(
        page,
        const OcrRect(left: 104, top: 24, right: 136, bottom: 44),
        0,
        200,
        0,
      );
      _paint(
        page,
        const OcrRect(left: 104, top: 256, right: 136, bottom: 276),
        0,
        0,
        200,
      );
      final _ColorReadingRecognizer rec = _ColorReadingRecognizer(
        const <int, String>{200: '列'},
      );
      // 竖长块（40×260，左上角 (100,20)），检出的列在裁图 (4,4)-(36,256)。
      final String text =
          await CtcColumnOcrRecognizer(
            lineDetector: _FakeLineDetector(<PpTextLine>[_line(4, 4, 36, 256)]),
            lineRecognizer: rec,
          ).recognize(
            page,
            const OcrRect(left: 100, top: 20, right: 140, bottom: 280),
          );

      expect(text, '列');
      final img.Image line = rec.lines.single;
      // 32×252 的列转成 252×32 的横行。
      expect(line.width, 252);
      expect(line.height, 32);
      // 列顶（绿）在左端、列底（蓝）在右端；顺时针转会正好反过来。
      expect(_rgb(line, 5, 16), <int>[0, 200, 0]);
      expect(_rgb(line, 246, 16), <int>[0, 0, 200]);
    });

    test('读不出字的列连同列框一起丢，拼回的文本不含它', () async {
      final OcrRecognition out = await CtcColumnOcrRecognizer(
        lineDetector: _FakeLineDetector(_bubbleLines()),
        lineRecognizer: _ColorReadingRecognizer(<int, String>{
          ..._columnText,
          _middleRed: '',
        }),
      ).recognizeWithLines(_bubblePage(), _bubble, vertical: true);

      expect(out.text, '右列左列');
      expect(out.lines, <String>['右列', '左列']);
      expect(out.lineBoxes!.map((OcrRect r) => r.left), <double>[270, 210]);
    });

    test('检到的列一个字都没读出：交回空文本，不再整块重读', () async {
      final _ColorReadingRecognizer rec = _ColorReadingRecognizer(
        const <int, String>{_rightRed: '', _middleRed: '', _leftRed: ''},
      );
      final OcrRecognition out = await CtcColumnOcrRecognizer(
        lineDetector: _FakeLineDetector(_bubbleLines()),
        lineRecognizer: rec,
      ).recognizeWithLines(_bubblePage(), _bubble, vertical: true);

      expect(out.text, isEmpty);
      expect(out.lines, isNull);
      expect(rec.lines, hasLength(3));
    });

    test('一行都没检到：整块当一行读（竖排同样转向），不带行几何', () async {
      final _ColorReadingRecognizer rec = _ColorReadingRecognizer(
        const <int, String>{_middleRed: '整块'},
      );
      final CtcColumnOcrRecognizer ctc = CtcColumnOcrRecognizer(
        lineDetector: _FakeLineDetector(<PpTextLine>[]),
        lineRecognizer: rec,
      );
      final img.Image page = _bubblePage();

      final OcrRecognition vertical = await ctc.recognizeWithLines(
        page,
        _bubble,
        vertical: true,
      );
      expect(vertical.text, '整块');
      expect(vertical.vertical, isTrue);
      expect(vertical.lines, isNull);
      expect(vertical.lineBoxes, isNull);
      // 130×220 的整块转成 220×130。
      expect(rec.lines.last.width, 220);
      expect(rec.lines.last.height, 130);

      final OcrRecognition horizontal = await ctc.recognizeWithLines(
        page,
        _bubble,
        vertical: false,
      );
      expect(horizontal.text, '整块');
      expect(horizontal.vertical, isFalse);
      expect(horizontal.lines, isNull);
      // 横排不转向。
      expect(rec.lines.last.width, 130);
      expect(rec.lines.last.height, 220);
    });

    test('方向按检出行投票：调用方说横排、检出的是竖列 → 按竖排逐列转向识别', () async {
      final _ColorReadingRecognizer rec = _ColorReadingRecognizer(_columnText);
      final OcrRecognition out = await CtcColumnOcrRecognizer(
        lineDetector: _FakeLineDetector(_bubbleLines()),
        lineRecognizer: rec,
      ).recognizeWithLines(_bubblePage(), _bubble, vertical: false);

      expect(out.vertical, isTrue);
      expect(out.lines, <String>['右列', '中列', '左列']);
      for (final img.Image line in rec.lines) {
        expect(line.width, greaterThan(line.height));
      }
    });

    test('方向按检出行投票：调用方说竖排、检出的是横行 → 按横排从上到下、不转向', () async {
      final img.Image page = img.Image(width: 400, height: 300);
      // 块 200×100，左上角 (50,100)；两条横行涂不同红值。
      _paint(
        page,
        const OcrRect(left: 60, top: 110, right: 240, bottom: 140),
        40,
        0,
        0,
      );
      _paint(
        page,
        const OcrRect(left: 60, top: 150, right: 240, bottom: 180),
        50,
        0,
        0,
      );
      final _ColorReadingRecognizer rec = _ColorReadingRecognizer(
        const <int, String>{40: '上', 50: '下'},
      );
      final OcrRecognition out =
          await CtcColumnOcrRecognizer(
            lineDetector: _FakeLineDetector(<PpTextLine>[
              _line(10, 50, 190, 80),
              _line(10, 10, 190, 40),
            ]),
            lineRecognizer: rec,
          ).recognizeWithLines(
            page,
            const OcrRect(left: 50, top: 100, right: 250, bottom: 200),
            vertical: true,
          );

      expect(out.vertical, isFalse);
      expect(out.lines, <String>['上', '下']);
      expect(out.lineBoxes!.map(_ltrb), <List<double>>[
        <double>[60, 110, 240, 140],
        <double>[60, 150, 240, 180],
      ]);
      expect(rec.lines.map((img.Image i) => i.width), <int>[180, 180]);
      expect(rec.lines.map((img.Image i) => i.height), <int>[30, 30]);
    });

    test('给了 lineHints 就不再检测，照样去振假名、排序后逐列识别', () async {
      final _FakeLineDetector det = _FakeLineDetector(<PpTextLine>[]);
      final List<OcrRect> hints = <OcrRect>[
        for (final PpTextLine line in _bubbleLines())
          OcrRect(
            left: 200 + line.rect.left,
            top: 40 + line.rect.top,
            right: 200 + line.rect.right,
            bottom: 40 + line.rect.bottom,
          ),
      ];
      final OcrRecognition out =
          await CtcColumnOcrRecognizer(
            lineDetector: det,
            lineRecognizer: _ColorReadingRecognizer(_columnText),
          ).recognizeWithLines(
            _bubblePage(),
            _bubble,
            vertical: true,
            lineHints: hints,
          );

      expect(det.crops, isEmpty);
      expect(out.lines, <String>['右列', '中列', '左列']);
      expect(out.lineBoxes!.map((OcrRect r) => r.left), <double>[
        270,
        240,
        210,
      ]);
    });
  });

  group('RoutingOcrRecognizer + LineOcrRecognizer', () {
    final img.Image page = img.Image(width: 400, height: 300);

    test('竖长块整块交逐行识别器：结果原样交回，路由不为排版再检测', () async {
      final _FakeLinePrimary primary = _FakeLinePrimary();
      final _FakeLineDetector routingDet = _FakeLineDetector(<PpTextLine>[]);
      final RoutingOcrRecognizer routed = RoutingOcrRecognizer(
        mangaOcr: primary,
        lineDetector: routingDet,
        lineRecognizer: _ConstLineRecognizer('P'),
      );
      expect(routed, isNot(isA<BatchOcrRecognizer>()));
      const OcrRect tall = OcrRect(left: 10, top: 10, right: 60, bottom: 200);

      final OcrRecognition out = (await routed.recognizeOriented(
        page,
        <OcrRect>[tall],
      )).single;

      expect(out, same(primary.reply));
      final _LineCall call = primary.calls.single;
      expect(call.box, same(tall));
      expect(call.vertical, isTrue);
      expect(call.lineHints, isNull);
      expect(primary.plainCalls, 0);
      expect(routingDet.crops, isEmpty);
      expect(await routed.recognize(page, tall), 'ab');
    });

    test('宽的多列竖排：路由检出的行作为 lineHints（页面坐标）交过去，不重复检测', () async {
      final _FakeLinePrimary primary = _FakeLinePrimary();
      final _FakeLineDetector routingDet = _FakeLineDetector(<PpTextLine>[
        _line(150, 5, 180, 95),
        _line(100, 5, 130, 95),
      ]);
      final RoutingOcrRecognizer routed = RoutingOcrRecognizer(
        mangaOcr: primary,
        lineDetector: routingDet,
        lineRecognizer: _ConstLineRecognizer('P'),
      );
      const OcrRect wide = OcrRect(left: 50, top: 100, right: 250, bottom: 200);

      final OcrRecognition out = (await routed.recognizeOriented(
        page,
        <OcrRect>[wide],
      )).single;

      expect(out, same(primary.reply));
      final _LineCall call = primary.calls.single;
      expect(call.vertical, isTrue);
      expect(call.lineHints!.map(_ltrb), <List<double>>[
        <double>[200, 105, 230, 195],
        <double>[150, 105, 180, 195],
      ]);
      expect(routingDet.crops, hasLength(1));
      expect(primary.plainCalls, 0);
    });

    test('批路由：主识别器也能逐行识别时，整块的块逐块走逐行识别、不发整框批次', () async {
      final _FakeBatchLinePrimary primary = _FakeBatchLinePrimary();
      final RoutingOcrRecognizer routed = RoutingOcrRecognizer(
        mangaOcr: primary,
        lineDetector: _FakeLineDetector(<PpTextLine>[_line(0, 0, 180, 40)]),
        lineRecognizer: _ConstLineRecognizer('P'),
      );
      expect(routed, isA<BatchOcrRecognizer>());
      const List<OcrRect> boxes = <OcrRect>[
        OcrRect(left: 300, top: 0, right: 340, bottom: 150),
        OcrRect(left: 20, top: 0, right: 220, bottom: 50),
        OcrRect(left: 350, top: 0, right: 390, bottom: 150),
      ];

      final List<OcrRecognition> out = await routed.recognizeOriented(
        page,
        boxes,
      );

      expect(out[0], same(primary.reply));
      expect(out[1].text, 'P');
      expect(out[1].vertical, isFalse);
      expect(out[2], same(primary.reply));
      expect(primary.calls.map((_LineCall c) => c.box), <OcrRect>[
        boxes[0],
        boxes[2],
      ]);
      expect(primary.batches, isEmpty);
      expect(primary.plainCalls, 0);
    });

    test('pipeline：CTC 作路由主识别器，逐列文本与列框原样落成 OcrBlock', () async {
      final _FakeLineDetector ctcDet = _FakeLineDetector(_bubbleLines());
      final _FakeLineDetector routingDet = _FakeLineDetector(<PpTextLine>[]);
      final OcrPageResult result = await MangaOcrPipeline(
        detector: _FixedRegionDetector(<OcrRect>[_bubble]),
        recognizer: RoutingOcrRecognizer(
          mangaOcr: CtcColumnOcrRecognizer(
            lineDetector: ctcDet,
            lineRecognizer: _ColorReadingRecognizer(_columnText),
          ),
          lineDetector: routingDet,
          lineRecognizer: _ConstLineRecognizer('P'),
        ),
      ).processPage(pageIndex: 0, image: _bubblePage());

      final OcrBlock block = result.blocks.single;
      expect(block.vertical, isTrue);
      expect(block.lines, <String>['右列', '中列', '左列']);
      expect(block.lineBoxes!.map((OcrRect r) => r.left), <double>[
        270,
        240,
        210,
      ]);
      expect(ctcDet.crops, hasLength(1));
      expect(routingDet.crops, isEmpty);
    });
  });
}
