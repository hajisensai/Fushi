part of 'gal_lookup_calibration_ocr.dart';

/// Inputs for the frozen v24 geometry fit.  [source] is indexed by logical
/// source position; each unit keeps its UTF-16 [index] for the Hook contract.
class _V24GeometryInput {
  const _V24GeometryInput({
    required this.source,
    required this.alignment,
    required this.selection,
    required this.imageWidth,
    required this.imageHeight,
  });

  final List<_SourceUnit> source;
  final GalCalibrationOcrAlignment alignment;
  final OcrRect selection;
  final double imageWidth;
  final double imageHeight;
}

class _V24Token {
  const _V24Token({
    required this.text,
    required this.rect,
    required this.confidence,
    required this.synthetic,
    required this.ocrTokenIndex,
  });

  final String text;
  final OcrRect rect;
  final double confidence;
  final bool synthetic;
  final int ocrTokenIndex;
}

class _V24Pair {
  const _V24Pair({
    required this.sourcePosition,
    required this.ocrPosition,
    required this.kind,
    required this.token,
  });

  final int sourcePosition;
  final int ocrPosition;
  final String kind;
  final _V24Token token;
}

class _V24Match {
  const _V24Match({
    required this.lineIndex,
    required this.sourceStart,
    required this.sourceEnd,
    required this.pairs,
    required this.line,
  });

  final int lineIndex;
  final int sourceStart;
  final int sourceEnd;
  final List<_V24Pair> pairs;
  final GalCalibrationOcrMatchedLine line;
}

double _v24Finite(Object? value, [double fallback = 0]) {
  final double? number = switch (value) {
    num item => item.toDouble(),
    String item => double.tryParse(item),
    _ => null,
  };
  return number != null && number.isFinite ? number : fallback;
}

double _v24ConfidenceWeight(Object? value, {bool synthetic = false}) {
  if (synthetic) return .08;
  double confidence = _v24Finite(value);
  if (confidence > 1) confidence /= 100;
  if (confidence <= 0) confidence = .25;
  return confidence.clamp(.10, 1.0).toDouble();
}

// Python round() uses ties-to-even; Dart round() uses ties-away-from-zero.
// Keep weight quantisation identical when the confidence lands on a half unit.
int _v24Round(double value) {
  final int lower = value.floor();
  if (value - lower == .5) return lower.isEven ? lower : lower + 1;
  return value.round();
}

int _v24ConfidenceUnits(double value) =>
    math.max(1, _v24Round(_v24ConfidenceWeight(value) * 100));

double _v24Median(Iterable<double> values) {
  final List<double> items =
      values.where((double value) => value.isFinite).toList()..sort();
  if (items.isEmpty) return double.nan;
  final int middle = items.length ~/ 2;
  return items.length.isOdd
      ? items[middle]
      : (items[middle - 1] + items[middle]) / 2;
}

({double value, Map<String, dynamic> detail}) _v24WeightedMedian(
  Iterable<({double value, num weight})> values,
) {
  final List<({double value, int weight})> items =
      <({double value, int weight})>[
        for (final ({double value, num weight}) item in values)
          if (item.value.isFinite && item.value > 0)
            (value: item.value, weight: math.max(1, item.weight.toInt())),
      ]..sort((({double value, int weight}) a, ({double value, int weight}) b) {
        final int byValue = a.value.compareTo(b.value);
        return byValue != 0 ? byValue : a.weight.compareTo(b.weight);
      });
  if (items.isEmpty) {
    return (
      value: double.nan,
      detail: <String, dynamic>{'observations': 0, 'method': 'none'},
    );
  }
  final int total = items.fold<int>(0, (int sum, item) => sum + item.weight);
  final double threshold = (total + 1) / 2;
  int accumulated = 0;
  for (final ({double value, int weight}) item in items) {
    accumulated += item.weight;
    if (accumulated >= threshold) {
      return (
        value: item.value,
        detail: <String, dynamic>{
          'observations': items.length,
          'weightedObservations': total,
          'method': 'weighted_line_regression_median',
        },
      );
    }
  }
  return (
    value: items.last.value,
    detail: <String, dynamic>{
      'observations': items.length,
      'weightedObservations': total,
      'method': 'weighted_line_regression_median',
    },
  );
}

({double value, Map<String, dynamic> detail}) _v24WeightedRobustPitch(
  Iterable<({double value, num weight})> values,
) {
  final List<({double value, double weight})> items =
      <({double value, double weight})>[
        for (final ({double value, num weight}) item in values)
          if (item.value.isFinite && item.value > 0)
            (value: item.value, weight: _v24ConfidenceWeight(item.weight)),
      ];
  if (items.isEmpty) {
    return (
      value: double.nan,
      detail: <String, dynamic>{
        'observations': 0,
        'inliers': 0,
        'weight': 0.0,
        'method': 'none',
      },
    );
  }
  if (items.length < 4) {
    final ordered = items.toList()
      ..sort(
        (a, b) => a.value != b.value
            ? a.value.compareTo(b.value)
            : a.weight.compareTo(b.weight),
      );
    final double total = ordered.fold<double>(
      0,
      (sum, item) => sum + item.weight,
    );
    double accumulated = 0;
    for (final item in ordered) {
      accumulated += item.weight;
      if (accumulated >= total / 2) {
        return (
          value: item.value,
          detail: <String, dynamic>{
            'observations': items.length,
            'inliers': items.length,
            'weight': total,
            'method': 'weighted_median_small_sample',
          },
        );
      }
    }
  }
  double bestWeight = -1;
  double bestDeviation = double.infinity;
  List<({double value, double weight})> bestInliers =
      <({double value, double weight})>[];
  for (final ({double value, double weight}) candidate in items) {
    final double tolerance = math.max(1, candidate.value.abs() * .06);
    final List<({double value, double weight})> inliers = items
        .where(
          (({double value, double weight}) item) =>
              (item.value - candidate.value).abs() <= tolerance,
        )
        .toList();
    final double center = _v24WeightedMedian(<({double value, num weight})>[
      for (final ({double value, double weight}) item in inliers)
        (value: item.value, weight: _v24ConfidenceUnits(item.weight)),
    ]).value;
    final double totalWeight = inliers.fold<double>(
      0,
      (double sum, item) => sum + item.weight,
    );
    final double deviation =
        inliers.fold<double>(
          0,
          (double sum, item) => sum + item.weight * (item.value - center).abs(),
        ) /
        math.max(totalWeight, 1e-6);
    if (totalWeight > bestWeight ||
        (totalWeight == bestWeight && -deviation > -bestDeviation)) {
      bestWeight = totalWeight;
      bestDeviation = deviation;
      bestInliers = inliers;
    }
  }
  final double center = _v24WeightedMedian(<({double value, num weight})>[
    for (final ({double value, double weight}) item in bestInliers)
      (value: item.value, weight: _v24ConfidenceUnits(item.weight)),
  ]).value;
  return (
    value: center,
    detail: <String, dynamic>{
      'observations': items.length,
      'inliers': bestInliers.length,
      'weight': bestInliers.fold<double>(
        0,
        (double sum, item) => sum + item.weight,
      ),
      'method': 'confidence_weighted_dominant_local_spacing',
      'inlierMin': bestInliers.map((item) => item.value).reduce(math.min),
      'inlierMax': bestInliers.map((item) => item.value).reduce(math.max),
    },
  );
}

