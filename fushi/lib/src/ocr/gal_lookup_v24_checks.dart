part of 'gal_lookup_calibration_ocr.dart';

// v24 geometry checks deliberately use the fit stage's JSON-shaped geometry
// contract.  This keeps candidate projection independent from the UI models.

({List<Map<String, dynamic>> warnings, Map<String, dynamic> summary})
_v24CheckInspectOcrGeometry({
  required List<GalCalibrationOcrMatchedLine> lines,
  required List<Map<String, dynamic>> cells,
  required List<Map<String, dynamic>> anchors,
  required double pitch,
  bool useVirtualBoundary = true,
}) {
  final List<Map<String, dynamic>> warnings = <Map<String, dynamic>>[];
  Map<String, dynamic> emptySummary() => <String, dynamic>{
    'anchorCount': 0,
    'anchorOutsideCellCount': 0,
    'lineCount': 0,
    'lineDisjointCount': 0,
    'contractedInsideLineCount': 0,
    'normalEdgeGapCount': 0,
    'virtualNormalBoundaryFrameCount': 0,
    'virtualNormalBoundarySideCount': 0,
    'warningCount': 0,
    'errorCount': 0,
  };
  if (!pitch.isFinite || pitch <= 0) {
    return (warnings: warnings, summary: emptySummary());
  }

  final double anchorTolerance = math.max(2.0, pitch * .05);
  for (final Map<String, dynamic> anchor in anchors) {
    final String text = '${anchor['text'] ?? ''}';
    if (_isPitchException(text)) continue;
    final int lineIndex = _v24CheckInt(anchor['ocrLine'], -1);
    final int sourceLogicalIndex = _v24CheckInt(
      anchor['sourceLogicalIndex'],
      -1,
    );
    final int tokenIndex = _v24CheckInt(anchor['ocrToken'], -1);
    final GalCalibrationOcrMatchedLine? match = _v24CheckMatchForLine(
      lines,
      lineIndex,
    );
    if (match == null || sourceLogicalIndex < 0 || tokenIndex < 0) continue;
    final GalCalibrationOcrGlyph? glyph = _v24CheckGlyphForLogical(
      match,
      sourceLogicalIndex,
      ocrToken: tokenIndex,
    );
    if (glyph == null || glyph.syntheticOcrPosition) continue;
    final Map<String, dynamic> predicted = _v24CheckMap(
      anchor['predictedRect'],
    );
    final double centerX = glyph.rect.centerX;
    final double centerY = glyph.rect.centerY;
    final double gapX = math.max(
      _v24CheckField(predicted, 'left') - centerX,
      centerX -
          _v24CheckField(
            predicted,
            'right',
            _v24CheckField(predicted, 'left') +
                _v24CheckField(predicted, 'width'),
          ),
    );
    final double gapY = math.max(
      _v24CheckField(predicted, 'top') - centerY,
      centerY -
          _v24CheckField(
            predicted,
            'bottom',
            _v24CheckField(predicted, 'top') +
                _v24CheckField(predicted, 'height'),
          ),
    );
    final double gap = math.max(0.0, math.max(gapX, gapY));
    if (gap <= anchorTolerance) continue;
    warnings.add(<String, dynamic>{
      'code': 'ocr_anchor_outside_final_cell',
      'severity': 'warning',
      'message': 'OCR 锚点中心与对应最终字格有明显偏差，保留为辅助诊断。',
      'ocrLine': lineIndex,
      'ocrToken': tokenIndex,
      'sourceLogicalIndex': anchor['sourceLogicalIndex'],
      'text': text,
      'gap': gap,
      'tolerance': anchorTolerance,
      'ocrRect': glyph.rect.toJson(),
      'predictedRect': predicted,
    });
  }

  final Map<int, List<Map<String, dynamic>>> rowsByLine =
      <int, List<Map<String, dynamic>>>{};
  for (final Map<String, dynamic> cell in cells) {
    rowsByLine
        .putIfAbsent(_v24CheckInt(cell['line']), () => <Map<String, dynamic>>[])
        .add(cell);
  }
  final double lineTolerance = math.max(2.0, pitch * .15);
  final double edgeTolerance = math.max(2.5, pitch * .08);
  final List<Map<String, dynamic>> virtualFrames = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> virtualDiagnostics =
      <Map<String, dynamic>>[];

  for (int row = 0; row < lines.length; row++) {
    final GalCalibrationOcrMatchedLine match = lines[row];
    final int lineIndex = match.lineIndex;
    final List<Map<String, dynamic>>? rowCells = rowsByLine[row];
    if (rowCells == null || rowCells.isEmpty) continue;
    final List<Map<String, dynamic>> normalCells =
        rowCells
            .where(
              (Map<String, dynamic> cell) =>
                  !_v24CheckFlag(cell['whitespace']) &&
                  !_isPitchException('${cell['text'] ?? ''}'),
            )
            .toList()
          ..sort(
            (a, b) => _v24CheckInt(
              a['sourceLogicalIndex'],
            ).compareTo(_v24CheckInt(b['sourceLogicalIndex'])),
          );
    if (normalCells.isEmpty) continue;
    final double gridLeft = rowCells
        .map((Map<String, dynamic> cell) => _v24CheckField(cell, 'left'))
        .reduce(math.min);
    final double gridTop = rowCells
        .map((Map<String, dynamic> cell) => _v24CheckField(cell, 'top'))
        .reduce(math.min);
    final double gridRight = rowCells
        .map(
          (Map<String, dynamic> cell) =>
              _v24CheckField(cell, 'left') + _v24CheckField(cell, 'width'),
        )
        .reduce(math.max);
    final double gridBottom = rowCells
        .map(
          (Map<String, dynamic> cell) =>
              _v24CheckField(cell, 'top') + _v24CheckField(cell, 'height'),
        )
        .reduce(math.max);
    final Map<String, dynamic>? virtualFrame = useVirtualBoundary
        ? _v24CheckVirtualNormalBoundaryFrame(
            lines: lines,
            match: match,
            rowCells: rowCells,
            pitch: pitch,
          )
        : null;
    if (virtualFrame != null) {
      virtualFrame['rawLeftMargin'] = gridLeft - match.rect.left;
      virtualFrame['rawRightMargin'] = match.rect.right - gridRight;
      virtualFrame['virtualLeftGapToGrid'] = virtualFrame['leftApplied'] == true
          ? gridLeft - _v24CheckField(virtualFrame, 'left')
          : null;
      virtualFrame['virtualRightGapToGrid'] =
          virtualFrame['rightApplied'] == true
          ? _v24CheckField(virtualFrame, 'right') - gridRight
          : null;
      virtualFrames.add(virtualFrame);
      final List<double> virtualGaps = <double>[
        for (final dynamic value in <dynamic>[
          virtualFrame['virtualLeftGapToGrid'],
          virtualFrame['virtualRightGapToGrid'],
        ])
          if (value is num && value.isFinite) value.abs().toDouble(),
      ];
      if (virtualGaps.any((double gap) => gap > edgeTolerance)) {
        virtualDiagnostics.add(<String, dynamic>{
          'code': 'virtual_normal_boundary_gap',
          'severity': 'diagnostic',
          'row': row,
          'ocrLine': lineIndex,
          'message': '虚拟普通字符边界与最终统一字格仍有间隔，只作为候选实验诊断，不改变当前红框判定。',
          'leftGap': virtualFrame['virtualLeftGapToGrid'],
          'rightGap': virtualFrame['virtualRightGapToGrid'],
          'tolerance': edgeTolerance,
          'frame': <String, dynamic>{
            'left': virtualFrame['left'],
            'right': virtualFrame['right'],
            'top': virtualFrame['top'],
            'bottom': virtualFrame['bottom'],
          },
        });
      }
    }

    final double xOverlap =
        math.min(gridRight, match.rect.right) -
        math.max(gridLeft, match.rect.left);
    final double yOverlap =
        math.min(gridBottom, match.rect.bottom) -
        math.max(gridTop, match.rect.top);
    if (xOverlap <= 0 || yOverlap <= 0) {
      warnings.add(<String, dynamic>{
        'code': 'ocr_line_disjoint_from_final_grid',
        'severity': 'error',
        'message': '最终字格与对应 OCR 行框没有重叠。',
        'row': row,
        'ocrLine': lineIndex,
        'ocrLineRect': match.rect.toJson(),
        'gridSpan': _v24CheckRectJson(gridLeft, gridTop, gridRight, gridBottom),
      });
      continue;
    }

    final double comparisonLeft = match.rect.left;
    final double comparisonRight = match.rect.right;
    final double leftMargin = gridLeft - comparisonLeft;
    final double rightMargin = comparisonRight - gridRight;
    Map<String, dynamic> lineComparison(
      String code,
      String severity,
      String message,
    ) => <String, dynamic>{
      'code': code,
      'severity': severity,
      'message': message,
      'row': row,
      'ocrLine': lineIndex,
      'leftMargin': leftMargin,
      'rightMargin': rightMargin,
      'rawLeftMargin': gridLeft - match.rect.left,
      'rawRightMargin': match.rect.right - gridRight,
      'tolerance': lineTolerance,
      'ocrLineRect': match.rect.toJson(),
      'comparisonFrame': _v24CheckRectJson(
        comparisonLeft,
        match.rect.top,
        comparisonRight,
        match.rect.bottom,
      ),
      'boundaryMode': virtualFrame == null ? 'raw_ocr_line' : 'virtual_normal',
      'gridSpan': _v24CheckRectJson(gridLeft, gridTop, gridRight, gridBottom),
    };
    if (leftMargin > lineTolerance && rightMargin > lineTolerance) {
      warnings.add(
        lineComparison(
          'final_grid_contracted_inside_ocr_line',
          'error',
          '最终整行字格明显缩进在 OCR 黄框内部，疑似格距或行起点被压窄。',
        ),
      );
    } else if (leftMargin > lineTolerance || rightMargin > lineTolerance) {
      warnings.add(
        lineComparison(
          'final_grid_does_not_reach_ocr_line_edge',
          'warning',
          '最终字格没有达到 OCR 行框的一侧边缘，保留为软性几何警告。',
        ),
      );
    }

    final Map<String, dynamic> firstBoundary = normalCells.first;
    final Map<String, dynamic> lastBoundary = normalCells.last;
    final GalCalibrationOcrGlyph? firstGlyph = _v24CheckGlyphForLogical(
      match,
      _v24CheckInt(firstBoundary['sourceLogicalIndex']),
    );
    final GalCalibrationOcrGlyph? lastGlyph = _v24CheckGlyphForLogical(
      match,
      _v24CheckInt(lastBoundary['sourceLogicalIndex']),
    );
    final List<int> tokenIndices = <int>[
      for (final GalCalibrationOcrGlyph glyph in match.glyphs)
        if (!glyph.syntheticOcrPosition && glyph.ocrTokenIndex != null)
          glyph.ocrTokenIndex!,
    ];
    final int? lastToken = tokenIndices.isEmpty
        ? null
        : tokenIndices.reduce(math.max);
    bool usableBoundary(GalCalibrationOcrGlyph? glyph, {required bool left}) {
      if (glyph == null ||
          !_v24CheckUsableGlyph(glyph) ||
          glyph.ocrTokenIndex == null) {
        return false;
      }
      return glyph.ocrTokenIndex ==
          (left
              ? 0
              : (match.ocrTokenCount == null
                    ? lastToken
                    : match.ocrTokenCount! - 1));
    }

    final bool rawLeftComparable = usableBoundary(firstGlyph, left: true);
    final bool rawRightComparable = usableBoundary(lastGlyph, left: false);
    final double leftEdgeGap = rawLeftComparable
        ? (_v24CheckField(firstBoundary, 'left') - match.rect.left).abs()
        : 0;
    final double rightBoundary =
        _v24CheckField(lastBoundary, 'left') +
        _v24CheckField(lastBoundary, 'width');
    final double rightEdgeGap = rawRightComparable
        ? (rightBoundary - match.rect.right).abs()
        : 0;
    final double leftEdgeDelta = rawLeftComparable
        ? _v24CheckField(firstBoundary, 'left') - match.rect.left
        : 0;
    final double rightEdgeDelta = rawRightComparable
        ? rightBoundary - match.rect.right
        : 0;
    if ((rawLeftComparable && leftEdgeGap.abs() > edgeTolerance) ||
        (rawRightComparable && rightEdgeGap > edgeTolerance)) {
      warnings.add(<String, dynamic>{
        'code': 'normal_grid_edge_gap_to_ocr_line',
        'severity': 'warning',
        'message': '普通字符格子没有贴近 OCR 黄框边缘，存在可见间隔；保留为强几何警告，不单独吞掉整句。',
        'row': row,
        'ocrLine': lineIndex,
        'leftGap': leftEdgeGap,
        'rightGap': rightEdgeGap,
        'leftDelta': leftEdgeDelta,
        'rightDelta': rightEdgeDelta,
        'leftRelation': leftEdgeDelta < -edgeTolerance
            ? 'outside'
            : leftEdgeDelta > edgeTolerance
            ? 'inside'
            : 'touching',
        'rightRelation': rightEdgeDelta > edgeTolerance
            ? 'outside'
            : rightEdgeDelta < -edgeTolerance
            ? 'inside'
            : 'touching',
        'leftComparable': rawLeftComparable,
        'rightComparable': rawRightComparable,
        'rawLeftComparable': rawLeftComparable,
        'rawRightComparable': rawRightComparable,
        'boundaryMode': 'raw_normal_anchor',
        'virtualBoundaryFrameAvailable': virtualFrame != null,
        'virtualLeftGapToGrid': virtualFrame?['virtualLeftGapToGrid'],
        'virtualRightGapToGrid': virtualFrame?['virtualRightGapToGrid'],
        'leftBoundaryText': firstBoundary['text'] ?? '',
        'rightBoundaryText': lastBoundary['text'] ?? '',
        'tolerance': edgeTolerance,
        'ocrLineRect': match.rect.toJson(),
        'comparisonFrame': _v24CheckRectJson(
          comparisonLeft,
          match.rect.top,
          comparisonRight,
          match.rect.bottom,
        ),
        'gridSpan': _v24CheckRectJson(
          _v24CheckField(firstBoundary, 'left'),
          gridTop,
          rightBoundary,
          gridBottom,
        ),
      });
    }
  }

  final Map<String, dynamic> summary = <String, dynamic>{
    'anchorCount': anchors
        .where(
          (Map<String, dynamic> anchor) =>
              !_v24CheckFlag(anchor['syntheticOcrPosition']),
        )
        .length,
    'anchorOutsideCellCount': warnings
        .where(
          (Map<String, dynamic> warning) =>
              warning['code'] == 'ocr_anchor_outside_final_cell',
        )
        .length,
    'lineCount': lines.length,
    'lineDisjointCount': warnings
        .where(
          (Map<String, dynamic> warning) =>
              warning['code'] == 'ocr_line_disjoint_from_final_grid',
        )
        .length,
    'contractedInsideLineCount': warnings
        .where(
          (Map<String, dynamic> warning) =>
              warning['code'] == 'final_grid_contracted_inside_ocr_line',
        )
        .length,
    'normalEdgeGapCount': warnings
        .where(
          (Map<String, dynamic> warning) =>
              warning['code'] == 'normal_grid_edge_gap_to_ocr_line',
        )
        .length,
    'virtualNormalBoundaryFrameCount': virtualFrames.length,
    'virtualNormalBoundarySideCount': virtualFrames.fold<int>(
      0,
      (int sum, Map<String, dynamic> frame) =>
          sum +
          (_v24CheckFlag(frame['leftApplied']) ? 1 : 0) +
          (_v24CheckFlag(frame['rightApplied']) ? 1 : 0),
    ),
    'virtualNormalBoundaryFrames': virtualFrames,
    'virtualNormalBoundaryDiagnostics': virtualDiagnostics,
    'virtualNormalBoundaryDiagnosticCount': virtualDiagnostics.length,
    'warningCount': warnings
        .where(
          (Map<String, dynamic> warning) => warning['severity'] == 'warning',
        )
        .length,
    'errorCount': warnings
        .where((Map<String, dynamic> warning) => warning['severity'] == 'error')
        .length,
  };
  return (warnings: warnings, summary: summary);
}

