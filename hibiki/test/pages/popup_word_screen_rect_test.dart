import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';

void main() {
  testWidgets(
      'popupWordScreenRect maps a popup-local word rect through the WebView '
      'render box, accounting for the header offset (BUG-129)', (tester) async {
    final GlobalKey webViewKey = GlobalKey();
    const double headerHeight = 48;
    const Rect positioned = Rect.fromLTWH(100, 50, 200, 300);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: <Widget>[
            Positioned(
              left: positioned.left,
              top: positioned.top,
              width: positioned.width,
              height: positioned.height,
              // Mirrors DictionaryPopupLayer._buildContent: header on top, the
              // WebView in the Expanded below it.
              child: Column(
                children: <Widget>[
                  const SizedBox(height: headerHeight),
                  Expanded(child: Container(key: webViewKey)),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    // Word selected at local (10,20) size 30x16 inside the WebView viewport.
    const Rect localRect = Rect.fromLTWH(10, 20, 30, 16);
    final Rect screen = popupWordScreenRect(
      webViewKey: webViewKey,
      localRect: localRect,
      fallback: Rect.zero,
    );

    // WebView top-left is BELOW the header: (100, 50 + 48) = (100, 98).
    expect(screen.left, 110);
    expect(screen.top, 118);
    expect(screen.width, 30);
    expect(screen.height, 16);

    // Regression guard: the old reconstruction shifted by the Positioned
    // top-left only (ignoring the ~48px header), giving top=70 — that sits
    // ABOVE the real word, so the child popup placed below it covered the word.
    final Rect naive = localRect.shift(positioned.topLeft);
    expect(naive.top, 70);
    expect(screen.top, greaterThan(naive.top),
        reason: 'header-corrected top must be lower than the naive shift');
  });

  testWidgets(
      'popupWordScreenRect returns the fallback when the render box is '
      'unavailable', (tester) async {
    final GlobalKey webViewKey = GlobalKey(); // never mounted
    const Rect fallback = Rect.fromLTWH(1, 2, 3, 4);
    final Rect r = popupWordScreenRect(
      webViewKey: webViewKey,
      localRect: const Rect.fromLTWH(10, 20, 30, 16),
      fallback: fallback,
    );
    expect(r, fallback);
  });

  test(
      'nested popup callbacks position children via popupWordScreenRect, not '
      'the naive Positioned-rect shift (BUG-129 source guard)', () {
    for (final String path in <String>[
      'lib/src/pages/base_source_page.dart',
      'lib/src/pages/implementations/dictionary_page_mixin.dart',
    ]) {
      final String src = File(path).readAsStringSync();
      expect(src, contains('popupWordScreenRect('),
          reason: '$path must map nested-lookup rects through the WebView box');
      expect(src, isNot(contains('localRect.shift(Offset(')),
          reason: '$path must not reconstruct the rect from the Positioned '
              'top-left (ignores the header/border/scale → covers the word)');
    }
  });
}
