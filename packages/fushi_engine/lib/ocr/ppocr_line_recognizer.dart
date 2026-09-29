/// PP-OCRv6 文本行识别器（CTC，PaddlePaddle/PP-OCRv6_small_rec_onnx，Apache-2.0）。
///
/// 只识别**横排行**。竖排行 manga-ocr 更准（小假名、中日异体字、『』「」都是
/// 查词的生死线，PP 在这些上会「读对了字读错了形」），横排行 manga-ocr 则幻觉
/// 95%+ 而 PP 只有 5%（2026-09-11 对拍 + 2026-09-13 用户真实页复测）。
///
/// IO 规格（已核实：该 repo 的 `inference.yml` + PaddleOCR `RecResizeImg` /
/// `CTCLabelDecode`，与对拍脚本 `ppocr.py` 逐步对齐）：
///
/// - 输入 `x` float32 [1,3,48,W]，**BGR**、`(x/255 - 0.5) / 0.5`。行图等比缩放到
///   高 48，宽 `ceil(48 * w / h)`；W = max(320, 该宽)，右侧零填充。
/// - 输出 [1,T,18710] 逐帧 logits；索引 0 = blank，1..18708 = `inference.yml`
///   的 `character_dict`，18709 = 空格（`use_space_char`）。
/// - 解码：逐帧 argmax，合并相邻重复，去 blank。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'package:fushi_engine/ocr/ocr_inference.dart';

/// 输入高。
const int kPpRecHeight = 48;

/// 最小输入宽（`RecResizeImg.image_shape` = [3,48,320]）。
const int kPpRecMinWidth = 320;

/// 从 `inference.yml` 文本解析 `character_dict` 列表。
///
/// 不引入 YAML 依赖：该文件里的字典项只有两种形式——裸字符（含 U+3000 全角
/// 空格）和单引号标量（`''` 表示一个 `'`）；其余 YAML 语法这里不需要、也不
/// 假装支持——遇到就抛，绝不静默解析成错位的词表（错位一格整行全错）。
List<String> parsePpOcrCharacterDict(String yaml) {
  final List<String> lines = yaml.split('\n');
  final int start = lines.indexWhere(
    (String l) => l.trim() == 'character_dict:',
  );
  if (start < 0) {
    throw const FormatException('character_dict not found in inference.yml');
  }
  final List<String> chars = <String>[];
  for (int i = start + 1; i < lines.length; i++) {
    final String line = lines[i].replaceFirst(RegExp(r'\r$'), '');
    if (!line.startsWith('  - ')) {
      break;
    }
    chars.add(_yamlScalar(line.substring(4)));
  }
  if (chars.isEmpty) {
    throw const FormatException('character_dict is empty');
  }
  return chars;
}

String _yamlScalar(String raw) {
  if (raw.startsWith("'")) {
    if (raw.length < 2 || !raw.endsWith("'")) {
      throw FormatException('unterminated single-quoted scalar: $raw');
    }
    return raw.substring(1, raw.length - 1).replaceAll("''", "'");
  }
  if (raw.startsWith('"') || raw.startsWith('[') || raw.startsWith('{')) {
    throw FormatException('unsupported YAML scalar form: $raw');
  }
  return raw;
}

/// CTC 词表：blank + 字典 + 空格。
List<String> buildPpOcrCtcVocab(List<String> characterDict) => <String>[
  '',
  ...characterDict,
  ' ',
];

/// 行图 → [1,3,48,W] BGR CHW float32；返回张量与 W。
({Float32List data, int width}) ppRecPreprocess(img.Image line) {
  final int scaledW = math.max(
    1,
    (kPpRecHeight * line.width / line.height).ceil(),
  );
  final int inputW = math.max(kPpRecMinWidth, scaledW);
  final img.Image resized = img.copyResize(
    line,
    width: scaledW,
    height: kPpRecHeight,
    interpolation: img.Interpolation.linear,
  );
  final int planeSize = kPpRecHeight * inputW;
  final Float32List chw = Float32List(3 * planeSize); // 填充区保持 0
  for (int y = 0; y < kPpRecHeight; y++) {
    for (int x = 0; x < scaledW; x++) {
      final img.Pixel pixel = resized.getPixel(x, y);
      final int index = y * inputW + x;
      chw[index] = (pixel.b / 255.0 - 0.5) / 0.5;
      chw[planeSize + index] = (pixel.g / 255.0 - 0.5) / 0.5;
      chw[2 * planeSize + index] = (pixel.r / 255.0 - 0.5) / 0.5;
    }
  }
  return (data: chw, width: inputW);
}