({double penalty, Map<String, dynamic> detail})
_v24CheckOcrGeometryWarningPenalty(
  List<Map<String, dynamic>> warnings,
  double pitch,
) {
  if (!pitch.isFinite || pitch <= 0) {
    return (
      penalty: 0.0,
      detail: <String, dynamic>{
        'warningCount': warnings.length,
        'penalty': 0.0,
      },
    );
  }
  double penalty = 0;
  final Map<String, int> byCode = <String, int>{};
  for (final Map<String, dynamic> warning in warnings) {
    final String code = '${warning['code'] ?? 'unknown'}';
    byCode[code] = (byCode[code] ?? 0) + 1;
    penalty += 1;
    if (code == 'ocr_line_disjoint_from_final_grid') {
      penalty += 100;
      continue;
    }
    if (code == 'ocr_anchor_outside_final_cell') {
      final double gap = _v24CheckField(warning, 'gap');
      final double tolerance = _v24CheckField(warning, 'tolerance');
      penalty += 8 * math.max(0.0, gap - tolerance) / pitch;
      continue;
    }
    if (code == 'final_grid_contracted_inside_ocr_line') {
      final double tolerance = _v24CheckField(warning, 'tolerance');
      final double excess =
          math.max(0.0, _v24CheckField(warning, 'leftMargin') - tolerance) +
          math.max(0.0, _v24CheckField(warning, 'rightMargin') - tolerance);
      penalty += 8 * excess / pitch;
      continue;
    }
    if (code == 'final_grid_does_not_reach_ocr_line_edge') {
      final double tolerance = _v24CheckField(warning, 'tolerance');
      final double excess =
          math.max(0.0, _v24CheckField(warning, 'leftMargin') - tolerance) +
          math.max(0.0, _v24CheckField(warning, 'rightMargin') - tolerance);
      penalty += 6 * excess / pitch;
      continue;
    }
    if (code == 'normal_grid_edge_gap_to_ocr_line') {
      final double tolerance = _v24CheckField(warning, 'tolerance');
      final double excess =
          math.max(0.0, _v24CheckField(warning, 'leftGap') - tolerance) +
          math.max(0.0, _v24CheckField(warning, 'rightGap') - tolerance);
      penalty += 8 * excess / pitch;
    }
  }
  return (
    penalty: penalty,
    detail: <String, dynamic>{
      'warningCount': warnings.length,
      'penalty': penalty,
      'byCode': byCode,
    },
  );
}

