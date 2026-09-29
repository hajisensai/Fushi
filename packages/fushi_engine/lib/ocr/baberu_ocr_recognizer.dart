/// Baberu OCR 的官方三图 ONNX 解码契约（vision / prefill / KV-cache step）。
///
/// 模型与参考实现：genshiai-daichi/baberu-ocr，revision
/// d9cc13153e9a1cd8fdfa3b7b1cc329da2020aeae，onnx_infer.py（Apache-2.0）。
/// 会话由宿主创建和关闭；这里仅负责预处理、字符词表和 greedy 解码。
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:image/image.dart' as img;

const int kBaberuInputSize = 224;
const int _bosId = 1;
const int _eosId = 2;
const int _cacheLayers = 6;

class BaberuOcrRecognizer implements OcrRecognizer {
  BaberuOcrRecognizer({
    required OcrSession visionSession,
    required OcrSession prefillSession,
    required OcrSession stepSession,
    required String vocabJson,
    this.maxNewTokens = 128,
    this.repetitionPenalty = 1.2,
    this.maxContentRun = 12,
  }) : assert(maxNewTokens > 0),
       assert(repetitionPenalty > 0),
       assert(maxContentRun >= 0),
       _vision = visionSession,
       _prefill = prefillSession,
       _step = stepSession,
       _charset = _readCharset(vocabJson) {
    final RegExp content = RegExp(r'^[\p{L}\p{N}]$', unicode: true);
    _contentIds = <int>{
      for (int i = 0; i < _charset.length; i++)
        if (_charset[i].runes.length == 1 &&
            !const <String>{'ー', 'ｰ', '〜', '~'}.contains(_charset[i]) &&
            content.hasMatch(_charset[i]))
          i + 4,
    };
  }

  final OcrSession _vision;
  final OcrSession _prefill;
  final OcrSession _step;
  final List<String> _charset;
  late final Set<int> _contentIds;
  final int maxNewTokens;
  final double repetitionPenalty;
  final int maxContentRun;

  static List<String> _readCharset(String source) {
    final Object? decoded = jsonDecode(source);
    if (decoded is! List ||
        decoded.isEmpty ||
        decoded.any((Object? item) => item is! String)) {
      throw const FormatException(
        'Baberu vocab must be a JSON character array',
      );
    }
    return List<String>.unmodifiable(decoded.cast<String>());
  }