int _ppRecContentWidth(img.Image line, int inputWidth) {
  final int scaledWidth = math.max(
    1,
    (kPpRecHeight * line.width / line.height).ceil(),
  );
  return math.min(inputWidth, scaledWidth);
}

/// CTC 贪心解码：[logits] 为 [T, V] 行主序。
String ctcGreedyDecode(
  Float32List logits,
  int frames,
  int vocabSize,
  List<String> vocab,
) {
  assert(logits.length == frames * vocabSize);
  final StringBuffer out = StringBuffer();
  int previous = -1;
  for (int t = 0; t < frames; t++) {
    final int base = t * vocabSize;
    int best = 0;
    double bestScore = logits[base];
    for (int v = 1; v < vocabSize; v++) {
      final double s = logits[base + v];
      if (s > bestScore) {
        bestScore = s;
        best = v;
      }
    }
    if (best != previous && best != 0) {
      out.write(vocab[best]);
    }
    previous = best;
  }
  return out.toString();
}

/// One non-blank CTC run from a PP-OCR recognition output.
///
/// [left], [right], and [centerX] are approximate positions in the original
/// line image.  They describe the receptive-field interval of the argmax
/// frames, not a glyph bounding box.  A token whose run is entirely in the
/// right padding has no position ([hasPosition] is false), but remains in the
/// decoded text for compatibility with the ordinary CTC output.
class PpOcrCtcToken {
  const PpOcrCtcToken({
    required this.tokenId,
    required this.text,
    required this.frameStart,
    required this.frameEndExclusive,
    required this.inputLeft,
    required this.inputRight,
    required this.left,
    required this.right,
    required this.confidence,
  });

  /// Index in the CTC vocabulary, including blank at index 0.
  final int tokenId;

  /// Vocabulary text for this CTC token.
  final String text;

  /// Consecutive argmax frame run, with [frameStart] inclusive and
  /// [frameEndExclusive] exclusive.  Blank-separated repeated characters are
  /// represented by separate token objects.
  final int frameStart;
  final int frameEndExclusive;

  /// Approximate interval in the model input's horizontal coordinate system,
  /// including any right padding.
  final double inputLeft;
  final double inputRight;

  /// Approximate interval in the original line image.  Both are null when the
  /// argmax run lies entirely in right padding.
  final double? left;
  final double? right;

  /// Mean argmax probability over the frames in this run.
  final double confidence;

  bool get hasPosition => left != null && right != null;

  double? get centerX {
    final double? tokenLeft = left;
    final double? tokenRight = right;
    if (tokenLeft == null || tokenRight == null) return null;
    return (tokenLeft + tokenRight) / 2;
  }
}

/// Detailed greedy CTC output for one PP-OCR line.
class PpOcrLineRecognition {
  PpOcrLineRecognition({
    required this.text,
    required List<PpOcrCtcToken> tokens,
    required this.lineWidth,
    required this.lineHeight,
    required this.contentWidth,
    required this.inputWidth,
  }) : tokens = List<PpOcrCtcToken>.unmodifiable(tokens);

  const PpOcrLineRecognition.empty()
    : text = '',
      tokens = const <PpOcrCtcToken>[],
      lineWidth = 0,
      lineHeight = 0,
      contentWidth = 0,
      inputWidth = 0;

  /// The same text returned by [PpOcrLineRecognizer.recognizeLine].
  final String text;
  final List<PpOcrCtcToken> tokens;

  /// Original line image dimensions and the two horizontal preprocessing
  /// widths.  [contentWidth] excludes right padding; [inputWidth] includes it.
  final int lineWidth;
  final int lineHeight;
  final int contentWidth;
  final int inputWidth;
}

class _PpOcrDecodedOutput {
  _PpOcrDecodedOutput(this.text, this.tokens);

  final String text;
  final List<PpOcrCtcToken> tokens;
}

