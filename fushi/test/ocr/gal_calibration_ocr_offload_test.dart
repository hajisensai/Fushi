// HBK-AUDIT-009: GalCalibrationOcrEngine.read used to run every pure step on
// the calling (UI) isolate: Dart decodePng (plus copying the decoded image
// back), copyCrop, the per-pixel edge padding, det/rec pre/post-processing and
// CTC decoding. It now runs them in three background Isolate.run stages around
// the two session.run calls. This file pins three things:
// 1. field-for-field parity with the pre-change synchronous implementation
//    (kept verbatim below as the reference, driven on this isolate);
// 2. the three stages really run on their named background isolates;
// 3. a stale fit (dialog closed) stops at the next boundary, never touches the
//    second sample, and still closes both sessions.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_capture.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_draft.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_image_fit.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_preview.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/ocr/gal_lookup_calibration_ocr.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/ppocr_line_detector.dart';
import 'package:fushi_engine/ocr/ppocr_line_recognizer.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

const int _width = 1920;
const int _height = 1080;

const GalLookupReferenceClientV1 _client = GalLookupReferenceClientV1(
  widthPx: _width,
  heightPx: _height,
  dpi: 96,
);

const GalLookupNormalizedRectV1 _selection = GalLookupNormalizedRectV1(
  left: .05,
  top: .62,
  width: .9,
  height: .34,
);

const List<String> _dict = <String>['あ', 'い', 'う', 'え', 'お'];
final List<String> _vocab = buildPpOcrCtcVocab(_dict);

/// Text rows: (top, left, character count). Glyphs are 32x36 dark blocks with
/// 8 px gaps; the background is a bright, non-uniform gradient so a pixel
/// mismatch between decoders, crops or edge padding changes the fake outputs.
/// The first row starts left of the selection and the last runs past its right
/// edge, so both detector edge paddings carry text.
const List<(int, int, int)> _rows = <(int, int, int)>[
  (720, 60, 20),
  (830, 200, 12),
  (940, 1500, 9),
];
const int _glyph = 32;
const int _gap = 8;
const int _rowHeight = 36;

img.Image _syntheticCapture({int channels = 4}) {
  final img.Image image = img.Image(
    width: _width,
    height: _height,
    numChannels: channels,
  );
  for (int y = 0; y < _height; y++) {
    for (int x = 0; x < _width; x++) {
      int r = 196 + (x * 7 + y * 3) % 56;
      int g = 206 + (x + y * 5) % 46;
      int b = 214 + (x * 3 + y) % 38;
      for (final (int top, int rowLeft, int count) in _rows) {
        if (y < top || y >= top + _rowHeight) continue;
        final int dx = x - rowLeft;
        if (dx < 0 || dx >= count * (_glyph + _gap)) continue;
        if (dx % (_glyph + _gap) >= _glyph) continue;
        r = 12 + (x * 5 + y * 3) % 40;
        g = 18 + (x + y) % 30;
        b = 10 + (x * 3 + y * 7) % 36;
      }
      image.setPixelRgba(x, y, r, g, b, 255 - (x + y) % 3);
    }
  }
  return image;
}

final Map<int, Uint8List> _pngCache = <int, Uint8List>{};

Uint8List _png({int channels = 4}) => _pngCache.putIfAbsent(
  channels,
  () =>
      Uint8List.fromList(img.encodePng(_syntheticCapture(channels: channels))),
);

/// Deterministic detector: a pixel is "text" when channel 0 (B, normalized) is
/// dark; the probability map dilates text 6 px horizontally so the glyphs of a
/// row merge into one connected component. Text probabilities also follow the
/// pixel value, so line scores depend on the exact input tensor.
class _DetSession implements OcrSession {
  int runs = 0;
  bool closed = false;
  void Function()? onRun;

  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) async {
    runs++;
    final OcrTensor input = inputs.values.single;
    final int h = input.shape[2];
    final int w = input.shape[3];
    final Float32List data = input.floatData!;
    final Float32List prob = Float32List(w * h);
    const int radius = 6;
    for (int y = 0; y < h; y++) {
      final Int32List prefix = Int32List(w + 1);
      for (int x = 0; x < w; x++) {
        prefix[x + 1] = prefix[x] + (data[y * w + x] < 0 ? 1 : 0);
      }
      for (int x = 0; x < w; x++) {
        final int lo = math.max(0, x - radius);
        final int hi = math.min(w, x + radius + 1);
        final double value = data[y * w + x];
        prob[y * w + x] = prefix[hi] - prefix[lo] > 0
            ? .6 + .3 * (value.abs() / 3).clamp(0, 1)
            : .05;
      }
    }
    onRun?.call();
    return <String, OcrTensor>{
      'prob': OcrTensor.float32(prob, <int>[1, 1, h, w]),
    };
  }

  @override
  Future<void> close() async => closed = true;
}

