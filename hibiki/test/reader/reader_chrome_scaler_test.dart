import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_chrome_scaler.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';

void main() {
  group('ReaderChromeScaler.scaledHeight', () {
    test('scale 1.0 returns base height unchanged', () {
      expect(ReaderChromeScaler.scaledHeight(56, 1.0), 56);
    });

    test('scale 1.5 multiplies base height', () {
      expect(ReaderChromeScaler.scaledHeight(56, 1.5), closeTo(84, 1e-9));
    });

    test('out-of-range scale is clamped via HibikiAppUiScale.normalize', () {
      // maxScale = 3.0 → 56*3 = 168
      expect(ReaderChromeScaler.scaledHeight(56, 99), closeTo(168, 1e-9));
      // minScale = 0.3 → 56*0.3 = 16.8
      expect(ReaderChromeScaler.scaledHeight(56, 0.01), closeTo(16.8, 1e-9));
      // NaN → defaultScale 1.0
      expect(ReaderChromeScaler.scaledHeight(56, double.nan), 56);
    });
  });

  group('ReaderChromeScaler widget', () {
    testWidgets('scale 1.0 passes child through (no extra box height)',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 300,
              child: ReaderChromeScaler(
                scale: 1.0,
                baseHeight: 56,
                child: const SizedBox(height: 56, key: ValueKey('content')),
              ),
            ),
          ),
        ),
      );
      final Size size = tester.getSize(find.byKey(const ValueKey('content')));
      expect(size.height, 56);
      // Passthrough means no scaling wrapper: scale 1.0 must not wrap the
      // child in a FittedBox.
      expect(find.byType(FittedBox), findsNothing);
    });

    testWidgets('scale 1.5 renders box at base*scale height, full width',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 300,
              child: ReaderChromeScaler(
                scale: 1.5,
                baseHeight: 56,
                child: const SizedBox.expand(key: ValueKey('content')),
              ),
            ),
          ),
        ),
      );
      final Size outer = tester.getSize(find.byType(ReaderChromeScaler));
      expect(outer.height, closeTo(84, 0.5));
      expect(outer.width, closeTo(300, 0.5));
    });
  });

  group('ReaderChromeScaler defaultScale contract', () {
    test('defaultScale constant is 1.0 (passthrough relies on it)', () {
      expect(HibikiAppUiScale.defaultScale, 1.0);
    });
  });
}