_PpOcrDecodedOutput _decodePpOcrDetailed({
  required Float32List data,
  required int frames,
  required int vocabSize,
  required List<String> vocab,
  required int lineWidth,
  required int contentWidth,
  required int inputWidth,
}) {
  final StringBuffer text = StringBuffer();
  final List<PpOcrCtcToken> tokens = <PpOcrCtcToken>[];
  int previous = -1;
  int? runToken;
  int runStart = 0;
  double confidenceSum = 0;
  int confidenceCount = 0;

  void finishRun(int endExclusive) {
    final int? tokenId = runToken;
    if (tokenId == null) return;
    final double inputLeft = runStart / frames * inputWidth;
    final double inputRight = endExclusive / frames * inputWidth;
    final double validInputLeft = math.max(0.0, inputLeft);
    final double validInputRight = math.min(
      contentWidth.toDouble(),
      inputRight,
    );
    final double inputCenter = (inputLeft + inputRight) / 2;
    // A run whose representative frame center is in right padding is still
    // decoded for text compatibility, but is not a usable calibration anchor.
    final bool hasPosition =
        inputCenter >= 0 &&
        inputCenter < contentWidth &&
        validInputRight > validInputLeft;
    final double? left = hasPosition
        ? validInputLeft / contentWidth * lineWidth
        : null;
    final double? right = hasPosition
        ? validInputRight / contentWidth * lineWidth
        : null;
    final double confidence = confidenceCount == 0
        ? 0
        : confidenceSum / confidenceCount;
    tokens.add(
      PpOcrCtcToken(
        tokenId: tokenId,
        text: vocab[tokenId],
        frameStart: runStart,
        frameEndExclusive: endExclusive,
        inputLeft: inputLeft,
        inputRight: inputRight,
        left: left,
        right: right,
        confidence: confidence,
      ),
    );
    text.write(vocab[tokenId]);
    runToken = null;
    confidenceSum = 0;
    confidenceCount = 0;
  }

  for (int t = 0; t < frames; t++) {
    final int base = t * vocabSize;
    int best = 0;
    double bestScore = data[base];
    for (int v = 1; v < vocabSize; v++) {
      final double score = data[base + v];
      if (score > bestScore) {
        bestScore = score;
        best = v;
      }
    }
    final double confidence = _ppOcrFrameConfidence(
      data,
      base,
      vocabSize,
      best,
    );
    if (best == 0 || best != previous) {
      finishRun(t);
    }
    if (best != 0) {
      if (runToken == null) {
        runToken = best;
        runStart = t;
      }
      confidenceSum += confidence;
      confidenceCount++;
    }
    previous = best;
  }
  finishRun(frames);
  return _PpOcrDecodedOutput(text.toString(), tokens);
}

double _ppOcrFrameConfidence(
  Float32List data,
  int base,
  int vocabSize,
  int best,
) {
  double sum = 0;
  bool probabilityRow = true;
  for (int v = 0; v < vocabSize; v++) {
    final double value = data[base + v];
    sum += value;
    if (value < -1e-5 || value > 1.00001) probabilityRow = false;
  }
  if (probabilityRow && (sum - 1).abs() <= 0.02) {
    return data[base + best].clamp(0.0, 1.0);
  }

  // PP-OCR exports normally contain probabilities, but accepting logits here
  // keeps the detailed API correct for equivalent ONNX exports.  Subtracting
  // the row maximum avoids overflow in exp() for large logits.
  final double rowMax = data[base + best];
  double denominator = 0;
  for (int v = 0; v < vocabSize; v++) {
    denominator += math.exp(data[base + v] - rowMax);
  }
  return 1 / denominator;
}

({Float32List data, int frames, int vocabSize}) _validatePpOcrOutput(
  OcrTensor tensor,
  int expectedVocabSize,
) {
  final List<int> shape = tensor.shape;
  if (shape.length != 3 || shape[0] != 1) {
    throw StateError(
      'PP-OCR rec invalid output shape: $shape; expected [1,T,V]',
    );
  }
  final int frames = shape[1];
  final int vocabSize = shape[2];
  if (frames <= 0 || vocabSize <= 0) {
    throw StateError(
      'PP-OCR rec invalid output shape: $shape; T and V must be positive',
    );
  }
  if (vocabSize != expectedVocabSize) {
    throw StateError(
      'PP-OCR rec vocab mismatch: model $vocabSize vs dict '
      '$expectedVocabSize',
    );
  }
  final Float32List? data = tensor.floatData;
  if (data == null) {
    throw StateError('PP-OCR rec output data is missing or not float32');
  }
  final int expectedLength = frames * vocabSize;
  if (data.length != expectedLength) {
    throw StateError(
      'PP-OCR rec output data length mismatch: got ${data.length}, '
      'expected $expectedLength for shape $shape',
    );
  }
  for (final double value in data) {
    if (!value.isFinite) {
      throw StateError('PP-OCR rec output data contains a non-finite value');
    }
  }
  return (data: data, frames: frames, vocabSize: vocabSize);
}

