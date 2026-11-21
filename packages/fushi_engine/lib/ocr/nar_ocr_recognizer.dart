/// muscgab manga-ocr-nar-small 的块识别器：一个文字块一次前向，非自回归，直接给出
/// 整块文本（最多 65 个字），不给字框。
///
/// 契约照上游参考实现逐行移植（`manga_ocr_nar_small/preprocess.py`、`vocab.py`、
/// `backends/onnx.py`，HF `muscgab/manga-ocr-nar-small` revision 81ff4f33）：
///
/// - 裁图保持比例缩放到「14 px 格子数不超过 324」（[narGrid] 是上游 `pad_grid` 的
///   二分搜索），贴在格子画布左上角，其余填缩放图四条边像素的逐通道中位数；按
///   CLIP 的均值 / 方差归一化后切成 14×14 的格子。
/// - 输入都**没有 batch 维**：`P` float32 `[324, 588]`（每格 3×14×14，通道在前），
///   `V` float32 `[324]`（有效格 1、补位 0），`R` / `C` int32 `[324]`（格子的行 / 列），
///   `H` / `W` int32 `[1]`（格子画布的行 / 列数）。补位的格子全 0。
/// - 输出 `ids` int32 `[65]`：字表下标，等于字表长度（6817）的是结束符，文本在第一
///   个结束符处截断。没有分数。
/// - 字表：`nar_vocabulary_6817.json` 的 `characters`（与 charspot-nano 的字表是
///   同一个文件）。
///
/// 两种后端都要接：app 的插件后端把整数输出读成 float32，服务端 FFI 后端按 int32
/// 原样给——[_tensorInts] 两种都认。
///
/// 缩放：同 charspot（`charspot_ocr_recognizer.dart` 的库注释）——上游用 PIL
/// bicubic，原生图像内核没有，缩小用区域平均、放大用双线性。
///
/// 行几何：模型不给字框，整块读出的文本按块内 PP-OCRv6 small det 检出的列 / 行的
/// 字格容量切开（`layoutOcrTextOnLines`，与路由识别器对整块识别器的做法相同），
/// 所以没有逐字命中格，阅读器按行均分。
///
/// 两种情况改为逐行读（每行单独交模型，行文本与行框一一对应）：
///
/// - 块太大（整张截图、整页文字图）：格子预算固定，大块被压到字只剩几个像素。判据
///   与 charspot 相同（[charspotLinesReadableAt]，行厚缩到模型输入后低于
///   [kCharspotMinLineInputPx]）：两个模型的输入面积几乎一样（324×14² = 63504 px，
///   charspot-small 是 256×16² = 65536 px），阈值直接沿用，没有在 nar 上另测。
/// - 65 个输出位全部用完、没有结束符：上游写明「更长的文字块要先切开」，这时整块
///   读出的文本是被截断的。
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'package:fushi_engine/media/image_kernels.dart';
import 'package:fushi_engine/ocr/charspot_ocr_recognizer.dart'
    show
        charspotBorderMedian,
        charspotInterpolation,
        charspotLinesReadableAt,
        kCharspotLinePadding,
        pythonRound;
import 'package:fushi_engine/ocr/manga_ocr_pipeline.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_line_layout.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/ppocr_line_detector.dart';

/// 格子边长（像素）。
const int kNarPatch = 14;

/// 格子预算（上游 `BUDGET`）。
const int kNarPatchBudget = 324;

/// 每格的特征数：3 通道 × 14 × 14。
const int kNarPatchFeatures = 3 * kNarPatch * kNarPatch;

/// 输出位数：一个块最多读出这么多字。
const int kNarMaxOutputLength = 65;

/// 字表长度（`config.json` 的 `vocab`）；id 等于它是结束符。
const int kNarVocabSize = 6817;

/// CLIP 的逐通道均值 / 标准差（RGB，0–1 口径）。
const List<double> _kNarMean = <double>[0.48145466, 0.4578275, 0.40821073];
const List<double> _kNarStd = <double>[0.26862954, 0.26130258, 0.27577711];