({double error, int count}) _v24CheckNormalAnchorError(
  List<GalCalibrationOcrMatchedLine> lines,
  List<Map<String, dynamic>> anchors,
  double pitch,
) {
  if (!pitch.isFinite || pitch <= 0) return (error: 0.0, count: 0);
  double total = 0;
  int count = 0;
  for (final Map<String, dynamic> anchor in anchors) {
    if (_isPitchException('${anchor['text'] ?? ''}')) continue;
    final int lineIndex = _v24CheckInt(anchor['ocrLine'], -1);
    final int sourceLogicalIndex = _v24CheckInt(
      anchor['sourceLogicalIndex'],
      -1,
    );
    final int tokenIndex = _v24CheckInt(anchor['ocrToken'], -1);
    final GalCalibrationOcrMatchedLine? match = _v24CheckMatchForLine(
      lines,
      lineIndex,
    );
    if (match == null) continue;
    final GalCalibrationOcrGlyph? glyph = _v24CheckGlyphForLogical(
      match,
      sourceLogicalIndex,
      ocrToken: tokenIndex,
    );
    if (glyph == null || glyph.syntheticOcrPosition) continue;
    final Map<String, dynamic> predicted = _v24CheckMap(
      anchor['predictedRect'],
    );
    final double predictedX =
        (_v24CheckField(predicted, 'left') +
            _v24CheckField(
              predicted,
              'right',
              _v24CheckField(predicted, 'left') +
                  _v24CheckField(predicted, 'width'),
            )) /
        2;
    final double predictedY =
        (_v24CheckField(predicted, 'top') +
            _v24CheckField(
              predicted,
              'bottom',
              _v24CheckField(predicted, 'top') +
                  _v24CheckField(predicted, 'height'),
            )) /
        2;
    final double centerError = math.sqrt(
      math.pow(glyph.rect.centerX - predictedX, 2) +
          math.pow(glyph.rect.centerY - predictedY, 2),
    );
    total +=
        _v24ConfidenceWeight(
          glyph.ocrConfidence ?? glyph.confidence,
          synthetic: glyph.syntheticOcrPosition,
        ) *
        centerError /
        pitch;
    count++;
  }
  return (error: total, count: count);
}