/// 行识别器：会话注入。
class PpOcrLineRecognizer {
  PpOcrLineRecognizer(
    this._session, {
    required this.vocab,
    this.inputName = 'x',
  });

  final OcrSession _session;

  /// [buildPpOcrCtcVocab] 的产物。
  final List<String> vocab;
  final String inputName;

  /// 识别一张已裁好的横排行图。
  ///
  /// 漫画 OCR（`routing_ocr_recognizer`）的热路径：只做单遍 argmax 的
  /// [ctcGreedyDecode]。**不要**改成转调 [recognizeLineDetailed]——详细路径每帧
  /// 要扫整个词表求置信度、对整个输出张量做有限值检查，逐行解码成本约涨数倍，且
  /// 遇到非有限值会抛错（这里照常解码）。解出的文字两条路径一致。
  Future<String> recognizeLine(img.Image line) async {
    if (line.width <= 0 || line.height <= 0) {
      return '';
    }
    final ({Float32List data, int width}) input = ppRecPreprocess(line);
    final Map<String, OcrTensor> outputs = await _session.run(
      <String, OcrTensor>{
        inputName: OcrTensor.float32(input.data, <int>[
          1,
          3,
          kPpRecHeight,
          input.width,
        ]),
      },
    );
    if (outputs.length != 1) {
      throw StateError(
        'PP-OCR rec expected 1 output, got ${outputs.keys.toList()}',
      );
    }
    final OcrTensor logits = outputs.values.single;
    final int vocabSize = logits.shape.last;
    final int frames = logits.shape[logits.shape.length - 2];
    if (vocabSize != vocab.length) {
      throw StateError(
        'PP-OCR rec vocab mismatch: model $vocabSize vs dict ${vocab.length}',
      );
    }
    return ctcGreedyDecode(logits.floatData!, frames, vocabSize, vocab);
  }

  /// 识别一张已裁好的横排行图，并保留 CTC 非 blank token 的位置和置信度。
  ///
  /// 坐标是原始 [line] 的像素坐标。位置是模型帧感受野映射得到的近似
  /// 横向范围，绝不是字形 bbox；右 padding 中的 token 仍保留在 [text]，
  /// 但 [PpOcrCtcToken.hasPosition] 为 false。
  Future<PpOcrLineRecognition> recognizeLineDetailed(img.Image line) async {
    if (line.width <= 0 || line.height <= 0) {
      return const PpOcrLineRecognition.empty();
    }
    final ({Float32List data, int width}) input = ppRecPreprocess(line);
    final int contentWidth = _ppRecContentWidth(line, input.width);
    final Map<String, OcrTensor> outputs = await _session.run(
      <String, OcrTensor>{
        inputName: OcrTensor.float32(input.data, <int>[
          1,
          3,
          kPpRecHeight,
          input.width,
        ]),
      },
    );
    if (outputs.length != 1) {
      throw StateError(
        'PP-OCR rec expected 1 output, got ${outputs.keys.toList()}',
      );
    }
    final OcrTensor logits = outputs.values.single;
    final ({Float32List data, int frames, int vocabSize}) validated =
        _validatePpOcrOutput(logits, vocab.length);
    final _PpOcrDecodedOutput decoded = _decodePpOcrDetailed(
      data: validated.data,
      frames: validated.frames,
      vocabSize: validated.vocabSize,
      vocab: vocab,
      lineWidth: line.width,
      contentWidth: contentWidth,
      inputWidth: input.width,
    );
    return PpOcrLineRecognition(
      text: decoded.text,
      tokens: decoded.tokens,
      lineWidth: line.width,
      lineHeight: line.height,
      contentWidth: contentWidth,
      inputWidth: input.width,
    );
  }

  Future<void> close() => _session.close();
}
