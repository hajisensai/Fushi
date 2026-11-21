import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_engine/ocr/nar_ocr_recognizer.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/ppocr_line_detector.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

/// 按第几次调用回一组 id，记下每次输入的格子行列数（`H` / `W`）。
class _FakeNarSession implements OcrSession {
  _FakeNarSession(this.reply, {this.int32 = true});

  final List<int> Function(int call) reply;

  /// true = FFI 后端的口径（int32），false = 插件后端的口径（整数读成 float32）。
  final bool int32;
  final List<List<int>> grids = <List<int>>[];
  final List<Map<String, OcrTensor>> inputs = <Map<String, OcrTensor>>[];

  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) async {
    this.inputs.add(inputs);
    grids.add(<int>[
      inputs['H']!.int32Data!.single,
      inputs['W']!.int32Data!.single,
    ]);
    final List<int> ids = _padIds(reply(grids.length - 1));
    return <String, OcrTensor>{
      'ids': int32
          ? OcrTensor.int32(Int32List.fromList(ids), const <int>[
              kNarMaxOutputLength,
            ])
          : OcrTensor.float32(
              Float32List.fromList(<double>[for (final int i in ids) i * 1.0]),
              const <int>[kNarMaxOutputLength],
            ),
    };
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

/// 测试字表：id 0 = あ、1 = い、2 = う、3 = え，其余是占位字；结束符是 6817。
final List<String> _vocab = parseNarVocab(
  jsonEncode(<String, Object?>{
    'characters': <String>[
      'あ',
      'い',
      'う',
      'え',
      for (int i = 4; i < kNarVocabSize; i++) '□',
    ],
  }),
);

/// 文本 id 后面补结束符到 65 位（模型输出的形状）。
List<int> _padIds(List<int> ids) => <int>[
  ...ids,
  for (int i = ids.length; i < kNarMaxOutputLength; i++) kNarVocabSize,
];

img.Image _solid(int width, int height, int r, int g, int b) {
  final img.Image image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return image;
}

PpTextLine _line(double left, double top, double right, double bottom) =>
    PpTextLine(
      rect: OcrRect(left: left, top: top, right: right, bottom: bottom),
      score: 0.9,
    );

void main() {
  group('narGrid (upstream pad_grid)', () {
    test('fills the 324-patch budget without exceeding it', () {
      for (final List<int> size in <List<int>>[
        <int>[200, 60],
        <int>[60, 200],
        <int>[252, 252],
        <int>[1902, 2600],
        <int>[17, 911],
      ]) {
        final NarGrid grid = narGrid(size[0], size[1]);
        expect(
          grid.rows * grid.cols,
          lessThanOrEqualTo(kNarPatchBudget),
          reason: '$size',
        );
        expect(grid.rows, (size[0] * grid.scale / kNarPatch).ceil());
        expect(grid.cols, (size[1] * grid.scale / kNarPatch).ceil());
        // 再大一点点就超预算：比例取到了上界。
        final double more = grid.scale * 1.0001;
        expect(
          (size[0] * more / kNarPatch).ceil() *
              (size[1] * more / kNarPatch).ceil(),
          greaterThan(kNarPatchBudget),
          reason: '$size',
        );
      }
    });

    test('a square crop gets an 18 x 18 grid', () {
      final NarGrid grid = narGrid(252, 252);
      expect(grid.rows, 18);
      expect(grid.cols, 18);
      expect(grid.scale, closeTo(1.0, 1e-9));
    });
  });

  group('parseNarVocab', () {
    test('reads the characters list', () {
      expect(_vocab, hasLength(kNarVocabSize));
      expect(_vocab.take(4), <String>['あ', 'い', 'う', 'え']);
    });

    test('rejects a vocabulary of the wrong size or shape', () {
      expect(
        () => parseNarVocab(
          jsonEncode(<String, Object?>{
            'characters': <String>['あ'],
          }),
        ),
        throwsFormatException,
      );
      expect(() => parseNarVocab('{}'), throwsFormatException);
      expect(() => parseNarVocab('[]'), throwsFormatException);
    });
  });

  group('decodeNarIds', () {
    test('cuts at the first end-of-text id', () {
      final NarText read = decodeNarIds(
        _padIds(<int>[0, 1, kNarVocabSize, 2]),
        _vocab,
      );
      expect(read.text, 'あい');
      expect(read.truncated, isFalse);
    });

    test('all 65 positions used means the text may be cut short', () {
      final NarText read = decodeNarIds(
        List<int>.filled(kNarMaxOutputLength, 3),
        _vocab,
      );
      expect(read.text, 'え' * kNarMaxOutputLength);
      expect(read.truncated, isTrue);
    });

    test('an id outside the vocabulary is a contract error', () {
      expect(
        () => decodeNarIds(<int>[kNarVocabSize + 1], _vocab),
        throwsStateError,
      );
      expect(() => decodeNarIds(<int>[-1], _vocab), throwsStateError);
    });
  });

  group('narPreprocess (upstream preprocess)', () {
    test('patch layout, padding and the six inputs', () {
      // 28×14 的裁图：左半纯红、右半纯蓝。放大后仍是左红右蓝，格子画布 13×25
      // （比例约 12.6）。
      final img.Image crop = img.Image(width: 28, height: 14);
      for (int y = 0; y < 14; y++) {
        for (int x = 0; x < 28; x++) {
          crop.setPixelRgb(x, y, x < 14 ? 255 : 0, 0, x < 14 ? 0 : 255);
        }
      }
      final NarGrid grid = narGrid(14, 28);
      final NarInput input = narPreprocess(crop);
      expect(input.gridRows, grid.rows);
      expect(input.gridCols, grid.cols);
      final int cells = grid.rows * grid.cols;
      expect(cells, lessThanOrEqualTo(kNarPatchBudget));

      expect(input.patches, hasLength(kNarPatchBudget * kNarPatchFeatures));
      expect(input.valid.take(cells), everyElement(1.0));
      expect(input.valid.skip(cells), everyElement(0.0));
      for (int cell = 0; cell < cells; cell++) {
        expect(input.rows[cell], cell ~/ grid.cols);
        expect(input.cols[cell], cell % grid.cols);
      }
      expect(input.rows.skip(cells), everyElement(0));
      expect(input.cols.skip(cells), everyElement(0));
      // 补位的格子全 0（不是填充色）。
      expect(input.patches.skip(cells * kNarPatchFeatures), everyElement(0.0));

      // 通道在前：每格前 196 个是 R，再 196 个 G，再 196 个 B；按 CLIP 均值方差
      // 归一化。第一格在纯红区。
      double norm(int v, double mean, double std) => (v / 255.0 - mean) / std;
      const int plane = kNarPatch * kNarPatch;
      expect(
        input.patches[0],
        closeTo(norm(255, 0.48145466, 0.26862954), 1e-5),
      );
      expect(
        input.patches[plane],
        closeTo(norm(0, 0.4578275, 0.26130258), 1e-5),
      );
      expect(
        input.patches[2 * plane],
        closeTo(norm(0, 0.40821073, 0.27577711), 1e-5),
      );
      // 第一行最后一格在纯蓝区。
      final int lastInRow = (grid.cols - 1) * kNarPatchFeatures;
      expect(
        input.patches[lastInRow + 2 * plane + plane - 1],
        closeTo(norm(255, 0.40821073, 0.27577711), 1e-5),
      );

      final Map<String, OcrTensor> tensors = input.toTensors();
      expect(tensors.keys, <String>['P', 'V', 'R', 'C', 'H', 'W']);
      expect(tensors['P']!.shape, <int>[kNarPatchBudget, kNarPatchFeatures]);
      expect(tensors['V']!.shape, <int>[kNarPatchBudget]);
      expect(tensors['R']!.type, OcrTensorType.int32);
      expect(tensors['C']!.shape, <int>[kNarPatchBudget]);
      expect(tensors['H']!.int32Data, <int>[grid.rows]);
      expect(tensors['W']!.int32Data, <int>[grid.cols]);
    });

    test('the canvas beyond the resized image is the border median', () {
      // 100×30：格子画布比缩放后的图多出一条，多出的像素是填充色（这里是纯色图，
      // 填充色就是图本身的颜色），不是 0。
      final NarInput input = narPreprocess(_solid(100, 30, 40, 80, 120));
      final int cells = input.gridRows * input.gridCols;
      const double r = (40 / 255.0 - 0.48145466) / 0.26862954;
      for (int cell = 0; cell < cells; cell++) {
        expect(
          input.patches[cell * kNarPatchFeatures + kNarPatch * kNarPatch - 1],
          closeTo(r, 1e-5),
          reason: 'cell $cell',
        );
      }
    });
  });

  group('NarOcrRecognizer', () {
    for (final bool int32 in <bool>[true, false]) {
      test('whole block in one call, text laid out on the detected columns '
          '(${int32 ? 'FFI int32' : 'plugin float32'})', () async {
        final _FakeNarSession session = _FakeNarSession(
          (int _) => <int>[0, 1, 2, 3],
          int32: int32,
        );
        // 两列竖排，右列在前（裁图坐标；块左上角在页面 (100, 50)）。
        final _FakeLineDetector det = _FakeLineDetector(<PpTextLine>[
          _line(10, 5, 40, 95),
          _line(60, 5, 90, 95),
        ]);
        final NarOcrRecognizer recognizer = NarOcrRecognizer(
          session,
          vocab: _vocab,
          lineDetector: det,
        );
        final OcrRecognition r = await recognizer.recognizeWithLines(
          _solid(400, 400, 255, 255, 255),
          const OcrRect(left: 100, top: 50, right: 200, bottom: 150),
          vertical: false,
        );
        expect(session.grids, hasLength(1));
        expect(det.calls, 1);
        expect(r.text, 'あいうえ');
        expect(r.vertical, isTrue, reason: 'voted from the columns');
        expect(r.lines, <String>['あい', 'うえ']);
        expect(r.lines!.join(), r.text);
        expect(r.lineBoxes, hasLength(2));
        expect(r.lineBoxes!.first.left, 160, reason: 'right column first');
        expect(r.lineBoxes!.last.left, 110);
        expect(r.glyphBoxes, isNull, reason: 'the model gives no boxes');
        expect(r.confidence, isNull, reason: 'the model gives no scores');
      });
    }

    test('no detected lines: the block text without line geometry', () async {
      final _FakeNarSession session = _FakeNarSession((int _) => <int>[0]);
      final NarOcrRecognizer recognizer = NarOcrRecognizer(
        session,
        vocab: _vocab,
        lineDetector: _FakeLineDetector(const <PpTextLine>[]),
      );
      final img.Image page = _solid(400, 400, 255, 255, 255);
      const OcrRect box = OcrRect(left: 100, top: 50, right: 160, bottom: 250);
      final OcrRecognition r = await recognizer.recognizeWithLines(
        page,
        box,
        vertical: true,
      );
      expect(r.text, 'あ');
      expect(r.lines, isNull);
      expect(r.vertical, isTrue);
      expect(await recognizer.recognize(page, box), 'あ');
      expect(
        (await recognizer.recognizeOriented(page, <OcrRect>[box])),
        hasLength(1),
      );
    });

    test('all output positions used: re-read line by line', () async {
      // 第一次（整块）65 位全满；之后每行各读一次。
      final _FakeNarSession session = _FakeNarSession(
        (int call) => call == 0
            ? List<int>.filled(kNarMaxOutputLength, 3)
            : <int>[call - 1],
      );
      final _FakeLineDetector det = _FakeLineDetector(<PpTextLine>[
        _line(10, 5, 40, 95),
        _line(60, 5, 90, 95),
      ]);
      final NarOcrRecognizer recognizer = NarOcrRecognizer(
        session,
        vocab: _vocab,
        lineDetector: det,
      );
      final OcrRecognition r = await recognizer.recognizeWithLines(
        _solid(400, 400, 255, 255, 255),
        const OcrRect(left: 100, top: 50, right: 200, bottom: 150),
        vertical: true,
      );
      expect(session.grids, hasLength(3));
      expect(r.lines, <String>['あ', 'い']);
      expect(r.text, 'あい');
      expect(r.lineBoxes!.first.left, 160);
    });

    test('a block too large for the budget is read line by line', () async {
      final _FakeNarSession session = _FakeNarSession(
        (int call) => <int>[call],
      );
      // 2000×1500 块缩放比例约 0.15；行厚 40 px → 输入里约 6 px，读不清。
      final _FakeLineDetector det = _FakeLineDetector(<PpTextLine>[
        _line(1900, 100, 1940, 900),
        _line(1800, 100, 1840, 900),
      ]);
      final NarOcrRecognizer recognizer = NarOcrRecognizer(
        session,
        vocab: _vocab,
        lineDetector: det,
      );
      final OcrRecognition r = await recognizer.recognizeWithLines(
        _solid(2000, 1500, 255, 255, 255),
        const OcrRect(left: 0, top: 0, right: 2000, bottom: 1500),
        vertical: true,
      );
      expect(session.grids, hasLength(2), reason: 'never the whole block');
      expect(r.lines, <String>['あ', 'い']);
      expect(r.lineBoxes, hasLength(2));
    });

    test('a downscaled block with readable lines is still one call', () async {
      final _FakeNarSession session = _FakeNarSession((int _) => <int>[0, 1]);
      // 600×600 块缩放比例约 0.42；行厚 80 px → 输入里约 34 px，够读。
      final _FakeLineDetector det = _FakeLineDetector(<PpTextLine>[
        _line(500, 10, 580, 590),
        _line(400, 10, 480, 590),
      ]);
      final NarOcrRecognizer recognizer = NarOcrRecognizer(
        session,
        vocab: _vocab,
        lineDetector: det,
      );
      final OcrRecognition r = await recognizer.recognizeWithLines(
        _solid(600, 600, 255, 255, 255),
        const OcrRect(left: 0, top: 0, right: 600, bottom: 600),
        vertical: true,
      );
      expect(session.grids, hasLength(1));
      expect(r.text, 'あい');
      expect(r.lines, <String>['あ', 'い']);
    });

    test('an empty read gives an empty block', () async {
      final NarOcrRecognizer recognizer = NarOcrRecognizer(
        _FakeNarSession((int _) => const <int>[]),
        vocab: _vocab,
        lineDetector: _FakeLineDetector(<PpTextLine>[_line(10, 5, 40, 95)]),
      );
      final OcrRecognition r = await recognizer.recognizeWithLines(
        _solid(400, 400, 255, 255, 255),
        const OcrRect(left: 100, top: 50, right: 200, bottom: 150),
        vertical: true,
      );
      expect(r.text, isEmpty);
      expect(r.lines, isNull);
    });
  });
}
