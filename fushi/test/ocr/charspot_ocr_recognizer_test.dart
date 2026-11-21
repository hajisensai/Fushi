import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_engine/ocr/charspot_ocr_recognizer.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/ppocr_line_detector.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

/// 按输入张量形状回一组 charspot 输出，记下每次输入的 [H, W]。
class _FakeCharspotSession implements OcrSession {
  _FakeCharspotSession(this.reply);

  final Map<String, OcrTensor> Function(int height, int width) reply;
  final List<List<int>> inputs = <List<int>>[];

  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) async {
    final OcrTensor input = inputs['img']!;
    this.inputs.add(<int>[input.shape[2], input.shape[3]]);
    return reply(input.shape[2], input.shape[3]);
  }

  @override
  Future<void> close() async {}
}

class _DeadSession implements OcrSession {
  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) =>
      throw StateError('fake must not run a session');

  @override
  Future<void> close() async {}
}

/// 固定吐出 [lines]（裁图坐标）的行检测器，记下调用次数。
class _FakeLineDetector extends PpOcrLineDetector {
  _FakeLineDetector(this.lines) : super(_DeadSession());

  final List<PpTextLine> lines;
  int calls = 0;

  @override
  Future<List<PpTextLine>> detect(img.Image crop) async {
    calls++;
    return lines;
  }
}

/// charspot 输出：插件后端的口径（整数读成 float32）或 FFI 后端的口径（int64）。
Map<String, OcrTensor> _outputs(
  List<List<double>> boxes,
  List<int> ids,
  List<int> order, {
  bool int64 = true,
}) {
  final int n = ids.length;
  return <String, OcrTensor>{
    'boxes': OcrTensor.float32(
      Float32List.fromList(<double>[for (final List<double> b in boxes) ...b]),
      <int>[n, 4],
    ),
    'scores': OcrTensor.float32(
      Float32List.fromList(<double>[for (int i = 0; i < n; i++) 0.9 - i / 100]),
      <int>[n],
    ),
    'ids': int64
        ? OcrTensor.int64(Int64List.fromList(ids), <int>[n])
        : OcrTensor.float32(
            Float32List.fromList(<double>[for (final int i in ids) i * 1.0]),
            <int>[n],
          ),
    'order': int64
        ? OcrTensor.int64(Int64List.fromList(order), <int>[n])
        : OcrTensor.float32(
            Float32List.fromList(<double>[for (final int i in order) i * 1.0]),
            <int>[n],
          ),
  };
}

/// 测试字表：id 0 = あ、1 = い、2 = う、3 = え，其余补空串，再接组合字。
final List<String> _vocab = parseCharspotVocab(
  jsonEncode(<String, Object?>{
    'characters': <String>['あ', 'い', 'う', 'え'],
  }),
);

CharspotChar _char(String text, double cx, double cy, {double size = 20}) =>
    CharspotChar(
      text: text,
      rect: OcrRect(
        left: cx - size / 2,
        top: cy - size / 2,
        right: cx + size / 2,
        bottom: cy + size / 2,
      ),
      score: 0.9,
    );

img.Image _solid(int width, int height, int r, int g, int b) {
  final img.Image image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return image;
}