int _v24EvidenceInt(
  Map<String, dynamic> evidence,
  String key, [
  int fallback = 0,
]) {
  final Object? value = evidence[key];
  return value is num ? value.toInt() : fallback;
}

double _v24EvidenceNumber(
  Map<String, dynamic> evidence,
  String key, [
  double fallback = 0,
]) => _v24Finite(evidence[key], fallback);

({List<double> origins, Map<String, dynamic> detail}) _v24FitDiscreteRowOrigins(
  List<double> measuredOrigins,
  List<Map<String, dynamic>> originEvidence,
  double pitch,
) {
  if (measuredOrigins.length < 2 ||
      !pitch.isFinite ||
      pitch <= 0 ||
      measuredOrigins.any((double value) => !value.isFinite)) {
    return (
      origins: List<double>.from(measuredOrigins),
      detail: <String, dynamic>{
        'rule': 'independent_rows',
        'selectedIndentCells': null,
        'candidates': <Map<String, dynamic>>[],
      },
    );
  }
  final List<double> rowQuality = <double>[];
  for (int index = 0; index < measuredOrigins.length; index++) {
    final Map<String, dynamic> evidence = index < originEvidence.length
        ? originEvidence[index]
        : <String, dynamic>{};
    final int anchorCount =
        _v24EvidenceInt(evidence, 'highConfidenceAnchors') +
        _v24EvidenceInt(evidence, 'lowConfidenceAnchors');
    double confidence = _v24EvidenceNumber(evidence, 'confidenceWeight', .5);
    if (anchorCount > 0) confidence /= anchorCount;
    final int interiorCount = math.max(
      0,
      _v24EvidenceInt(evidence, 'interiorAnchorCount'),
    );
    final double interiorSpan = math.max(
      0,
      _v24EvidenceNumber(evidence, 'interiorSpanUnits'),
    );
    double quality = math.max(.10, confidence);
    quality *= 1 + math.min(1, interiorCount / 12);
    quality *= 1 + math.min(.5, interiorSpan / 48);
    final int boundaryCount = math.max(
      0,
      _v24EvidenceInt(
        evidence,
        'boundaryAnchorCount',
        (evidence['boundaryAnchors'] is List<dynamic>)
            ? (evidence['boundaryAnchors'] as List<dynamic>).length
            : 0,
      ),
    );
    final double boundaryWeight = math.max(
      0,
      _v24EvidenceNumber(evidence, 'boundaryConfidenceWeight'),
    );
    if (boundaryCount > 0) {
      quality *= 1 + math.min(.75, boundaryCount / 4);
      final double boundaryAverage = boundaryWeight / boundaryCount;
      quality *= .75 + .25 * math.min(1, math.max(0, boundaryAverage));
    }
    rowQuality.add(quality);
  }

  int qualityCompare(int a, int b) {
    final Map<String, dynamic> aEvidence = a < originEvidence.length
        ? originEvidence[a]
        : <String, dynamic>{};
    final Map<String, dynamic> bEvidence = b < originEvidence.length
        ? originEvidence[b]
        : <String, dynamic>{};
    final List<num> aKey = <num>[
      rowQuality[a],
      _v24EvidenceInt(aEvidence, 'interiorAnchorCount'),
      _v24EvidenceNumber(aEvidence, 'interiorSpanUnits'),
      _v24EvidenceInt(aEvidence, 'boundaryAnchorCount'),
      _v24EvidenceInt(aEvidence, 'highConfidenceAnchors'),
      -_v24EvidenceInt(aEvidence, 'lowConfidenceAnchors'),
      -a,
    ];
    final List<num> bKey = <num>[
      rowQuality[b],
      _v24EvidenceInt(bEvidence, 'interiorAnchorCount'),
      _v24EvidenceNumber(bEvidence, 'interiorSpanUnits'),
      _v24EvidenceInt(bEvidence, 'boundaryAnchorCount'),
      _v24EvidenceInt(bEvidence, 'highConfidenceAnchors'),
      -_v24EvidenceInt(bEvidence, 'lowConfidenceAnchors'),
      -b,
    ];
    for (int i = 0; i < aKey.length; i++) {
      final int comparison = aKey[i].compareTo(bKey[i]);
      if (comparison != 0) return comparison;
    }
    return 0;
  }

  final int referenceRow = List<int>.generate(
    measuredOrigins.length,
    (int index) => index,
  ).reduce((int a, int b) => qualityCompare(a, b) >= 0 ? a : b);
  final List<({double value, num weight})> tailValues =
      <({double value, num weight})>[
        for (int row = 1; row < measuredOrigins.length; row++)
          (
            value: measuredOrigins[row],
            weight: math.max(1, _v24Round(rowQuality[row] * 100)),
          ),
      ];
  final ({double value, Map<String, dynamic> detail}) tailMedian =
      _v24WeightedMedian(tailValues);
  final double measuredTailOrigin = tailMedian.value;
  if (!measuredTailOrigin.isFinite) {
    return (
      origins: List<double>.from(measuredOrigins),
      detail: <String, dynamic>{
        'rule': 'independent_rows',
        'selectedIndentCells': null,
        'candidates': <Map<String, dynamic>>[],
      },
    );
  }

  final List<Map<String, dynamic>> candidates = <Map<String, dynamic>>[];
  for (final int indentCells in <int>[-1, 0, 1]) {
    final List<double> transformedMeasurements = <double>[
      measuredOrigins.first,
      for (final double origin in measuredOrigins.skip(1))
        origin - indentCells * pitch,
    ];
    final ({double value, Map<String, dynamic> detail}) jointMedian =
        _v24WeightedMedian(<({double value, num weight})>[
          for (int row = 0; row < transformedMeasurements.length; row++)
            (
              value: transformedMeasurements[row],
              weight: math.max(1, _v24Round(rowQuality[row] * 100)),
            ),
        ]);
    final double robustCenter = jointMedian.value.isFinite
        ? jointMedian.value
        : measuredOrigins.first;
    final double consensusTolerance = math.max(4, pitch * .30);
    final List<({double value, double weight})> inlierMeasurements =
        <({double value, double weight})>[
          for (int row = 0; row < transformedMeasurements.length; row++)
            if ((transformedMeasurements[row] - robustCenter).abs() <=
                consensusTolerance)
              (value: transformedMeasurements[row], weight: rowQuality[row]),
        ];
    final double totalWeight = inlierMeasurements.fold<double>(
      0,
      (double sum, item) => sum + item.weight,
    );
    final double baseOrigin = inlierMeasurements.length >= 2
        ? inlierMeasurements.fold<double>(
                0,
                (double sum, item) => sum + item.value * item.weight,
              ) /
              math.max(totalWeight, 1e-6)
        : robustCenter;
    final Map<String, dynamic> jointConsensus = <String, dynamic>{
      ...jointMedian.detail,
      'method': 'confidence_weighted_inlier_mean',
      'robustCenter': robustCenter,
      'tolerance': consensusTolerance,
      'inlierCount': inlierMeasurements.length,
      'inlierMeasurements': <double>[
        for (final ({double value, double weight}) item in inlierMeasurements)
          item.value,
      ],
    };
    final double tailOrigin = baseOrigin + indentCells * pitch;
    final List<double> residuals = <double>[
      (measuredOrigins.first - baseOrigin).abs(),
      for (final double origin in measuredOrigins.skip(1))
        (origin - tailOrigin).abs(),
    ];
    final double weightedResidual =
        residuals.asMap().entries.fold<double>(
          0,
          (double sum, entry) => sum + rowQuality[entry.key] * entry.value,
        ) /
        math.max(
          rowQuality.fold<double>(0, (double sum, value) => sum + value),
          1e-6,
        );
    candidates.add(<String, dynamic>{
      'indentCells': indentCells,
      'origin': tailOrigin,
      'baseOrigin': baseOrigin,
      'baseOriginMeasured': measuredOrigins.first,
      'transformedMeasurements': transformedMeasurements,
      'jointConsensus': jointConsensus,
      'referenceRow': referenceRow,
      'referenceOrigin': measuredOrigins[referenceRow],
      'baseShift': baseOrigin - measuredOrigins.first,
      'baseShiftClamped': false,
      'weightedResidual': weightedResidual,
      'maxResidual': residuals.isEmpty ? 0.0 : residuals.reduce(math.max),
      'residuals': residuals,
    });
  }

  candidates.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
    final List<num> aKey = <num>[
      a['weightedResidual'] as num,
      a['maxResidual'] as num,
      (a['indentCells'] as num).abs(),
      a['indentCells'] as num,
    ];
    final List<num> bKey = <num>[
      b['weightedResidual'] as num,
      b['maxResidual'] as num,
      (b['indentCells'] as num).abs(),
      b['indentCells'] as num,
    ];
    for (int i = 0; i < aKey.length; i++) {
      final int comparison = aKey[i].compareTo(bKey[i]);
      if (comparison != 0) return comparison;
    }
    return 0;
  });
  final Map<String, dynamic> selected = candidates.first;
  final double baseOrigin = (selected['baseOrigin'] as num).toDouble();
  final double tailOrigin = (selected['origin'] as num).toDouble();
  final List<double> residuals = (selected['residuals'] as List<dynamic>)
      .cast<num>()
      .map((num value) => value.toDouble())
      .toList();
  final double constraintTolerance = math.max(4, pitch * .18);
  final double maxResidual = (selected['maxResidual'] as num).toDouble();
  final List<double> origins = <double>[
    for (int row = 0; row < measuredOrigins.length; row++)
      row == 0 ? baseOrigin : tailOrigin,
  ];
  return (
    origins: origins,
    detail: <String, dynamic>{
      'rule': 'best_row_reference_plus_minus_one_cell_indent_joint_consensus',
      'selectedIndentCells': selected['indentCells'],
      'referenceRow': referenceRow,
      'referenceOrigin': measuredOrigins[referenceRow],
      'baseOrigin': baseOrigin,
      'baseOriginMeasured': measuredOrigins.first,
      'tailOrigin': tailOrigin,
      'measuredTailOrigin': measuredTailOrigin,
      'baseShift': selected['baseShift'],
      'baseShiftClamped': selected['baseShiftClamped'],
      'candidateOrigins': candidates,
      'jointConsensus': selected['jointConsensus'],
      'transformedMeasurements': selected['transformedMeasurements'],
      'tailConsensus': tailMedian.detail,
      'weightedResidual': selected['weightedResidual'],
      'maxResidual': maxResidual,
      'constraintTolerance': constraintTolerance,
      'constraintWarning': maxResidual > constraintTolerance,
      'residuals': residuals,
      'rowQuality': rowQuality,
      'referenceEvidence': referenceRow < originEvidence.length
          ? originEvidence[referenceRow]
          : <String, dynamic>{},
      'weight': rowQuality.fold<double>(
        0,
        (double sum, double value) => sum + value,
      ),
    },
  );
}

