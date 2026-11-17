/// muscgab manga-ocr-charspot（small / nano）的块识别器：一个文字块一次推理，模型
/// 直接给出每个字的框、分数、字 id 与阅读序（框解码、NMS、去振假名、阅读序都在
/// ONNX 图里）。这里只做前处理、把字按几何排成列 / 行、换回页面坐标。
///
/// 契约照上游参考实现逐行移植（`manga_ocr_charspot_small/core.py` 与
/// `backends/onnx.py`，HF `muscgab/manga-ocr-charspot-small` revision 72ca2920）：
///
/// - 输入 `img` float32 `[1, 3, H, W]`，RGB、原始 0–255（不归一化），H / W 是 16 的
///   倍数。裁图保持比例缩放到「16 px 格子数不超过预算」（small 256 格、nano 196
///   格；[charspotGrid] 是上游 `pad_grid` 的二分搜索），贴在左上角，其余填缩放图
///   四条边像素的逐通道中位数。
/// - 输出 `boxes` `[n, 4]`（输入像素）、`scores` `[n]`、`ids` `[n]`（int64）、
///   `order` `[n]`（int64，阅读序下标）。n 可以为 0。
/// - 字表：`vocab.json` 的 `characters` 补空串到 [kCharspotClassCount]，再接 12 个
///   `!?` 组合字（[kCharspotCombos]），一个 id 是 0~3 个字符。
///
/// 两种后端都要接：app 的插件后端把整数输出读成 float32（`onnx_inference_ort.dart`
/// 的契约），服务端 FFI 后端按 int64 原样给——[_tensorInts] 两种都认。
///
/// 缩放：上游训练用 PIL bicubic，原生图像内核没有 bicubic（只有 nearest / linear /
/// average）。缩小用 average（区域平均，最接近 PIL 缩小时按比例放宽的抗锯齿核），
/// 放大用 linear。JMangaBench 1000 块上与 Python 参考的字错误率差见
/// `kCharspotSmallGeneration` 的实测注释。
///
/// 块太大时（整张截图、整页文字图）：格子预算是固定的，大块被压到字只剩几个像素，
/// 模型读不出来，而且不是读出空串，是读出几个乱字（实测整页 2600×1902 交 small
/// 读出「:マ0Wローなタかの」），所以不能看输出再补救，要在推理前判断。裁图需要
/// 缩小时先用 PP-OCRv6 small det 检出列 / 行，行厚（各行短边的中位数）乘缩放比例
/// 小于 [kCharspotMinLineInputPx] 就改为逐行交 charspot 读
/// （[CharspotOcrRecognizer.recognizeWithLines]）。
///
/// 阈值的依据（2026-11-14，同参数 det 的 Python 移植）：JMangaBench 1000 块里需要
/// 缩小的 250（small）/ 313（nano）块，行厚 × 比例最小 22.6 / 19.0 px；整页是
/// 4.1 / 3.6 px，四分之一页 7.5 / 6.7 px。不缩小的块字只会更大，不检测。
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'package:fushi_engine/media/image_kernels.dart';
import 'package:fushi_engine/ocr/manga_ocr_pipeline.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_line_layout.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/ppocr_line_detector.dart';

/// 模型输入格子边长（像素）。
const int kCharspotCell = 16;

/// `pad_grid` 的搜索格子边长：上游沿用 manga-ocr-nar-small 的 14 px 搜索，再按
/// 16 px 格子放大。
const int _kCharspotSearchCell = 14;

/// small 的格子预算（上游 `BUDGET`）。
const int kCharspotSmallCellBudget = 256;

/// nano 的格子预算。
const int kCharspotNanoCellBudget = 196;

/// 字表补齐到的类数（两个模型 `config.json` 的 `n_cls` 都是 6818）；其后接
/// [kCharspotCombos]，共 `n_out` = 6830 类。
const int kCharspotClassCount = 6818;

