/// manga-ocr 识别器（mayocream/manga-ocr-onnx 双模型导出）。
///
/// IO 规格：
/// - encoder（ViT）：输入 `pixel_values` float32 [1,3,224,224]；输出
///   `last_hidden_state` [1,196,768]。
/// - decoder（BERT 自回归）：输入 `input_ids` int64 [beams, seqLen] +
///   `encoder_hidden_states` float32 [beams,196,768]；输出 `logits`
///   [beams, seqLen, vocab]。无 KV cache，每步全序列重跑。
///
/// 预处理对齐原版 manga_ocr：PIL `convert("L").convert("RGB")`（ITU-R 601-2
/// 亮度灰度化后三通道复制）→ squish resize 到 224x224 → ViT feature
/// extractor 惯例归一化 `(x/255 - 0.5) / 0.5`（mean=std=0.5，逐通道同值）。
///
/// 解码：beam search（num_beams=4, length_penalty=2.0,
/// no_repeat_ngram_size=3, max_length=300，对齐原版 generation_config；
/// 已实测该配置与原版输出逐字一致）。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'package:fushi_engine/ocr/beam_search.dart';
import 'package:fushi_engine/ocr/manga_ocr_tokenizer.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';

/// encoder 输入边长。
const int kRecInputSize = 224;

/// encoder 输出 patch 数 / 隐层宽度（224/16 = 14，14*14 = 196）。
const int kRecEncoderTokens = 196;
const int kRecHiddenSize = 768;

/// 灰度化（PIL convert("L") 的 8 位取整）后按 ViT 惯例归一化，
/// 输出 CHW float32（三通道数值相同）。输入必须已是 224x224。
Float32List mangaOcrNormalize(img.Image resized) {
  assert(resized.width == kRecInputSize && resized.height == kRecInputSize);
  const int planeSize = kRecInputSize * kRecInputSize;
  final Float32List chw = Float32List(3 * planeSize);
  int index = 0;
  for (int y = 0; y < kRecInputSize; y++) {
    for (int x = 0; x < kRecInputSize; x++) {
      final img.Pixel pixel = resized.getPixel(x, y);
      final int luma = _pilLuma(pixel);
      final double value = (luma / 255.0 - 0.5) / 0.5;
      chw[index] = value;
      chw[planeSize + index] = value;
      chw[2 * planeSize + index] = value;
      index++;
    }
  }
  return chw;
}

/// 从页面裁出 [box]（clamp 到页面内，可选向外扩 [marginRatio] 比例的边距）
/// 先转成 8 位灰度，再按 PIL BILINEAR 做 squish resize 到 224x224。
///
/// manga-ocr 的 preprocessor_config.json 指定 resample=2（BILINEAR）。
/// image.copyResize(linear) 缩小时只取相邻四点，细笔画会混叠甚至消失；
/// 索引色 PNG 更会强制降成 nearest。因此这里按 PIL 的像素中心、缩小滤波
/// 支撑区间和两遍 8 位取整处理，不把「bilinear」名字相同当成行为相同。
img.Image cropAndResizeForRecognition(
  img.Image page,
  OcrRect box, {
  double marginRatio = 0,
}) {
  final double marginX = box.width * marginRatio;
  final double marginY = box.height * marginRatio;
  final OcrRect expanded = OcrRect(
    left: box.left - marginX,
    top: box.top - marginY,
    right: box.right + marginX,
    bottom: box.bottom + marginY,
  ).clamp(page.width.toDouble(), page.height.toDouble());
  final int x = expanded.left.floor().clamp(0, page.width - 1);
  final int y = expanded.top.floor().clamp(0, page.height - 1);
  // 左上向下取整、右下向上取整；ceil(width) 会在小数框上漏掉末列/末行。
  final int w = math.max(1, expanded.right.ceil() - x);
  final int h = math.max(1, expanded.bottom.ceil() - y);
  final Uint8List gray = Uint8List(w * h);
  for (int row = 0; row < h; row++) {
    for (int col = 0; col < w; col++) {
      gray[row * w + col] = _pilLuma(page.getPixel(x + col, y + row));
    }
  }
  return _resizeMangaGray(gray, w, h);
}