Map<String, dynamic> _v24PreferReliableLinePitch(
  double globalPitch,
  List<Map<String, dynamic>> linePitchEvidence,
) {
  final List<Map<String, dynamic>> candidates =
      linePitchEvidence
          .where(
            (Map<String, dynamic> item) =>
                item['source'] == 'long_span_consensus' &&
                _v24EvidenceInt(item, 'longSlopes') >= 4 &&
                item['pitch'] is num &&
                (item['pitch'] as num).toDouble().isFinite &&
                (item['pitch'] as num).toDouble() > 0,
          )
          .toList()
        ..sort(
          (Map<String, dynamic> a, Map<String, dynamic> b) => _v24EvidenceInt(
            b,
            'longSlopes',
          ).compareTo(_v24EvidenceInt(a, 'longSlopes')),
        );
  if (candidates.isEmpty || !globalPitch.isFinite || globalPitch <= 0) {
    return <String, dynamic>{};
  }
  final Map<String, dynamic> dominant = candidates.first;
  final int runnerUpLongSlopes = candidates.length >= 2
      ? _v24EvidenceInt(candidates[1], 'longSlopes')
      : 0;
  final int dominantLongSlopes = _v24EvidenceInt(dominant, 'longSlopes');
  final double dominantPitch = (dominant['pitch'] as num).toDouble();
  final double dominantDelta =
      (dominantPitch - globalPitch).abs() / math.max(globalPitch, 1e-6);
  if (dominantLongSlopes < math.max(4, runnerUpLongSlopes * 4) ||
      dominantDelta <= .002) {
    return <String, dynamic>{};
  }
  return <String, dynamic>{
    'method': 'reliable_line_pitch_over_global_long',
    'globalLongPitch': globalPitch,
    'referenceLine': dominant['line'],
    'referenceLinePitch': dominantPitch,
    'referenceLineLongSlopes': dominantLongSlopes,
    'runnerUpLongSlopes': runnerUpLongSlopes,
    'referenceLineDelta': dominantDelta,
  };
}

List<_V24Match> _v24Matches(_V24GeometryInput input) {
  final List<_V24Match> matches = <_V24Match>[];
  for (int row = 0; row < input.alignment.lines.length; row++) {
    final GalCalibrationOcrMatchedLine line = input.alignment.lines[row];
    final List<_V24Pair> pairs = <_V24Pair>[];
    for (int glyphIndex = 0; glyphIndex < line.glyphs.length; glyphIndex++) {
      final GalCalibrationOcrGlyph glyph = line.glyphs[glyphIndex];
      final int sourcePosition = line.sourceStart + glyph.cellOffset;
      if (sourcePosition < 0 || sourcePosition >= input.source.length) continue;
      final int ocrPosition = glyph.ocrTokenIndex ?? glyphIndex;
      final double rawConfidence = glyph.ocrConfidence ?? glyph.confidence;
      pairs.add(
        _V24Pair(
          sourcePosition: sourcePosition,
          ocrPosition: ocrPosition,
          kind: glyph.matchKind,
          token: _V24Token(
            text: glyph.ocrText ?? input.source[sourcePosition].value,
            rect: glyph.rect,
            confidence: rawConfidence,
            synthetic: glyph.syntheticOcrPosition,
            ocrTokenIndex: ocrPosition,
          ),
        ),
      );
    }
    pairs.sort((_V24Pair a, _V24Pair b) {
      final int bySource = a.sourcePosition.compareTo(b.sourcePosition);
      return bySource != 0 ? bySource : a.ocrPosition.compareTo(b.ocrPosition);
    });
    matches.add(
      _V24Match(
        lineIndex: line.lineIndex,
        sourceStart: line.sourceStart,
        sourceEnd: line.sourceEnd,
        pairs: pairs,
        line: line,
      ),
    );
  }
  return matches;
}

bool _v24SourceSpanHasHardBreak(List<_SourceUnit> source, int start, int end) {
  if (start < 0 || end > source.length || end <= start) return false;
  return source
      .sublist(start + 1, end)
      .any((_SourceUnit unit) => unit.hardBreakBefore);
}

