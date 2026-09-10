import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';

void main() {
  for (final double scale in <double>[1, 1.5]) {
    testWidgets(
      'reader nested anchors stay local with offset and scale $scale',
      (WidgetTester tester) async {
        final GlobalKey space = GlobalKey();
        final GlobalKey webView = GlobalKey();
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 20, top: 32),
                child: Transform.scale(
                  scale: scale,
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 500,
                    height: 400,
                    child: Stack(
                      key: space,
                      children: <Widget>[
                        Positioned(
                          left: 50,
                          top: 40,
                          width: 200,
                          height: 250,
                          child: Column(
                            children: <Widget>[
                              const SizedBox(height: 36),
                              Expanded(child: SizedBox.expand(key: webView)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        const Rect localWord = Rect.fromLTWH(10, 80, 60, 36);
        const Rect expected = Rect.fromLTWH(60, 156, 60, 36);
        final Rect initial = popupWordScreenRect(
          webViewKey: webView,
          localRect: localWord,
          fallback: Rect.zero,
          coordinateSpaceKey: space,
        );
        expect(initial, rectMoreOrLessEquals(expected));
        final Rect screenWord = popupWordScreenRect(
          webViewKey: webView,
          localRect: localWord,
          fallback: Rect.zero,
        );
        expect(screenWord, isNot(expected));
        // A large child is placed above the word. Feeding screen coordinates to
        // this local Stack pushes its bottom across the word (the reported bug).
        final Rect oldPopup = calcPopupPosition(
          selectionRect: screenWord,
          screen: const Size(500, 400),
          maxHeight: 350,
        );
        expect(oldPopup.overlaps(expected), isTrue);
        final Rect popup = calcPopupPosition(
          selectionRect: initial,
          screen: const Size(500, 400),
          maxHeight: 350,
        );
        expect(popup.overlaps(expected), isFalse);

        final DictionaryPopupController controller = DictionaryPopupController(
          lowMemory: false,
        );
        addTearDown(controller.dispose);
        controller.beginTop(
          term: '親',
          rect: Rect.zero,
          reuseWarmSlot: false,
          replaceStack: false,
          visible: true,
        );
        controller.pushChild(
          term: '十分',
          rect: const Rect.fromLTWH(60, 156, 20, 18),
          parentIndex: 0,
          visible: true,
        );
        expect(
          reanchorNestedPopupToWord(
            controller: controller,
            parentWebViewKey: webView,
            parentIndex: 0,
            expectedTerm: '十分',
            wordLocalRect: localWord,
            fallback: Rect.zero,
            coordinateSpaceKey: space,
          ),
          isTrue,
        );
        expect(controller.entries[1].selectionRect, rectMoreOrLessEquals(expected));
        expect(
          popupWordScreenRect(
            webViewKey: webView,
            localRect: localWord,
            fallback: expected,
            coordinateSpaceKey: GlobalKey(),
          ),
          expected,
        );
      },
    );
  }

  test(
    'reader text and link callbacks convert initial and whole-word anchors',
    () {
      final String source = File(
        'lib/src/pages/base_source_page.dart',
      ).readAsStringSync();
      expect(source, contains('key: _popupCoordinateSpaceKey'));
      expect(
        'coordinateSpaceKey: _popupCoordinateSpaceKey'.allMatches(source),
        hasLength(4),
      );
    },
  );
}