/// 竖中横的 `!?` 组合字（上游 `COMBOS`）：先全部两字组合，再全部三字组合。
final List<String> kCharspotCombos = List<String>.unmodifiable(<String>[
  for (final String a in const <String>['!', '?'])
    for (final String b in const <String>['!', '?']) '$a$b',
  for (final String a in const <String>['!', '?'])
    for (final String b in const <String>['!', '?'])
      for (final String c in const <String>['!', '?']) '$a$b$c',
]);

/// 行厚（PP det 各行短边的中位数）缩放到模型输入后低于这个像素数，就当「块被压得
/// 太小」改逐行读（依据见库注释）。
const double kCharspotMinLineInputPx = 14;

/// 逐行读时每条行框四周外扩的像素（与路由层竖行的边距同值）。
const int kCharspotLinePadding = 4;

/// 解析 `vocab.json`，产出 id → 字符串表（长 [kCharspotClassCount] + 12）。
List<String> parseCharspotVocab(String json) {
  final Object? decoded = jsonDecode(json);
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('charspot vocab.json is not a JSON object');
  }
  final Object? characters = decoded['characters'];
  if (characters is! List<Object?>) {
    throw const FormatException('charspot vocab.json has no "characters" list');
  }
  if (characters.length > kCharspotClassCount) {
    throw FormatException(
      'charspot vocab.json lists ${characters.length} characters, '
      'more than the $kCharspotClassCount model classes',
    );
  }
  return List<String>.unmodifiable(<String>[
    for (final Object? c in characters) c! as String,
    for (int i = characters.length; i < kCharspotClassCount; i++) '',
    ...kCharspotCombos,
  ]);
}

/// [charspotGrid] 的结果：缩放比例与格子行列数。
typedef CharspotGrid = ({double scale, int rows, int cols});