// PIL Convert.c 的 RGB -> L 定点系数。先灰度化再缩放，避免彩色逐通道取整
// 改变灰度；也自然解开 PNG palette，不让缩放退成 nearest。
int _pilLuma(img.Pixel pixel) {
  // 单通道灰度的 g/b getter 为 0；不能当成红色再乘一次亮度系数。
  // length 返回调色板颜色通道数，不能用索引图存储的 numChannels 判断。
  if (pixel.length < 3) return pixel.r.toInt();
  return (19595 * pixel.r.toInt() +
          38470 * pixel.g.toInt() +
          7471 * pixel.b.toInt() +
          32768) >>
      16;
}

const int _pilResampleBits = 22;
const int _pilResampleScale = 1 << _pilResampleBits;

typedef _BilinearTap = ({int start, Int32List weights});

/// PIL Resample.c 的 BILINEAR 系数：以像素中心采样，缩小时扩宽三角滤波核。
/// 22 位定点系数与每一遍的舍入对齐其 8bpc 路径。
List<_BilinearTap> _mangaBilinearTaps(int sourceSize) {
  final double scale = sourceSize / kRecInputSize;
  final double support = math.max(1.0, scale);
  return List<_BilinearTap>.generate(kRecInputSize, (int dst) {
    final double center = (dst + 0.5) * scale;
    final int start = math.max(0, (center - support + 0.5).toInt());
    final int end = math.min(sourceSize, (center + support + 0.5).toInt());
    final List<double> weights = <double>[
      for (int src = start; src < end; src++)
        math.max(0.0, 1.0 - ((src - center + 0.5) / support).abs()),
    ];
    final double sum = weights.fold(0.0, (double a, double b) => a + b);
    return (
      start: start,
      weights: Int32List.fromList(<int>[
        for (final double weight in weights)
          (weight / sum * _pilResampleScale).round(),
      ]),
    );
  }, growable: false);
}

img.Image _resizeMangaGray(Uint8List gray, int width, int height) {
  final List<_BilinearTap> xTaps = _mangaBilinearTaps(width);
  final List<_BilinearTap> yTaps = _mangaBilinearTaps(height);
  final Uint8List horizontal = Uint8List(kRecInputSize * height);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < kRecInputSize; x++) {
      final _BilinearTap tap = xTaps[x];
      int sum = _pilResampleScale ~/ 2;
      for (int i = 0; i < tap.weights.length; i++) {
        sum += gray[y * width + tap.start + i] * tap.weights[i];
      }
      horizontal[y * kRecInputSize + x] = (sum >> _pilResampleBits).clamp(
        0,
        255,
      );
    }
  }
  final img.Image resized = img.Image(
    width: kRecInputSize,
    height: kRecInputSize,
  );
  for (int y = 0; y < kRecInputSize; y++) {
    final _BilinearTap tap = yTaps[y];
    for (int x = 0; x < kRecInputSize; x++) {
      int sum = _pilResampleScale ~/ 2;
      for (int i = 0; i < tap.weights.length; i++) {
        sum += horizontal[(tap.start + i) * kRecInputSize + x] * tap.weights[i];
      }
      final int value = (sum >> _pilResampleBits).clamp(0, 255);
      resized.setPixelRgb(x, y, value, value, value);
    }
  }
  return resized;
}

/// manga-ocr 识别器：encoder 跑一次，decoder 以 beam batch 自回归。
class MangaOcrRecognizer implements OcrRecognizer {
  MangaOcrRecognizer({
    required OcrSession encoderSession,
    required OcrSession decoderSession,
    required this.tokenizer,
    this.numBeams = 4,
    this.lengthPenalty = 2.0,
    this.noRepeatNgramSize = 3,
    this.maxLength = 300,
    this.earlyStopping = true,
    this.encoderInputName = 'pixel_values',
    this.encoderOutputName = 'last_hidden_state',
    this.decoderInputIdsName = 'input_ids',
    this.decoderHiddenStatesName = 'encoder_hidden_states',
    this.decoderOutputName = 'logits',
  }) : _encoder = encoderSession,
       _decoder = decoderSession;

