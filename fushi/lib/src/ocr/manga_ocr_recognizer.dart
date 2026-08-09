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

import 'package:fushi/src/ocr/beam_search.dart';
import 'package:fushi/src/ocr/manga_ocr_tokenizer.dart';
import 'package:fushi/src/ocr/ocr_inference.dart';
import 'package:fushi/src/ocr/ocr_types.dart';

/// encoder 输入边长。
const int kRecInputSize = 224;

/// encoder 输出 patch 数 / 隐层宽度（224/16 = 14，14*14 = 196）。
const int kRecEncoderTokens = 196;
const int kRecHiddenSize = 768;

/// 灰度化（ITU-R 601-2，与 PIL convert("L") 同系数）后按 ViT 惯例归一化，
/// 输出 CHW float32（三通道数值相同）。输入必须已是 224x224。
Float32List mangaOcrNormalize(img.Image resized) {
  assert(resized.width == kRecInputSize && resized.height == kRecInputSize);
  const int planeSize = kRecInputSize * kRecInputSize;
  final Float32List chw = Float32List(3 * planeSize);
  int index = 0;
  for (int y = 0; y < kRecInputSize; y++) {
    for (int x = 0; x < kRecInputSize; x++) {
      final img.Pixel pixel = resized.getPixel(x, y);
      final double luma =
          (299 * pixel.r + 587 * pixel.g + 114 * pixel.b) / 1000;
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
/// 并做 squish resize 到 224x224。
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
  final int x = expanded.left.floor();
  final int y = expanded.top.floor();
  final int w = math.max(1, expanded.width.ceil());
  final int h = math.max(1, expanded.height.ceil());
  final img.Image crop = img.copyCrop(
    page,
    x: x,
    y: y,
    width: math.min(w, page.width - x),
    height: math.min(h, page.height - y),
  );
  return img.copyResize(
    crop,
    width: kRecInputSize,
    height: kRecInputSize,
    interpolation: img.Interpolation.linear,
  );
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
    this.encoderInputName = 'pixel_values',
    this.encoderOutputName = 'last_hidden_state',
    this.decoderInputIdsName = 'input_ids',
    this.decoderHiddenStatesName = 'encoder_hidden_states',
    this.decoderOutputName = 'logits',
  })  : _encoder = encoderSession,
        _decoder = decoderSession;

  final OcrSession _encoder;
  final OcrSession _decoder;
  final MangaOcrTokenizer tokenizer;

  final int numBeams;
  final double lengthPenalty;
  final int noRepeatNgramSize;
  final int maxLength;

  final String encoderInputName;
  final String encoderOutputName;
  final String decoderInputIdsName;
  final String decoderHiddenStatesName;
  final String decoderOutputName;

  @override
  Future<String> recognize(img.Image page, OcrRect box) async {
    final img.Image resized = cropAndResizeForRecognition(page, box);
    final Float32List pixels = mangaOcrNormalize(resized);

    final Map<String, OcrTensor> encoderOutputs =
        await _encoder.run(<String, OcrTensor>{
      encoderInputName:
          OcrTensor.float32(pixels, <int>[1, 3, kRecInputSize, kRecInputSize]),
    });
    final OcrTensor? hidden = encoderOutputs[encoderOutputName];
    if (hidden == null) {
      throw StateError('encoder output $encoderOutputName missing: '
          '${encoderOutputs.keys.toList()}');
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
    final OcrTensor hiddenTensor =
        OcrTensor.float32(tiledHidden, <int>[numBeams, encTokens, hiddenSize]);

    final BeamSearchResult result = await beamSearchDecode(
      config: BeamSearchConfig(
        startTokenId: tokenizer.clsId,
        eosTokenId: tokenizer.sepId,
        numBeams: numBeams,
        lengthPenalty: lengthPenalty,
        noRepeatNgramSize: noRepeatNgramSize,
        maxLength: maxLength,
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
    final Map<String, OcrTensor> outputs =
        await _decoder.run(<String, OcrTensor>{
      decoderInputIdsName: OcrTensor.int64(inputIds, <int>[beams, seqLen]),
      decoderHiddenStatesName: hiddenTensor,
    });
    final OcrTensor? logits = outputs[decoderOutputName];
    if (logits == null) {
      throw StateError('decoder output $decoderOutputName missing: '
          '${outputs.keys.toList()}');
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