/// Deterministic recognizer: one frame per 4 input columns; a frame with at
/// least 20 % dark pixels emits the next character (cycling the dictionary) at
/// each light-to-dark transition, other frames emit blank. Logit magnitudes
/// follow the frame's darkness so confidences differ per token.
class _RecSession implements OcrSession {
  int runs = 0;
  bool closed = false;

  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) async {
    runs++;
    final OcrTensor input = inputs.values.single;
    final int h = input.shape[2];
    final int w = input.shape[3];
    final Float32List data = input.floatData!;
    const int frameWidth = 4;
    final int frames = w ~/ frameWidth;
    final int vocabSize = _vocab.length;
    final Float32List logits = Float32List(frames * vocabSize);
    int run = -1;
    bool wasDark = false;
    for (int t = 0; t < frames; t++) {
      int darkPixels = 0;
      double sum = 0;
      for (int y = 0; y < h; y++) {
        for (int x = t * frameWidth; x < (t + 1) * frameWidth; x++) {
          final double value = data[y * w + x];
          sum += value;
          if (value < -.2) darkPixels++;
        }
      }
      final double mean = sum / (h * frameWidth);
      final double darkness = darkPixels / (h * frameWidth);
      final bool dark = darkness >= .2;
      if (dark && !wasDark) run++;
      wasDark = dark;
      final int token = dark ? 1 + run % _dict.length : 0;
      for (int v = 0; v < vocabSize; v++) {
        logits[t * vocabSize + v] = (v * 3 + t) % 5 * .1;
      }
      logits[t * vocabSize + token] = 2 + darkness * 3 + mean * .5;
    }
    return <String, OcrTensor>{
      'logits': OcrTensor.float32(logits, <int>[1, frames, vocabSize]),
    };
  }

  @override
  Future<void> close() async => closed = true;
}

GalCalibrationOcrEngine _engine(_DetSession det, _RecSession rec) =>
    GalCalibrationOcrEngine.forTesting(
      detector: PpOcrLineDetector(det),
      recognizer: PpOcrLineRecognizer(rec, vocab: _vocab),
    );

// ---------------------------------------------------------------------------
// Reference: GalCalibrationOcrEngine.read as it was before HBK-AUDIT-009,
// verbatim except that `compute(img.decodePng, ...)` is a direct call and the
// private helpers carry a `_ref` prefix. Runs entirely on the test isolate.
// ---------------------------------------------------------------------------

