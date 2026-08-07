import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards BUG-042: the reader quick-settings 「布局与显示」 sub-page (and any other
/// embedded `buildDetailContent(shrinkWrap: true)` caller) could not be scrolled
/// by touch on Android. The sub-page content is a `ListView.builder(shrinkWrap)`
/// nested inside the sheet's outer `SingleChildScrollView`. Shrink-wrapped, the
/// inner list has zero scroll extent, yet it still installs its own vertical
/// drag recognizer — so a drag that lands ON its rows wins the gesture arena,
/// moves nothing, and never bubbles to the parent scroller. The fix gives the
/// embedded list `NeverScrollableScrollPhysics` so every drag reaches the parent.
///
/// Two layers:
///   1. Behavioral — the gesture mechanism itself (red without the physics).
///   2. Source-scan — the renderers actually apply the physics (binds the fix).
void main() {
  group('BUG-042 behavioral: embedded shrinkWrap list must not eat drags', () {
    Widget harness({required ScrollPhysics? innerPhysics}) {
      const int rowCount = 14;
      return MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const SizedBox(
                            height: 48,
                            child: Center(child: Text('header')),
                          ),
                          ListView.builder(
                            shrinkWrap: true,
                            physics: innerPhysics,
                            itemCount: rowCount,
                            itemBuilder: (_, int index) => SizedBox(
                              height: 64,
                              child: Center(child: Text('row-$index')),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    Future<double> dragOverRow(
      WidgetTester tester, {
      required ScrollPhysics? innerPhysics,
    }) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(harness(innerPhysics: innerPhysics));
      await tester.pumpAndSettle();
      // Drag starting ON a row inside the inner shrinkWrap ListView.
      await tester.drag(find.text('row-2'), const Offset(0, -300));
      await tester.pumpAndSettle();

      // Offset of the OUTER SingleChildScrollView (the parent scroller).
      return Scrollable.of(
        tester.element(find.text('header')),
      ).position.pixels;
    }

    testWidgets('default physics → inner list eats the drag (the bug)',
        (WidgetTester tester) async {
      // Demonstrates the failure mode: with the inner list owning a live
      // gesture recognizer, a drag over its rows scrolls nothing.
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final ScrollController outer = ScrollController();
      addTearDown(outer.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 480),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Flexible(
                      child: SingleChildScrollView(
                        controller: outer,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            const SizedBox(
                              height: 48,
                              child: Center(child: Text('header')),
                            ),
                            ListView.builder(
                              shrinkWrap: true,
                              itemCount: 14,
                              itemBuilder: (_, int index) => SizedBox(
                                height: 64,
                                child: Center(child: Text('row-$index')),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(outer.position.maxScrollExtent, greaterThan(0));
      await tester.drag(find.text('row-2'), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(outer.offset, 0,
          reason: 'reproduces BUG-042: drag over rows scrolls nothing');
    });

    testWidgets('NeverScrollableScrollPhysics → drag scrolls the parent (fix)',
        (WidgetTester tester) async {
      final double offset = await dragOverRow(
        tester,
        innerPhysics: const NeverScrollableScrollPhysics(),
      );
      expect(offset, greaterThan(0),
          reason: 'the fix lets drags over rows reach the parent scroller');
    });
  });

  group('BUG-042 source-scan: renderers disable embedded inner scroll', () {
    String shrinkWrapBranch(String relativePath, String endMarker) {
      final File file = File(relativePath);
      expect(file.existsSync(), isTrue, reason: 'missing $relativePath');
      final String src = file.readAsStringSync();
      final int start = src.indexOf('if (shrinkWrap) {');
      expect(start, greaterThanOrEqualTo(0),
          reason: 'no shrinkWrap branch in $relativePath');
      final int end = src.indexOf(endMarker, start);
      expect(end, greaterThan(start),
          reason: 'no end marker "$endMarker" after shrinkWrap branch');
      return src.substring(start, end);
    }

    test(
        'material renderer: NeverScrollableScrollPhysics gated on no controller',
        () {
      final String branch = shrinkWrapBranch(
        'lib/src/settings/material_settings_renderer.dart',
        'Own-scrolling detail page',
      );
      expect(branch.contains('NeverScrollableScrollPhysics'), isTrue,
          reason:
              'embedded shrinkWrap list must disable its own scroll (BUG-042)');
      expect(branch.contains('scrollController == null'), isTrue,
          reason:
              'self-scrolling caller (passes a controller) must keep real physics');
    });

    test('cupertino renderer: shrinkWrap branch is NeverScrollable', () {
      final String branch = shrinkWrapBranch(
        'lib/src/settings/cupertino_settings_renderer.dart',
        '自滚动',
      );
      expect(branch.contains('NeverScrollableScrollPhysics'), isTrue,
          reason: 'cupertino embedded shrinkWrap list must not own the scroll');
    });
  });
}