void main() {
  group('charspotGrid (upstream pad_grid)', () {
    // 期望值由上游 core.pad_grid 算出（2026-11-14）。
    test('matches the Python reference', () {
      final CharspotGrid a = charspotGrid(734, 317, budget: 256);
      expect((a.rows, a.cols), (24, 10));
      expect(a.scale, closeTo(0.5047318611987375, 1e-9));
      final CharspotGrid b = charspotGrid(325, 93, budget: 256);
      expect((b.rows, b.cols), (28, 9));
      final CharspotGrid c = charspotGrid(325, 93, budget: 196);
      expect((c.rows, c.cols), (25, 7));
      expect(c.scale, closeTo(1.2043010752688166, 1e-9));
      final CharspotGrid d = charspotGrid(40, 1000, budget: 256);
      expect((d.rows, d.cols), (3, 75));
      final CharspotGrid e = charspotGrid(10, 10, budget: 256);
      expect((e.rows, e.cols), (16, 16));
      expect(e.scale, closeTo(25.6, 1e-9));
      final CharspotGrid f = charspotGrid(2400, 1080, budget: 256);
      expect((f.rows, f.cols), (23, 11));
      expect(f.scale, closeTo(0.1533333333333326, 1e-9));
    });
  });

  group('charspotPreprocess', () {
    test('grid size, resized size, scale factors and padding colour', () {
      final CharspotInput input = charspotPreprocess(
        _solid(317, 734, 10, 120, 240),
        budget: 256,
      );
      // 上游：gh 24、gw 10、rw 160、rh 370、比例 (1.98125, 1.98378…)。
      expect(input.width, 160);
      expect(input.height, 384);
      expect(input.resizedWidth, 160);
      expect(input.resizedHeight, 370);
      expect(input.scaleXFor(317), closeTo(1.98125, 1e-9));
      expect(input.scaleYFor(734), closeTo(1.9837837837837837, 1e-9));
      expect(input.fillColor, <int>[10, 120, 240]);
      expect(input.data.length, 3 * 160 * 384);
      const int plane = 160 * 384;
      // 填充区（第 380 行）与图内（第 10 行）都是 RGB 原值，不归一化。
      for (final int y in <int>[10, 380]) {
        expect(input.data[y * 160 + 5], 10);
        expect(input.data[plane + y * 160 + 5], 120);
        expect(input.data[2 * plane + y * 160 + 5], 240);
      }
    });

    test('padding colour is the truncated per-channel border median', () {
      // 2×1 图：边框 = 首行 + 末行 + 首列 + 末列 = a,b,a,b,a,b → 偶数个，取中间
      // 两个的平均后截断（上游 np.median(...).astype(uint8)）。
      final Uint8List rgb = Uint8List.fromList(<int>[1, 1, 1, 2, 4, 255]);
      expect(charspotBorderMedian(rgb, width: 2, height: 1), <int>[1, 2, 128]);
    });

    test('downscaling uses area averaging, upscaling bilinear', () {
      expect(
        charspotInterpolation(
          fromWidth: 317,
          fromHeight: 734,
          toWidth: 160,
          toHeight: 370,
        ),
        img.Interpolation.average,
      );
      expect(
        charspotInterpolation(
          fromWidth: 93,
          fromHeight: 325,
          toWidth: 128,
          toHeight: 448,
        ),
        img.Interpolation.linear,
      );
    });
  });

  group('parseCharspotVocab', () {
    test('pads to the class count and appends the !? glyphs', () {
      expect(_vocab, hasLength(kCharspotClassCount + 12));
      expect(_vocab.take(4), <String>['あ', 'い', 'う', 'え']);
      expect(_vocab[4], '');
      expect(_vocab[kCharspotClassCount - 1], '');
      expect(_vocab.sublist(kCharspotClassCount), <String>[
        '!!',
        '!?',
        '?!',
        '??',
        '!!!',
        '!!?',
        '!?!',
        '!??',
        '?!!',
        '?!?',
        '??!',
        '???',
      ]);
    });

    test('rejects a vocabulary larger than the model classes', () {
      expect(
        () => parseCharspotVocab(
          jsonEncode(<String, Object?>{
            'characters': List<String>.filled(kCharspotClassCount + 1, 'x'),
          }),
        ),
        throwsFormatException,
      );
      expect(() => parseCharspotVocab('{}'), throwsFormatException);
    });
  });

  group('decodeCharspotOutputs', () {
    for (final bool int64 in <bool>[true, false]) {
      test(
        'reading order, scale and origin (${int64 ? 'FFI int64' : 'plugin float32'})',
        () {
          final List<CharspotChar> chars = decodeCharspotOutputs(
            _outputs(
              <List<double>>[
                <double>[0, 20, 10, 30],
                <double>[0, 0, 10, 10],
              ],
              <int>[1, kCharspotClassCount + 1],
              <int>[1, 0],
              int64: int64,
            ),
            vocab: _vocab,
            scaleX: 2,
            scaleY: 3,
            originX: 100,
            originY: 50,
            cropWidth: 1000,
            cropHeight: 1000,
          );
          expect(chars.map((CharspotChar c) => c.text), <String>['!?', 'い']);
          expect(chars.first.rect.left, 100);
          expect(chars.first.rect.right, 120);
          expect(chars.first.rect.top, 50);
          expect(chars.first.rect.bottom, 80);
          expect(chars.last.rect.top, 110);
          expect(chars.last.rect.bottom, 140);
          expect(chars.first.score, closeTo(0.89, 1e-6));
        },
      );
    }

    test('boxes are clamped to the crop', () {
      // The model works on the padded grid canvas: a box may reach into the
      // padding (or below zero), which is outside the crop on the page.
      final List<CharspotChar> chars = decodeCharspotOutputs(
        _outputs(
          <List<double>>[
            <double>[-4, -2, 10, 10],
            <double>[40, 90, 70, 130],
            <double>[60, 120, 80, 140],
          ],
          <int>[1, 1, 1],
          <int>[0, 1, 2],
        ),
        vocab: _vocab,
        scaleX: 2,
        scaleY: 1,
        originX: 100,
        originY: 50,
        cropWidth: 100,
        cropHeight: 100,
      );
      expect(chars, hasLength(3), reason: 'the reading is not edited');
      for (final CharspotChar c in chars) {
        expect(c.rect.left, inInclusiveRange(100, 200));
        expect(c.rect.right, inInclusiveRange(100, 200));
        expect(c.rect.top, inInclusiveRange(50, 150));
        expect(c.rect.bottom, inInclusiveRange(50, 150));
      }
      expect(chars[0].rect.left, 100);
      expect(chars[0].rect.top, 50);
      expect(chars[1].rect.right, 200);
      expect(chars[1].rect.bottom, 150);
      // Entirely in the padding: collapses onto the crop edge.
      expect(chars[2].rect.width, 0);
      expect(chars[2].rect.height, 0);
    });

    test('zero characters decode to an empty list', () {
      expect(
        decodeCharspotOutputs(
          _outputs(const <List<double>>[], const <int>[], const <int>[]),
          vocab: _vocab,
          scaleX: 1,
          scaleY: 1,
          originX: 0,
          originY: 0,
          cropWidth: 1000,
          cropHeight: 1000,
        ),
        isEmpty,
      );
    });

    test('an id outside the vocabulary is a contract error', () {
      expect(
        () => decodeCharspotOutputs(
          _outputs(
            <List<double>>[
              <double>[0, 0, 1, 1],
            ],
            <int>[_vocab.length],
            <int>[0],
          ),
          vocab: _vocab,
          scaleX: 1,
          scaleY: 1,
          originX: 0,
          originY: 0,
          cropWidth: 1000,
          cropHeight: 1000,
        ),
        throwsStateError,
      );
    });
  });

  group('groupCharspotLines', () {
    test('vertical: two columns read right to left', () {
      final CharspotLayout layout = groupCharspotLines(<CharspotChar>[
        _char('あ', 100, 20),
        _char('い', 100, 42),
        // 句读点在竖排里偏右上，仍属同一列。
        _char('、', 106, 58, size: 10),
        _char('う', 100, 72),
        _char('え', 70, 20),
        _char('あ', 70, 42),
      ], fallbackVertical: false);
      expect(layout.vertical, isTrue);
      expect(layout.lines.map((CharspotLine l) => l.text), <String>[
        'あい、う',
        'えあ',
      ]);
      final OcrRect first = layout.lines.first.box;
      expect(first.left, 90);
      expect(first.top, 10);
      expect(first.right, 111);
      expect(first.bottom, 82);
    });

    test('horizontal: two rows read top to bottom', () {
      final CharspotLayout layout = groupCharspotLines(<CharspotChar>[
        _char('あ', 20, 100),
        _char('い', 42, 100),
        _char('う', 64, 100),
        _char('え', 20, 130),
        _char('あ', 42, 130),
      ], fallbackVertical: true);
      expect(layout.vertical, isFalse);
      expect(layout.lines.map((CharspotLine l) => l.text), <String>[
        'あいう',
        'えあ',
      ]);
    });

    test('a single character keeps the caller orientation', () {
      for (final bool vertical in <bool>[true, false]) {
        final CharspotLayout layout = groupCharspotLines(<CharspotChar>[
          _char('あ', 20, 20),
        ], fallbackVertical: vertical);
        expect(layout.vertical, vertical);
        expect(layout.lines.single.text, 'あ');
      }
    });

    test('padding ids (empty strings) are dropped', () {
      final CharspotLayout layout = groupCharspotLines(<CharspotChar>[
        _char('', 20, 20),
      ], fallbackVertical: true);
      expect(layout.lines, isEmpty);
    });
  });

  group('charspotRecognition', () {
    test('lines join to the text; glyph boxes follow UTF-16 offsets', () {
      final OcrRecognition r = charspotRecognition(
        groupCharspotLines(<CharspotChar>[
          _char('あ', 100, 20),
          _char('!?', 100, 42),
          _char('い', 70, 20),
        ], fallbackVertical: true),
      );
      expect(r.vertical, isTrue);
      expect(r.text, 'あ!?い');
      expect(r.lines, <String>['あ!?', 'い']);
      expect(r.lines!.join(), r.text);
      expect(r.lineBoxes, hasLength(2));
      expect(
        r.glyphBoxes!.map((OcrGlyphBox g) => (g.start, g.end)),
        <(int, int)>[(0, 1), (1, 3), (3, 4)],
      );
      expect(ocrGlyphBoxesFitText(r.glyphBoxes!, r.text), isTrue);
      expect(r.glyphBoxes![1].rect.top, 32);
      expect(r.confidence, closeTo(0.9, 1e-9));
    });

    test('no characters is an empty recognition without geometry', () {
      final OcrRecognition r = charspotRecognition((
        vertical: true,
        lines: const <CharspotLine>[],
      ));
      expect(r.text, isEmpty);
      expect(r.lines, isNull);
      expect(r.glyphBoxes, isNull);
    });
  });

  group('CharspotOcrRecognizer', () {
    // 每次推理在输入正中回一个「あ」（边长 = 输入短边的一半）。
    Map<String, OcrTensor> centreChar(int h, int w) {
      final double s = (h < w ? h : w) / 4;
      return _outputs(
        <List<double>>[
          <double>[w / 2 - s, h / 2 - s, w / 2 + s, h / 2 + s],
        ],
        <int>[0],
        <int>[0],
      );
    }

    test(
      'a block that fits the budget is read in one call, no detection',
      () async {
        final _FakeCharspotSession session = _FakeCharspotSession(centreChar);
        final _FakeLineDetector det = _FakeLineDetector(const <PpTextLine>[]);
        final CharspotOcrRecognizer recognizer = CharspotOcrRecognizer(
          session,
          vocab: _vocab,
          cellBudget: kCharspotSmallCellBudget,
          lineDetector: det,
        );
        final img.Image page = _solid(400, 400, 255, 255, 255);
        final OcrRecognition r = await recognizer.recognizeWithLines(
          page,
          const OcrRect(left: 100, top: 50, right: 160, bottom: 250),
          vertical: true,
        );
        expect(det.calls, 0);
        expect(session.inputs, hasLength(1));
        expect(r.text, 'あ');
        // 字框换回页面坐标，落在块里（fake 把字放在填充后输入的正中，略偏右下）。
        final OcrRect glyph = r.glyphBoxes!.single.rect;
        expect(glyph.centerX, inInclusiveRange(100, 160));
        expect(glyph.centerY, inInclusiveRange(50, 250));
        final List<OcrRecognition> oriented = await recognizer
            .recognizeOriented(page, const <OcrRect>[
              OcrRect(left: 100, top: 50, right: 160, bottom: 250),
            ]);
        expect(oriented.single.text, 'あ');
      },
    );

    test('a downscaled block with readable lines is still one call', () async {
      final _FakeCharspotSession session = _FakeCharspotSession(centreChar);
      // 600×600 块缩放比例约 0.43；行厚 80 px → 输入里约 34 px，够读。
      final _FakeLineDetector det = _FakeLineDetector(const <PpTextLine>[
        PpTextLine(
          rect: OcrRect(left: 500, top: 10, right: 580, bottom: 590),
          score: 0.9,
        ),
        PpTextLine(
          rect: OcrRect(left: 400, top: 10, right: 480, bottom: 590),
          score: 0.9,
        ),
      ]);
      final CharspotOcrRecognizer recognizer = CharspotOcrRecognizer(
        session,
        vocab: _vocab,
        cellBudget: kCharspotSmallCellBudget,
        lineDetector: det,
      );
      final OcrRecognition r = await recognizer.recognizeWithLines(
        _solid(600, 600, 255, 255, 255),
        const OcrRect(left: 0, top: 0, right: 600, bottom: 600),
        vertical: true,
      );
      expect(det.calls, 1);
      expect(session.inputs, hasLength(1));
      expect(r.text, 'あ');
    });

    test('a block too large for the budget is read line by line', () async {
      final _FakeCharspotSession session = _FakeCharspotSession(centreChar);
      // 2000×1500 块缩放比例约 0.14；行厚 40 px → 输入里约 6 px，读不清。
      final _FakeLineDetector det = _FakeLineDetector(const <PpTextLine>[
        PpTextLine(
          rect: OcrRect(left: 1900, top: 100, right: 1940, bottom: 900),
          score: 0.9,
        ),
        PpTextLine(
          rect: OcrRect(left: 1840, top: 100, right: 1880, bottom: 700),
          score: 0.9,
        ),
      ]);
      final CharspotOcrRecognizer recognizer = CharspotOcrRecognizer(
        session,
        vocab: _vocab,
        cellBudget: kCharspotSmallCellBudget,
        lineDetector: det,
      );
      final OcrRecognition r = await recognizer.recognizeWithLines(
        _solid(2000, 1500, 255, 255, 255),
        const OcrRect(left: 0, top: 0, right: 2000, bottom: 1500),
        vertical: false,
      );
      expect(det.calls, 1);
      // 每列一次推理，不整块读。
      expect(session.inputs, hasLength(2));
      expect(r.vertical, isTrue);
      expect(r.lines, <String>['あ', 'あ']);
      // 右列先读，字落在各自的列框里。
      expect(r.lineBoxes!.first.centerX, inInclusiveRange(1900, 1940));
      expect(r.lineBoxes!.last.centerX, inInclusiveRange(1840, 1880));
    });

    test('line hints from the caller replace detection', () async {
      final _FakeCharspotSession session = _FakeCharspotSession(centreChar);
      final _FakeLineDetector det = _FakeLineDetector(const <PpTextLine>[]);
      final CharspotOcrRecognizer recognizer = CharspotOcrRecognizer(
        session,
        vocab: _vocab,
        cellBudget: kCharspotNanoCellBudget,
        lineDetector: det,
      );
      final OcrRecognition r = await recognizer.recognizeWithLines(
        _solid(2000, 1500, 255, 255, 255),
        const OcrRect(left: 0, top: 0, right: 2000, bottom: 1500),
        vertical: true,
        lineHints: const <OcrRect>[
          OcrRect(left: 100, top: 100, right: 900, bottom: 140),
        ],
      );
      expect(det.calls, 0);
      expect(r.vertical, isFalse);
      expect(r.text, 'あ');
    });

    test('an empty model result is an empty recognition', () async {
      final CharspotOcrRecognizer recognizer = CharspotOcrRecognizer(
        _FakeCharspotSession(
          (int h, int w) =>
              _outputs(const <List<double>>[], const <int>[], const <int>[]),
        ),
        vocab: _vocab,
        cellBudget: kCharspotSmallCellBudget,
        lineDetector: _FakeLineDetector(const <PpTextLine>[]),
      );
      final OcrRecognition r = await recognizer.recognizeWithLines(
        _solid(100, 100, 255, 255, 255),
        const OcrRect(left: 0, top: 0, right: 100, bottom: 100),
        vertical: true,
      );
      expect(r.text, isEmpty);
      expect(r.lines, isNull);
    });

    test('readable-line check: empty detections never force a line split', () {
      expect(charspotLinesReadableAt(const <OcrRect>[], 0.01), isTrue);
      const OcrRect line = OcrRect(left: 0, top: 0, right: 40, bottom: 400);
      expect(charspotLinesReadableAt(const <OcrRect>[line], 0.5), isTrue);
      expect(charspotLinesReadableAt(const <OcrRect>[line], 0.3), isFalse);
    });
  });
}
