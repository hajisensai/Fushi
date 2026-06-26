import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/src/reader/reader_top_progress.dart';

/// TODO-728 (3) guards:
///  (a) readerTopProgressAlignment / readerTopProgressTextAlign pure mapping of
///      left/center/right to Alignment / TextAlign (with normalization fallback).
///  (b) Tapping the progress text rect toggles chrome; tapping OUTSIDE the text
///      (in the empty part of the same Positioned strip) does NOT toggle and
///      passes through to the WebView (no text-selection swallow). This is the
///      core penetration guard, mirroring _buildTopProgressBar's structure:
///      Positioned -> Align -> opaque GestureDetector wrapping ONLY the Text.
void main() {
  group('pure position helpers', () {
    test('alignment maps left/center/right', () {
      expect(readerTopProgressAlignment('left'), Alignment.centerLeft);
      expect(readerTopProgressAlignment('center'), Alignment.center);
      expect(readerTopProgressAlignment('right'), Alignment.centerRight);
      expect(readerTopProgressAlignment('bogus'), Alignment.center);
    });

    test('text align maps left/center/right', () {
      expect(readerTopProgressTextAlign('left'), TextAlign.left);
      expect(readerTopProgressTextAlign('center'), TextAlign.center);
      expect(readerTopProgressTextAlign('right'), TextAlign.right);
      expect(readerTopProgressTextAlign('bogus'), TextAlign.center);
    });

    test('ReaderSettings.normalizeTopProgressPosition degrades unknown', () {
      expect(ReaderSettings.normalizeTopProgressPosition('left'), 'left');
      expect(ReaderSettings.normalizeTopProgressPosition('center'), 'center');
      expect(ReaderSettings.normalizeTopProgressPosition('right'), 'right');
      expect(ReaderSettings.normalizeTopProgressPosition(''), 'center');
      expect(ReaderSettings.normalizeTopProgressPosition('top'), 'center');
    });
  });

  group('tap-to-toggle penetration guard', () {
    testWidgets(
        'tap on the text toggles; tap in the empty strip passes through',
        (tester) async {
      int toggles = 0;
      int passthrough = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => passthrough++,
                  ),
                ),
                Positioned(
                  top: 8,
                  left: 16,
                  right: 16,
                  child: Align(
                    // Left-aligned: text sits at the strip's left edge, leaving
                    // a wide empty area on the right of the strip.
                    alignment: readerTopProgressAlignment('left'),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => toggles++,
                      child: const Text(
                        '0 / 100  0.00%',
                        key: ValueKey<String>('hoshi_progress'),
                        textAlign: TextAlign.left,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      // 1) Tap the text -> toggles, no passthrough.
      await tester.tap(find.byKey(const ValueKey<String>('hoshi_progress')));
      await tester.pump();
      expect(toggles, 1);
      expect(passthrough, 0);

      // 2) Tap far to the RIGHT inside the Positioned strip but OUTSIDE the
      // (left-aligned) text box -> must fall through to the WebView stand-in,
      // NOT toggle.
      final Rect textRect =
          tester.getRect(find.byKey(const ValueKey<String>('hoshi_progress')));
      final Size size = tester.getSize(find.byType(MaterialApp));
      final Offset emptyStripPoint =
          Offset(size.width - 24, textRect.center.dy);
      expect(textRect.contains(emptyStripPoint), isFalse);
      await tester.tapAt(emptyStripPoint);
      await tester.pump();
      expect(toggles, 1, reason: 'empty strip area must not toggle chrome');
      expect(passthrough, 1,
          reason: 'tap outside the text box must pass through to the WebView');
    });
  });
}
