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

  Future<void> close() => _session.close();
}