/// 解析 `nar_vocabulary_6817.json`，产出 id → 字符表（长 [kNarVocabSize]）。
List<String> parseNarVocab(String json) {
  final Object? decoded = jsonDecode(json);
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('nar vocabulary is not a JSON object');
  }
  final Object? characters = decoded['characters'];
  if (characters is! List<Object?>) {
    throw const FormatException('nar vocabulary has no "characters" list');
  }
  if (characters.length != kNarVocabSize) {
    throw FormatException(
      'nar vocabulary lists ${characters.length} characters, '
      'the model has $kNarVocabSize',
    );
  }
  return List<String>.unmodifiable(<String>[
    for (final Object? c in characters) c! as String,
  ]);
}

/// [narGrid] 的结果：缩放比例与格子行列数。
typedef NarGrid = ({double scale, int rows, int cols});

/// 上游 `pad_grid`：格子数不超过 [kNarPatchBudget] 的最大比例（60 次二分）。
NarGrid narGrid(int height, int width) {
  double lo = 1e-4;
  double hi = 1000.0;
  for (int i = 0; i < 60; i++) {
    final double mid = (lo + hi) / 2;
    final int cells =
        (height * mid / kNarPatch).ceil() * (width * mid / kNarPatch).ceil();
    if (cells <= kNarPatchBudget) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return (
    scale: lo,
    rows: (height * lo / kNarPatch).ceil(),
    cols: (width * lo / kNarPatch).ceil(),
  );
}

/// [narPreprocess] 的结果：六个模型输入（都按 [kNarPatchBudget] 补齐）。
class NarInput {
  const NarInput({
    required this.patches,
    required this.valid,
    required this.rows,
    required this.cols,
    required this.gridRows,
    required this.gridCols,
  });

  /// `P`：`[324, 588]`，每格通道在前（c, y, x）。
  final Float32List patches;

  /// `V`：`[324]`。
  final Float32List valid;

  /// `R` / `C`：`[324]`。
  final Int32List rows;
  final Int32List cols;

  /// `H` / `W`。
  final int gridRows;
  final int gridCols;

  Map<String, OcrTensor> toTensors() => <String, OcrTensor>{
    'P': OcrTensor.float32(patches, const <int>[
      kNarPatchBudget,
      kNarPatchFeatures,
    ]),
    'V': OcrTensor.float32(valid, const <int>[kNarPatchBudget]),
    'R': OcrTensor.int32(rows, const <int>[kNarPatchBudget]),
    'C': OcrTensor.int32(cols, const <int>[kNarPatchBudget]),
    'H': OcrTensor.int32(Int32List.fromList(<int>[gridRows]), const <int>[1]),
    'W': OcrTensor.int32(Int32List.fromList(<int>[gridCols]), const <int>[1]),
  };
}

/// 上游 `preprocess`：保持比例缩放、贴左上、其余填边缘中位色，归一化后切格子。
NarInput narPreprocess(img.Image crop) {
  final NarGrid grid = narGrid(crop.height, crop.width);
  final int canvasWidth = grid.cols * kNarPatch;
  final int canvasHeight = grid.rows * kNarPatch;
  final int rw = math.max(
    1,
    math.min(canvasWidth, pythonRound(crop.width * grid.scale)),
  );
  final int rh = math.max(
    1,
    math.min(canvasHeight, pythonRound(crop.height * grid.scale)),
  );
  final img.Image resized = resizeImageExact(
    crop,
    width: rw,
    height: rh,
    interpolation: charspotInterpolation(
      fromWidth: crop.width,
      fromHeight: crop.height,
      toWidth: rw,
      toHeight: rh,
    ),
  );
  final Uint8List rgb = resized.getBytes(order: img.ChannelOrder.rgb);
  final List<int> fill = charspotBorderMedian(rgb, width: rw, height: rh);
  // 归一化查表：每通道 256 个取值。
  final List<Float32List> normalized = <Float32List>[
    for (int c = 0; c < 3; c++)
      Float32List.fromList(<double>[
        for (int v = 0; v < 256; v++) (v / 255.0 - _kNarMean[c]) / _kNarStd[c],
      ]),
  ];
  final int cells = grid.rows * grid.cols;
  final Float32List patches = Float32List(kNarPatchBudget * kNarPatchFeatures);
  const int plane = kNarPatch * kNarPatch;
  for (int cell = 0; cell < cells; cell++) {
    final int cellRow = cell ~/ grid.cols;
    final int cellCol = cell % grid.cols;
    final int base = cell * kNarPatchFeatures;
    for (int py = 0; py < kNarPatch; py++) {
      final int y = cellRow * kNarPatch + py;
      for (int px = 0; px < kNarPatch; px++) {
        final int x = cellCol * kNarPatch + px;
        final int at = base + py * kNarPatch + px;
        if (y < rh && x < rw) {
          final int s = (y * rw + x) * 3;
          patches[at] = normalized[0][rgb[s]];
          patches[plane + at] = normalized[1][rgb[s + 1]];
          patches[2 * plane + at] = normalized[2][rgb[s + 2]];
        } else {
          patches[at] = normalized[0][fill[0]];
          patches[plane + at] = normalized[1][fill[1]];
          patches[2 * plane + at] = normalized[2][fill[2]];
        }
      }
    }
  }
  final Float32List valid = Float32List(kNarPatchBudget);
  final Int32List rows = Int32List(kNarPatchBudget);
  final Int32List cols = Int32List(kNarPatchBudget);
  for (int cell = 0; cell < cells; cell++) {
    valid[cell] = 1;
    rows[cell] = cell ~/ grid.cols;
    cols[cell] = cell % grid.cols;
  }
  return NarInput(
    patches: patches,
    valid: valid,
    rows: rows,
    cols: cols,
    gridRows: grid.rows,
    gridCols: grid.cols,
  );
}

/// 整数输出：FFI 后端给 int32 / int64，插件后端读成 float32。
List<int> _tensorInts(OcrTensor tensor) {
  final Int32List? i32 = tensor.int32Data;
  if (i32 != null) return i32;
  final Int64List? i64 = tensor.intData;
  if (i64 != null) return i64;
  return <int>[for (final double v in tensor.floatData!) v.round()];
}

/// [decodeNarIds] 的结果：文本，以及输出位是否全部用完（没有结束符，文本可能被
/// 截断）。
typedef NarText = ({String text, bool truncated});

/// 上游 `Vocab.decode`：在第一个结束符（id == 字表长度）处截断。字表外的 id 抛
/// [StateError]（字表与模型不配套）。
NarText decodeNarIds(List<int> ids, List<String> vocab) {
  final StringBuffer text = StringBuffer();
  for (final int id in ids) {
    if (id == vocab.length) return (text: text.toString(), truncated: false);
    if (id < 0 || id > vocab.length) {
      throw StateError(
        'nar id $id outside the ${vocab.length}-entry vocabulary',
      );
    }
    text.write(vocab[id]);
  }
  return (text: text.toString(), truncated: true);
}

/// manga-ocr-nar-small 块识别器。与 charspot 一样不经路由识别器，自己就是 isolate
/// 里的顶层识别器：每个块先整块读，方向与行几何按块内检出的列 / 行给。
class NarOcrRecognizer
    implements
        LineOcrRecognizer,
        OrientedOcrRecognizer,
        LineLayoutOcrRecognizer {
  NarOcrRecognizer(
    this._session, {
    required this.vocab,
    required PpOcrLineDetector lineDetector,
  }) : _lineDetector = lineDetector;

  final OcrSession _session;

  /// [parseNarVocab] 的产物。
  final List<String> vocab;

  /// 块内列 / 行检测（PP-OCRv6 small det）：给整块文本配行几何，块太大或文本太长
  /// 时切行。
  final PpOcrLineDetector _lineDetector;

  Future<void> close() => _session.close();

  Future<NarText> _read(img.Image crop) async {
    final Map<String, OcrTensor> outputs = await _session.run(
      narPreprocess(crop).toTensors(),
    );
    final OcrTensor? ids = outputs['ids'];
    if (ids == null) {
      throw StateError(
        'nar model has no "ids" output (got ${outputs.keys.toList()})',
      );
    }
    return decodeNarIds(_tensorInts(ids), vocab);
  }

  @override
  Future<String> recognize(img.Image page, OcrRect box) async =>
      (await recognizeWithLines(
        page,
        box,
        vertical: isVerticalBlock(box),
      )).text;

  /// 整块一次前向，文本按检出的列 / 行切开。块缩到模型输入后行太细
  /// （[charspotLinesReadableAt]）或输出位用完时改为逐行读。[lineHints] 给了就用
  /// 它，不再检测。
  @override
  Future<OcrRecognition> recognizeWithLines(
    img.Image page,
    OcrRect box, {
    required bool vertical,
    List<OcrRect>? lineHints,
  }) async {
    final OcrBlockCrop? crop = cropOcrBlock(page, box);
    if (crop == null) return OcrRecognition(text: '', vertical: vertical);
    final ({List<OcrRect> lines, double tilt}) detected = lineHints != null
        ? (lines: lineHints, tilt: 0.0)
        : await _lineDetector.detectLayoutInBlock(page, box);
    // 方向按检出行投票（宽扁的多列竖排常被块外形带偏），没有明确的行时保持传入的
    // 方向；切行与排版用同一个结论。
    final bool blockVertical =
        voteOcrLineOrientation(detected.lines) ?? vertical;
    final List<OcrRect> lines = orderOcrLinesForReading(
      mergeOcrLineFragments(
        dropOcrRubyLines(detected.lines, vertical: blockVertical),
        vertical: blockVertical,
      ),
      vertical: blockVertical,
    );
    final double scale = narGrid(crop.image.height, crop.image.width).scale;
    if (scale < 1 && !charspotLinesReadableAt(detected.lines, scale)) {
      return _recognizeByLines(
        page,
        lines,
        vertical: blockVertical,
        tilt: detected.tilt,
      );
    }
    final NarText read = await _read(crop.image);
    if (read.truncated && lines.length > 1) {
      return _recognizeByLines(
        page,
        lines,
        vertical: blockVertical,
        tilt: detected.tilt,
      );
    }
    if (read.text.isEmpty) return OcrRecognition(text: '', vertical: vertical);
    final OcrLineLayout? layout = layoutOcrTextOnLines(
      read.text,
      lines,
      vertical: blockVertical,
    );
    if (layout == null) {
      return OcrRecognition(text: read.text, vertical: vertical);
    }
    return OcrRecognition(
      text: read.text,
      vertical: blockVertical,
      lines: layout.lines,
      lineBoxes: layout.boxes,
      lineTilt: detected.tilt,
    );
  }

  /// 逐行读 [lines]（页面坐标、阅读序、已去注音并合并碎片）：每行外扩
  /// [kCharspotLinePadding] 后单独交模型，读不出字的行不出框。
  Future<OcrRecognition> _recognizeByLines(
    img.Image page,
    List<OcrRect> lines, {
    required bool vertical,
    required double tilt,
  }) async {
    final List<String> texts = <String>[];
    final List<OcrRect> boxes = <OcrRect>[];
    for (final OcrRect line in lines) {
      final OcrBlockCrop? crop = cropOcrBlock(
        page,
        OcrRect(
          left: line.left - kCharspotLinePadding,
          top: line.top - kCharspotLinePadding,
          right: line.right + kCharspotLinePadding,
          bottom: line.bottom + kCharspotLinePadding,
        ),
      );
      if (crop == null) continue;
      final String text = (await _read(crop.image)).text;
      if (text.isEmpty) continue;
      texts.add(text);
      boxes.add(line);
    }
    if (texts.isEmpty) return OcrRecognition(text: '', vertical: vertical);
    return OcrRecognition(
      text: texts.join(),
      vertical: vertical,
      lines: texts,
      lineBoxes: boxes,
      lineTilt: tilt,
    );
  }

  /// 页面里的每个块各读一次；方向由块内检出的列 / 行决定，块外形只在没有明确的行
  /// 时兜底。
  @override
  Future<List<OcrRecognition>> recognizeOriented(
    img.Image page,
    List<OcrRect> boxes,
  ) async => <OcrRecognition>[
    for (final OcrRect box in boxes)
      await recognizeWithLines(page, box, vertical: isVerticalBlock(box)),
  ];

  /// 旧版缓存升级（[LineLayoutOcrRecognizer]）：整块重读，不用缓存里的 [text]——
  /// 这一块在新识别里是整块读还是逐行读，只有重读才知道。
  @override
  Future<OcrRecognition> layoutRecognized(
    img.Image page,
    OcrRect box,
    String text, {
    required bool vertical,
  }) => recognizeWithLines(page, box, vertical: vertical);
}
