import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/ocr/gal_lookup_calibration_ocr.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/ppocr_line_detector.dart';
import 'package:fushi_engine/ocr/ppocr_line_recognizer.dart';
import 'package:image/image.dart' as img;

class _NoopSession implements OcrSession {
  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) async =>
      <String, OcrTensor>{};

  @override
  Future<void> close() async {}
}

class _FakeDetector extends PpOcrLineDetector {
  _FakeDetector(this.line) : super(_NoopSession());

  final PpTextLine line;
  final List<img.Image> inputs = <img.Image>[];

  @override
  Future<List<PpTextLine>> detect(img.Image crop) async {
    inputs.add(crop);
    return <PpTextLine>[line];
  }
}

class _FakeRecognizer extends PpOcrLineRecognizer {
  _FakeRecognizer(this.buildRecognition)
    : super(_NoopSession(), vocab: const <String>['']);

  final PpOcrLineRecognition Function(img.Image line) buildRecognition;
  final List<img.Image> inputs = <img.Image>[];

  @override
  Future<PpOcrLineRecognition> recognizeLineDetailed(img.Image line) async {
    inputs.add(line);
    return buildRecognition(line);
  }
}

const GalLookupReferenceClientV1 _client = GalLookupReferenceClientV1(
  widthPx: 20,
  heightPx: 12,
  dpi: 96,
);

const GalLookupNormalizedRectV1 _selection = GalLookupNormalizedRectV1(
  left: .25,
  top: .25,
  width: .5,
  height: .5,
);

img.Image _sourceImage() {
  final img.Image image = img.Image(width: 20, height: 12, numChannels: 4);
  for (int y = 0; y < image.height; y++) {
    for (int x = 0; x < image.width; x++) {
      image.setPixelRgba(x, y, x * 11 % 256, y * 17 % 256, x + y, 255);
    }
  }
  return image;
}

Uint8List _sourcePng() => Uint8List.fromList(img.encodePng(_sourceImage()));

List<int> _rgb(img.Image image, int x, int y) {
  final img.Pixel pixel = image.getPixel(x, y);
  return <int>[pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt()];
}

PpOcrCtcToken _token(
  String text, {
  required double left,
  required double right,
}) => PpOcrCtcToken(
  tokenId: 1,
  text: text,
  frameStart: 0,
  frameEndExclusive: 1,
  inputLeft: left,
  inputRight: right,
  left: left,
  right: right,
  confidence: .99,
);

PpOcrCtcToken _unpositionedToken(String text) => PpOcrCtcToken(
  tokenId: 1,
  text: text,
  frameStart: 0,
  frameEndExclusive: 1,
  inputLeft: 0,
  inputRight: 1,
  left: null,
  right: null,
  confidence: .99,
);

PpOcrLineRecognition _recognition(
  img.Image line, {
  required String text,
  required List<PpOcrCtcToken> tokens,
}) => PpOcrLineRecognition(
  text: text,
  tokens: tokens,
  lineWidth: line.width,
  lineHeight: line.height,
  contentWidth: line.width,
  inputWidth: line.width,
);

Future<List<GalCalibrationOcrLine>> _read({
  required _FakeDetector detector,
  required _FakeRecognizer recognizer,
}) => GalCalibrationOcrEngine.forTesting(
  detector: detector,
  recognizer: recognizer,
).read(_sourcePng(), _selection, _client);