Future<List<GalCalibrationOcrLine>> _referenceRead(
  PpOcrLineDetector detector,
  PpOcrLineRecognizer recognizer,
  Uint8List pngBytes,
  GalLookupNormalizedRectV1 rect,
  GalLookupReferenceClientV1 client,
) async {
  final img.Image? decoded = img.decodePng(pngBytes);
  if (decoded == null ||
      decoded.width != client.widthPx ||
      decoded.height != client.heightPx) {
    throw const FormatException('ocr_capture_decode_failed');
  }
  final GalLookupNormalizedRectV1 searchRect = rect;
  final int left = (searchRect.left * decoded.width).floor().clamp(
    0,
    decoded.width - 1,
  );
  final int top = (searchRect.top * decoded.height).floor().clamp(
    0,
    decoded.height - 1,
  );
  final int right = (searchRect.right * decoded.width).ceil().clamp(
    left + 1,
    decoded.width,
  );
  final int bottom = (searchRect.bottom * decoded.height).ceil().clamp(
    top + 1,
    decoded.height,
  );
  final img.Image crop = img.copyCrop(
    decoded,
    x: left,
    y: top,
    width: right - left,
    height: bottom - top,
  );
  final int detectorPadding = _refOcrEdgePadding(
    crop,
    maxPadding: _refMaxDetectorCropPadding,
  );
  final ({img.Image image, int padding}) detectorInput =
      _refCopyWithReplicatedEdge(crop, detectorPadding);
  final List<({PpTextLine line, OcrRect unpaddedRect})> detected =
      [
          for (final PpTextLine paddedLine in await detector.detect(
            detectorInput.image,
          ))
            if (_refUnpaddedDetectorRect(
                  paddedLine.rect,
                  detectorInput.padding,
                ).clamp(crop.width.toDouble(), crop.height.toDouble()).width >
                0)
              (
                line: PpTextLine(
                  rect: _refUnpaddedDetectorRect(
                    paddedLine.rect,
                    detectorInput.padding,
                  ).clamp(crop.width.toDouble(), crop.height.toDouble()),
                  score: paddedLine.score,
                ),
                unpaddedRect: _refUnpaddedDetectorRect(
                  paddedLine.rect,
                  detectorInput.padding,
                ),
              ),
        ]
        ..removeWhere((({PpTextLine line, OcrRect unpaddedRect}) item) {
          return item.line.vertical || item.line.rect.height <= 0;
        })
        ..sort(
          (
            ({PpTextLine line, OcrRect unpaddedRect}) a,
            ({PpTextLine line, OcrRect unpaddedRect}) b,
          ) => a.line.rect.centerY.compareTo(b.line.rect.centerY),
        );
  final List<GalCalibrationOcrLine> result = <GalCalibrationOcrLine>[];
  for (final ({PpTextLine line, OcrRect unpaddedRect}) detectedLine
      in detected) {
    final PpTextLine line = detectedLine.line;
    final int x = detectedLine.unpaddedRect.left.floor().clamp(
      0,
      crop.width - 1,
    );
    final int y = detectedLine.unpaddedRect.top.floor().clamp(
      0,
      crop.height - 1,
    );
    final int r = detectedLine.unpaddedRect.right.ceil().clamp(
      x + 1,
      crop.width,
    );
    final int b = detectedLine.unpaddedRect.bottom.ceil().clamp(
      y + 1,
      crop.height,
    );
    final img.Image lineCrop = img.copyCrop(
      crop,
      x: x,
      y: y,
      width: r - x,
      height: b - y,
    );
    final int linePadding = _refOcrEdgePadding(
      lineCrop,
      maxPadding: _refMaxRecognizerLinePadding,
    );
    final ({img.Image image, int padding}) lineInput =
        _refCopyWithReplicatedEdge(lineCrop, linePadding);
    final PpOcrLineRecognition recognition = await recognizer
        .recognizeLineDetailed(lineInput.image);
    final String text = recognition.text;
    if (text.trim().isEmpty) continue;
    result.add(
      GalCalibrationOcrLine(
        text: text,
        rect: OcrRect(
          left: left + line.rect.left,
          top: top + line.rect.top,
          right: left + line.rect.right,
          bottom: top + line.rect.bottom,
        ),
        score: line.score,
        tokens: <GalCalibrationOcrToken>[
          for (final PpOcrCtcToken token in recognition.tokens)
            GalCalibrationOcrToken(
              token.text,
              OcrRect(
                left:
                    left +
                    x +
                    (token.left == null ? 0 : token.left! - lineInput.padding),
                top: (top + y).toDouble(),
                right:
                    left +
                    x +
                    (token.right == null
                        ? 0
                        : token.right! - lineInput.padding),
                bottom: (top + b).toDouble(),
              ).clamp(decoded.width.toDouble(), decoded.height.toDouble()),
              token.hasPosition ? token.confidence : 0,
            ),
        ],
      ),
    );
  }
  return result;
}

const int _refMaxDetectorCropPadding = 8;
const int _refMaxRecognizerLinePadding = 4;

int _refOcrEdgePadding(img.Image image, {required int maxPadding}) {
  final int shortest = math.min(image.width, image.height);
  return math.min(maxPadding, math.max(2, shortest ~/ 24));
}

({img.Image image, int padding}) _refCopyWithReplicatedEdge(
  img.Image source,
  int padding,
) {
  final img.Image result = img.Image(
    width: source.width + padding * 2,
    height: source.height + padding * 2,
    numChannels: 4,
  );
  for (int y = 0; y < result.height; y++) {
    final int sourceY = (y - padding).clamp(0, source.height - 1);
    for (int x = 0; x < result.width; x++) {
      final int sourceX = (x - padding).clamp(0, source.width - 1);
      final img.Pixel pixel = source.getPixel(sourceX, sourceY);
      result.setPixelRgba(x, y, pixel.r, pixel.g, pixel.b, pixel.a);
    }
  }
  return (image: result, padding: padding);
}

OcrRect _refUnpaddedDetectorRect(OcrRect rect, int padding) => OcrRect(
  left: rect.left - padding,
  top: rect.top - padding,
  right: rect.right - padding,
  bottom: rect.bottom - padding,
);

// ---------------------------------------------------------------------------

String _rect(OcrRect r) => '${r.left},${r.top},${r.right},${r.bottom}';