bool _v24CheckRedCandidateAnchorCompatible(
  double baselineError,
  double candidateError,
) {
  if (!baselineError.isFinite || !candidateError.isFinite) return false;
  final double allowedIncrease = math.max(.25, baselineError * .10);
  return candidateError <= baselineError + allowedIncrease;
}

({
  double pitch,
  List<double> origins,
  List<Map<String, dynamic>> cells,
  List<Map<String, dynamic>> boxes,
  Map<String, dynamic> summary,
})
_v24CheckRefineGridWithOcrGeometry({
  required List<GalCalibrationOcrMatchedLine> lines,
  required List<Map<String, dynamic>> cells,
  required List<Map<String, dynamic>> anchors,
  required double pitch,
  required List<double> origins,
  required int? indentCells,
}) {
  final ({List<Map<String, dynamic>> warnings, Map<String, dynamic> summary})
  baselineInspection = _v24CheckInspectOcrGeometry(
    lines: lines,
    cells: cells,
    anchors: anchors,
    pitch: pitch,
    useVirtualBoundary: false,
  );
  final ({double penalty, Map<String, dynamic> detail}) baselinePenalty =
      _v24CheckOcrGeometryWarningPenalty(baselineInspection.warnings, pitch);
  final ({double error, int count}) baselineAnchor = _v24CheckNormalAnchorError(
    lines,
    anchors,
    pitch,
  );
  final Map<String, dynamic> baseSummary = <String, dynamic>{
    'applied': false,
    'method': 'red_geometry_candidate_search',
    'baseline': <String, dynamic>{
      'pitch': pitch,
      'origins': <double>[...origins],
      'summary': baselineInspection.summary,
      'redPenalty': baselinePenalty.detail,
      'normalAnchorError': baselineAnchor.error,
      'normalAnchorCount': baselineAnchor.count,
    },
    'selected': null,
  };
  List<Map<String, dynamic>> boxesFor(List<Map<String, dynamic>> values) =>
      <Map<String, dynamic>>[
        for (final Map<String, dynamic> cell in values)
          if (!_v24CheckFlag(cell['whitespace'])) cell,
      ];
  ({
    double pitch,
    List<double> origins,
    List<Map<String, dynamic>> cells,
    List<Map<String, dynamic>> boxes,
    Map<String, dynamic> summary,
  })
  noChange() => (
    pitch: pitch,
    origins: <double>[...origins],
    cells: cells,
    boxes: boxesFor(cells),
    summary: baseSummary,
  );
  if (cells.isEmpty ||
      anchors.isEmpty ||
      !pitch.isFinite ||
      pitch <= 0 ||
      origins.isEmpty ||
      baselineInspection.warnings.isEmpty ||
      indentCells == null) {
    return noChange();
  }
  const Set<String> actionableCodes = <String>{
    'ocr_anchor_outside_final_cell',
    'ocr_line_disjoint_from_final_grid',
    'final_grid_contracted_inside_ocr_line',
    'normal_grid_edge_gap_to_ocr_line',
  };
  if (!baselineInspection.warnings.any(
    (Map<String, dynamic> warning) => actionableCodes.contains(warning['code']),
  )) {
    return noChange();
  }

  final Map<String, double> cellOffsets = <String, double>{};
  for (final Map<String, dynamic> cell in cells) {
    final int row = _v24CheckInt(cell['line']);
    if (row < 0 || row >= origins.length) continue;
    final String key = '${_v24CheckInt(cell['sourceLogicalIndex'])}:$row';
    cellOffsets[key] = (_v24CheckField(cell, 'left') - origins[row]) / pitch;
  }

  ({
    List<double> origins,
    List<Map<String, dynamic>> cells,
    List<Map<String, dynamic>> anchors,
  })
  project(double candidatePitch, double baseOrigin) {
    final List<double> candidateOrigins = <double>[
      for (int row = 0; row < origins.length; row++)
        row == 0 ? baseOrigin : baseOrigin + indentCells * candidatePitch,
    ];
    final List<Map<String, dynamic>> candidateCells = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> cell in cells) {
      final int row = _v24CheckInt(cell['line']);
      final String key = '${_v24CheckInt(cell['sourceLogicalIndex'])}:$row';
      final double? offset = cellOffsets[key];
      if (offset == null || row < 0 || row >= candidateOrigins.length) continue;
      final Map<String, dynamic> candidate = <String, dynamic>{...cell};
      candidate['left'] = candidateOrigins[row] + offset * candidatePitch;
      candidate['width'] = candidatePitch;
      candidate['height'] = _v24CheckField(cell, 'height');
      candidateCells.add(candidate);
    }
    final Map<String, Map<String, dynamic>>
    byKey = <String, Map<String, dynamic>>{
      for (final Map<String, dynamic> cell in candidateCells)
        '${_v24CheckInt(cell['sourceLogicalIndex'])}:${_v24CheckInt(cell['line'])}':
            cell,
    };
    final List<Map<String, dynamic>> candidateAnchors =
        <Map<String, dynamic>>[];
    for (final Map<String, dynamic> anchor in anchors) {
      final Map<String, dynamic> candidate = <String, dynamic>{...anchor};
      final String key =
          '${_v24CheckInt(anchor['sourceLogicalIndex'])}:${_v24CheckInt(anchor['ocrLine'])}';
      final Map<String, dynamic>? cell = byKey[key];
      if (cell != null) {
        final double left = _v24CheckField(cell, 'left');
        final double top = _v24CheckField(cell, 'top');
        final double height = _v24CheckField(cell, 'height');
        final Map<String, dynamic> predicted = _v24CheckRectJson(
          left,
          top,
          left + candidatePitch,
          top + height,
          dimensions: true,
        );
        candidate['predictedRect'] = predicted;
        final GalCalibrationOcrMatchedLine? match = _v24CheckMatchForLine(
          lines,
          _v24CheckInt(anchor['ocrLine'], -1),
        );
        final GalCalibrationOcrGlyph? glyph = match == null
            ? null
            : _v24CheckGlyphForLogical(
                match,
                _v24CheckInt(anchor['sourceLogicalIndex']),
                ocrToken: _v24CheckInt(anchor['ocrToken'], -1),
              );
        if (glyph != null) {
          candidate['centerErrorX'] =
              glyph.rect.centerX - (left + candidatePitch / 2);
          candidate['centerErrorY'] = glyph.rect.centerY - (top + height / 2);
        }
      }
      candidateAnchors.add(candidate);
    }
    return (
      origins: candidateOrigins,
      cells: candidateCells,
      anchors: candidateAnchors,
    );
  }

  Map<String, dynamic>? best;
  const List<double> scaleCandidates = <double>[.98, .99, 1.0, 1.01, 1.02];
  const List<double> shiftCandidates = <double>[
    -.5,
    -.375,
    -.25,
    -.125,
    0,
    .125,
    .25,
    .375,
    .5,
  ];
  for (final double scale in scaleCandidates) {
    final double candidatePitch = pitch * scale;
    for (final double shiftCells in shiftCandidates) {
      final double baseOrigin = origins.first + shiftCells * candidatePitch;
      final ({
        List<double> origins,
        List<Map<String, dynamic>> cells,
        List<Map<String, dynamic>> anchors,
      })
      projected = project(candidatePitch, baseOrigin);
      final ({
        List<Map<String, dynamic>> warnings,
        Map<String, dynamic> summary,
      })
      inspection = _v24CheckInspectOcrGeometry(
        lines: lines,
        cells: projected.cells,
        anchors: projected.anchors,
        pitch: candidatePitch,
        useVirtualBoundary: false,
      );
      final ({double penalty, Map<String, dynamic> detail}) redPenalty =
          _v24CheckOcrGeometryWarningPenalty(
            inspection.warnings,
            candidatePitch,
          );
      final ({double error, int count}) anchorError =
          _v24CheckNormalAnchorError(lines, projected.anchors, candidatePitch);
      final double drift = (scale - 1).abs() + shiftCells.abs() * .12;
      final Map<String, dynamic> candidate = <String, dynamic>{
        'pitch': candidatePitch,
        'origins': projected.origins,
        'cells': projected.cells,
        'anchors': projected.anchors,
        'summary': inspection.summary,
        'redPenalty': redPenalty.detail,
        'normalAnchorError': anchorError.error,
        'normalAnchorCount': anchorError.count,
        'drift': drift,
        'shiftCells': shiftCells,
        'scale': scale,
        'score': redPenalty.penalty * 2 + anchorError.error + drift,
      };
      final bool improvesRed =
          redPenalty.penalty + .02 < baselinePenalty.penalty;
      final bool avoidsNewHardConflict =
          _v24CheckInt(inspection.summary['errorCount']) <=
          _v24CheckInt(baselineInspection.summary['errorCount']);
      final bool staysAnchorCompatible = _v24CheckRedCandidateAnchorCompatible(
        baselineAnchor.error,
        anchorError.error,
      );
      if (!improvesRed || !staysAnchorCompatible || !avoidsNewHardConflict) {
        continue;
      }
      final bool better =
          best == null ||
          (candidate['score'] as double) < (best['score'] as double) ||
          ((candidate['score'] as double) == (best['score'] as double) &&
              redPenalty.penalty <
                  _v24CheckField(_v24CheckMap(best['redPenalty']), 'penalty'));
      if (better) best = candidate;
    }
  }
  if (best == null) return noChange();
  baseSummary['applied'] = true;
  baseSummary['selected'] = <String, dynamic>{
    'pitch': best['pitch'],
    'origins': best['origins'],
    'summary': best['summary'],
    'redPenalty': best['redPenalty'],
    'normalAnchorError': best['normalAnchorError'],
    'normalAnchorCount': best['normalAnchorCount'],
    'scale': best['scale'],
    'shiftCells': best['shiftCells'],
    'score': best['score'],
  };
  final List<Map<String, dynamic>> selectedCells = _v24CheckMaps(best['cells']);
  return (
    pitch: (best['pitch'] as num).toDouble(),
    origins: _v24CheckList(
      best['origins'],
    ).whereType<num>().map((num value) => value.toDouble()).toList(),
    cells: selectedCells,
    boxes: boxesFor(selectedCells),
    summary: baseSummary,
  );
}

