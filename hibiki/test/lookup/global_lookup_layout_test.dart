// TODO-867 P3c-B2: computeFrameRect pure-function unit tests.
//
// Covers the cascade-layout semantics ported from hoshi LookupPopupLayout.kt.
// Every expected value is hand-computed from the Hoshi algorithm; each case
// annotates the matching Hoshi branch (width/height/centerX/centerY/showBelow/
// showOnRight/clampLikeIos).

import 'dart:io';

import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/lookup/global_lookup_layout.dart';

void main() {
  group('horizontal isVertical false', () {
    test('case1 ample below: top = selBottom + padding', () {
      // sel (100,200) 50x20, screen 800x600, maxW 300 maxH 400, pad 4 border 6.
      // spaceBelow = 376; spaceAbove = 196. width = min(788,300)=300.
      // height = min(max(196,376)-6,400)=370. showBelow 376>=370 true.
      // rawY=409 clamp[191,409]->409 top=224. rawX=250 left=100.
      final GlobalLookupFrameRect r = computeFrameRect(
        selectionRect: const Rect.fromLTWH(100, 200, 50, 20),
        screenW: 800,
        screenH: 600,
        maxWidth: 300,
        maxHeight: 400,
        isVertical: false,
      );
      expect(r.width, 300);
      expect(r.height, 370);
      expect(r.left, 100);
      expect(r.top, closeTo(224, 1e-9));
    });

    test('case2 not enough below ample above: flip to above', () {
      // sel (100,560) 50x20. spaceBelow=16 spaceAbove=556.
      // height=min(550,200)=200. showBelow 16>=200 false -> above.
      // top = selY - padding - height = 560-4-200 = 356.
      final GlobalLookupFrameRect r = computeFrameRect(
        selectionRect: const Rect.fromLTWH(100, 560, 50, 20),
        screenW: 800,
        screenH: 600,
        maxWidth: 300,
        maxHeight: 200,
        isVertical: false,
      );
      expect(r.height, 200);
      expect(r.top + r.height, closeTo(556, 1e-9));
      expect(r.top, closeTo(356, 1e-9));
    });

    test('case3a centerX past left edge clamps; left == border', () {
      // sel (0,300) 0x20. width=min(788,200)=200. rawX=100 lower=106 -> left=6.
      final GlobalLookupFrameRect r = computeFrameRect(
        selectionRect: const Rect.fromLTWH(0, 300, 0, 20),
        screenW: 800,
        screenH: 600,
        maxWidth: 200,
        maxHeight: 200,
        isVertical: false,
      );
      expect(r.width, 200);
      expect(r.left, closeTo(6, 1e-9));
    });

    test('case3b centerX past right edge clamps to screenW-width/2-border', () {
      // sel (800,300) 0x20. rawX=900 upper=694 -> left=594.
      final GlobalLookupFrameRect r = computeFrameRect(
        selectionRect: const Rect.fromLTWH(800, 300, 0, 20),
        screenW: 800,
        screenH: 600,
        maxWidth: 200,
        maxHeight: 200,
        isVertical: false,
      );
      expect(r.left + r.width, closeTo(794, 1e-9));
      expect(r.left, closeTo(594, 1e-9));
    });
  });

  group('vertical isVertical true', () {
    test('case4a ample right: popup to the right of selection', () {
      // sel (100,300) 50x40. spaceLeft=96 spaceRight=646.
      // width=min(640,200)=200. height=maxHeight=300.
      // showOnRight true. left = selRight + padding = 154.
      final GlobalLookupFrameRect r = computeFrameRect(
        selectionRect: const Rect.fromLTWH(100, 300, 50, 40),
        screenW: 800,
        screenH: 600,
        maxWidth: 200,
        maxHeight: 300,
        isVertical: true,
      );
      expect(r.height, 300);
      expect(r.left, closeTo(154, 1e-9));
      expect(
          r.top,
          closeTo(294,
              1e-9)); // centerY uses height/2: rawY=300+150=450 clamp[156,444]->444 top=294
    });

    test('case4b not enough right ample left: flip to left side', () {
      // sel (700,300) 50x40. spaceLeft=696 spaceRight=46. width=200.
      // showOnRight false -> left = selX - padding - width = 700-4-200 = 496.
      final GlobalLookupFrameRect r = computeFrameRect(
        selectionRect: const Rect.fromLTWH(700, 300, 50, 40),
        screenW: 800,
        screenH: 600,
        maxWidth: 200,
        maxHeight: 300,
        isVertical: true,
      );
      expect(r.left + r.width, closeTo(696, 1e-9));
      expect(r.left, closeTo(496, 1e-9));
    });
  });

  group('convergence and degenerate', () {
    test('case5 maxWidth > screen: width = screenW - 2*border', () {
      final GlobalLookupFrameRect r = computeFrameRect(
        selectionRect: const Rect.fromLTWH(400, 300, 10, 10),
        screenW: 800,
        screenH: 600,
        maxWidth: 9999,
        maxHeight: 400,
        isVertical: false,
      );
      expect(r.width, closeTo(788, 1e-9));
      expect(r.left, greaterThanOrEqualTo(0));
      expect(r.left + r.width, lessThanOrEqualTo(800 + 1e-6));
    });

    test('case6a selection at screen center: finite non-negative', () {
      final GlobalLookupFrameRect r = computeFrameRect(
        selectionRect: const Rect.fromLTWH(390, 290, 20, 20),
        screenW: 800,
        screenH: 600,
        maxWidth: 300,
        maxHeight: 300,
        isVertical: false,
      );
      _assertFinitePositive(r);
    });

    test('case6b zero-size selection at each corner does not crash', () {
      for (final Rect corner in const <Rect>[
        Rect.fromLTWH(0, 0, 0, 0),
        Rect.fromLTWH(800, 0, 0, 0),
        Rect.fromLTWH(0, 600, 0, 0),
        Rect.fromLTWH(800, 600, 0, 0),
      ]) {
        _assertFinitePositive(computeFrameRect(
          selectionRect: corner,
          screenW: 800,
          screenH: 600,
          maxWidth: 300,
          maxHeight: 300,
          isVertical: false,
        ));
        _assertFinitePositive(computeFrameRect(
          selectionRect: corner,
          screenW: 800,
          screenH: 600,
          maxWidth: 300,
          maxHeight: 300,
          isVertical: true,
        ));
      }
    });

    test('case6c tiny maxHeight does not yield negative height', () {
      final GlobalLookupFrameRect r = computeFrameRect(
        selectionRect: const Rect.fromLTWH(400, 300, 10, 10),
        screenW: 800,
        screenH: 600,
        maxWidth: 200,
        maxHeight: 1,
        isVertical: false,
      );
      expect(r.height, 1);
      _assertFinitePositive(r);
    });
  });

  // TODO-893 — regression lock for symptom 2 (nested child shoved the parent
  // card off the top). Root cause was NOT computeFrameRect: it was fed the
  // off-screen MEASUREMENT CANVAS height (~2x the card) as screenH instead of
  // the real monitor work area. With the tiny canvas, spaceBelow is almost
  // always < height -> showBelow false -> every child cascades UP, and the host
  // bbox-shift then moves the whole window (root included) up. Feeding the real
  // screen makes showBelow correctly decide the word's card fits below.
  group('TODO-893 screenH must be the real screen, not the measurement canvas',
      () {
    // A word near the top of the window (window origin = cursor). cardH = 480.
    const Rect sel = Rect.fromLTWH(120, 40, 60, 24);
    const double cardH = 480;
    const double cardW = 360;

    test('canvas-height screenH (the BUG) forces the child to flip UP', () {
      // boundsH = cardH * 2 = 960 (the old off-screen canvas). spaceBelow =
      // 960 - 40 - 24 - 4 = 892; height = min(max(spaceAbove,spaceBelow)-6,480)
      // = 480. showBelow 892>=480 true here actually — so to expose the real
      // regression we use the SMALLER canvas factor the bug produced when the
      // card sits low in the canvas. Model the reported case: selection near the
      // canvas BOTTOM (the cascade child measured low), canvas just ~1.2x card.
      const double canvasH = cardH * 1.2; // 576
      const Rect lowSel = Rect.fromLTWH(120, 360, 60, 24);
      final GlobalLookupFrameRect r = computeFrameRect(
        selectionRect: lowSel,
        screenW: cardW * 2,
        screenH: canvasH,
        maxWidth: cardW,
        maxHeight: cardH,
        isVertical: false,
      );
      // spaceBelow = 576-360-24-4 = 188; height=min(max(356,188)-6,480)=350.
      // showBelow 188>=350 false -> flips ABOVE: top = 360-4-350 = 6.
      expect(r.top + r.height, lessThan(lowSel.top),
          reason: 'with the canvas height the card is forced above the word');
    });

    test('real screen-work-area screenH keeps the child BELOW the word', () {
      // Same low selection, but the real 1080p work area (≈1040 CSS px tall).
      const Rect lowSel = Rect.fromLTWH(120, 360, 60, 24);
      final GlobalLookupFrameRect r = computeFrameRect(
        selectionRect: lowSel,
        screenW: 1920,
        screenH: 1040,
        maxWidth: cardW,
        maxHeight: cardH,
        isVertical: false,
      );
      // spaceBelow = 1040-360-24-4 = 652; height=min(max(356,652)-6,480)=480.
      // showBelow 652>=480 true -> stays BELOW: top = 360+24+4 = 388.
      expect(r.top, greaterThanOrEqualTo(lowSel.bottom),
          reason:
              'with the real screen the card stays below (no upward shove)');
    });

    test('a word high on the real screen also drops below', () {
      final GlobalLookupFrameRect r = computeFrameRect(
        selectionRect: sel,
        screenW: 1920,
        screenH: 1040,
        maxWidth: cardW,
        maxHeight: cardH,
        isVertical: false,
      );
      expect(r.top, greaterThanOrEqualTo(sel.bottom),
          reason: 'ample space below the high word -> card drops below');
    });
  });

  // TODO-893 — REAL wiring regression lock for symptom 2. The earlier
  // 'screenH must be the real screen' group only proves computeFrameRect's math;
  // it hand-feeds screenH and never touches WHICH dimension _renderStack passes.
  // pickScreenDim is the extracted selection (`_screenWork* > 0 ? work :
  // bounds`) that _renderStack now calls verbatim. Locking it here means: if
  // anyone rewires _renderStack to pass the measurement canvas (_layoutBounds*)
  // instead of the work area, the work-vs-bounds case below turns red.
  group('TODO-893 pickScreenDim wiring (work area beats measurement canvas)',
      () {
    test('work area valid -> returns work area (the FIX)', () {
      // Real 1080p work area vs the ~2x card measurement canvas: must pick work.
      expect(pickScreenDim(1040, 960, 480), 1040);
      expect(pickScreenDim(1920, 720, 360), 1920);
    });

    test('REGRESSION LOCK: work != bounds -> chooses work, never bounds', () {
      const double work = 1040;
      const double bounds = 576; // cardH * 1.2 — the tiny off-screen canvas
      final double picked = pickScreenDim(work, bounds, 480);
      expect(picked, work,
          reason: 'must feed the real screen, not the measurement canvas');
      expect(picked, isNot(bounds),
          reason: 'reverting the fix to _layoutBounds* must turn this red');
    });

    test('work area unreported (0, native query failed) -> measurement canvas',
        () {
      expect(pickScreenDim(0, 960, 480), 960);
    });

    test('neither work nor bounds -> single-card fallback', () {
      expect(pickScreenDim(0, 0, 480), 480);
    });

    test('negative/degenerate work treated as unreported', () {
      // workDim is CSS px; only > 0 counts as a real report.
      expect(pickScreenDim(-1, 960, 480), 960);
    });
  });

  // TODO-893 — source guard: _renderStack must keep feeding pickScreenDim with
  // the work area FIRST. A behavioural lock (above) catches a logic flip; this
  // catches someone bypassing the helper and inlining _layoutBounds* again.
  group('TODO-893 _renderStack source wiring guard', () {
    test('screenW/screenH are sourced via pickScreenDim(_screenWork*, ...)',
        () {
      final File controller =
          File('lib/src/lookup/global_lookup_controller.dart');
      final String body = controller.readAsStringSync();
      expect(
        body.contains('pickScreenDim(_screenWorkW, _layoutBoundsW, cardW)'),
        isTrue,
        reason: 'screenW must come from the work area first via pickScreenDim',
      );
      expect(
        body.contains('pickScreenDim(_screenWorkH, _layoutBoundsH, cardH)'),
        isTrue,
        reason: 'screenH must come from the work area first via pickScreenDim',
      );
    });
  });

  group('GlobalLookupFrameRect data class', () {
    test('centerX/centerY derived plus value equality', () {
      const GlobalLookupFrameRect a =
          GlobalLookupFrameRect(left: 10, top: 20, width: 100, height: 50);
      expect(a.centerX, 60);
      expect(a.centerY, 45);
      const GlobalLookupFrameRect b =
          GlobalLookupFrameRect(left: 10, top: 20, width: 100, height: 50);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });
}

void _assertFinitePositive(GlobalLookupFrameRect r) {
  expect(r.width.isFinite, isTrue, reason: 'width must be finite');
  expect(r.height.isFinite, isTrue, reason: 'height must be finite');
  expect(r.left.isFinite, isTrue, reason: 'left must be finite');
  expect(r.top.isFinite, isTrue, reason: 'top must be finite');
  expect(r.width, greaterThanOrEqualTo(0), reason: 'width non-negative');
  expect(r.height, greaterThanOrEqualTo(0), reason: 'height non-negative');
}