/// Every field of every line and token, exactly (doubles via toString, which
/// round-trips).
List<String> _describe(List<GalCalibrationOcrLine> lines) => <String>[
  for (final GalCalibrationOcrLine line in lines) ...<String>[
    'line|${line.text}|${_rect(line.rect)}|${line.score}',
    for (final GalCalibrationOcrToken token in line.tokens)
      '  token|${token.text}|${_rect(token.rect)}|${token.confidence}|'
          '${token.synthetic}',
  ],
];

GalLookupCalibrationCapture _capture(Uint8List png, String occurrenceId) =>
    GalLookupCalibrationCapture(
      sourceText: 'あいうえおあいうえお',
      pngBytes: png,
      referenceClient: _client,
      exePath: r'C:\synthetic\game.exe',
      exeSha256: 'a' * 64,
      sessionEpoch: 1,
      occurrenceId: occurrenceId,
      targetHwnd: 1,
      capturedAt: DateTime.utc(2026, 10, 19),
      selectedThreadKey: 'synthetic',
    );

Future<GalCalibrationPreview> _noPreview({
  required String text,
  required GalLookupReferenceClientV1 client,
  required GalLookupNormalizedRectV1 rect,
  required GalLookupTextLayoutV1 layout,
}) => throw StateError('preview must not be built for a stale fit');

class _Factory implements OcrSessionFactory {
  _Factory(this.det, this.rec);

  final _DetSession det;
  final _RecSession rec;
  int created = 0;

  @override
  Future<Set<OcrExecutionProvider>> availableAcceleratedProviders() async =>
      const <OcrExecutionProvider>{};

  @override
  Future<int?> deviceMemoryBudgetBytes() async => null;

  @override
  Future<OcrSession> createSession(
    String modelPath, {
    required List<OcrExecutionProvider> providers,
    void Function(OcrProviderResolution resolution)? onProviderResolved,
    int? intraOpNumThreads,
    Map<String, int>? freeDimensionOverrides,
  }) async {
    created++;
    return switch (p.basename(modelPath)) {
      kPpOcrDetFileName => det,
      kPpOcrRecFileName => rec,
      _ => throw StateError('unexpected model $modelPath'),
    };
  }
}