int _v24VisibleSourceCount(List<_SourceUnit> source, int start, int end) =>
    source
        .sublist(start.clamp(0, source.length), end.clamp(0, source.length))
        .where((_SourceUnit unit) => !unit.whitespace && !unit.newline)
        .length;

List<_V24Pair> _v24InteriorPairs(_V24Match match) {
  final List<_V24Pair> pairs = List<_V24Pair>.from(match.pairs)
    ..sort((a, b) => a.sourcePosition.compareTo(b.sourcePosition));
  if (pairs.length <= 2) return <_V24Pair>[];
  return pairs.sublist(1, pairs.length - 1);
}

double _v24SourceAdvance(_SourceUnit unit, Map<String, double> widths) =>
    unit.newline ? 0 : 1;

double _v24PrefixAdvance(
  List<_SourceUnit> source,
  int start,
  int end,
  Map<String, double> widths,
) => source
    .sublist(start, end)
    .fold<double>(
      0,
      (double sum, _SourceUnit unit) => sum + _v24SourceAdvance(unit, widths),
    );

({Map<String, double> widths, List<Map<String, dynamic>> evidence})
_v24InferWidths(
  List<_SourceUnit> source,
  List<_V24Match> matches,
  double pitch,
) => (
  widths: <String, double>{},
  evidence: <Map<String, dynamic>>[
    <String, dynamic>{
      'rule': 'single_uniform_width',
      'acceptedCategories': <String>[],
      'observations': 0,
      'accepted': true,
      'note': 'All source units use one standard cell width.',
    },
  ],
);

Map<String, dynamic> _v24RectMap(OcrRect rect) => <String, dynamic>{
  'left': rect.left,
  'top': rect.top,
  'right': rect.right,
  'bottom': rect.bottom,
};

double _v24LineConfidence(_V24Match match, double fallback) =>
    match.line.ocrScore.isFinite ? match.line.ocrScore : fallback;

double? _v24NullableFinite(double value) => value.isFinite ? value : null;