  final OcrSession _encoder;
  final OcrSession _decoder;
  final MangaOcrTokenizer tokenizer;

  final int numBeams;
  final double lengthPenalty;
  final int noRepeatNgramSize;
  final int maxLength;

  /// 对齐原版 generation_config 的 early_stopping=true（BUG-2457）。
  final bool earlyStopping;

  final String encoderInputName;
  final String encoderOutputName;
  final String decoderInputIdsName;
  final String decoderHiddenStatesName;
  final String decoderOutputName;

  @override
  Future<String> recognize(img.Image page, OcrRect box) async {
    final img.Image resized = cropAndResizeForRecognition(page, box);
    final Float32List pixels = mangaOcrNormalize(resized);

    final Map<String, OcrTensor> encoderOutputs = await _encoder.run(
      <String, OcrTensor>{
        encoderInputName: OcrTensor.float32(pixels, <int>[
          1,
          3,
          kRecInputSize,
          kRecInputSize,
        ]),
      },
    );
    final OcrTensor? hidden = encoderOutputs[encoderOutputName];
    if (hidden == null) {
      throw StateError(
        'encoder output $encoderOutputName missing: '
        '${encoderOutputs.keys.toList()}',
      );
    }
    final int encTokens = hidden.shape[1];
    final int hiddenSize = hidden.shape[2];
    final Float32List hiddenData = hidden.floatData!;

    // encoder_hidden_states 沿 beam 维 tile 一份，整轮解码复用。
    final int perBeam = encTokens * hiddenSize;
    final Float32List tiledHidden = Float32List(numBeams * perBeam);
    for (int b = 0; b < numBeams; b++) {
      tiledHidden.setRange(b * perBeam, (b + 1) * perBeam, hiddenData);
    }
    final OcrTensor hiddenTensor = OcrTensor.float32(tiledHidden, <int>[
      numBeams,
      encTokens,
      hiddenSize,
    ]);

    final BeamSearchResult result = await beamSearchDecode(
      config: BeamSearchConfig(
        startTokenId: tokenizer.clsId,
        eosTokenId: tokenizer.sepId,
        numBeams: numBeams,
        lengthPenalty: lengthPenalty,
        noRepeatNgramSize: noRepeatNgramSize,
        maxLength: maxLength,
        earlyStopping: earlyStopping,
      ),
      stepLogits: (List<List<int>> sequences) =>
          _decoderStep(sequences, hiddenTensor),
    );
    return tokenizer.decode(result.tokens);
  }

  Future<List<Float32List>> _decoderStep(
    List<List<int>> sequences,
    OcrTensor hiddenTensor,
  ) async {
    final int beams = sequences.length;
    final int seqLen = sequences[0].length;
    final Int64List inputIds = Int64List(beams * seqLen);
    for (int b = 0; b < beams; b++) {
      assert(sequences[b].length == seqLen);
      for (int t = 0; t < seqLen; t++) {
        inputIds[b * seqLen + t] = sequences[b][t];
      }
    }
    final Map<String, OcrTensor> outputs = await _decoder.run(
      <String, OcrTensor>{
        decoderInputIdsName: OcrTensor.int64(inputIds, <int>[beams, seqLen]),
        decoderHiddenStatesName: hiddenTensor,
      },
    );
    final OcrTensor? logits = outputs[decoderOutputName];
    if (logits == null) {
      throw StateError(
        'decoder output $decoderOutputName missing: '
        '${outputs.keys.toList()}',
      );
    }
    final int vocabSize = logits.shape[2];
    final Float32List data = logits.floatData!;
    // 取每条 beam 最后一个位置的 logits。
    final List<Float32List> lastStep = <Float32List>[];
    for (int b = 0; b < beams; b++) {
      final int offset = (b * seqLen + (seqLen - 1)) * vocabSize;
      lastStep.add(Float32List.sublistView(data, offset, offset + vocabSize));
    }
    return lastStep;
  }

  Future<void> close() async {
    await _encoder.close();
    await _decoder.close();
  }
}
