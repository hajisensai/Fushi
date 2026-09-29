import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/ocr/gal_lookup_calibration_ocr.dart';

// Synthetic inputs and expected cells were exported from the frozen v24 Python
// oracle. This exercises text matching and geometry together; no Python runtime
// or private game screenshots are required to run the regression.
void main() {
  final data =
      jsonDecode(
            File('test/ocr/fixtures/gal_lookup_v24.json').readAsStringSync(),
          )
          as Map;
  for (final fixture in data['cases'] as List) {
    test('frozen v24: ${fixture['name']}', () {
      final input = fixture['input'] as Map;
      final expected = fixture['expected'] as Map;
      final selection =
          input['selection'] as Map? ??
          {'left': 0, 'top': 0, 'width': 800, 'height': 180};
      OcrRect rect(Map value) => OcrRect(
        left: (value['left'] as num).toDouble(),
        top: (value['top'] as num).toDouble(),
        right: (value['left'] as num) + (value['width'] as num).toDouble(),
        bottom: (value['top'] as num) + (value['height'] as num).toDouble(),
      );
      final actual = fitGalCalibrationV24(
        sourceText: input['text'] as String,
        lines: [
          for (final l in input['lines'] as List)
            GalCalibrationOcrLine(
              text: l['text'] as String,
              rect: rect(l as Map),
              score: (l['score'] as num).toDouble(),
              tokens: [
                for (final t in l['tokens'] as List? ?? [])
                  GalCalibrationOcrToken(
                    t['text'] as String,
                    rect(t as Map),
                    (t['confidence'] as num).toDouble(),
                  ),
              ],
            ),
        ],
        selection: rect(selection),
        client: const GalLookupReferenceClientV1(
          widthPx: 800,
          heightPx: 180,
          dpi: 96,
        ),
      );
      if (Platform.environment['FUSHI_V24_DIAGNOSTICS'] == '1') {
        Object? clean(Object? v) {
          if (v is num && !v.isFinite) return null;
          if (v is Map) {
            return {
              for (final entry in v.entries)
                entry.key.toString(): clean(entry.value),
            };
          }
          if (v is List) return v.map(clean).toList();
          return v;
        }

        File(
          '../.codex-test/v24-parity/actual-${fixture['name']}.json',
        ).writeAsStringSync(jsonEncode(clean(actual)));
      }
      // The production entry rejects an invalid crop before fitting, while
      // the oracle can fail earlier for unrelated missing geometry evidence.
      if (rect(selection).right > 800 ||
          rect(selection).bottom > 180 ||
          rect(selection).left < 0 ||
          rect(selection).top < 0) {
        expect(actual['ok'], isFalse);
        expect(actual['reason'], 'selection_out_of_bounds');
        return;
      }
      expect(
        actual['ok'],
        expected['ok'],
        reason: 'reason=${actual['reason']}',
      );
      expect(actual['reason'], expected['reason']);
      final cells = actual['cells'] as List? ?? [];
      final expectedCells = expected['cells'] as List;
      expect(
        cells.length,
        expectedCells.length,
        reason: 'all Hook cells, including spaces',
      );
      for (int i = 0; i < cells.length; i++) {
        for (final key in [
          'sourceIndex',
          'length',
          'text',
          'line',
          'whitespace',
          'anchored',
          'matchKind',
          'widthClass',
        ]) {
          expect(cells[i][key], expectedCells[i][key], reason: 'cell $i $key');
        }
        for (final key in ['left', 'top', 'width', 'height']) {
          expect(
            cells[i][key],
            closeTo((expectedCells[i][key] as num).toDouble(), 1e-6),
            reason: 'cell $i $key',
          );
        }
      }
      for (final key in ['pitch', 'cellHeight', 'lineAdvance']) {
        if (expected[key] != null) {
          expect(
            actual[key],
            closeTo((expected[key] as num).toDouble(), 1e-6),
            reason: key,
          );
        }
      }
      if (expected['origins'] != null) {
        expect(
          actual['origins'],
          hasLength((expected['origins'] as List).length),
        );
        for (int i = 0; i < (expected['origins'] as List).length; i++) {
          expect(
            (actual['origins'] as List)[i],
            closeTo((expected['origins'][i] as num).toDouble(), 1e-6),
            reason: 'origin $i',
          );
        }
      }
    });
  }
}