Map<String, dynamic> _v24CheckMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return <String, dynamic>{
      for (final MapEntry<dynamic, dynamic> entry in value.entries)
        entry.key.toString(): entry.value,
    };
  }
  return <String, dynamic>{};
}

List<Map<String, dynamic>> _v24CheckMaps(dynamic value) {
  if (value is! List) return <Map<String, dynamic>>[];
  return <Map<String, dynamic>>[
    for (final dynamic item in value) _v24CheckMap(item),
  ];
}

List<dynamic> _v24CheckList(dynamic value) =>
    value is List ? value : const <dynamic>[];

double _v24CheckField(
  Map<String, dynamic> value,
  String key, [
  double fallback = 0,
]) {
  final dynamic raw = value[key];
  final double number = raw is num ? raw.toDouble() : fallback;
  return number.isFinite ? number : fallback;
}

int _v24CheckInt(dynamic value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num && value.isFinite) return value.toInt();
  return fallback;
}

bool _v24CheckFlag(dynamic value) => value == true;

Map<String, dynamic> _v24CheckRectJson(
  double left,
  double top,
  double right,
  double bottom, {
  bool dimensions = false,
}) {
  final Map<String, dynamic> result = <String, dynamic>{
    'left': left,
    'top': top,
    'right': right,
    'bottom': bottom,
  };
  if (dimensions) {
    result['width'] = right - left;
    result['height'] = bottom - top;
  }
  return result;
}