void main() {
  for (final int channels in <int>[4, 3]) {
    test('background stages match the pre-change synchronous read '
        'field for field ($channels-channel PNG)', () async {
      final Uint8List png = _png(channels: channels);

      final _DetSession refDet = _DetSession();
      final _RecSession refRec = _RecSession();
      final List<GalCalibrationOcrLine> expected = await _referenceRead(
        PpOcrLineDetector(refDet),
        PpOcrLineRecognizer(refRec, vocab: _vocab),
        png,
        _selection,
        _client,
      );

      final _DetSession det = _DetSession();
      final _RecSession rec = _RecSession();
      final List<GalCalibrationOcrLine>? actual = await _engine(
        det,
        rec,
      ).read(png, _selection, _client);

      // The fixture must exercise multiple lines and positioned tokens,
      // otherwise parity is vacuous.
      expect(expected.length, greaterThanOrEqualTo(2));
      expect(
        expected
            .expand((GalCalibrationOcrLine l) => l.tokens)
            .where((GalCalibrationOcrToken t) => t.confidence > 0)
            .length,
        greaterThanOrEqualTo(4),
      );
      expect(actual, isNotNull);
      expect(_describe(actual!), _describe(expected));
      // Same session traffic: one detection, one recognition per line.
      expect(det.runs, refDet.runs);
      expect(rec.runs, refRec.runs);
    });
  }

  test(
    'the three pure stages run on their named background isolates',
    () async {
      final String? testIsolate = Isolate.current.debugName;
      final List<GalCalibrationOcrLine>? lines = await _engine(
        _DetSession(),
        _RecSession(),
      ).read(_png(), _selection, _client);

      expect(lines, isNotNull);
      expect(lines, isNotEmpty);
      expect(debugLastGalCalibrationOcrStageIsolates, <String>[
        kGalCalibrationOcrPrepareIsolateName,
        kGalCalibrationOcrPlanIsolateName,
        kGalCalibrationOcrDecodeIsolateName,
      ]);
      for (final String? name in debugLastGalCalibrationOcrStageIsolates) {
        expect(name, isNot(testIsolate));
      }
    },
  );

  test('a recognizer output that does not fit the dictionary fails on the '
      'first line, like the synchronous read did', () async {
    // Recognition runs line by line and decoding is batched afterwards; the
    // shape / vocabulary check must still stop the read at the first line
    // instead of running every remaining line first.
    final _RecSession rec = _RecSession();
    final GalCalibrationOcrEngine engine = GalCalibrationOcrEngine.forTesting(
      detector: PpOcrLineDetector(_DetSession()),
      recognizer: PpOcrLineRecognizer(
        rec,
        vocab: _vocab.sublist(0, _vocab.length - 1),
      ),
    );
    await expectLater(
      engine.read(_png(), _selection, _client),
      throwsA(
        isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          contains('vocab mismatch'),
        ),
      ),
    );
    expect(rec.runs, 1);
  });

  test('a capture whose size differs from the client still fails the same '
      'way', () async {
    await expectLater(
      _engine(_DetSession(), _RecSession()).read(
        _png(),
        _selection,
        const GalLookupReferenceClientV1(widthPx: 1280, heightPx: 720, dpi: 96),
      ),
      throwsA(
        isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          'ocr_capture_decode_failed',
        ),
      ),
    );
  });

  test('a fit that goes stale after the first detection stops, skips the '
      'second sample and closes both sessions', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'gal-calibration-ocr-offload-',
    );
    addTearDown(() async {
      if (directory.existsSync()) await directory.delete(recursive: true);
    });
    await File(p.join(directory.path, kPpOcrRecDictFileName)).writeAsString(
      'PostProcess:\n  character_dict:\n'
      '${_dict.map((String c) => '  - $c\n').join()}',
    );
    final _DetSession det = _DetSession();
    final _RecSession rec = _RecSession();
    bool closed = false;
    det.onRun = () => closed = true;
    final GalCalibrationOcrRunner runner = GalCalibrationOcrRunner(
      models: GalCalibrationOcrModelStore(
        directoryProvider: () async => directory,
        manifest: const <MangaOcrModelFile>[],
      ),
      factoryBuilder: () => _Factory(det, rec),
    );
    final Uint8List png = _png();
    final GalLookupCalibrationDraft draft = GalLookupCalibrationDraft(
      rect: _selection,
      layout: const GalLookupTextLayoutV1(),
      samples: <GalCalibrationSample>[
        GalCalibrationSample(capture: _capture(png, 'sample-1')),
        GalCalibrationSample(capture: _capture(png, 'sample-2')),
      ],
    );

    final GalCalibrationImageFit? fit = await runner.fit(
      draft,
      build: _noPreview,
      isStale: () => closed,
    );

    expect(fit, isNotNull);
    expect(fit!.reason, kGalCalibrationImageFitStale);
    expect(fit.draft, isNull);
    // Only sample 1's detection ran: no recognition, nothing for sample 2.
    expect(det.runs, 1);
    expect(rec.runs, 0);
    // It stopped right after the detection run: stage 2 never started.
    expect(debugLastGalCalibrationOcrStageIsolates, <String>[
      kGalCalibrationOcrPrepareIsolateName,
    ]);
    expect(det.closed, isTrue);
    expect(rec.closed, isTrue);
    // The busy flag was released: a fresh fit is not rejected as ocr_busy.
    det.onRun = null;
    closed = false;
    final GalCalibrationImageFit? again = await runner.fit(
      draft,
      build: _noPreview,
      isStale: () => true,
    );
    expect(again?.reason, kGalCalibrationImageFitStale);
  });

  test('fitGalCalibrationImages passes a stale assist result through and '
      'does not fall back to the pixel fitter', () async {
    final GalLookupCalibrationDraft draft = GalLookupCalibrationDraft(
      rect: _selection,
      layout: const GalLookupTextLayoutV1(),
      samples: <GalCalibrationSample>[
        GalCalibrationSample(capture: _capture(_png(), 'sample-1')),
      ],
    );
    bool? forwarded;
    galCalibrationOcrAssist =
        (
          GalLookupCalibrationDraft fitting, {
          required GalCalibrationPreviewBuilder build,
          bool Function()? isStale,
        }) async {
          forwarded = isStale?.call();
          return const GalCalibrationImageFit(
            reason: kGalCalibrationImageFitStale,
          );
        };
    addTearDown(() => galCalibrationOcrAssist = null);

    final GalCalibrationImageFit result = await fitGalCalibrationImages(
      draft,
      build: _noPreview,
      isStale: () => true,
    );
    expect(forwarded, isTrue);
    expect(result.reason, kGalCalibrationImageFitStale);

    // No assist installed (model pack missing): a stale caller skips the
    // pixel fallback too.
    galCalibrationOcrAssist = null;
    final GalCalibrationImageFit fallback = await fitGalCalibrationImages(
      draft,
      build: _noPreview,
      isStale: () => true,
    );
    expect(fallback.reason, kGalCalibrationImageFitStale);
  });
}
