import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ocr/baberu_ocr_recognizer.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:image/image.dart' as img;

typedef _Run = Map<String, OcrTensor> Function(Map<String, OcrTensor>, int);

class _Session implements OcrSession {
  _Session(this.callback);
  final _Run callback;
  final List<Map<String, OcrTensor>> inputs = <Map<String, OcrTensor>>[];

  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> values) async {
    inputs.add(values);
    return callback(values, inputs.length - 1);
  }

  @override
  Future<void> close() async {}
}

/// Maps deliberately insert values in reverse order: cache wiring must use names.
Map<String, OcrTensor> _decoderOutput(
  List<double> scores, {
  required int pastLength,
  int sequenceLength = 1,
}) {
  final Float32List logits = Float32List(scores.length * sequenceLength);
  for (int row = 0; row < sequenceLength - 1; row++) {
    logits[row * scores.length + 2] = 100; // Only the last row is predictive.
  }
  logits.setRange(logits.length - scores.length, logits.length, scores);
  return <String, OcrTensor>{
    for (final String kind in <String>['v', 'k'])
      for (int layer = 5; layer >= 0; layer--)
        'present_$kind$layer': OcrTensor.float32(
          Float32List(2 * pastLength * 64)
            ..[0] = (kind == 'k' ? 100 : 200) + layer + pastLength.toDouble(),
          <int>[1, 2, pastLength, 64],
        ),
    'logits': OcrTensor.float32(logits, <int>[
      1,
      sequenceLength,
      scores.length,
    ]),
  };
}

List<double> _scores(int size, Map<int, double> values) => <double>[
  for (int id = 0; id < size; id++) values[id] ?? -100,
];

class _Harness {
  _Harness({
    required this.charset,
    required List<List<double>> predictions,
    int visionTokens = 2,
    int maxNewTokens = 128,
    double repetitionPenalty = 1.2,
    int maxContentRun = 12,
  }) {
    vision = _Session(
      (Map<String, OcrTensor> _, int call) => <String, OcrTensor>{
        'vision_embeds': OcrTensor.float32(
          Float32List(visionTokens * 512),
          <int>[1, visionTokens, 512],
        ),
      },
    );
    prefill = _Session((Map<String, OcrTensor> _, int call) {
      final Map<String, OcrTensor> result = _decoderOutput(
        predictions.first,
        pastLength: visionTokens + 1,
        sequenceLength: visionTokens + 1,
      );
      outputs.add(result);
      return result;
    });
    step = _Session((Map<String, OcrTensor> _, int call) {
      final Map<String, OcrTensor> result = _decoderOutput(
        predictions[(call + 1).clamp(0, predictions.length - 1)],
        pastLength: visionTokens + call + 2,
      );
      outputs.add(result);
      return result;
    });
    recognizer = BaberuOcrRecognizer(
      visionSession: vision,
      prefillSession: prefill,
      stepSession: step,
      vocabJson: jsonEncode(charset),
      maxNewTokens: maxNewTokens,
      repetitionPenalty: repetitionPenalty,
      maxContentRun: maxContentRun,
    );
  }

  final List<String> charset;
  late final _Session vision;
  late final _Session prefill;
  late final _Session step;
  late final BaberuOcrRecognizer recognizer;
  final List<Map<String, OcrTensor>> outputs = <Map<String, OcrTensor>>[];

  Future<String> recognize() => recognizer.recognize(
    img.Image(width: 3, height: 5),
    const OcrRect(left: 0, top: 0, right: 3, bottom: 5),
  );
}

img.Image _pattern(int width, int height, {int channels = 3}) {
  final img.Image image = img.Image(
    width: width,
    height: height,
    numChannels: channels,
  );
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      image.setPixelRgba(
        x,
        y,
        (x * 17 + y * 13) % 256,
        (x * 3 + y * 29 + ((x + y).isOdd ? 255 : 0)) % 256,
        (x ~/ 3 + y ~/ 5).isOdd ? 255 : 0,
        0,
      );
    }
  }
  return image;
}

