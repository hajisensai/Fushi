import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

// Unit guards for the pure width estimator that decides whether a settings
// segmented strip is laid out full-width (it fits) or falls back to a
// horizontal scroll view (it does not). The estimate only needs to be
// conservative — never an under-estimate that would force a too-tight
// full-width layout and re-introduce BUG-008 clipping.
void main() {
  group('estimateSegmentedStripWidth', () {
    test('empty segment list estimates zero width', () {
      expect(
        estimateSegmentedStripWidth(
          segmentLabels: const <String?>[],
          fontSize: 14,
          textScaleFactor: 1,
        ),
        0.0,
      );
    });

    test('more segments → wider estimate (monotonic in segment count)', () {
      final double two = estimateSegmentedStripWidth(
        segmentLabels: const <String?>['On', 'Off'],
        fontSize: 14,
        textScaleFactor: 1,
      );
      final double four = estimateSegmentedStripWidth(
        segmentLabels: const <String?>['On', 'Off', 'Auto', 'None'],
        fontSize: 14,
        textScaleFactor: 1,
      );
      expect(four, greaterThan(two));
    });

    test('longer labels → wider estimate', () {
      final double short = estimateSegmentedStripWidth(
        segmentLabels: const <String?>['On', 'Off'],
        fontSize: 14,
        textScaleFactor: 1,
      );
      final double long = estimateSegmentedStripWidth(
        segmentLabels: const <String?>[
          'Material Design 3',
          'iOS (Cupertino)',
        ],
        fontSize: 14,
        textScaleFactor: 1,
      );
      expect(long, greaterThan(short));
    });

    test('higher text scale → wider estimate', () {
      final double base = estimateSegmentedStripWidth(
        segmentLabels: const <String?>['Auto', 'Vertical', 'Spread'],
        fontSize: 14,
        textScaleFactor: 1,
      );
      final double scaled = estimateSegmentedStripWidth(
        segmentLabels: const <String?>['Auto', 'Vertical', 'Spread'],
        fontSize: 14,
        textScaleFactor: 2,
      );
      expect(scaled, greaterThan(base));
    });

    test('icon-only segments (null labels) still reserve width', () {
      final double iconOnly = estimateSegmentedStripWidth(
        segmentLabels: const <String?>[null, null, null],
        fontSize: 14,
        textScaleFactor: 1,
      );
      expect(iconOnly, greaterThan(0.0));
    });

    test('short 3-segment strip is estimated to fit a roomy pane', () {
      // 设计系统 / 跨页模式-style short strip: comfortably under a wide pane,
      // so the host stretches it full-width.
      final double w = estimateSegmentedStripWidth(
        segmentLabels: const <String?>['Off', 'On', 'Auto'],
        fontSize: 14,
        textScaleFactor: 1,
      );
      expect(w, lessThan(600));
    });

    test('many long segments exceed a narrow pane (falls back to scroll)', () {
      final double w = estimateSegmentedStripWidth(
        segmentLabels: const <String?>[
          'Automatic detect',
          'Vertical writing',
          'Horizontal writing',
          'Two-page spread',
          'Continuous scroll',
        ],
        fontSize: 14,
        textScaleFactor: 1,
      );
      expect(w, greaterThan(300));
    });
  });
}
