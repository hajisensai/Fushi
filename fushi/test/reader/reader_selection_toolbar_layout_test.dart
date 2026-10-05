import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_selection_toolbar_layout.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderSelectionActionBar, ReaderSelectionActionItem;

void main() {
  const Size screen = Size(400, 700);
  const Size bar = Size(384, 48);
  Offset place(
    Rect selection, {
    List<Rect> grips = const <Rect>[],
    Size child = bar,
    EdgeInsets insets = EdgeInsets.zero,
  }) => ReaderSelectionToolbarLayout(
    selectionRect: selection,
    gripBoxes: grips,
    safeInsets: insets,
  ).getPositionForChild(screen, child);

  test('vertical upper grip has a full gap from the toolbar', () {
    // First glyph begins at 200, but its upper 32px grip reaches up to 176.
    const Rect selection = Rect.fromLTWH(180, 200, 32, 24);
    const List<Rect> grips = <Rect>[
      Rect.fromLTWH(180, 176, 32, 32),
      Rect.fromLTWH(180, 216, 32, 32),
    ];
    final Rect result = place(selection, grips: grips) & bar;
    expect(result.bottom, 168);
    expect(result.overlaps(selection), isFalse);
    for (final Rect grip in grips) {
      expect(result.overlaps(grip), isFalse);
    }
  });

  test('near top uses below both grips, respecting safe area', () {
    const Rect selection = Rect.fromLTWH(100, 52, 32, 24);
    const List<Rect> grips = <Rect>[
      Rect.fromLTWH(100, 28, 32, 32),
      Rect.fromLTWH(100, 96, 32, 32),
    ];
    final Rect result =
        place(selection, grips: grips, insets: const EdgeInsets.only(top: 24)) &
        bar;
    expect(result.top, 136);
    for (final Rect grip in grips) {
      expect(result.overlaps(grip), isFalse);
    }
  });

  test('near bottom uses above, and tall measured bars remain clear', () {
    const Rect selection = Rect.fromLTWH(100, 660, 330, 24);
    const List<Rect> grips = <Rect>[Rect.fromLTWH(100, 590, 32, 80)];
    const Size tallBar = Size(384, 90);
    final Rect result =
        place(selection, grips: grips, child: tallBar) & tallBar;
    expect(result.bottom, 582);
    expect(result.top, greaterThanOrEqualTo(8));
    expect(result.overlaps(grips.single), isFalse);
  });

  test(
    'horizontal ranges anchor above the selected text, not above the grips',
    () {
      // 横排时两球挂在字**下方**（y 350..382），正文在 320..342。面板要贴正文上方；
      // 若拿手柄的并集当锚点，算出来的位置会落在正文里。
      const Rect selection = Rect.fromLTWH(18, 320, 330, 22);
      const List<Rect> grips = <Rect>[Rect.fromLTWH(18, 350, 330, 32)];
      final Rect result = place(selection, grips: grips) & bar;
      expect(result.bottom, 312);
      expect(result.overlaps(selection), isFalse);
      expect(result.overlaps(grips.single), isFalse);
    },
  );

  test('viewport-sized range chooses an in-bounds least-overlap fallback', () {
    const Rect huge = Rect.fromLTWH(0, -10, 400, 750);
    final Rect result = place(huge, grips: const <Rect>[huge]) & bar;
    expect(result.top, greaterThanOrEqualTo(8));
    expect(result.bottom, lessThanOrEqualTo(692));
  });

  // 用户报「面板往下了」的复现：竖排页顶选区 + 两球离得很远。旧实现只看两球的并集
  // bbox（0..552），"上方放不下"时把面板翻到 bbox 底端（560）= 选区尾部下方。
  // 按单个球避让后，y 64..112 与上球（≤32）、下球（≥512）都不相交，面板留在选区头部。
  test('vertical page-top range keeps the toolbar at the selection head', () {
    const Size wide = Size(800, 640);
    const Size wideBar = Size(784, 48);
    const Rect selection = Rect.fromLTWH(768, 0, 27, 24);
    const List<Rect> grips = <Rect>[
      Rect.fromLTWH(733.5, 0, 32, 32),
      Rect.fromLTWH(733.5, 520, 32, 32),
    ];
    final Offset result = const ReaderSelectionToolbarLayout(
      selectionRect: selection,
      gripBoxes: grips,
    ).getPositionForChild(wide, wideBar);
    expect(result.dy, 64, reason: '面板必须留在选区头部（正文底 + 手柄预留），不能翻到手柄并集底端');
    final Rect placed = result & wideBar;
    for (final Rect grip in grips) {
      expect(placed.overlaps(grip), isFalse);
    }
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
        const Rect gripRect = Rect.fromLTWH(180, 210, 32, 80);
        const Rect selection = Rect.fromLTWH(180, 234, 32, 48);
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
                          rect: gripRect,
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
                              selectionRect: selection,
                              gripBoxes: <Rect>[gripRect],
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
        expect(local.dy + barBox.size.height, closeTo(gripRect.top - 8, 0.01));
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