  @override
  Future<String> recognize(img.Image page, OcrRect box) async {
    final Map<String, OcrTensor> vision = await _vision.run(<String, OcrTensor>{
      'pixel_values': OcrTensor.float32(baberuOcrPreprocess(page, box), <int>[
        1,
        3,
        kBaberuInputSize,
        kBaberuInputSize,
      ]),
    });
    final OcrTensor? embeds = vision['vision_embeds'];
    if (embeds == null ||
        embeds.floatData == null ||
        embeds.shape.length != 3 ||
        embeds.shape[0] != 1 ||
        embeds.shape[1] < 1) {
      throw StateError(
        'Baberu vision_embeds must be float32 [1, tokens, hidden]',
      );
    }
    Map<String, OcrTensor> outputs = await _prefill.run(<String, OcrTensor>{
      'vision_embeds': embeds,
      'input_ids': OcrTensor.int64(Int64List.fromList(<int>[_bosId]), <int>[
        1,
        1,
      ]),
    });
    final List<int> tokens = <int>[];
    final Set<int> seen = <int>{_bosId};
    int position = embeds.shape[1] + 1;
    for (int index = 0; index < maxNewTokens; index++) {
      // 官方先升成 float64 再施加 penalty，不能原地改 float32 模型输出。
      final Float64List logits = _lastLogits(outputs);
      if (repetitionPenalty != 1.0) {
        for (final int id in seen) {
          final double score = logits[id];
          logits[id] = score < 0
              ? score * repetitionPenalty
              : score / repetitionPenalty;
        }
      }
      if (maxContentRun > 0 &&
          tokens.isNotEmpty &&
          _contentIds.contains(tokens.last)) {
        final int last = tokens.last;
        int run = 0;
        for (int i = tokens.length - 1; i >= 0 && tokens[i] == last; i--) {
          run++;
        }
        if (run >= maxContentRun) logits[last] = double.negativeInfinity;
      }
      int next = 0;
      for (int id = 1; id < logits.length; id++) {
        // 严格 > 保留最小 ID，匹配 numpy.argmax 的同分规则。
        if (logits[id] > logits[next]) next = id;
      }
      if (next == _eosId) break;
      tokens.add(next);
      seen.add(next);
      if (tokens.length >= maxNewTokens) break;

      final Map<String, OcrTensor> feed = <String, OcrTensor>{
        'input_ids': OcrTensor.int64(Int64List.fromList(<int>[next]), <int>[
          1,
          1,
        ]),
        'position_ids': OcrTensor.int64(
          Int64List.fromList(<int>[position]),
          <int>[1, 1],
        ),
      };
      for (final String kind in <String>['k', 'v']) {
        for (int layer = 0; layer < _cacheLayers; layer++) {
          final String name = '$kind$layer';
          final OcrTensor? cache = outputs['present_$name'];
          if (cache == null || cache.floatData == null) {
            throw StateError('Baberu decoder output present_$name missing');
          }
          // 保留原张量，不在 Dart 多复制一次 KV；宿主桥的往返由会话实现负责。
          feed['past_$name'] = cache;
        }
      }
      outputs = await _step.run(feed);
      position++;
    }
    return <String>[
      for (final int id in tokens)
        if (id >= 4) _charset[id - 4],
    ].join();
  }

  Float64List _lastLogits(Map<String, OcrTensor> outputs) {
    final OcrTensor? tensor = outputs['logits'];
    final int vocabSize = _charset.length + 4;
    if (tensor == null ||
        tensor.floatData == null ||
        tensor.shape.length != 3 ||
        tensor.shape[0] != 1 ||
        tensor.shape[1] < 1 ||
        tensor.shape[2] != vocabSize ||
        tensor.floatData!.length != tensor.shape[1] * vocabSize) {
      throw StateError(
        'Baberu logits must be float32 [1, sequence, $vocabSize]',
      );
    }
    final Float32List data = tensor.floatData!;
    final int offset = data.length - vocabSize;
    return Float64List.fromList(data.sublist(offset));
  }
}

/// 对齐官方 Pillow RGB BICUBIC → ImageNet float32 → NCHW，保留彩色。
/// 索引图解开调色板，灰度通道复制到 RGB；alpha 与 Pillow convert("RGB") 一样丢弃。
Float32List baberuOcrPreprocess(img.Image page, OcrRect box) {
  final OcrRect bounded = box.clamp(
    page.width.toDouble(),
    page.height.toDouble(),
  );
  final int left = bounded.left.floor().clamp(0, page.width - 1);
  final int top = bounded.top.floor().clamp(0, page.height - 1);
  final int width = math.max(1, bounded.right.ceil() - left);
  final int height = math.max(1, bounded.bottom.ceil() - top);
  final Uint8List rgb = Uint8List(width * height * 3);
  int offset = 0;
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final img.Pixel pixel = page.getPixel(left + x, top + y);
      rgb[offset++] = pixel.r.toInt();
      rgb[offset++] = (pixel.length < 3 ? pixel.r : pixel.g).toInt();
      rgb[offset++] = (pixel.length < 3 ? pixel.r : pixel.b).toInt();
    }
  }
  final Uint8List resized = _resizeBicubic(rgb, width, height);
  const int planeSize = kBaberuInputSize * kBaberuInputSize;
  final Float32List chw = Float32List(planeSize * 3);
  for (int channel = 0; channel < 3; channel++) {
    for (int pixel = 0; pixel < planeSize; pixel++) {
      chw[channel * planeSize + pixel] =
          _normalization[channel * 256 + resized[pixel * 3 + channel]];
    }
  }
  return chw;
}

