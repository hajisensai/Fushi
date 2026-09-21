/// 跨平台漫画分镜检测契约与后处理。
///
/// 算法层只使用 `image` 和共享 ONNX 抽象，模型文件、下载及平台执行器由
/// app 装配。模型契约是 RGB/CHW/640 输入、`[x1,y1,x2,y2,score,class]`
/// 输出（也兼容图内后处理的 `scores/labels/boxes` 三输出）。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/text_detector.dart'
    show LetterboxTransform, computeLetterbox, kDetInputSize, rtdetrPreprocess;
import 'package:image/image.dart' as img;

const int kPanelClassId = 0;
const int kPanelTextClassId = 1;
const double kPanelConfidenceThreshold = 0.25;
const double kPanelNmsIouThreshold = 0.50;

enum PanelReadingDirection { rtl, ltr }

class PanelRect {
  const PanelRect({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    this.score = 1,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;
  final double score;

  double get width => math.max(0, right - left);
  double get height => math.max(0, bottom - top);
  double get area => width * height;
  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;

  PanelRect clamp() => PanelRect(
    left: left.clamp(0.0, 1.0),
    top: top.clamp(0.0, 1.0),
    right: right.clamp(0.0, 1.0),
    bottom: bottom.clamp(0.0, 1.0),
    score: score,
  );

  double iou(PanelRect other) {
    final double overlapWidth = math.max(
      0,
      math.min(right, other.right) - math.max(left, other.left),
    );
    final double overlapHeight = math.max(
      0,
      math.min(bottom, other.bottom) - math.max(top, other.top),
    );
    final double intersection = overlapWidth * overlapHeight;
    final double union = area + other.area - intersection;
    return union <= 0 ? 0 : intersection / union;
  }

  Map<String, double> toJson() => <String, double>{
    'left': left,
    'top': top,
    'right': right,
    'bottom': bottom,
    'score': score,
  };
}

class PanelTextBox {
  const PanelTextBox({required this.rect, required this.score});

  final PanelRect rect;
  final double score;
}

enum PanelDetectionStatus { ready, empty, unavailable, failed }

class PanelDetectionResult {
  const PanelDetectionResult({
    required this.status,
    required this.panels,
    this.textBoxes = const <PanelTextBox>[],
    this.error,
  });

  const PanelDetectionResult.unavailable([String? error])
    : this(
        status: PanelDetectionStatus.unavailable,
        panels: const <PanelRect>[],
        error: error,
      );

  final PanelDetectionStatus status;
  final List<PanelRect> panels;
  final List<PanelTextBox> textBoxes;
  final String? error;

  bool get usable => status == PanelDetectionStatus.ready && panels.isNotEmpty;
}

abstract interface class PanelDetector {
  Future<PanelDetectionResult> detect(
    img.Image page, {
    required String pageKey,
    required PanelReadingDirection direction,
  });
}

/// 先按置信度执行贪心 NMS，再将结果分行。
List<PanelRect> orderPanelRects(
  Iterable<PanelRect> input, {
  required PanelReadingDirection direction,
}) {
  final List<PanelRect> candidates =
      input
          .map((PanelRect rect) => rect.clamp())
          .where((PanelRect rect) => rect.area > 0)
          .toList()
        ..sort((PanelRect a, PanelRect b) => b.score.compareTo(a.score));
  final List<PanelRect> kept = <PanelRect>[];
  for (final PanelRect candidate in candidates) {
    if (kept.any(
      (PanelRect existing) => existing.iou(candidate) >= kPanelNmsIouThreshold,
    )) {
      continue;
    }
    kept.add(candidate);
  }
  kept.sort((PanelRect a, PanelRect b) => a.centerY.compareTo(b.centerY));
  final List<List<PanelRect>> rows = <List<PanelRect>>[];
  for (final PanelRect panel in kept) {
    List<PanelRect>? row;
    for (final List<PanelRect> candidate in rows) {
      final double rowY =
          candidate
              .map((PanelRect item) => item.centerY)
              .reduce((double a, double b) => a + b) /
          candidate.length;
      final double tolerance = math.max(
        0.035,
        math.max(
              panel.height,
              candidate
                  .map((PanelRect item) => item.height)
                  .reduce((double a, double b) => math.max(a, b)),
            ) *
            0.5,
      );
      if ((rowY - panel.centerY).abs() <= tolerance) {
        row = candidate;
        break;
      }
    }
    if (row == null) {
      row = <PanelRect>[];
      rows.add(row);
    }
    row.add(panel);
  }
  rows.sort(
    (List<PanelRect> a, List<PanelRect> b) =>
        _rowCenterPanels(a).compareTo(_rowCenterPanels(b)),
  );
  for (final List<PanelRect> row in rows) {
    row.sort(
      (PanelRect a, PanelRect b) => direction == PanelReadingDirection.rtl
          ? b.centerX.compareTo(a.centerX)
          : a.centerX.compareTo(b.centerX),
    );
  }
  return List<PanelRect>.unmodifiable(
    rows.expand((List<PanelRect> row) => row),
  );
}

double _rowCenterPanels(List<PanelRect> row) =>
    row
        .map((PanelRect panel) => panel.centerY)
        .reduce((double a, double b) => a + b) /
    row.length;

/// 将覆盖大部分页面的单框拆成非重叠阅读锚点。
List<PanelRect> splitLargePanel(
  PanelRect panel,
  Iterable<PanelTextBox> textBoxes, {
  required PanelReadingDirection direction,
}) {
  final PanelRect bounded = panel.clamp();
  if (bounded.area <= 0.75) return <PanelRect>[bounded];
  final List<PanelTextBox> inside = textBoxes
      .map(
        (PanelTextBox box) =>
            PanelTextBox(rect: box.rect.clamp(), score: box.score),
      )
      .where((PanelTextBox box) {
        final PanelRect rect = box.rect;
        return rect.area > 0 &&
            rect.centerX >= bounded.left &&
            rect.centerX <= bounded.right &&
            rect.centerY >= bounded.top &&
            rect.centerY <= bounded.bottom;
      })
      .toList();
  if (inside.length < 2) return <PanelRect>[bounded];

  final List<List<PanelTextBox>> rows = <List<PanelTextBox>>[];
  inside.sort(
    (PanelTextBox a, PanelTextBox b) =>
        a.rect.centerY.compareTo(b.rect.centerY),
  );
  for (final PanelTextBox box in inside) {
    List<PanelTextBox>? row;
    for (final List<PanelTextBox> candidate in rows) {
      final double tolerance = math.max(0.025, box.rect.height * 0.75);
      if ((candidate.first.rect.centerY - box.rect.centerY).abs() <=
          tolerance) {
        row = candidate;
        break;
      }
    }
    (row ??= <PanelTextBox>[]).add(box);
  }
  if (rows.length >= 2) {
    rows.sort(
      (List<PanelTextBox> a, List<PanelTextBox> b) =>
          _rowCenter(a).compareTo(_rowCenter(b)),
    );
    final List<PanelRect> strips = <PanelRect>[];
    for (int i = 0; i < rows.length; i++) {
      final double current = _rowCenter(rows[i]);
      final double previous = i == 0
          ? bounded.top
          : (_rowCenter(rows[i - 1]) + current) / 2;
      final double next = i + 1 == rows.length
          ? bounded.bottom
          : (current + _rowCenter(rows[i + 1])) / 2;
      if (next - previous > 0.01) {
        strips.add(
          PanelRect(
            left: bounded.left,
            top: previous,
            right: bounded.right,
            bottom: next,
            score: bounded.score,
          ),
        );
      }
    }
    return strips.length >= 2 ? strips : <PanelRect>[bounded];
  }

  inside.sort(
    (PanelTextBox a, PanelTextBox b) => direction == PanelReadingDirection.rtl
        ? b.rect.centerX.compareTo(a.rect.centerX)
        : a.rect.centerX.compareTo(b.rect.centerX),
  );
  final List<PanelRect> columns = <PanelRect>[];
  for (int i = 0; i < inside.length; i++) {
    final double current = inside[i].rect.centerX;
    final double previous = i == 0
        ? bounded.left
        : (inside[i - 1].rect.centerX + current) / 2;
    final double next = i + 1 == inside.length
        ? bounded.right
        : (current + inside[i + 1].rect.centerX) / 2;
    if (next - previous > 0.01) {
      columns.add(
        PanelRect(
          left: previous,
          top: bounded.top,
          right: next,
          bottom: bounded.bottom,
          score: bounded.score,
        ),
      );
    }
  }
  return columns.length >= 2 ? columns : <PanelRect>[bounded];
}

double _rowCenter(List<PanelTextBox> row) =>
    row
        .map((PanelTextBox box) => box.rect.centerY)
        .reduce((double a, double b) => a + b) /
    row.length;

class OnnxPanelDetector implements PanelDetector {
  OnnxPanelDetector(
    this._session, {
    this.inputName = 'images',
    this.outputName,
    this.scoreThreshold = kPanelConfidenceThreshold,
    this.modelRevision = 'unknown',
    this.cropParameters = 'none',
    PanelDetectionCache? cache,
  }) : _cache = cache ?? PanelDetectionCache();

  final OcrSession _session;
  final String inputName;
  final String? outputName;
  final double scoreThreshold;
  final String modelRevision;

  /// Crop/viewport parameters are part of the cache identity even though the
  /// current detector uses the complete page. Future callers can therefore
  /// safely reuse one detector when a crop-aware preprocessor is added.
  final String cropParameters;
  final PanelDetectionCache _cache;
  Future<void> _serial = Future<void>.value();

  @override
  Future<PanelDetectionResult> detect(
    img.Image page, {
    required String pageKey,
    required PanelReadingDirection direction,
  }) {
    final String key =
        '$pageKey|$modelRevision|${direction.name}|$cropParameters|640x640';
    final PanelDetectionResult? cached = _cache.read(key);
    if (cached != null) return Future<PanelDetectionResult>.value(cached);
    final Future<PanelDetectionResult> result = _serial.then((_) async {
      final PanelDetectionResult? again = _cache.read(key);
      if (again != null) return again;
      final PanelDetectionResult computed = await _detectUnlocked(
        page,
        direction,
      );
      _cache.write(key, computed);
      return computed;
    });
    _serial = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<PanelDetectionResult> _detectUnlocked(
    img.Image page,
    PanelReadingDirection direction,
  ) async {
    try {
      final LetterboxTransform transform = computeLetterbox(
        page.width,
        page.height,
      );
      final Float32List input = rtdetrPreprocess(page, transform);
      final Map<String, OcrTensor> outputs = await _session.run(
        <String, OcrTensor>{
          inputName: OcrTensor.float32(input, const <int>[
            1,
            3,
            kDetInputSize,
            kDetInputSize,
          ]),
        },
      );
      final List<_PanelDetection> detections = _decode(outputs, transform);
      final List<PanelRect> rawPanels = <PanelRect>[];
      final List<PanelTextBox> text = <PanelTextBox>[];
      for (final _PanelDetection detection in detections) {
        if (detection.classId == kPanelClassId) {
          rawPanels.add(detection.rect.copyWith(score: detection.score));
        } else if (detection.classId == kPanelTextClassId) {
          text.add(
            PanelTextBox(
              rect: detection.rect.copyWith(score: detection.score),
              score: detection.score,
            ),
          );
        }
      }
      final List<PanelRect> expanded = <PanelRect>[];
      for (final PanelRect panel in orderPanelRects(
        rawPanels,
        direction: direction,
      )) {
        expanded.addAll(splitLargePanel(panel, text, direction: direction));
      }
      final List<PanelRect> ordered = orderPanelRects(
        expanded,
        direction: direction,
      );
      return PanelDetectionResult(
        status: ordered.isEmpty
            ? PanelDetectionStatus.empty
            : PanelDetectionStatus.ready,
        panels: ordered,
        textBoxes: List<PanelTextBox>.unmodifiable(text),
      );
    } on Object catch (error) {
      return PanelDetectionResult(
        status: PanelDetectionStatus.failed,
        panels: const <PanelRect>[],
        error: '$error',
      );
    }
  }

  List<_PanelDetection> _decode(
    Map<String, OcrTensor> outputs,
    LetterboxTransform transform,
  ) {
    final OcrTensor? scores = outputs['scores'];
    final OcrTensor? labels = outputs['labels'];
    final OcrTensor? boxes = outputs['boxes'];
    if (scores != null && labels != null && boxes != null) {
      final List<num>? scoreData = scores.floatData;
      final List<num>? labelData =
          labels.floatData ?? labels.intData ?? labels.int32Data;
      final Float32List? boxData = boxes.floatData;
      if (scoreData == null ||
          labelData == null ||
          boxData == null ||
          scoreData.length != labelData.length ||
          boxData.length != scoreData.length * 4) {
        throw StateError('invalid processed panel output shape');
      }
      return <_PanelDetection>[
        for (int i = 0; i < scoreData.length; i++)
          if (scoreData[i].toDouble() >= scoreThreshold)
            _PanelDetection(
              rect: _toNormalizedRect(boxData, i * 4, transform),
              score: scoreData[i].toDouble(),
              classId: labelData[i].round(),
            ),
      ];
    }
    final OcrTensor? tensor = outputName == null
        ? (outputs['output0'] ??
              (outputs.isEmpty ? null : outputs.values.first))
        : outputs[outputName!];
    final Float32List? values = tensor?.floatData;
    if (values == null || tensor == null || !_isNx6Shape(tensor.shape))
      throw StateError('panel detector output must contain Nx6 float values');
    return <_PanelDetection>[
      for (int offset = 0; offset < values.length; offset += 6)
        if (values[offset + 4] >= scoreThreshold)
          _PanelDetection(
            rect: _toNormalizedRect(values, offset, transform),
            score: values[offset + 4],
            classId: values[offset + 5].round(),
          ),
    ];
  }

  bool _isNx6Shape(List<int> shape) =>
      (shape.length == 2 && shape[1] == 6) ||
      (shape.length == 3 && shape[0] == 1 && shape[2] == 6);

  PanelRect _toNormalizedRect(
    Float32List values,
    int offset,
    LetterboxTransform transform,
  ) {
    final double x1 = values[offset];
    final double y1 = values[offset + 1];
    final double x2 = values[offset + 2];
    final double y2 = values[offset + 3];
    final bool normalized = <double>[
      x1,
      y1,
      x2,
      y2,
    ].every((double value) => value.abs() <= 1.0);
    final double scaleX = normalized
        ? 1
        : transform.srcWidth / transform.dstWidth;
    final double scaleY = normalized
        ? 1
        : transform.srcHeight / transform.dstHeight;
    return PanelRect(
      left: normalized ? x1 : x1 * scaleX / transform.srcWidth,
      top: normalized ? y1 : y1 * scaleY / transform.srcHeight,
      right: normalized ? x2 : x2 * scaleX / transform.srcWidth,
      bottom: normalized ? y2 : y2 * scaleY / transform.srcHeight,
    ).clamp();
  }

  Future<void> close() => _session.close();
}

class _PanelDetection {
  const _PanelDetection({
    required this.rect,
    required this.score,
    required this.classId,
  });
  final PanelRect rect;
  final double score;
  final int classId;
}

extension on PanelRect {
  PanelRect copyWith({double? score}) => PanelRect(
    left: left,
    top: top,
    right: right,
    bottom: bottom,
    score: score ?? this.score,
  );
}

class PanelDetectionCache {
  PanelDetectionCache({this.capacity = 32}) : assert(capacity > 0);
  final int capacity;
  final Map<String, PanelDetectionResult> _entries =
      <String, PanelDetectionResult>{};

  PanelDetectionResult? read(String key) {
    final PanelDetectionResult? result = _entries.remove(key);
    if (result != null) _entries[key] = result;
    return result;
  }

  void write(String key, PanelDetectionResult value) {
    _entries.remove(key);
    _entries[key] = value;
    while (_entries.length > capacity) _entries.remove(_entries.keys.first);
  }

  void clear() => _entries.clear();
}