String _tensorHash(img.Image image, [OcrRect? box]) {
  final Float32List tensor = baberuOcrPreprocess(
    image,
    box ??
        OcrRect(
          left: 0,
          top: 0,
          right: image.width.toDouble(),
          bottom: image.height.toDouble(),
        ),
  );
  expect(tensor.length, 3 * 224 * 224);
  return sha256.convert(tensor.buffer.asUint8List()).toString();
}

void main() {
  group('Baberu official preprocessing', () {
    // Independent Python oracle: Pillow 12.3.0 + official onnx_infer.preprocess,
    // SHA256(preprocess(Image.fromarray(rgb)).tobytes()). RGB pattern is:
    // r=(17*x+13*y)%256, g=(3*x+29*y+(255 if (x+y)%2 else 0))%256,
    // b=255 if (x//3+y//5)%2 else 0. The hash covers every NCHW float32 bit,
    // including per-axis uint8 clipping and each NumPy normalization rounding.
    const List<(int, int, String)> gold = <(int, int, String)>[
      (
        1,
        1,
        'b6b5e270cc3ba102b4450ce63e032239fe4da992bc9c852b98b37920cc9d0287',
      ),
      (
        7,
        13,
        'bc73a2fb8988c0559ef8d55c5076ddc1b8239cf5c1b0c202d5a8bcd101cfb628',
      ),
      (
        224,
        224,
        '723bd9f5a6d6a546e6a2df46efd7475703ea218d90ba36e80ac158e017bc97bd',
      ),
      (
        73,
        511,
        '07de0290ba1271c0d01d314daee2489a3f1d9e3b45bb386dc1b86d4251916bfb',
      ),
      (
        509,
        317,
        '1ed1fe9dd5f17c6dc3f3281f584fd95c7e25431f2410630b44e5a581f843f822',
      ),
      (
        225,
        224,
        '6351ffef91a314daca91a912410b0ca47dffe75008847893abd653953ce2e896',
      ),
      (
        224,
        225,
        'e0830704a1f7fdeb0b2d37f4653e6eb99478ff750d15e82aaf61c08a76ea150a',
      ),
    ];
    for (final (int width, int height, String hash) in gold) {
      test('RGB $width × $height matches Pillow bicubic and float32', () {
        expect(_tensorHash(_pattern(width, height)), hash);
      });
    }

    test('fractional crop covers both boundary pixels before resizing', () {
      expect(
        _tensorHash(
          _pattern(29, 37),
          const OcrRect(left: 1.2, top: 2.8, right: 28.6, bottom: 35.9),
        ),
        '6285d777a6885937388a82fdcaf75fd7c5cb2d19c7983abc6834e0f7afa20524',
      );
    });

    test('grayscale and transparent RGBA follow Pillow RGB conversion', () {
      final img.Image gray = img.Image(width: 29, height: 37, numChannels: 1);
      for (final img.Pixel pixel in gray) {
        pixel.r = (pixel.x * 17 + pixel.y * 13) % 256;
      }
      expect(
        _tensorHash(gray),
        'e995bb4202819ee94cf3302621c3de45d05c3d016b7e3db180d0b5b6715f5277',
      );
      expect(
        _tensorHash(_pattern(29, 37, channels: 4)),
        '0c0ac5b257c5da56998c21fae19476c0fcb3c01ebd03c85e951d9310b4bc6945',
      );
    });

    test('palette entries are RGB colors, not grayscale index values', () {
      final img.Image palette = img.Image(
        width: 29,
        height: 37,
        numChannels: 3,
        withPalette: true,
      );
      for (int index = 0; index < 256; index++) {
        palette.palette!.setRgb(index, index, 255 - index, (index * 53) % 256);
      }
      for (final img.Pixel pixel in palette) {
        pixel.index = (3 * pixel.x + 5 * pixel.y) % 256;
      }
      expect(
        _tensorHash(palette),
        'c965c1115727ad15f1fe1126c8d319f3f887a9bc12bd81e97f7546faae5bd792',
      );
    });
  });

  group('Baberu cached greedy decode', () {
    test(
      'BOS, last prefill logit, 12 named caches, positions and EOS',
      () async {
        final _Harness h = _Harness(
          charset: <String>['猫', 'B'],
          visionTokens: 256,
          predictions: <List<double>>[
            _scores(6, <int, double>{4: 10}),
            _scores(6, <int, double>{5: 10}),
            _scores(6, <int, double>{2: 10}),
          ],
        );
        expect(await h.recognize(), '猫B');
        expect(h.vision.inputs.single.keys, <String>['pixel_values']);
        expect(h.vision.inputs.single['pixel_values']!.shape, <int>[
          1,
          3,
          224,
          224,
        ]);
        expect(h.prefill.inputs.single['input_ids']!.intData, <int>[1]);
        expect(h.prefill.inputs.single['input_ids']!.shape, <int>[1, 1]);
        expect(h.prefill.inputs.single['vision_embeds']!.shape, <int>[
          1,
          256,
          512,
        ]);
        expect(h.step.inputs, hasLength(2));
        for (int step = 0; step < 2; step++) {
          final Map<String, OcrTensor> feed = h.step.inputs[step];
          expect(feed, hasLength(14));
          expect(feed['input_ids']!.intData, <int>[4 + step]);
          expect(feed['input_ids']!.shape, <int>[1, 1]);
          expect(feed['position_ids']!.intData, <int>[257 + step]);
          expect(feed['position_ids']!.shape, <int>[1, 1]);
          for (final String kind in <String>['k', 'v']) {
            for (int layer = 0; layer < 6; layer++) {
              expect(
                feed['past_$kind$layer'],
                same(h.outputs[step]['present_$kind$layer']),
                reason:
                    'Reuse the preceding step cache with its exact layer/key',
              );
            }
          }
        }
      },
    );

    test('EOS from prefill performs no step and returns empty text', () async {
      final _Harness h = _Harness(
        charset: <String>['猫'],
        predictions: <List<double>>[
          _scores(5, <int, double>{2: 10}),
        ],
      );
      expect(await h.recognize(), isEmpty);
      expect(h.step.inputs, isEmpty);
    });

    test(
      'token cap counts new tokens only and avoids the final unused run',
      () async {
        final _Harness h = _Harness(
          charset: <String>['猫'],
          maxNewTokens: 2,
          predictions: <List<double>>[
            _scores(5, <int, double>{4: 10}),
          ],
        );
        expect(await h.recognize(), '猫猫');
        expect(h.step.inputs, hasLength(1));
      },
    );

    test(
      'positive and negative repeated scores use the official penalty',
      () async {
        final _Harness positive = _Harness(
          charset: <String>['猫', '犬'],
          predictions: <List<double>>[
            _scores(6, <int, double>{1: 1.1, 4: 1.0}), // Penalize BOS too.
            _scores(6, <int, double>{4: 1.2, 5: 1.1}),
            _scores(6, <int, double>{5: 1.2, 2: 1.1}),
          ],
        );
        expect(await positive.recognize(), '猫犬');
        final _Harness negative = _Harness(
          charset: <String>['猫', '犬'],
          predictions: <List<double>>[
            _scores(6, <int, double>{4: -1}),
            _scores(6, <int, double>{4: -1, 5: -1.1}),
            _scores(6, <int, double>{2: 10}),
          ],
        );
        expect(await negative.recognize(), '猫犬');
      },
    );

    test(
      'penalty applies once per distinct ID, not once per occurrence',
      () async {
        final _Harness h = _Harness(
          charset: <String>['猫', '犬'],
          predictions: <List<double>>[
            _scores(6, <int, double>{4: 10}),
            _scores(6, <int, double>{4: 10}),
            _scores(6, <int, double>{4: 1.4, 5: 1.1}),
            _scores(6, <int, double>{2: 10}),
          ],
        );
        expect(await h.recognize(), '猫猫猫');
      },
    );

    for (final String character in <String>['猫', 'A', '3', '²', '𠮷']) {
      test('content run caps Unicode letter/number $character at 12', () async {
        final _Harness h = _Harness(
          charset: <String>[character],
          predictions: <List<double>>[
            _scores(5, <int, double>{4: 10, 2: 1}),
          ],
        );
        expect(await h.recognize(), List<String>.filled(12, character).join());
        expect(h.step.inputs, hasLength(12));
      });
    }

    for (final String character in <String>['ー', 'ｰ', '〜', '~', '!', 'あい']) {
      test(
        'symbol or multi-character token $character is not content-capped',
        () async {
          final _Harness h = _Harness(
            charset: <String>[character],
            maxNewTokens: 14,
            predictions: <List<double>>[
              _scores(5, <int, double>{4: 10, 2: 1}),
            ],
          );
          expect(
            await h.recognize(),
            List<String>.filled(14, character).join(),
          );
        },
      );
    }

    test(
      'tie uses the first ID; charset tokens concatenate without BPE cleanup',
      () async {
        final _Harness h = _Harness(
          charset: <String>['##猫', ' ', '…'],
          predictions: <List<double>>[
            _scores(7, <int, double>{
              3: 10,
            }), // UNK is fed back, omitted from text.
            _scores(7, <int, double>{4: 10, 5: 10}),
            _scores(7, <int, double>{5: 10}),
            _scores(7, <int, double>{6: 10}),
            _scores(7, <int, double>{2: 10}),
          ],
        );
        expect(await h.recognize(), '##猫 …');
        expect(h.step.inputs.first['input_ids']!.intData, <int>[3]);
      },
    );

    test('bad vocabulary shape fails before inference', () {
      final _Session session = _Session(
        (Map<String, OcrTensor> _, int __) =>
            throw StateError('Should not infer'),
      );
      for (final String source in <String>['{}', '[]', '[1]', 'invalid']) {
        expect(
          () => BaberuOcrRecognizer(
            visionSession: session,
            prefillSession: session,
            stepSession: session,
            vocabJson: source,
          ),
          throwsFormatException,
        );
      }
    });

    test(
      'missing cache and mismatched vocab are explicit model errors',
      () async {
        final _Session vision = _Session(
          (Map<String, OcrTensor> _, int __) => <String, OcrTensor>{
            'vision_embeds': OcrTensor.float32(Float32List(2), <int>[1, 1, 2]),
          },
        );
        final _Session step = _Session(
          (Map<String, OcrTensor> _, int __) =>
              throw StateError('Should not infer'),
        );
        final _Session missing = _Session(
          (Map<String, OcrTensor> _, int __) =>
              _decoderOutput(_scores(5, <int, double>{4: 10}), pastLength: 2)
                ..remove('present_k3'),
        );
        final BaberuOcrRecognizer recognizer = BaberuOcrRecognizer(
          visionSession: vision,
          prefillSession: missing,
          stepSession: step,
          vocabJson: '["猫"]',
        );
        await expectLater(
          recognizer.recognize(
            img.Image(width: 1, height: 1),
            const OcrRect(left: 0, top: 0, right: 1, bottom: 1),
          ),
          throwsA(
            isA<StateError>().having(
              (StateError e) => e.message,
              'message',
              contains('present_k3'),
            ),
          ),
        );
        final _Session mismatch = _Session(
          (Map<String, OcrTensor> _, int __) =>
              _decoderOutput(_scores(6, <int, double>{4: 10}), pastLength: 2),
        );
        await expectLater(
          BaberuOcrRecognizer(
            visionSession: vision,
            prefillSession: mismatch,
            stepSession: step,
            vocabJson: '["猫"]',
          ).recognize(
            img.Image(width: 1, height: 1),
            const OcrRect(left: 0, top: 0, right: 1, bottom: 1),
          ),
          throwsA(isA<StateError>()),
        );
      },
    );
  });
}