// NumPy 对 /255、减 mean、除 std 各做一次 float32 舍入。预先算 3×256 个值，
// 避免 Dart double 一路算完才转 float32 造成 ULP 差异。
final Float32List _normalization = _buildNormalization();

Float32List _buildNormalization() {
  final Float32List means = Float32List.fromList(<double>[0.485, 0.456, 0.406]);
  final Float32List stds = Float32List.fromList(<double>[0.229, 0.224, 0.225]);
  final Float32List values = Float32List(3 * 256);
  for (int channel = 0; channel < 3; channel++) {
    for (int value = 0; value < 256; value++) {
      final int index = channel * 256 + value;
      values[index] = value / 255.0;
      values[index] = values[index] - means[channel];
      values[index] = values[index] / stds[channel];
    }
  }
  return values;
}

const int _filterBits = 22;
const int _filterScale = 1 << _filterBits;
typedef _BicubicTap = ({int start, Int32List weights});

// Pillow Resample.c: bicubic a=-0.5，缩小时将整个支撑区按比例扩宽。
double _bicubic(double distance) {
  final double x = distance.abs();
  if (x < 1) return ((1.5 * x - 2.5) * x) * x + 1;
  if (x < 2) return (((x - 5) * x + 8) * x - 4) * -0.5;
  return 0;
}

List<_BicubicTap> _bicubicTaps(int sourceSize) {
  final double scale = sourceSize / kBaberuInputSize;
  final double filterScale = math.max(1.0, scale);
  final double support = 2 * filterScale;
  return List<_BicubicTap>.generate(kBaberuInputSize, (int destination) {
    final double center = (destination + 0.5) * scale;
    final int start = math.max(0, (center - support + 0.5).toInt());
    final int end = math.min(sourceSize, (center + support + 0.5).toInt());
    final List<double> weights = <double>[
      for (int source = start; source < end; source++)
        _bicubic((source - center + 0.5) / filterScale),
    ];
    final double sum = weights.fold(0, (double a, double b) => a + b);
    return (
      start: start,
      weights: Int32List.fromList(<int>[
        for (final double weight in weights)
          (weight / sum * _filterScale).round(),
      ]),
    );
  }, growable: false);
}

Uint8List _resizeBicubic(Uint8List rgb, int width, int height) {
  final List<_BicubicTap> xTaps = _bicubicTaps(width);
  final List<_BicubicTap> yTaps = _bicubicTaps(height);
  final Uint8List horizontal = Uint8List(kBaberuInputSize * height * 3);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < kBaberuInputSize; x++) {
      final _BicubicTap tap = xTaps[x];
      for (int channel = 0; channel < 3; channel++) {
        int sum = _filterScale ~/ 2;
        for (int i = 0; i < tap.weights.length; i++) {
          sum +=
              rgb[(y * width + tap.start + i) * 3 + channel] * tap.weights[i];
        }
        horizontal[(y * kBaberuInputSize + x) * 3 + channel] =
            (sum >> _filterBits).clamp(0, 255);
      }
    }
  }
  final Uint8List resized = Uint8List(kBaberuInputSize * kBaberuInputSize * 3);
  for (int y = 0; y < kBaberuInputSize; y++) {
    final _BicubicTap tap = yTaps[y];
    for (int x = 0; x < kBaberuInputSize; x++) {
      for (int channel = 0; channel < 3; channel++) {
        int sum = _filterScale ~/ 2;
        for (int i = 0; i < tap.weights.length; i++) {
          sum +=
              horizontal[((tap.start + i) * kBaberuInputSize + x) * 3 +
                  channel] *
              tap.weights[i];
        }
        resized[(y * kBaberuInputSize + x) * 3 + channel] = (sum >> _filterBits)
            .clamp(0, 255);
      }
    }
  }
  return resized;
}