double _v24CheckWeightedMedian(List<({double value, int weight})> values) {
  final List<({double value, int weight})> sorted =
      values
          .where(
            (({double value, int weight}) item) =>
                item.value.isFinite && item.value > 0,
          )
          .map(
            (({double value, int weight}) item) =>
                (value: item.value, weight: math.max(1, item.weight)),
          )
          .toList()
        ..sort((a, b) => a.value.compareTo(b.value));
  if (sorted.isEmpty) return double.nan;
  final int total = sorted.fold<int>(
    0,
    (int sum, ({double value, int weight}) item) => sum + item.weight,
  );
  final double threshold = (total + 1) / 2;
  int accumulated = 0;
  for (final ({double value, int weight}) item in sorted) {
    accumulated += item.weight;
    if (accumulated >= threshold) return item.value;
  }
  return sorted.last.value;
}

GalCalibrationOcrMatchedLine? _v24CheckMatchForLine(
  List<GalCalibrationOcrMatchedLine> matches,
  int lineIndex,
) {
  for (final GalCalibrationOcrMatchedLine match in matches) {
    if (match.lineIndex == lineIndex) return match;
  }
  return lineIndex >= 0 && lineIndex < matches.length
      ? matches[lineIndex]
      : null;
}

GalCalibrationOcrGlyph? _v24CheckGlyphForLogical(
  GalCalibrationOcrMatchedLine match,
  int sourceLogicalIndex, {
  int? ocrToken,
}) {
  for (final GalCalibrationOcrGlyph glyph in match.glyphs) {
    if (match.sourceStart + glyph.cellOffset != sourceLogicalIndex) continue;
    if (ocrToken != null && glyph.ocrTokenIndex != ocrToken) continue;
    return glyph;
  }
  return null;
}

