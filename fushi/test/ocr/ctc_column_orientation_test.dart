// 本机 Manga CTC 把字距比列距大的竖排（疏排、斜体）读成横排：行检测器沿小空隙把
// 字连成横行，方向投票跟着判成横排，逐行读出「しど言 / てんっ / くなた」这样串列的
// 字（JMangaBench_Read 10140115_0；前 1,480 框里竖长块投出横排的 28 例有 25 例
// 如此）。竖长块投出横排时，逐列识别器把裁图横向拉宽重检一次，列能被连出来就按
// 竖排读；也覆盖横跨多列的检出框不再触发连锁合并（10091317_1）。
import 'package:test/test.dart';
import 'package:fushi_engine/ocr/ctc_column_ocr_recognizer.dart';
import 'package:fushi_engine/ocr/ocr_glyph_boxes.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/ppocr_line_detector.dart';
import 'package:fushi_engine/ocr/ppocr_line_recognizer.dart';
import 'package:image/image.dart' as img;

class _DeadSession implements OcrSession {
  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) =>
      throw StateError('fake must not run a session');

  @override
  Future<void> close() async {}
}

PpTextLine _line(double l, double t, double r, double b) => PpTextLine(
  rect: OcrRect(left: l, top: t, right: r, bottom: b),
  score: 1,
);

/// 原尺寸裁图吐 [native]，横向拉宽过的裁图（宽度不等于 [nativeWidth]）吐
/// [stretched]（拉宽后的坐标）；记下每次收到的裁图宽度。
class _StretchAwareDetector extends PpOcrLineDetector {
  _StretchAwareDetector({
    required this.nativeWidth,
    required this.native,
    required this.stretched,
  }) : super(_DeadSession());

  final int nativeWidth;
  final List<PpTextLine> native;
  final List<PpTextLine> stretched;
  final List<int> widths = <int>[];

  @override
  Future<List<PpTextLine>> detect(img.Image crop) async {
    widths.add(crop.width);
    return crop.width == nativeWidth ? native : stretched;
  }
}

class _ConstLineRecognizer extends PpOcrLineRecognizer {
  _ConstLineRecognizer() : super(_DeadSession(), vocab: const <String>['']);

  @override
  Future<PpOcrPositionedLine> recognizeLinePositioned(img.Image line) async =>
      const PpOcrPositionedLine(
        text: '字',
        confidence: null,
        tokens: <OcrLineToken>[],
      );
}

img.Image _blank(int width, int height) {
  final img.Image image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  return image;
}

/// 三列竖排被检成的六条横行（裁图 100×220）。
final List<PpTextLine> _rows = <PpTextLine>[
  for (int i = 0; i < 6; i++) _line(2, 5 + i * 36, 98, 38 + i * 36),
];

void main() {
  test('竖长块投出横排：横向拉宽重检出列，按竖排逐列读', () async {
    final _StretchAwareDetector detector = _StretchAwareDetector(
      nativeWidth: 100,
      native: _rows,
      // 拉宽 2 倍后的坐标：三列各 60 宽。
      stretched: <PpTextLine>[
        _line(4, 5, 64, 215),
        _line(70, 5, 130, 215),
        _line(136, 5, 196, 180),
      ],
    );
    final OcrRecognition result =
        await CtcColumnOcrRecognizer(
          lineDetector: detector,
          lineRecognizer: _ConstLineRecognizer(),
        ).recognizeWithLines(
          _blank(100, 220),
          const OcrRect(left: 0, top: 0, right: 100, bottom: 220),
          vertical: true,
        );
    expect(detector.widths, <int>[100, 200]);
    expect(result.vertical, isTrue);
    expect(result.lines, hasLength(3));
    // 行框换回原裁图坐标（x 减半），阅读序从右到左。
    expect(result.lineBoxes!.first.left, 68);
    expect(result.lineBoxes!.first.right, 98);
    expect(result.lineBoxes!.last.left, 2);
  });

  test('拉宽后仍是横行的真横排保持横排', () async {
    final _StretchAwareDetector detector = _StretchAwareDetector(
      nativeWidth: 100,
      native: _rows,
      stretched: <PpTextLine>[
        for (int i = 0; i < 6; i++) _line(4, 5 + i * 36, 196, 38 + i * 36),
      ],
    );
    final OcrRecognition result =
        await CtcColumnOcrRecognizer(
          lineDetector: detector,
          lineRecognizer: _ConstLineRecognizer(),
        ).recognizeWithLines(
          _blank(100, 220),
          const OcrRect(left: 0, top: 0, right: 100, bottom: 220),
          vertical: true,
        );
    expect(detector.widths, <int>[100, 200]);
    expect(result.vertical, isFalse);
    expect(result.lines, hasLength(6));
  });

  test('宽扁块投出横排不重检', () async {
    final _StretchAwareDetector detector = _StretchAwareDetector(
      nativeWidth: 300,
      native: <PpTextLine>[_line(5, 5, 295, 45), _line(5, 55, 295, 95)],
      stretched: const <PpTextLine>[],
    );
    final OcrRecognition result =
        await CtcColumnOcrRecognizer(
          lineDetector: detector,
          lineRecognizer: _ConstLineRecognizer(),
        ).recognizeWithLines(
          _blank(300, 100),
          const OcrRect(left: 0, top: 0, right: 300, bottom: 100),
          vertical: false,
        );
    expect(detector.widths, <int>[300]);
    expect(result.vertical, isFalse);
  });

  test('压在三列列首上的横框不再把三列并成一列', () async {
    // JMangaBench_Read 10091317_1 的真实检出框（裁图 116×337）。
    final _StretchAwareDetector detector = _StretchAwareDetector(
      nativeWidth: 116,
      native: <PpTextLine>[
        _line(5, 8, 116, 57),
        _line(37, 41, 84, 303),
        _line(75, 42, 115, 266),
        _line(5, 46, 47, 337),
      ],
      stretched: const <PpTextLine>[],
    );
    final OcrRecognition result =
        await CtcColumnOcrRecognizer(
          lineDetector: detector,
          lineRecognizer: _ConstLineRecognizer(),
        ).recognizeWithLines(
          _blank(116, 337),
          const OcrRect(left: 0, top: 0, right: 116, bottom: 337),
          vertical: true,
        );
    expect(result.lines, hasLength(3));
    for (final OcrRect column in result.lineBoxes!) {
      expect(column.top, 8, reason: '列首那个字并回各列');
    }
  });
}
