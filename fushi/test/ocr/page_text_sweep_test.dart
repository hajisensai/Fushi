import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/page_text_sweep.dart';
import 'package:fushi_engine/ocr/ppocr_line_detector.dart';
import 'package:fushi_engine/ocr/ppocr_line_recognizer.dart';
import 'package:image/image.dart' as img;

OcrRect _r(double l, double t, double r, double b) =>
    OcrRect(left: l, top: t, right: r, bottom: b);

List<double> _ltrb(OcrRect r) => <double>[r.left, r.top, r.right, r.bottom];

DetectedTextRegion _weak(OcrRect rect, double score) => DetectedTextRegion(
  rect: rect,
  score: score,
  classId: 2,
  insideBubble: false,
);

class _DeadSession implements OcrSession {
  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) =>
      throw StateError('fake must not run a session');

  @override
  Future<void> close() async {}
}

/// 页面上「真实存在」的行：检行时只交回落进区域的部分（裁图边界截断行），
/// 记下每次检行的区域。
class _PageLineDetector extends PpOcrLineDetector {
  _PageLineDetector(this.pageLines) : super(_DeadSession());

  final List<OcrRect> pageLines;
  final List<OcrRect> regions = <OcrRect>[];

  @override
  Future<List<OcrRect>> detectInBlock(img.Image page, OcrRect box) async {
    regions.add(box);
    return <OcrRect>[
      for (final OcrRect line in pageLines)
        if (line.right > box.left &&
            line.left < box.right &&
            line.bottom > box.top &&
            line.top < box.bottom)
          OcrRect(
            left: line.left < box.left ? box.left : line.left,
            top: line.top < box.top ? box.top : line.top,
            right: line.right > box.right ? box.right : line.right,
            bottom: line.bottom > box.bottom ? box.bottom : line.bottom,
          ),
    ];
  }
}

/// 按行图宽度认字：整行宽度对得上才给全文，被截断的行只读出前半截。
class _WidthReadingRecognizer extends PpOcrLineRecognizer {
  _WidthReadingRecognizer(this.byWidth, {this.confidence = 0.97})
    : super(_DeadSession(), vocab: const <String>['']);

  final Map<int, String> byWidth;
  final double confidence;

  @override
  Future<PpOcrLineRecognition> recognizeLineDetailed(img.Image line) async {
    final String text = byWidth[line.width] ?? 'モテる';
    return PpOcrLineRecognition(
      text: text,
      tokens: <PpOcrCtcToken>[
        for (int i = 0; i < text.length; i++)
          PpOcrCtcToken(
            tokenId: i + 1,
            text: text[i],
            frameStart: i,
            frameEndExclusive: i + 1,
            inputLeft: i.toDouble(),
            inputRight: i + 1,
            left: i.toDouble(),
            right: i + 1,
            confidence: confidence,
          ),
      ],
      lineWidth: line.width,
      lineHeight: line.height,
      contentWidth: line.width,
      inputWidth: line.width,
    );
  }
}