bool _v24CheckUsableGlyph(GalCalibrationOcrGlyph glyph) =>
    _reliableRelation(glyph.matchKind) &&
    !glyph.syntheticOcrPosition &&
    glyph.rect.left.isFinite &&
    glyph.rect.top.isFinite &&
    glyph.rect.right.isFinite &&
    glyph.rect.bottom.isFinite &&
    glyph.rect.width > 0 &&
    glyph.rect.height > 0;

double _v24CheckGlyphConfidence(GalCalibrationOcrGlyph glyph) =>
    _v24ConfidenceWeight(
      glyph.ocrConfidence ?? glyph.confidence,
      synthetic: glyph.syntheticOcrPosition,
    );

Map<String, dynamic>? _v24CheckVirtualNormalBoundaryFrame({
  required List<GalCalibrationOcrMatchedLine> lines,
  required GalCalibrationOcrMatchedLine match,
  required List<Map<String, dynamic>> rowCells,
  required double pitch,
}) {
  if (!pitch.isFinite || pitch <= 0 || rowCells.isEmpty) return null;
  final List<Map<String, dynamic>> ordered = rowCells.toList()
    ..sort(
      (a, b) => _v24CheckInt(
        a['sourceLogicalIndex'],
      ).compareTo(_v24CheckInt(b['sourceLogicalIndex'])),
    );
  final List<int> visible = <int>[
    for (int index = 0; index < ordered.length; index++)
      if (!_v24CheckFlag(ordered[index]['whitespace'])) index,
  ];
  if (visible.isEmpty) return null;
  final int firstVisible = visible.first;
  final int lastVisible = visible.last;
  int? firstNormal;
  int? lastNormal;
  for (final int index in visible) {
    if (!_isPitchException('${ordered[index]['text'] ?? ''}')) {
      firstNormal = index;
      break;
    }
  }
  for (final int index in visible.reversed) {
    if (!_isPitchException('${ordered[index]['text'] ?? ''}')) {
      lastNormal = index;
      break;
    }
  }
  if (firstNormal == null || lastNormal == null) return null;
  final int leading = firstNormal - firstVisible;
  final int trailing = lastVisible - lastNormal;
  if (leading <= 0 && trailing <= 0) return null;

  GalCalibrationOcrGlyph? reliableToken(int cellIndex) {
    final int logical = _v24CheckInt(ordered[cellIndex]['sourceLogicalIndex']);
    final GalCalibrationOcrGlyph? glyph = _v24CheckGlyphForLogical(
      match,
      logical,
    );
    return glyph != null && _v24CheckUsableGlyph(glyph) ? glyph : null;
  }

  final GalCalibrationOcrGlyph? leftAnchor = reliableToken(firstNormal);
  final GalCalibrationOcrGlyph? rightAnchor = reliableToken(lastNormal);
  final bool leftApplied = leading > 0 && leftAnchor != null;
  final bool rightApplied = trailing > 0 && rightAnchor != null;
  if (!leftApplied && !rightApplied) return null;

  final List<({double value, int weight})> estimates =
      <({double value, int weight})>[];
  for (int index = 0; index < ordered.length; index++) {
    final Map<String, dynamic> cell = ordered[index];
    if (_v24CheckFlag(cell['whitespace']) ||
        _isPitchException('${cell['text'] ?? ''}')) {
      continue;
    }
    final GalCalibrationOcrGlyph? glyph = reliableToken(index);
    if (glyph == null) continue;
    final double origin = glyph.rect.centerX - (index + .5) * pitch;
    if (origin.isFinite) {
      estimates.add((
        value: origin,
        weight: _v24ConfidenceUnits(_v24CheckGlyphConfidence(glyph)),
      ));
    }
  }
  if (estimates.length < 2) return null;
  final double origin = _v24CheckWeightedMedian(estimates);
  if (!origin.isFinite) return null;
  final double left = leftApplied ? origin : match.rect.left;
  final double right = rightApplied
      ? origin + ordered.length * pitch
      : match.rect.right;
  if (!left.isFinite || !right.isFinite || right <= left) return null;

  final List<String> leftExceptions = <String>[
    for (final int index in visible.take(
      math.max(0, firstNormal - firstVisible),
    ))
      '${ordered[index]['text'] ?? ''}',
  ];
  final int rightStart = math.max(0, lastNormal - firstVisible + 1);
  final List<String> rightExceptions = <String>[
    for (final int index in visible.skip(rightStart))
      '${ordered[index]['text'] ?? ''}',
  ];
  return <String, dynamic>{
    'row': _v24CheckInt(ordered.first['line'], match.lineIndex),
    'ocrLine': match.lineIndex,
    'method': 'virtual_normal_boundary_from_reliable_token',
    'applied': true,
    'leftApplied': leftApplied,
    'rightApplied': rightApplied,
    'leadingExceptionCells': leading,
    'trailingExceptionCells': trailing,
    'leftBoundaryText': ordered[firstNormal]['text'] ?? '',
    'rightBoundaryText': ordered[lastNormal]['text'] ?? '',
    'leftExceptionText': leftExceptions,
    'rightExceptionText': rightExceptions,
    'leftAnchorOcrPosition': leftAnchor?.ocrTokenIndex,
    'rightAnchorOcrPosition': rightAnchor?.ocrTokenIndex,
    'normalAnchorCount': estimates.length,
    'normalAnchorOrigin': origin,
    'normalAnchorOriginConsensus': <String, dynamic>{
      'observations': estimates.length,
      'weightedObservations': estimates.fold<int>(
        0,
        (int sum, ({double value, int weight}) item) => sum + item.weight,
      ),
      'method': 'weighted_line_regression_median',
    },
    'rawLeft': match.rect.left,
    'rawRight': match.rect.right,
    'left': left,
    'right': right,
    'top': match.rect.top,
    'bottom': match.rect.bottom,
    'rawLeftGapToGrid': null,
    'rawRightGapToGrid': null,
    'virtualLeftGapToGrid': null,
    'virtualRightGapToGrid': null,
  };
}