/// 上游 `pad_grid`：14 px 网格下格子数不超过 [budget] 的最大比例（60 次二分），
/// 再按 16 px 格子换算比例。
CharspotGrid charspotGrid(int height, int width, {required int budget}) {
  double lo = 1e-4;
  double hi = 1000.0;
  for (int i = 0; i < 60; i++) {
    final double mid = (lo + hi) / 2;
    final int cells =
        (height * mid / _kCharspotSearchCell).ceil() *
        (width * mid / _kCharspotSearchCell).ceil();
    if (cells <= budget) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return (
    scale: lo * kCharspotCell / _kCharspotSearchCell,
    rows: (height * lo / _kCharspotSearchCell).ceil(),
    cols: (width * lo / _kCharspotSearchCell).ceil(),
  );
}

/// Python 3 的 `round()`：恰好一半时取偶数（Dart 的 `round` 远离零取整）。上游几个
/// 模型的前处理都用它算缩放后的宽高（`nar_ocr_recognizer.dart` 同用）。
int pythonRound(double v) {
  final double f = v.floorToDouble();
  final double diff = v - f;
  if (diff > 0.5) return f.toInt() + 1;
  if (diff < 0.5) return f.toInt();
  final int fi = f.toInt();
  return fi.isEven ? fi : fi + 1;
}

/// [charspotPreprocess] 的结果：模型输入（CHW float32，`[3, height, width]`）、
/// 缩放后图的宽高与从模型输入像素换回裁图像素的比例。
class CharspotInput {
  const CharspotInput({
    required this.data,
    required this.width,
    required this.height,
    required this.resizedWidth,
    required this.resizedHeight,
    required this.fillColor,
  });

  final Float32List data;
  final int width;
  final int height;
  final int resizedWidth;
  final int resizedHeight;

  /// 填充色（RGB）。
  final List<int> fillColor;

  /// 输入像素 → 裁图像素（上游 `(img.width / rw, img.height / rh)`）。
  double scaleXFor(int cropWidth) => cropWidth / resizedWidth;
  double scaleYFor(int cropHeight) => cropHeight / resizedHeight;
}

/// 缩放插值：缩小用区域平均，放大用双线性（见库注释）。
img.Interpolation charspotInterpolation({
  required int fromWidth,
  required int fromHeight,
  required int toWidth,
  required int toHeight,
}) => toWidth < fromWidth || toHeight < fromHeight
    ? img.Interpolation.average
    : img.Interpolation.linear;

/// 上游 `preprocess`：保持比例缩放、贴左上、其余填边缘中位色，转 CHW float32。
CharspotInput charspotPreprocess(img.Image crop, {required int budget}) {
  final CharspotGrid grid = charspotGrid(
    crop.height,
    crop.width,
    budget: budget,
  );
  final int gridWidth = grid.cols * kCharspotCell;
  final int gridHeight = grid.rows * kCharspotCell;
  final int rw = math.max(
    1,
    math.min(gridWidth, pythonRound(crop.width * grid.scale)),
  );
  final int rh = math.max(
    1,
    math.min(gridHeight, pythonRound(crop.height * grid.scale)),
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
  final int plane = gridWidth * gridHeight;
  final Float32List data = Float32List(3 * plane);
  for (int c = 0; c < 3; c++) {
    data.fillRange(c * plane, (c + 1) * plane, fill[c].toDouble());
  }
  for (int y = 0; y < rh; y++) {
    final int src = y * rw * 3;
    final int dst = y * gridWidth;
    for (int x = 0; x < rw; x++) {
      final int s = src + x * 3;
      data[dst + x] = rgb[s].toDouble();
      data[plane + dst + x] = rgb[s + 1].toDouble();
      data[2 * plane + dst + x] = rgb[s + 2].toDouble();
    }
  }
  return CharspotInput(
    data: data,
    width: gridWidth,
    height: gridHeight,
    resizedWidth: rw,
    resizedHeight: rh,
    fillColor: fill,
  );
}

/// 上游的填充色：首行、末行、首列、末列（角点各算两次）逐通道 `np.median` 后
/// `astype(uint8)`（截断）。[rgb] 是行紧排的 RGB 字节。
List<int> charspotBorderMedian(
  Uint8List rgb, {
  required int width,
  required int height,
}) {
  final List<List<int>> channels = <List<int>>[<int>[], <int>[], <int>[]];
  void add(int x, int y) {
    final int i = (y * width + x) * 3;
    for (int c = 0; c < 3; c++) {
      channels[c].add(rgb[i + c]);
    }
  }

  for (int x = 0; x < width; x++) {
    add(x, 0);
  }
  for (int x = 0; x < width; x++) {
    add(x, height - 1);
  }
  for (int y = 0; y < height; y++) {
    add(0, y);
  }
  for (int y = 0; y < height; y++) {
    add(width - 1, y);
  }
  return <int>[
    for (final List<int> values in channels) _medianTruncated(values),
  ];
}

int _medianTruncated(List<int> values) {
  final List<int> sorted = List<int>.of(values)..sort();
  final int n = sorted.length;
  if (n.isOdd) return sorted[n ~/ 2];
  return (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) ~/ 2;
}

/// 模型读出的一个字：文字（0~3 个字符，字表补位 id 是空串）、页面框、分数。
class CharspotChar {
  const CharspotChar({
    required this.text,
    required this.rect,
    required this.score,
  });

  final String text;
  final OcrRect rect;
  final double score;
}

/// 整数输出：FFI 后端给 int64 / int32，插件后端读成 float32。
List<int> _tensorInts(OcrTensor tensor) {
  final Int64List? i64 = tensor.intData;
  if (i64 != null) return i64;
  final Int32List? i32 = tensor.int32Data;
  if (i32 != null) return i32;
  return <int>[for (final double v in tensor.floatData!) v.round()];
}

List<double> _tensorDoubles(OcrTensor tensor) {
  final Float32List? f = tensor.floatData;
  if (f != null) return f;
  return <double>[for (final int v in _tensorInts(tensor)) v.toDouble()];
}

OcrTensor _output(Map<String, OcrTensor> outputs, String name) {
  final OcrTensor? tensor = outputs[name];
  if (tensor == null) {
    throw StateError(
      'charspot model has no "$name" output (got ${outputs.keys.toList()})',
    );
  }
  return tensor;
}

/// 模型输出 → 阅读序的字（页面坐标）。框乘 ([scaleX], [scaleY]) 换回裁图像素，
/// 夹进裁图（[cropWidth] × [cropHeight]），再加裁图在页面上的左上角
/// ([originX], [originY])。字表外的 id 抛 [StateError]（字表与模型不配套）。
///
/// 为什么要夹：模型看到的是补齐到整格的画布，裁图只占左上角，框解码又不设边界，
/// 字框可以伸进填充区或小于 0。不夹的话换回页面后字框落在块外（贴着页边的块甚至
/// 落到页面外），行框是字框的外接矩形，跟着一起越界。字本身不删：读出的文本不改，
/// 整个落在填充区的框收成裁图边上的零面积框。
List<CharspotChar> decodeCharspotOutputs(
  Map<String, OcrTensor> outputs, {
  required List<String> vocab,
  required double scaleX,
  required double scaleY,
  required double originX,
  required double originY,
  required int cropWidth,
  required int cropHeight,
}) {
  final List<double> boxes = _tensorDoubles(_output(outputs, 'boxes'));
  final List<double> scores = _tensorDoubles(_output(outputs, 'scores'));
  final List<int> ids = _tensorInts(_output(outputs, 'ids'));
  final List<int> order = _tensorInts(_output(outputs, 'order'));
  final int n = scores.length;
  if (boxes.length != n * 4 || ids.length != n || order.length > n) {
    throw StateError(
      'charspot outputs disagree: ${boxes.length} box values, $n scores, '
      '${ids.length} ids, ${order.length} order entries',
    );
  }
  final List<CharspotChar> chars = <CharspotChar>[];
  for (final int k in order) {
    if (k < 0 || k >= n) {
      throw StateError('charspot order index $k out of range 0..${n - 1}');
    }
    final int id = ids[k];
    if (id < 0 || id >= vocab.length) {
      throw StateError(
        'charspot id $id outside the ${vocab.length}-entry vocabulary',
      );
    }
    final OcrRect inCrop = OcrRect(
      left: boxes[k * 4] * scaleX,
      top: boxes[k * 4 + 1] * scaleY,
      right: boxes[k * 4 + 2] * scaleX,
      bottom: boxes[k * 4 + 3] * scaleY,
    ).clamp(cropWidth.toDouble(), cropHeight.toDouble());
    chars.add(
      CharspotChar(
        text: vocab[id],
        rect: OcrRect(
          left: originX + inCrop.left,
          top: originY + inCrop.top,
          right: originX + inCrop.right,
          bottom: originY + inCrop.bottom,
        ),
        score: scores[k],
      ),
    );
  }
  return chars;
}

/// 一列 / 一行字（阅读序）。
class CharspotLine {
  const CharspotLine(this.chars);

  final List<CharspotChar> chars;

  String get text => chars.map((CharspotChar c) => c.text).join();

  /// 各字框的外接矩形。
  OcrRect get box => OcrRect(
    left: chars.map((CharspotChar c) => c.rect.left).reduce(math.min),
    top: chars.map((CharspotChar c) => c.rect.top).reduce(math.min),
    right: chars.map((CharspotChar c) => c.rect.right).reduce(math.max),
    bottom: chars.map((CharspotChar c) => c.rect.bottom).reduce(math.max),
  );
}

/// [groupCharspotLines] 的结果：块方向与阅读序的列 / 行。
typedef CharspotLayout = ({bool vertical, List<CharspotLine> lines});

double _median(List<double> values) {
  final List<double> sorted = List<double>.of(values)..sort();
  return sorted[(sorted.length - 1) ~/ 2];
}

/// 把阅读序的字按几何切成列（竖排）或行（横排）。空串字（字表补位 id）丢掉。
///
/// 方向：相邻两字中心的位移投票——往下走（|dy| ≥ |dx| 且 dy > 0）算竖排一票，
/// 往右走（|dx| > |dy| 且 dx > 0）算横排一票；平票或不足两个字时取
/// [fallbackVertical]。
///
/// 换列（竖排）：下一个字比上一个字高出半个字以上（回到列顶），或中心横向偏出
/// 当前列的横向范围四分之一个字以上。横排把 x / y 对调。字的尺度 u 取各字框长边
/// 的中位数（上游 `detect` 同口径）。顺序本身不动：`lines.join()` 就是模型给的
/// 阅读序文本。
CharspotLayout groupCharspotLines(
  List<CharspotChar> chars, {
  required bool fallbackVertical,
}) {
  final List<CharspotChar> visible = <CharspotChar>[
    for (final CharspotChar c in chars)
      if (c.text.isNotEmpty) c,
  ];
  if (visible.isEmpty) {
    return (vertical: fallbackVertical, lines: const <CharspotLine>[]);
  }
  int down = 0;
  int right = 0;
  for (int i = 1; i < visible.length; i++) {
    final double dx = visible[i].rect.centerX - visible[i - 1].rect.centerX;
    final double dy = visible[i].rect.centerY - visible[i - 1].rect.centerY;
    if (dy.abs() >= dx.abs() && dy > 0) {
      down++;
    } else if (dx.abs() > dy.abs() && dx > 0) {
      right++;
    }
  }
  final bool vertical = down == right ? fallbackVertical : down > right;
  final double u = _median(<double>[
    for (final CharspotChar c in visible) math.max(c.rect.width, c.rect.height),
  ]);
  final List<CharspotLine> lines = <CharspotLine>[];
  List<CharspotChar> current = <CharspotChar>[visible.first];
  double crossMin = vertical ? visible.first.rect.left : visible.first.rect.top;
  double crossMax = vertical
      ? visible.first.rect.right
      : visible.first.rect.bottom;
  for (int i = 1; i < visible.length; i++) {
    final CharspotChar prev = visible[i - 1];
    final CharspotChar next = visible[i];
    final double along = vertical
        ? next.rect.centerY - prev.rect.centerY
        : next.rect.centerX - prev.rect.centerX;
    final double cross = vertical ? next.rect.centerX : next.rect.centerY;
    final bool sameLine =
        along >= -0.5 * u &&
        cross >= crossMin - 0.25 * u &&
        cross <= crossMax + 0.25 * u;
    if (sameLine) {
      current.add(next);
      crossMin = math.min(crossMin, vertical ? next.rect.left : next.rect.top);
      crossMax = math.max(
        crossMax,
        vertical ? next.rect.right : next.rect.bottom,
      );
      continue;
    }
    lines.add(CharspotLine(current));
    current = <CharspotChar>[next];
    crossMin = vertical ? next.rect.left : next.rect.top;
    crossMax = vertical ? next.rect.right : next.rect.bottom;
  }
  lines.add(CharspotLine(current));
  return (vertical: vertical, lines: lines);
}

/// 缩放比例为 [scale] 的块里，检出的行 [lines] 缩到模型输入后是否还够厚（行厚取各行
/// 短边的中位数）；没有行时为 true（没有能逐行读的东西，整块读）。
bool charspotLinesReadableAt(List<OcrRect> lines, double scale) {
  if (lines.isEmpty) return true;
  final double thickness = _median(<double>[
    for (final OcrRect line in lines) math.min(line.width, line.height),
  ]);
  return thickness * scale >= kCharspotMinLineInputPx;
}

/// charspot 块识别器。不经路由识别器（`routing_ocr_recognizer.dart`）：路由把宽块
/// 切成横行逐行读，charspot 在整块上明显更准（JMangaBench 横排块经路由逐行读字
/// 错误率 10.4%，整块读 4.5%，Dart 管线 2026-11-14 实测），所以每个块都先整块读，
/// 只有块大到读不清时才切列 / 行（[recognizeWithLines]）。它自己就是 isolate 里的
/// 顶层识别器：方向（[OrientedOcrRecognizer]）、行几何（[LineOcrRecognizer]）、
/// 旧缓存升级（[LineLayoutOcrRecognizer]）都由它给。
class CharspotOcrRecognizer
    implements
        LineOcrRecognizer,
        ScoredOcrRecognizer,
        OrientedOcrRecognizer,
        LineLayoutOcrRecognizer {
  CharspotOcrRecognizer(
    this._session, {
    required this.vocab,
    required this.cellBudget,
    required PpOcrLineDetector lineDetector,
  }) : _lineDetector = lineDetector;

  final OcrSession _session;

  /// [parseCharspotVocab] 的产物。
  final List<String> vocab;

  /// 格子预算：small [kCharspotSmallCellBudget]、nano [kCharspotNanoCellBudget]。
  final int cellBudget;

  /// 块太大时切列 / 行用（PP-OCRv6 small det）。
  final PpOcrLineDetector _lineDetector;

  Future<void> close() => _session.close();

  /// 读一张裁图，字换回页面坐标（裁图左上角在页面上是 ([originX], [originY])）。
  Future<List<CharspotChar>> _read(
    img.Image crop, {
    required int originX,
    required int originY,
  }) async {
    final CharspotInput input = charspotPreprocess(crop, budget: cellBudget);
    final Map<String, OcrTensor> outputs = await _session.run(
      <String, OcrTensor>{
        'img': OcrTensor.float32(input.data, <int>[
          1,
          3,
          input.height,
          input.width,
        ]),
      },
    );
    return decodeCharspotOutputs(
      outputs,
      vocab: vocab,
      scaleX: input.scaleXFor(crop.width),
      scaleY: input.scaleYFor(crop.height),
      originX: originX.toDouble(),
      originY: originY.toDouble(),
      cropWidth: crop.width,
      cropHeight: crop.height,
    );
  }

  @override
  Future<String> recognize(img.Image page, OcrRect box) async =>
      (await recognizeScored(page, box)).text;

  @override
  Future<ScoredOcrText> recognizeScored(img.Image page, OcrRect box) async {
    final OcrRecognition r = await recognizeWithLines(
      page,
      box,
      vertical: isVerticalBlock(box),
    );
    return (text: r.text, confidence: r.confidence);
  }

  /// 整块一次推理。裁图要缩小时先检出列 / 行，行缩到模型输入后太细
  /// （[charspotLinesReadableAt]）就改为逐行读（[lineHints] 给了就用它，不再检测）。
  @override
  Future<OcrRecognition> recognizeWithLines(
    img.Image page,
    OcrRect box, {
    required bool vertical,
    List<OcrRect>? lineHints,
  }) async {
    final OcrBlockCrop? crop = cropOcrBlock(page, box);
    if (crop == null) return OcrRecognition(text: '', vertical: vertical);
    final double scale = charspotGrid(
      crop.image.height,
      crop.image.width,
      budget: cellBudget,
    ).scale;
    if (scale < 1) {
      final List<OcrRect> detected =
          lineHints ??
          (await _lineDetector.detectLayoutInBlock(page, box)).lines;
      if (!charspotLinesReadableAt(detected, scale)) {
        return _recognizeByLines(page, detected, vertical: vertical);
      }
    }
    final List<CharspotChar> chars = await _read(
      crop.image,
      originX: crop.x,
      originY: crop.y,
    );
    return charspotRecognition(
      groupCharspotLines(chars, fallbackVertical: vertical),
    );
  }

  /// 逐行读 [detected]（页面坐标的原始检出行）。与逐列 CTC 同一套行处理（方向
  /// 投票、去注音列、合并碎片、阅读序），每行外扩 [kCharspotLinePadding] 后交
  /// charspot。
  Future<OcrRecognition> _recognizeByLines(
    img.Image page,
    List<OcrRect> detected, {
    required bool vertical,
  }) async {
    final bool blockVertical = voteOcrLineOrientation(detected) ?? vertical;
    final List<OcrRect> lines = orderOcrLinesForReading(
      mergeOcrLineFragments(
        dropOcrRubyLines(detected, vertical: blockVertical),
        vertical: blockVertical,
      ),
      vertical: blockVertical,
    );
    final List<CharspotLine> read = <CharspotLine>[];
    final List<OcrRect> accepted = <OcrRect>[];
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
      final List<CharspotChar> chars = await _read(
        crop.image,
        originX: crop.x,
        originY: crop.y,
      );
      // 外扩的边距会带进相邻列 / 行的一角，检出的行框之间也可能互相重叠（整页
      // 截图上实测过），charspot 会把同一个字在两行里各读一遍。只留中心落在本行
      // 框里、且没被前面的行读过（与已收的字 IoU 不超过 0.5）的字。
      final List<CharspotChar> own = <CharspotChar>[
        for (final CharspotChar c in chars)
          if (line.containsPoint(c.rect.centerX, c.rect.centerY) &&
              !accepted.any((OcrRect r) => r.iou(c.rect) > 0.5))
            c,
      ];
      accepted.addAll(<OcrRect>[for (final CharspotChar c in own) c.rect]);
      read.addAll(
        groupCharspotLines(own, fallbackVertical: blockVertical).lines,
      );
    }
    return charspotRecognition((vertical: blockVertical, lines: read));
  }

  /// 页面里的每个块各读一次；方向由读出的字的几何决定（[groupCharspotLines]），
  /// 块外形只在字太少、定不了方向时兜底。
  @override
  Future<List<OcrRecognition>> recognizeOriented(
    img.Image page,
    List<OcrRect> boxes,
  ) async => <OcrRecognition>[
    for (final OcrRect box in boxes)
      await recognizeWithLines(page, box, vertical: isVerticalBlock(box)),
  ];

  /// 旧版缓存升级（[LineLayoutOcrRecognizer]）：行文本与逐字框只有重读才拿得到，
  /// 与逐列 CTC 在路由层的做法相同，整块重读，不用缓存里的 [text]。
  @override
  Future<OcrRecognition> layoutRecognized(
    img.Image page,
    OcrRect box,
    String text, {
    required bool vertical,
  }) => recognizeWithLines(page, box, vertical: vertical);
}

double? _minScore(Iterable<CharspotChar> chars) {
  double? low;
  for (final CharspotChar c in chars) {
    low = minOcrConfidence(low, c.score);
  }
  return low;
}

/// 字 → 逐字命中格：区间按块文本的 UTF-16 偏移（从 [utf16Offset] 起）累加，框是
/// 模型给的字框。
List<OcrGlyphBox> charspotGlyphBoxes(
  List<CharspotChar> chars, {
  int utf16Offset = 0,
}) {
  final List<OcrGlyphBox> boxes = <OcrGlyphBox>[];
  int offset = utf16Offset;
  for (final CharspotChar c in chars) {
    if (c.text.isEmpty) continue;
    boxes.add(
      OcrGlyphBox(start: offset, end: offset + c.text.length, rect: c.rect),
    );
    offset += c.text.length;
  }
  return boxes;
}

/// 排好的列 / 行 → [OcrRecognition]：`lines.join() == text`，行框是各行字框的外接
/// 矩形，逐字命中格就是字框，置信度取各字分数的最小值。没有字时给空文本。
OcrRecognition charspotRecognition(CharspotLayout layout) {
  final List<CharspotLine> lines = <CharspotLine>[
    for (final CharspotLine line in layout.lines)
      if (line.chars.isNotEmpty) line,
  ];
  if (lines.isEmpty) {
    return OcrRecognition(text: '', vertical: layout.vertical);
  }
  final List<String> texts = <String>[
    for (final CharspotLine line in lines) line.text,
  ];
  final List<CharspotChar> all = <CharspotChar>[
    for (final CharspotLine line in lines) ...line.chars,
  ];
  return OcrRecognition(
    text: texts.join(),
    vertical: layout.vertical,
    lines: texts,
    lineBoxes: <OcrRect>[for (final CharspotLine line in lines) line.box],
    confidence: _minScore(all),
    glyphBoxes: charspotGlyphBoxes(all),
  );
}