void main() {
  final img.Image page = img.Image(width: 1000, height: 1000);
  // 用户真实页的稀疏标题：第一行「モテる女子の」宽 500，第二行「オキテ」宽 300。
  final OcrRect row1 = _r(100, 500, 600, 560);
  final OcrRect row2 = _r(150, 570, 450, 630);

  group('PpOcrPageTextSweeper', () {
    test('弱候选只框住半行：外扩检行、截断就延长，两行读全并成一块', () async {
      final _PageLineDetector detector = _PageLineDetector(<OcrRect>[
        row1,
        row2,
      ]);
      final PpOcrPageTextSweeper sweeper = PpOcrPageTextSweeper(
        lineDetector: detector,
        lineRecognizer: _WidthReadingRecognizer(<int, String>{
          500: 'モテる女子の',
          300: 'オキテ',
        }),
      );
      final List<OcrBlock> blocks = await sweeper.sweep(
        page,
        candidates: <DetectedTextRegion>[
          _weak(_r(100, 500, 400, 560), 0.125),
          _weak(_r(160, 575, 380, 630), 0.021),
        ],
        covered: const <OcrRect>[],
      );

      expect(blocks, hasLength(1));
      expect(blocks.single.lines, <String>['モテる女子の', 'オキテ']);
      expect(blocks.single.vertical, isFalse);
      expect(blocks.single.lineBoxes!.map(_ltrb), <List<double>>[
        _ltrb(row1),
        _ltrb(row2),
      ]);
      // 第一次检行区域在「の」之前截断，之后向右延长。
      expect(detector.regions.length, greaterThan(1));
      expect(detector.regions.first.right, lessThan(row1.right));
      expect(detector.regions.last.right, greaterThanOrEqualTo(row1.right));
    });

    test('读出来不是日文（水印）的块不收', () async {
      final PpOcrPageTextSweeper sweeper = PpOcrPageTextSweeper(
        lineDetector: _PageLineDetector(<OcrRect>[_r(100, 900, 400, 950)]),
        lineRecognizer: _WidthReadingRecognizer(<int, String>{
          300: 'DL-Raw.Se',
        }),
      );
      final List<OcrBlock> blocks = await sweeper.sweep(
        page,
        candidates: <DetectedTextRegion>[_weak(_r(100, 900, 400, 950), 0.2)],
        covered: const <OcrRect>[],
      );
      expect(blocks, isEmpty);
    });

    test('读得没把握（画面笔触）的块不收', () async {
      final PpOcrPageTextSweeper sweeper = PpOcrPageTextSweeper(
        lineDetector: _PageLineDetector(<OcrRect>[row1]),
        lineRecognizer: _WidthReadingRecognizer(<int, String>{
          500: 'モテる女子の',
        }, confidence: 0.5),
      );
      final List<OcrBlock> blocks = await sweeper.sweep(
        page,
        candidates: <DetectedTextRegion>[_weak(row1, 0.2)],
        covered: const <OcrRect>[],
      );
      expect(blocks, isEmpty);
    });

    test('落在已有文字块里的弱候选、分太低的团都不复核', () async {
      final _PageLineDetector detector = _PageLineDetector(<OcrRect>[row1]);
      final PpOcrPageTextSweeper sweeper = PpOcrPageTextSweeper(
        lineDetector: detector,
        lineRecognizer: _WidthReadingRecognizer(const <int, String>{}),
      );
      final List<OcrBlock> blocks = await sweeper.sweep(
        page,
        candidates: <DetectedTextRegion>[
          _weak(_r(110, 505, 590, 555), 0.2), // 已被正式块覆盖
          _weak(_r(100, 100, 300, 160), 0.03), // 团最高分不到门槛
        ],
        covered: <OcrRect>[row1],
      );
      expect(blocks, isEmpty);
      expect(detector.regions, isEmpty);
    });
  });

  group('clusterOcrSweepCandidates', () {
    test('并进交叠最深的团，不被先建的隔壁团抢走', () {
      // 「夏は恋しなきゃ」竖列先建团（分更高）；标题的「モ」离它 38 px，在间距上限
      // 内、并进去也不超面积上限，但被标题框整个包住——应当归标题。面积上限取用户
      // 真实页（1350×2083）的 8%，它把竖列与标题分成两团。
      final DetectedTextRegion natsu = _weak(_r(680, 560, 836, 1378), 0.286);
      final DetectedTextRegion title = _weak(_r(870, 1023, 1343, 1279), 0.057);
      final DetectedTextRegion mo = _weak(_r(874, 1046, 940, 1126), 0.047);
      final List<List<DetectedTextRegion>> clusters = clusterOcrSweepCandidates(
        <DetectedTextRegion>[natsu, title, mo],
        maxArea: 0.08 * 1350 * 2083,
      );
      expect(clusters, hasLength(2));
      expect(clusters[1], <DetectedTextRegion>[title, mo]);
    });

    test('并进去会超出面积上限就另起一团', () {
      final List<List<DetectedTextRegion>> clusters = clusterOcrSweepCandidates(
        <DetectedTextRegion>[
          _weak(_r(0, 0, 100, 100), 0.2),
          _weak(_r(110, 0, 210, 100), 0.1),
        ],
        maxArea: 15000,
      );
      expect(clusters, hasLength(2));
    });
  });

  group('growOcrSweepRegion', () {
    test('横行碰到左右边界就往那头延长，碰不到返回 null', () {
      final OcrRect region = _r(100, 480, 470, 650);
      final OcrRect? grown = growOcrSweepRegion(
        region,
        <OcrRect>[_r(100, 500, 470, 560)],
        vertical: false,
        pageWidth: 1000,
        pageHeight: 1000,
      );
      expect(grown, isNotNull);
      expect(grown!.right, 470 + 2 * 60);
      expect(grown.left, 0); // 100 - 2 * 60 夹到页边
      expect(grown.top, region.top);
      expect(
        growOcrSweepRegion(
          region,
          <OcrRect>[_r(150, 500, 400, 560)],
          vertical: false,
          pageWidth: 1000,
          pageHeight: 1000,
        ),
        isNull,
      );
    });

    test('已经贴着页边的不再延长', () {
      expect(
        growOcrSweepRegion(
          _r(0, 0, 1000, 100),
          <OcrRect>[_r(0, 10, 1000, 60)],
          vertical: false,
          pageWidth: 1000,
          pageHeight: 1000,
        ),
        isNull,
      );
    });
  });

  group('pickOcrSweepOrientation', () {
    test('全是近方形单字时按合并后行数少的方向定：两列竖排', () {
      final List<OcrRect> chars = <OcrRect>[
        for (int i = 0; i < 4; i++) ...<OcrRect>[
          _r(200, 100.0 + i * 80, 250, 150.0 + i * 80), // 右列
          _r(120, 100.0 + i * 80, 170, 150.0 + i * 80), // 左列
        ],
      ];
      expect(pickOcrSweepOrientation(chars, _r(120, 100, 250, 390)), isTrue);
    });

    test('全是近方形单字时按合并后行数少的方向定：一行横排', () {
      final List<OcrRect> chars = <OcrRect>[
        for (int i = 0; i < 5; i++)
          _r(100.0 + i * 80, 500, 150.0 + i * 80, 560),
      ];
      expect(pickOcrSweepOrientation(chars, _r(100, 500, 470, 560)), isFalse);
    });
  });

  group('acceptOcrSweepText', () {
    test('置信度与日文门槛', () {
      expect(acceptOcrSweepText('モテる女子の', 0.95), isTrue);
      expect(acceptOcrSweepText('モテる女子の', 0.6), isFalse);
      expect(acceptOcrSweepText('DL-Raw.Se', 0.99), isFalse);
      expect(acceptOcrSweepText('あ', 0.99), isFalse);
      expect(acceptOcrSweepText('7月号', 0.99), isTrue);
      expect(acceptOcrSweepText('ガララ', 0.99), isTrue);
    });
  });
}