void main() {
  test(
    'detector/recognizer only receive selected pixels and map padding back',
    () async {
      final _FakeDetector detector = _FakeDetector(
        const PpTextLine(
          rect: OcrRect(left: 4, top: 3, right: 10, bottom: 6),
          score: .99,
        ),
      );
      final _FakeRecognizer recognizer = _FakeRecognizer(
        (img.Image line) => _recognition(
          line,
          text: 'あ',
          tokens: <PpOcrCtcToken>[_token('あ', left: 3, right: 5)],
        ),
      );

      final List<GalCalibrationOcrLine> lines = await _read(
        detector: detector,
        recognizer: recognizer,
      );

      expect(detector.inputs, hasLength(1));
      expect(detector.inputs.single.width, 14);
      expect(detector.inputs.single.height, 10);
      for (int y = 0; y < detector.inputs.single.height; y++) {
        for (int x = 0; x < detector.inputs.single.width; x++) {
          final int sourceX = 5 + (x - 2).clamp(0, 9);
          final int sourceY = 3 + (y - 2).clamp(0, 5);
          expect(
            _rgb(detector.inputs.single, x, y),
            _rgb(_sourceImage(), sourceX, sourceY),
          );
        }
      }

      expect(recognizer.inputs, hasLength(1));
      expect(recognizer.inputs.single.width, 10);
      expect(recognizer.inputs.single.height, 7);
      for (int y = 0; y < recognizer.inputs.single.height; y++) {
        for (int x = 0; x < recognizer.inputs.single.width; x++) {
          final int sourceX = 7 + (x - 2).clamp(0, 5);
          final int sourceY = 4 + (y - 2).clamp(0, 2);
          expect(
            _rgb(recognizer.inputs.single, x, y),
            _rgb(_sourceImage(), sourceX, sourceY),
          );
        }
      }

      expect(lines, hasLength(1));
      expect(lines.single.text, 'あ');
      expect(lines.single.rect.left, 7);
      expect(lines.single.rect.top, 4);
      expect(lines.single.rect.right, 13);
      expect(lines.single.rect.bottom, 7);
      expect(lines.single.tokens.single.rect.left, 8);
      expect(lines.single.tokens.single.rect.top, 4);
      expect(lines.single.tokens.single.rect.right, 10);
      expect(lines.single.tokens.single.rect.bottom, 7);
    },
  );

  test(
    'short tail without positioned tokens remains an OCR candidate',
    () async {
      final _FakeDetector detector = _FakeDetector(
        const PpTextLine(
          rect: OcrRect(left: 4, top: 3, right: 12, bottom: 6),
          score: .99,
        ),
      );
      final _FakeRecognizer recognizer = _FakeRecognizer(
        (img.Image line) => _recognition(
          line,
          text: '」',
          tokens: <PpOcrCtcToken>[_unpositionedToken('」')],
        ),
      );

      final List<GalCalibrationOcrLine> lines = await _read(
        detector: detector,
        recognizer: recognizer,
      );

      expect(lines, hasLength(1));
      expect(lines.single.text, '」');
      expect(lines.single.tokens.single.confidence, 0);
    },
  );

  test(
    'positioned token touching a horizontal crop edge remains a candidate',
    () async {
      final _FakeDetector detector = _FakeDetector(
        const PpTextLine(
          rect: OcrRect(left: 4, top: 3, right: 12, bottom: 6),
          score: .99,
        ),
      );
      final _FakeRecognizer recognizer = _FakeRecognizer(
        (img.Image line) => _recognition(
          line,
          text: 'あ',
          // line padding is 2; after it is removed, right == lineCrop.width.
          tokens: <PpOcrCtcToken>[_token('あ', left: 7, right: 10)],
        ),
      );

      expect(
        await _read(detector: detector, recognizer: recognizer),
        hasLength(1),
      );
    },
  );

  test(
    'vertical crop-edge contact alone does not reject a positioned line',
    () async {
      final _FakeDetector detector = _FakeDetector(
        const PpTextLine(
          rect: OcrRect(left: 4, top: 2, right: 10, bottom: 5),
          score: .99,
        ),
      );
      final _FakeRecognizer recognizer = _FakeRecognizer(
        (img.Image line) => _recognition(
          line,
          text: 'あ',
          tokens: <PpOcrCtcToken>[_token('あ', left: 4, right: 6)],
        ),
      );

      expect(
        await _read(detector: detector, recognizer: recognizer),
        hasLength(1),
      );
    },
  );
}
