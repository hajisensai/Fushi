import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_selection_toolbar_layout.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderSelectionActionBar, ReaderSelectionActionItem;

void main() {
  const Size screen = Size(400, 700);
  const Size bar = Size(384, 48);
  Offset place(
    Rect grips, {
    Size child = bar,
    EdgeInsets insets = EdgeInsets.zero,
  }) => ReaderSelectionToolbarLayout(
    protectedRect: grips,
    safeInsets: insets,
  ).getPositionForChild(screen, child);

  test('vertical upper grip has a full gap from the toolbar', () {
    // First glyph begins at 200, but its upper 32px grip reaches up to 176.
    const Rect grips = Rect.fromLTWH(180, 176, 32, 72);
    final Rect result = place(grips) & bar;
    expect(result.bottom, 168);
    expect(result.overlaps(grips), isFalse);
  });

  test('near top uses below both grips, respecting safe area', () {
    const Rect grips = Rect.fromLTWH(100, 28, 32, 100);
    final Rect result =
        place(grips, insets: const EdgeInsets.only(top: 24)) & bar;
    expect(result.top, 136);
    expect(result.overlaps(grips), isFalse);
  });

  test('near bottom uses above, and tall measured bars remain clear', () {
    const Rect grips = Rect.fromLTWH(100, 590, 32, 80);
    const Size tallBar = Size(384, 90);
    final Rect result = place(grips, child: tallBar) & tallBar;
    expect(result.bottom, 582);
    expect(result.top, greaterThanOrEqualTo(8));
  });

  test(
    'horizontal ranges use the same actual bounds, not writing-mode guesses',
    () {
      const Rect grips = Rect.fromLTWH(18, 350, 330, 32);
      final Rect result = place(grips) & bar;
      expect(result.bottom, 342);
      expect(result.overlaps(grips), isFalse);
    },
  );

  test('viewport-sized range chooses an in-bounds least-overlap fallback', () {
    final Rect result = place(const Rect.fromLTWH(0, -10, 400, 750)) & bar;
    expect(result.top, greaterThanOrEqualTo(8));
    expect(result.bottom, lessThanOrEqualTo(692));
  });

  for (final double scale in <double>[1, 1.5]) {
    testWidgets(
      'real toolbar shrink-wraps and leaves underlying grips interactive ($scale)',
      (WidgetTester tester) async {
        tester.view.resetPhysicalSize();
        tester.view.physicalSize = const Size(600, 1050);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        int gripCalls = 0;
        const Rect protected = Rect.fromLTWH(180, 210, 32, 80);
        final GlobalKey canvas = GlobalKey();
        final GlobalKey toolbar = GlobalKey();
        const Key grip = ValueKey<String>('grip');
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: Transform.scale(
                  scale: scale,
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 400,
                    height: 700,
                    child: Stack(
                      key: canvas,
                      children: <Widget>[
                        Positioned.fromRect(
                          rect: protected,
                          child: GestureDetector(
                            key: grip,
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              gripCalls++;
                            },
                            child: const SizedBox.expand(),
                          ),
                        ),
                        Positioned.fill(
                          child: CustomSingleChildLayout(
                            delegate: const ReaderSelectionToolbarLayout(
                              protectedRect: protected,
                            ),
                            child: ReaderSelectionActionBar(
                              key: toolbar,
                              items: <ReaderSelectionActionItem>[
                                ReaderSelectionActionItem(
                                  icon: Icons.copy,
                                  label: 'Copy',
                                  onPressed: () {},
                                ),
                                ReaderSelectionActionItem(
                                  icon: Icons.search,
                                  label: 'Look up',
                                  onPressed: () {},
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
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final RenderBox barBox =
            toolbar.currentContext!.findRenderObject()! as RenderBox;
        final RenderBox canvasBox =
            canvas.currentContext!.findRenderObject()! as RenderBox;
        final Offset local = canvasBox.globalToLocal(
          barBox.localToGlobal(Offset.zero),
        );
        expect(barBox.size.height, lessThan(120));
        expect(local.dy + barBox.size.height, closeTo(protected.top - 8, 0.01));
        await tester.tap(find.byKey(grip));
        expect(
          gripCalls,
          1,
          reason: 'full-screen layout must not become a modal hit target',
        );
      },
    );
  }
}