Map<String, dynamic> _v24FitGeometry(_V24GeometryInput input) {
  final List<_V24Match> matches = _v24Matches(input);
  final List<GalCalibrationOcrMatchedLine> lines = input.alignment.lines;
  Map<String, dynamic> failure(
    String reason,
    double rowHeight,
    double lineAdvance,
  ) => <String, dynamic>{
    'ok': false,
    'reason': reason,
    'pitch': null,
    'cellHeight': rowHeight,
    'lineAdvance': lineAdvance,
    'slopes': <double>[],
    'directSlopes': <double>[],
    'pitchConsensus': <String, dynamic>{},
    'lineSpanPitch': null,
    'lineSpanPitchEvidence': <Map<String, dynamic>>[],
    'trimmedSpanPitch': null,
    'trimmedSpanPitchEvidence': <Map<String, dynamic>>[],
    'trimmedSpanPitchConsensus': <String, dynamic>{},
    'edgeAnchorsExcluded': 0,
  };
  if (input.source.isEmpty || matches.isEmpty || lines.isEmpty) {
    return failure('geometry_evidence_insufficient', double.nan, double.nan);
  }

  final List<double> slopes = <double>[];
  final List<double> directSlopes = <double>[];
  final List<double> longSlopes = <double>[];
  final List<({double value, num weight})> directSlopeEvidence =
      <({double value, num weight})>[];
  final List<({double value, num weight})> longSlopeEvidence =
      <({double value, num weight})>[];
  final List<Map<String, dynamic>> linePitchEvidence = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> lineSpanPitchEvidence =
      <Map<String, dynamic>>[];
  final List<({double value, num weight})> trimmedSpanSlopeEvidence =
      <({double value, num weight})>[];
  final List<Map<String, dynamic>> trimmedSpanPitchEvidence =
      <Map<String, dynamic>>[];
  int edgeAnchorsExcluded = 0;

  for (final _V24Match match in matches) {
    final GalCalibrationOcrMatchedLine line = match.line;
    final List<_V24Pair> allPairs = List<_V24Pair>.from(match.pairs)
      ..sort((a, b) => a.sourcePosition.compareTo(b.sourcePosition));
    final List<_V24Pair> pairs = _v24InteriorPairs(match);
    edgeAnchorsExcluded += allPairs.length - pairs.length;
    final List<_V24Pair> ordinaryPairs = allPairs
        .where(
          (_V24Pair pair) =>
              _reliableRelation(pair.kind) &&
              !pair.token.synthetic &&
              !input.source[pair.sourcePosition].whitespace &&
              !input.source[pair.sourcePosition].newline &&
              !_isPitchException(input.source[pair.sourcePosition].value),
        )
        .toList();
    if (ordinaryPairs.length >= 2) {
      final _V24Pair leftPair = ordinaryPairs.first;
      final _V24Pair rightPair = ordinaryPairs.last;
      final int spanCells = input.source
          .sublist(leftPair.sourcePosition, rightPair.sourcePosition + 1)
          .where((unit) => !unit.newline)
          .length;
      final double centerDistance =
          rightPair.token.rect.centerX - leftPair.token.rect.centerX;
      if (spanCells >= 2 && centerDistance > 0) {
        final double measuredSpanPitch = centerDistance / (spanCells - 1);
        final double endpointWeight = math.sqrt(
          _v24ConfidenceWeight(leftPair.token.confidence) *
              _v24ConfidenceWeight(rightPair.token.confidence),
        );
        if (measuredSpanPitch.isFinite && measuredSpanPitch > 0) {
          trimmedSpanSlopeEvidence.add((
            value: measuredSpanPitch,
            weight: endpointWeight,
          ));
          trimmedSpanPitchEvidence.add(<String, dynamic>{
            'line': match.lineIndex,
            'pitch': measuredSpanPitch,
            'sourceStart': leftPair.sourcePosition,
            'sourceEnd': rightPair.sourcePosition,
            'sourceStartText': input.source[leftPair.sourcePosition].value,
            'sourceEndText': input.source[rightPair.sourcePosition].value,
            'spanCells': spanCells,
            'ordinaryAnchorCount': ordinaryPairs.length,
            'leftOcrPosition': leftPair.ocrPosition,
            'rightOcrPosition': rightPair.ocrPosition,
            'leftConfidence': _v24ConfidenceWeight(leftPair.token.confidence),
            'rightConfidence': _v24ConfidenceWeight(rightPair.token.confidence),
            'weight': endpointWeight,
            'method': 'trimmed_normal_anchor_endpoint_center_span',
          });
        }
      }
    }
    final int visibleLineUnits = _v24VisibleSourceCount(
      input.source,
      match.sourceStart,
      match.sourceEnd,
    );
    if (visibleLineUnits >= 4 && line.rect.width > 0) {
      lineSpanPitchEvidence.add(<String, dynamic>{
        'line': match.lineIndex,
        'pitch': line.rect.width / visibleLineUnits,
        'visibleUnits': visibleLineUnits,
        'confidenceWeight': _v24ConfidenceWeight(
          _v24LineConfidence(match, input.alignment.confidence),
        ),
      });
    }

    final List<double> lineDirectSlopes = <double>[];
    final List<({double value, num weight})> lineDirectEvidence =
        <({double value, num weight})>[];
    final List<double> lineLongSlopes = <double>[];
    final List<({double value, num weight})> lineLongEvidence =
        <({double value, num weight})>[];
    final List<({double u, double x, double weight})> regressionPoints =
        <({double u, double x, double weight})>[];
    double? lineRegressionPitch;
    for (final _V24Pair pair in pairs) {
      if (!_reliableRelation(pair.kind)) continue;
      final _SourceUnit unit = input.source[pair.sourcePosition];
      if (pair.token.synthetic ||
          unit.whitespace ||
          unit.newline ||
          _isPitchException(unit.value)) {
        continue;
      }
      regressionPoints.add((
        u: (pair.sourcePosition - match.sourceStart).toDouble(),
        x: pair.token.rect.centerX,
        weight: _v24ConfidenceWeight(pair.token.confidence),
      ));
    }
    if (regressionPoints.length >= 3) {
      final double totalWeight = regressionPoints.fold<double>(
        0,
        (double sum, point) => sum + point.weight,
      );
      final double meanU =
          regressionPoints.fold<double>(
            0,
            (double sum, point) => sum + point.u * point.weight,
          ) /
          math.max(totalWeight, 1e-6);
      final double meanX =
          regressionPoints.fold<double>(
            0,
            (double sum, point) => sum + point.x * point.weight,
          ) /
          math.max(totalWeight, 1e-6);
      final double numerator = regressionPoints.fold<double>(
        0,
        (double sum, point) =>
            sum + point.weight * (point.u - meanU) * (point.x - meanX),
      );
      final double denominator = regressionPoints.fold<double>(
        0,
        (double sum, point) =>
            sum + point.weight * (point.u - meanU) * (point.u - meanU),
      );
      if (denominator > 0) {
        final double candidate = numerator / denominator;
        if (candidate.isFinite && candidate > 0) {
          lineRegressionPitch = candidate;
        }
      }
    }
    for (int leftIndex = 0; leftIndex < pairs.length; leftIndex++) {
      final _V24Pair leftPair = pairs[leftIndex];
      for (final _V24Pair rightPair in pairs.skip(leftIndex + 1)) {
        final int delta = rightPair.sourcePosition - leftPair.sourcePosition;
        final int ocrDelta = rightPair.ocrPosition - leftPair.ocrPosition;
        if (delta < 1 || ocrDelta < 1) continue;
        final bool invalidSpan =
            _v24SourceSpanHasHardBreak(
              input.source,
              leftPair.sourcePosition,
              rightPair.sourcePosition + 1,
            ) ||
            input.source
                .sublist(leftPair.sourcePosition, rightPair.sourcePosition + 1)
                .any(
                  (_SourceUnit unit) =>
                      unit.whitespace ||
                      unit.newline ||
                      _isPitchException(unit.value),
                );
        if (invalidSpan ||
            !_reliableRelation(leftPair.kind) ||
            !_reliableRelation(rightPair.kind) ||
            leftPair.token.synthetic ||
            rightPair.token.synthetic) {
          continue;
        }
        final double x1 = leftPair.token.rect.centerX;
        final double x2 = rightPair.token.rect.centerX;
        if (x2 <= x1) continue;
        final double measured = (x2 - x1) / delta;
        final double evidenceWeight = math.sqrt(
          _v24ConfidenceWeight(leftPair.token.confidence) *
              _v24ConfidenceWeight(rightPair.token.confidence),
        );
        slopes.add(measured);
        if (ocrDelta == delta && delta == 1) {
          directSlopes.add(measured);
          lineDirectSlopes.add(measured);
          directSlopeEvidence.add((value: measured, weight: evidenceWeight));
          lineDirectEvidence.add((value: measured, weight: evidenceWeight));
        }
        if (delta >= 4) {
          longSlopes.add(measured);
          lineLongSlopes.add(measured);
          longSlopeEvidence.add((value: measured, weight: evidenceWeight));
          lineLongEvidence.add((value: measured, weight: evidenceWeight));
        }
      }
    }
    double? selectedLinePitch;
    String selectedPitchSource = 'none';
    double? longPitch;
    Map<String, dynamic> longConsensus = <String, dynamic>{};
    if (lineLongSlopes.length >= 4) {
      final ({double value, Map<String, dynamic> detail}) result =
          _v24WeightedRobustPitch(lineLongEvidence);
      longPitch = result.value;
      longConsensus = result.detail;
      if (longPitch.isFinite &&
          (longConsensus['inliers'] as num? ?? 0) >=
              math.max(3, lineLongSlopes.length * .30)) {
        selectedLinePitch = longPitch;
        selectedPitchSource = 'long_span_consensus';
      }
    }
    if (selectedLinePitch == null) {
      selectedLinePitch = lineRegressionPitch;
      selectedPitchSource = 'line_regression';
    }
    double? directPitch;
    Map<String, dynamic> directConsensus = <String, dynamic>{};
    if (lineDirectSlopes.length >= 3) {
      final ({double value, Map<String, dynamic> detail}) result =
          _v24WeightedRobustPitch(lineDirectEvidence);
      directPitch = result.value;
      directConsensus = result.detail;
      directConsensus['total'] = lineDirectSlopes.length;
      if (directPitch.isFinite &&
          (directConsensus['inliers'] as num? ?? 0) >=
              lineDirectSlopes.length * .75 &&
          (selectedLinePitch == null || lineLongSlopes.isEmpty)) {
        selectedLinePitch = directPitch;
        selectedPitchSource = 'consistent_adjacent_spacing';
      }
    }
    if (selectedLinePitch != null) {
      linePitchEvidence.add(<String, dynamic>{
        'line': match.lineIndex,
        'pitch': selectedLinePitch,
        'regressionPitch': lineRegressionPitch,
        'directPitch': directPitch,
        'longPitch': longPitch,
        'longSlopes': lineLongSlopes.length,
        'anchors': regressionPoints.length,
        'weight': math.max(
          1,
          _v24Round(
            regressionPoints.fold<double>(
              0,
              (double sum, point) => sum + point.weight,
            ),
          ),
        ),
        'confidenceWeight': regressionPoints.fold<double>(
          0,
          (double sum, point) => sum + point.weight,
        ),
        'source': selectedPitchSource,
        'directConsensus': directConsensus,
        'longConsensus': longConsensus,
      });
    }
  }

  final trimmed = _v24WeightedRobustPitch(trimmedSpanSlopeEvidence);
  final double trimmedSpanPitch = trimmed.value;
  final Map<String, dynamic> trimmedSpanConsensus = trimmed.detail
    ..['total'] = trimmedSpanSlopeEvidence.length;
  final bool trimmedSpanUsable =
      trimmedSpanPitch.isFinite &&
      trimmedSpanSlopeEvidence.length >= 2 &&
      (trimmedSpanConsensus['inliers'] as num? ?? 0) >=
          math.max(2, (trimmedSpanSlopeEvidence.length * .50).ceil());
  double pitch = double.nan;
  Map<String, dynamic> pitchConsensus = {};
  double lineSpanPitch = double.nan;
  if (lineSpanPitchEvidence.isNotEmpty) {
    lineSpanPitch = _v24WeightedMedian([
      for (final item in lineSpanPitchEvidence)
        (value: item['pitch'] as double, weight: item['visibleUnits'] as num),
    ]).value;
  }
  if (longSlopes.length >= 4) {
    final result = _v24WeightedRobustPitch(longSlopeEvidence);
    if (result.value.isFinite &&
        (result.detail['inliers'] as num? ?? 0) >=
            math.max(4, longSlopes.length * .20)) {
      pitch = result.value;
      pitchConsensus = {
        ...result.detail,
        'method': 'global_long_span_consensus',
        'longSpanObservations': longSlopes.length,
        'lines': linePitchEvidence,
        'lineSpanPitch': lineSpanPitch,
        'lineSpanEvidence': lineSpanPitchEvidence,
      };
      final preferred = _v24PreferReliableLinePitch(pitch, linePitchEvidence);
      if (preferred.isNotEmpty) {
        pitch = preferred['referenceLinePitch'] as double;
        pitchConsensus.addAll(preferred);
      }
      final regression = _v24WeightedMedian([
        for (final item in linePitchEvidence)
          if (item['regressionPitch'] is num &&
              (item['regressionPitch'] as num).isFinite &&
              (item['regressionPitch'] as num) > 0)
            (
              value: (item['regressionPitch'] as num).toDouble(),
              weight: (item['confidenceWeight'] ?? item['weight']) as num,
            ),
      ]);
      if (regression.value.isFinite &&
          lineSpanPitch.isFinite &&
          lineSpanPitch > 0) {
        final double longError = (pitch - lineSpanPitch).abs() / lineSpanPitch;
        final double regressionError =
            (regression.value - lineSpanPitch).abs() / lineSpanPitch;
        if (longError >= .04 && regressionError + .005 < longError) {
          final double oldPitch = pitch;
          pitch = regression.value;
          pitchConsensus.addAll({
            'method': 'line_regression_cross_checked_by_line_span',
            'longPitch': oldPitch,
            'regressionPitch': pitch,
            'regressionConsensus': regression.detail,
            'lineSpanPitch': lineSpanPitch,
            'lineSpanError': {'long': longError, 'regression': regressionError},
          });
        }
      }
    }
  }
  if (!pitch.isFinite && linePitchEvidence.isNotEmpty) {
    final result = _v24WeightedMedian([
      for (final item in linePitchEvidence)
        (value: item['pitch'] as double, weight: item['weight'] as num),
    ]);
    pitch = result.value;
    pitchConsensus = {...result.detail, 'lines': linePitchEvidence};
  }
  if (!pitch.isFinite) {
    final result = _v24WeightedRobustPitch(
      directSlopes.length >= 4
          ? directSlopeEvidence
          : [for (final value in slopes) (value: value, weight: .5)],
    );
    pitch = result.value;
    pitchConsensus = {...result.detail, 'lines': <dynamic>[]};
  }
  double lineLevelPitch = double.nan;
  Map<String, dynamic> lineLevelConsensus = {};
  final eligible = <({double value, num weight})>[
    for (final item in linePitchEvidence)
      if (item['pitch'] is num &&
          (item['pitch'] as num).isFinite &&
          (item['pitch'] as num) > 0 &&
          (item['confidenceWeight'] as num? ?? 0) >= 8)
        (
          value: (item['pitch'] as num).toDouble(),
          weight: item['confidenceWeight'] as num,
        ),
  ];
  if (eligible.length >= 2) {
    final result = _v24WeightedRobustPitch(eligible);
    lineLevelPitch = result.value;
    lineLevelConsensus = result.detail;
    if (lineLevelPitch.isFinite &&
        pitch.isFinite &&
        (lineLevelPitch - pitch).abs() / math.max(pitch, 1e-6) >= .015) {
      pitchConsensus.addAll({
        'method': 'line_level_confidence_consensus',
        'previousPitch': pitch,
        'lineLevelPitch': lineLevelPitch,
        'lineLevelConsensus': lineLevelConsensus,
      });
      pitch = lineLevelPitch;
    }
  }
  if (trimmedSpanUsable) {
    final double? delta = pitch.isFinite
        ? (trimmedSpanPitch - pitch).abs() / math.max(pitch, 1e-6)
        : null;
    final bool conflict =
        pitch.isFinite &&
        (pitchConsensus['inliers'] as num? ?? 0) >= 4 &&
        delta != null &&
        delta > 1e-6;
    pitchConsensus.addAll({
      'method': conflict
          ? 'internal_pitch_over_trimmed_span_conflict'
          : 'trimmed_normal_anchor_span_consensus',
      if (!conflict) 'previousPitch': _v24NullableFinite(pitch),
      'trimmedSpanPitch': trimmedSpanPitch,
      'trimmedSpanConsensus': trimmedSpanConsensus,
      'trimmedSpanDelta': delta,
      'trimmedSpanEvidence': trimmedSpanPitchEvidence,
      if (conflict) 'trimmedSpanConflict': true,
    });
    if (!conflict) pitch = trimmedSpanPitch;
  }
  final double rowHeight = _v24Median(lines.map((line) => line.rect.height));
  final double lineAdvance = _v24Median([
    for (int i = 1; i < lines.length; i++)
      lines[i].rect.centerY - lines[i - 1].rect.centerY,
  ]);
  final Map<String, dynamic> pitchDiagnostics = {
    'pitch': _v24NullableFinite(pitch),
    'cellHeight': rowHeight,
    'lineAdvance': lineAdvance,
    'slopes': slopes,
    'directSlopes': directSlopes,
    'pitchConsensus': pitchConsensus,
    'lineSpanPitch': lineSpanPitch,
    'lineSpanPitchEvidence': lineSpanPitchEvidence,
    'trimmedSpanPitch': _v24NullableFinite(trimmedSpanPitch),
    'trimmedSpanPitchEvidence': trimmedSpanPitchEvidence,
    'trimmedSpanPitchConsensus': trimmedSpanConsensus,
    'edgeAnchorsExcluded': edgeAnchorsExcluded,
  };
  if (!pitch.isFinite || pitch <= 0 || !rowHeight.isFinite || rowHeight <= 0) {
    return {
      ...pitchDiagnostics,
      'ok': false,
      'reason': 'geometry_evidence_insufficient',
      'pitch': null,
    };
  }
  if (lines.length < 2 || !lineAdvance.isFinite || lineAdvance <= 0) {
    return {
      ...pitchDiagnostics,
      'ok': false,
      'reason': 'line_spacing_insufficient',
    };
  }
  final List<({int start, int end})> ranges = [];
  for (int row = 0; row < matches.length; row++) {
    final match = matches[row];
    int start = match.sourceStart, end = match.sourceEnd;
    if (start > 0 &&
        '「『'.contains(input.source[start - 1].value) &&
        !input.source[start].hardBreakBefore) {
      start--;
    }
    if (row == matches.length - 1 &&
        end < input.source.length &&
        '」』'.contains(input.source[end].value) &&
        !input.source[end].hardBreakBefore) {
      end++;
    }
    ranges.add((start: start, end: end));
  }
  final List<double> measuredOrigins = [];
  final List<Map<String, dynamic>> originEvidence = [];
  for (int row = 0; row < matches.length; row++) {
    final match = matches[row];
    final range = ranges[row];
    List<_V24Pair> reliablePairs = match.pairs
        .where((pair) => _reliableRelation(pair.kind) && !pair.token.synthetic)
        .toList();
    final bool fallback = reliablePairs.isEmpty;
    if (fallback) reliablePairs = match.pairs;
    final confidences = <double>[
      for (final pair in reliablePairs)
        _v24ConfidenceWeight(
          pair.token.confidence,
          synthetic: fallback && pair.token.synthetic,
        ),
    ];
    ({double value, num weight}) estimate(
      _V24Pair pair, {
      bool synthetic = false,
    }) => (
      value:
          pair.token.rect.centerX -
          (_v24PrefixAdvance(
                    input.source,
                    range.start,
                    pair.sourcePosition,
                    const {},
                  ) +
                  .5) *
              pitch,
      weight: _v24ConfidenceUnits(
        _v24ConfidenceWeight(pair.token.confidence, synthetic: synthetic),
      ),
    );
    final estimates = [
      for (final pair in reliablePairs)
        estimate(pair, synthetic: fallback && pair.token.synthetic),
    ];
    double medianOrigin = _v24WeightedMedian(estimates).value;
    double origin = medianOrigin;
    final visible = [
      for (int pos = range.start; pos < range.end; pos++)
        if (!input.source[pos].whitespace && !input.source[pos].newline) pos,
    ];
    final Set<int> edges = visible.isEmpty ? {} : {visible.first, visible.last};
    final interiors = reliablePairs
        .where((pair) => !edges.contains(pair.sourcePosition))
        .toList();
    if (interiors.length >= 2) {
      medianOrigin = _v24WeightedMedian([
        for (final pair in interiors) estimate(pair),
      ]).value;
    }
    final normal = visible
        .where((pos) => !_isPitchException(input.source[pos].value))
        .toList();
    final List<({String role, int position})> boundaries = [];
    if (normal.isNotEmpty) {
      if (row == 0) {
        boundaries.add((
          role: 'first_row_last_normal_anchor',
          position: normal.last,
        ));
      } else {
        boundaries.add((
          role: 'wrapped_row_first_normal_anchor',
          position: normal.first,
        ));
        if (matches.length >= 3 && row == 1) {
          boundaries.add((
            role: 'middle_row_last_normal_anchor',
            position: normal.last,
          ));
        }
      }
    }
    final List<({double value, num weight})> boundaryEstimates = [];
    final List<Map<String, dynamic>> boundaryAnchors = [];
    for (final boundary in boundaries) {
      final candidates = reliablePairs
          .where((pair) => pair.sourcePosition == boundary.position)
          .toList();
      if (candidates.isEmpty) {
        boundaryAnchors.add({
          'role': boundary.role,
          'sourceLogicalIndex': boundary.position,
          'sourceText': input.source[boundary.position].value,
          'matched': false,
        });
        continue;
      }
      _V24Pair pair = candidates.first;
      for (final candidate in candidates.skip(1)) {
        if (_v24ConfidenceWeight(
              candidate.token.confidence,
              synthetic: candidate.token.synthetic,
            ) >
            _v24ConfidenceWeight(
              pair.token.confidence,
              synthetic: pair.token.synthetic,
            )) {
          pair = candidate;
        }
      }
      final double confidence = _v24ConfidenceWeight(
        pair.token.confidence,
        synthetic: pair.token.synthetic,
      );
      final double boundaryOrigin =
          pair.token.rect.centerX -
          (_v24PrefixAdvance(
                    input.source,
                    range.start,
                    boundary.position,
                    const {},
                  ) +
                  .5) *
              pitch;
      if (boundaryOrigin.isFinite) {
        boundaryEstimates.add((
          value: boundaryOrigin,
          weight: _v24ConfidenceUnits(confidence),
        ));
      }
      boundaryAnchors.add({
        'role': boundary.role,
        'sourceLogicalIndex': boundary.position,
        'sourceText': input.source[boundary.position].value,
        'ocrPosition': pair.ocrPosition,
        'ocrText': pair.token.text,
        'matchKind': pair.kind,
        'confidence': confidence,
        'origin': boundaryOrigin,
        'matched': true,
      });
    }
    final boundary = _v24WeightedMedian(boundaryEstimates);
    final double tolerance = math.max(2, pitch * .08);
    final bool conflict =
        boundary.value.isFinite &&
        medianOrigin.isFinite &&
        (boundary.value - medianOrigin).abs() > tolerance;
    final bool used = boundary.value.isFinite;
    if (used) origin = boundary.value;
    originEvidence.add({
      'row': row,
      'medianOrigin': medianOrigin,
      'selectedOrigin': origin,
      'method': used
          ? (conflict
                ? 'normal_anchor_boundary_anchor_conflict'
                : 'normal_anchor_boundary_anchor')
          : (conflict
                ? 'interior_anchor_median_boundary_conflict'
                : (interiors.length >= 2
                      ? 'interior_anchor_median'
                      : 'reliable_anchor_median')),
      'edgeOrigin': used ? boundary.value : null,
      'edgeSourceLogicalIndex': used
          ? boundaryAnchors.firstWhere(
              (a) => a['matched'] == true,
            )['sourceLogicalIndex']
          : null,
      'boundaryOrigin': _v24NullableFinite(boundary.value),
      'boundaryConsensus': boundary.detail,
      'boundaryTolerance': tolerance,
      'boundaryUsed': used,
      'boundaryConflict': conflict,
      'boundaryAnchors': boundaryAnchors,
      'boundaryAnchorCount': boundaryAnchors
          .where((a) => a['matched'] == true)
          .length,
      'boundaryConfidenceWeight': boundaryAnchors
          .where((a) => a['matched'] == true)
          .fold<double>(
            0,
            (sum, a) => sum + (a['confidence'] as num).toDouble(),
          ),
      'confidenceWeight': confidences.fold<double>(0, (a, b) => a + b),
      'highConfidenceAnchors': confidences.where((c) => c >= .75).length,
      'lowConfidenceAnchors': confidences.where((c) => c < .50).length,
      'interiorAnchorCount': interiors.length,
      'interiorSpanUnits': interiors.isEmpty
          ? 0
          : interiors.map((p) => p.sourcePosition).reduce(math.max) -
                interiors.map((p) => p.sourcePosition).reduce(math.min) +
                1,
      'averageConfidence': confidences.isEmpty
          ? 0.0
          : confidences.fold<double>(0, (a, b) => a + b) / confidences.length,
    });
    measuredOrigins.add(origin);
  }
  final discrete = _v24FitDiscreteRowOrigins(
    measuredOrigins,
    originEvidence,
    pitch,
  );
  List<double> origins = discrete.origins;
  final Map<String, dynamic> discreteFit = discrete.detail;
  List<Map<String, dynamic>> cells = [];
  List<Map<String, dynamic>> boxes = [];
  final List<Map<String, dynamic>> anchors = [];
  for (int row = 0; row < matches.length; row++) {
    final match = matches[row];
    final range = ranges[row];
    double cursor = origins[row];
    final double cellTop = match.line.rect.centerY - rowHeight / 2;
    final pairs = {for (final pair in match.pairs) pair.sourcePosition: pair};
    for (int pos = range.start; pos < range.end; pos++) {
      final unit = input.source[pos];
      if (unit.newline) {
        cursor = origins[row];
        continue;
      }
      final pair = pairs[pos];
      final Map<String, dynamic> cell = {
        'sourceLogicalIndex': pos,
        'sourceIndex': unit.index,
        'length': unit.length,
        'text': unit.value,
        'line': row,
        'left': cursor,
        'top': cellTop,
        'width': pitch,
        'height': rowHeight,
        'whitespace': unit.whitespace,
        'specialWidthCategory': null,
        'specialWidthCandidate': null,
        'widthClass': 'standard',
        'anchored': pair != null,
        'matchKind': pair?.kind ?? 'inferred',
      };
      cells.add(cell);
      if (!unit.whitespace) boxes.add(cell);
      if (pair != null) {
        anchors.add({
          'sourceLogicalIndex': pos,
          'sourceIndex': unit.index,
          'text': unit.value,
          'matchKind': pair.kind,
          'confidence': pair.token.confidence,
          'ocrLine': match.lineIndex,
          'ocrToken': pair.ocrPosition,
          'ocrText': pair.token.text,
          'ocrRect': _v24RectMap(pair.token.rect),
          'predictedRect': {
            'left': cursor,
            'top': cellTop,
            'right': cursor + pitch,
            'bottom': cellTop + rowHeight,
            'width': pitch,
            'height': rowHeight,
          },
          'centerErrorX': pair.token.rect.centerX - cursor - pitch / 2,
          'centerErrorY': pair.token.rect.centerY - cellTop - rowHeight / 2,
          'syntheticOcrPosition': pair.token.synthetic,
        });
      }
      cursor += pitch;
    }
  }
  final refined = _v24CheckRefineGridWithOcrGeometry(
    lines: lines,
    cells: cells,
    anchors: anchors,
    pitch: pitch,
    origins: origins,
    indentCells: discreteFit['selectedIndentCells'] as int?,
  );
  final Map<String, dynamic> redGeometryFit = refined.summary;
  if (redGeometryFit['applied'] == true) {
    pitch = refined.pitch;
    origins = refined.origins;
    cells = refined.cells;
    boxes = refined.boxes;
    final residuals = [
      for (int row = 0; row < origins.length; row++)
        (measuredOrigins[row] - origins[row]).abs(),
    ];
    discreteFit.addAll({
      'baseOrigin': origins.first,
      'baseOriginMeasured': measuredOrigins.first,
      'tailOrigin': origins.length > 1 ? origins[1] : origins.first,
      'baseShift': origins.first - measuredOrigins.first,
      'redGeometryAdjusted': true,
      'residuals': residuals,
      'maxResidual': residuals.reduce(math.max),
      'constraintTolerance': math.max(4, pitch * .18),
      'constraintWarning':
          residuals.reduce(math.max) > math.max(4, pitch * .18),
    });
  }
  final inspected = _v24CheckInspectOcrGeometry(
    lines: lines,
    cells: cells,
    anchors: anchors,
    pitch: pitch,
  );
  final Set<int> edgeIndices = {};
  for (final range in ranges) {
    final visible = [
      for (int pos = range.start; pos < range.end; pos++)
        if (!input.source[pos].whitespace && !input.source[pos].newline) pos,
    ];
    if (visible.isNotEmpty) edgeIndices.addAll([visible.first, visible.last]);
  }
  final double selectionTolerance = math.max(
    4,
    math.max(pitch * .5, rowHeight * .25),
  );
  bool outside(Map<String, dynamic> c, OcrRect rect, double tolerance) =>
      (c['left'] as num) < rect.left - tolerance ||
      (c['top'] as num) < rect.top - tolerance ||
      (c['left'] as num) + (c['width'] as num) > rect.right + tolerance ||
      (c['top'] as num) + (c['height'] as num) > rect.bottom + tolerance;
  final imageRect = OcrRect(
    left: 0,
    top: 0,
    right: input.imageWidth,
    bottom: input.imageHeight,
  );
  final imageOut = boxes.where((c) => outside(c, imageRect, 0)).toList();
  final selectionOut = boxes
      .where(
        (c) =>
            !edgeIndices.contains(c['sourceLogicalIndex']) &&
            outside(c, input.selection, selectionTolerance),
      )
      .toList();
  final double warningTolerance = math.max(2, pitch * .05);
  final selectionWarnings = boxes
      .where((c) => outside(c, input.selection, warningTolerance))
      .toList();
  final covered = cells.map((c) => c['sourceLogicalIndex']).toSet();
  final int start = ranges.map((r) => r.start).reduce(math.min),
      end = ranges.map((r) => r.end).reduce(math.max);
  Map<String, dynamic> sourceMap(int pos) => {
    'logicalIndex': pos,
    'sourceIndex': input.source[pos].index,
    'length': input.source[pos].length,
    'text': input.source[pos].value,
  };
  final uncovered = [
    for (int pos = start; pos < end; pos++)
      if (!covered.contains(pos) &&
          !input.source[pos].whitespace &&
          !input.source[pos].newline)
        sourceMap(pos),
  ];
  final unobserved = [
    for (int pos = 0; pos < input.source.length; pos++)
      if ((pos < start || pos >= end) &&
          !input.source[pos].whitespace &&
          !input.source[pos].newline)
        sourceMap(pos),
  ];
  final String? reason = imageOut.isNotEmpty || selectionOut.isNotEmpty
      ? 'selection_out_of_bounds'
      : uncovered.isNotEmpty
      ? 'text_correspondence_insufficient'
      : (inspected.summary['errorCount'] as num? ?? 0) > 0
      ? 'ocr_geometry_conflict'
      : null;
  return {
    ...pitchDiagnostics,
    'ok': reason == null,
    'reason': reason,
    'pitch': pitch,
    'origins': origins,
    'measuredOrigins': measuredOrigins,
    'originRule': discreteFit['rule'],
    'originSnapTolerance': math.max(2, pitch * .18),
    'originEvidence': originEvidence,
    'originDiscreteFit': discreteFit,
    'originConstraintWarning': discreteFit['constraintWarning'] == true,
    'renderRanges': [
      for (int row = 0; row < ranges.length; row++)
        {
          'row': row,
          'sourceStart': ranges[row].start,
          'sourceEnd': ranges[row].end,
          'inferredLeadingUnits': math.max(
            0,
            matches[row].sourceStart - ranges[row].start,
          ),
          'inferredTrailingUnits': math.max(
            0,
            ranges[row].end - matches[row].sourceEnd,
          ),
        },
    ],
    'indentCells': [
      for (final origin in origins.skip(1)) (origin - origins.first) / pitch,
    ],
    'lineLevelPitch': _v24NullableFinite(lineLevelPitch),
    'lineLevelPitchConsensus': lineLevelConsensus,
    'widths': <String, double>{},
    'widthEvidence': _v24InferWidths(input.source, matches, pitch).evidence,
    'cells': cells,
    'boxes': boxes,
    'anchors': anchors,
    'uncoveredSourceUnits': uncovered,
    'unobservedSourceUnits': unobserved,
    'outOfBoundsCount': imageOut.length,
    'imageOutOfBoundsCount': imageOut.length,
    'selectionOutOfBoundsCount': selectionOut.length,
    'selectionMarginWarningCount': selectionWarnings.length,
    'selectionTolerance': selectionTolerance,
    'selectionWarningTolerance': warningTolerance,
    'selectionEdgeExemptions': edgeIndices.toList()..sort(),
    'selectionMarginWarnings': [
      for (final c in selectionWarnings)
        {
          for (final key in [
            'sourceLogicalIndex',
            'text',
            'left',
            'top',
            'width',
            'height',
          ])
            key: c[key],
        },
    ],
    'ocrGeometryWarnings': inspected.warnings,
    'ocrGeometrySummary': inspected.summary,
    'virtualNormalBoundaryFrames':
        inspected.summary['virtualNormalBoundaryFrames'] ?? [],
    'virtualNormalBoundaryDiagnostics':
        inspected.summary['virtualNormalBoundaryDiagnostics'] ?? [],
    'redGeometryFit': redGeometryFit,
    'rect': _v24RectMap(input.selection),
    'imageSize': {'width': input.imageWidth, 'height': input.imageHeight},
  };
}
