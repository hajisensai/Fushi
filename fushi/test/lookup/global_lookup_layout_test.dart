// TODO-867 P3c-B2: computeFrameRect pure-function unit tests.
//
// Covers the cascade-layout semantics ported from hoshi LookupPopupLayout.kt.
// Every expected value is hand-computed from the Hoshi algorithm; each case
// annotates the matching Hoshi branch (width/height/centerX/centerY/showBelow/
// showOnRight/clampLikeIos).

import 'dart:io';

import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/global_lookup_layout.dart';

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

  // TODO-893 v2 (symptom 3) — coordinate-domain regression lock. The child
  // anchor reaches the render builder in WINDOW-LOCAL CSS px (re-anchored to the
  // shell origin = the cursor), but screenW/H are the WORK-AREA dimensions
  // (absolute display domain). When the cursor is near the screen BOTTOM edge,
  // the window-local selY is small, so feeding it straight in over-estimates
  // spaceBelow -> showBelow wrongly true -> the child is placed below the bottom
  // edge and the host's bbox shift shoves the parent card off the top. The fix
  // adds the window-origin work-area offset to lift the anchor into the SAME
  // absolute domain BEFORE the cascade math (render.dart _frameRectMap), then
  // shifts the result back. These cases prove the offset flips the decision.
  group('TODO-893 v2 coordinate-domain (near screen bottom edge)', () {
    const double screenW = 1920;
    const double screenH = 1040; // work-area height (CSS px)
    const double cardW = 360;
    const double cardH = 480;
    // The window origin sits 980 px down the work area (cursor near the bottom).
    const double cursorWorkY = 980;
    // Child word at window-local (60, 20): on screen it is at absolute y ~ 1000.
    const Rect windowLocalAnchor = Rect.fromLTWH(60, 20, 30, 18);

    test('WRONG domain (raw window-local selY) mis-decides showBelow=true', () {
      // Bug reproduction: feed the window-local anchor straight in. selY=20 is
      // tiny, so spaceBelow = 1040-20-18-4 = 998 >= height -> showBelow true ->
      // the card is placed BELOW (top > anchor bottom), which on the real screen
      // is off the bottom edge.
      final GlobalLookupFrameRect wrong = computeFrameRect(
        selectionRect: windowLocalAnchor,
        screenW: screenW,
        screenH: screenH,
        maxWidth: cardW,
        maxHeight: cardH,
        isVertical: false,
      );
      expect(wrong.top, greaterThan(windowLocalAnchor.bottom),
          reason: 'raw window-local domain wrongly places the card below');
    });

    test('FIXED domain (anchor lifted by cursorWorkY) flips to ABOVE', () {
      // The fix lifts the anchor into the absolute domain: selY becomes
      // 20 + 980 = 1000. spaceBelow = 1040-1000-18-4 = 18 < height -> showBelow
      // false -> the card flips ABOVE the word. Subtracting the offset back
      // brings the result into window-local for the shell.
      final Rect lifted = windowLocalAnchor.shift(const Offset(0, cursorWorkY));
      final GlobalLookupFrameRect r = computeFrameRect(
        selectionRect: lifted,
        screenW: screenW,
        screenH: screenH,
        maxWidth: cardW,
        maxHeight: cardH,
        isVertical: false,
      );
      // Result is in absolute domain; the card is ABOVE the lifted word.
      expect(r.top + r.height, lessThanOrEqualTo(lifted.top),
          reason: 'lifted domain correctly flips the card above near the edge');
      // Shifting back to window-local keeps the card above the original anchor.
      final double windowLocalTop = r.top - cursorWorkY;
      expect(
          windowLocalTop + r.height, lessThanOrEqualTo(windowLocalAnchor.top),
          reason: 'after shifting back, the card stays above the word locally');
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

  group('TODO-1231 (BUG-583) ratchetOverlayOrigin (outward-only origin)', () {
    test('first box with no prior constraint takes the box origin as-is', () {
      final RatchetedOverlayBox r = ratchetOverlayOrigin(
        left: 0,
        top: 0,
        width: 200,
        height: 160,
        prevLeft: double.infinity,
        prevTop: double.infinity,
      );
      expect(r.left, 0);
      expect(r.top, 0);
      expect(r.width, 200);
      expect(r.height, 160);
    });

    test('down-right cascade keeps origin (0,0): pure no-op ratchet', () {
      // A child cascading down-right leaves minLeft=minTop=0; growing the box
      // only extends maxRight/maxBottom, so the origin never moves and width/
      // height equal the raw box — identical to the pre-fix behaviour.
      final RatchetedOverlayBox r = ratchetOverlayOrigin(
        left: 0,
        top: 0,
        width: 340,
        height: 500,
        prevLeft: 0,
        prevTop: 0,
      );
      expect(r.left, 0);
      expect(r.top, 0);
      expect(r.width, 340);
      expect(r.height, 500);
    });

    test('up/left cascade OPEN moves the origin outward (adopts negative)', () {
      // Nested open: the child extends left/up of the cursor, so the tight bbox
      // origin goes negative. With no tighter prior constraint the ratchet adopts
      // it (the window grows/moves outward — the open case, unchanged behaviour).
      final RatchetedOverlayBox r = ratchetOverlayOrigin(
        left: -60,
        top: -40,
        width: 400, // maxRight = 340
        height: 520, // maxBottom = 480
        prevLeft: 0,
        prevTop: 0,
      );
      expect(r.left, -60,
          reason: 'origin moved outward to the child min-corner');
      expect(r.top, -40);
      expect(r.width, 400, reason: 'maxRight(340) - originLeft(-60)');
      expect(r.height, 520, reason: 'maxBottom(480) - originTop(-40)');
    });

    test(
        'up/left cascade CLOSE HOLDS the outward origin, only far edges shrink',
        () {
      // The core fix: after an up/left child closes, the tight bbox origin snaps
      // back toward (0,0) but the ratchet HOLDS the outermost (-60,-40) seen this
      // session. So dx/dy (window top-left) do NOT change — only width/height
      // shrink to the surviving root's extent — and the pinned root card never
      // lurches ("消失第二个弹窗时闪" eliminated).
      final RatchetedOverlayBox r = ratchetOverlayOrigin(
        left: 0, // tight origin back at the root
        top: 0,
        width: 340, // root-only extent: maxRight = 340
        height: 500, // maxBottom = 500
        prevLeft: -60, // held from the earlier open
        prevTop: -40,
      );
      expect(r.left, -60,
          reason: 'origin HELD at the outward min-corner (no move)');
      expect(r.top, -40);
      expect(r.width, 400, reason: 'maxRight(340) - heldOrigin(-60) = 400');
      expect(r.height, 540, reason: 'maxBottom(500) - heldOrigin(-40) = 540');
    });

    test('a partial cascade only ratchets the axis that moved outward', () {
      // A child that extends left but stays below the cursor moves only the X
      // origin; the Y origin holds at its prior (0) value.
      final RatchetedOverlayBox r = ratchetOverlayOrigin(
        left: -30,
        top: 20,
        width: 300, // maxRight = 270
        height: 400, // maxBottom = 420
        prevLeft: 0,
        prevTop: 0,
      );
      expect(r.left, -30, reason: 'X origin moved outward');
      expect(r.top, 0, reason: 'Y origin held (min(20,0)=0)');
      expect(r.width, 300, reason: 'maxRight(270) - (-30)');
      expect(r.height, 420, reason: 'maxBottom(420) - 0');
    });
  });

  group('TODO-1345/TODO-1231 (BUG-583/BUG-670) computeCascadeHeadroomSeed', () {
    test('cursor deep inside reserves ALL the way to the work-area edge', () {
      // TODO-1231 (BUG-670): the seed now reserves the FULL cursor-to-edge distance
      // (not just one card) so a DEEP cascade (grandchild / a card taller than one
      // card) can never reach past the reserved origin. Cursor 1700/900 into a
      // 1920x1040 work area -> reserve -1700 left / -900 top (to the edge).
      final ({double left, double top}) s = computeCascadeHeadroomSeed(
        cursorWorkX: 1700,
        cursorWorkY: 900,
        screenWorkW: 1920,
        screenWorkH: 1040,
      );
      expect(s.left, -1700,
          reason: 'left headroom reserved to the work-area edge');
      expect(s.top, -900,
          reason: 'top headroom reserved to the work-area edge');
    });

    test(
        'cursor against the LEFT/TOP edge reserves NOTHING (no up/left cascade)',
        () {
      // At the top-left edge the cursor-to-edge distance is 0, so the seed
      // degenerates to (0,0): an up/left cascade never happens there (children go
      // down/right) and reserving headroom would push the window off-screen.
      final ({double left, double top}) s = computeCascadeHeadroomSeed(
        cursorWorkX: 0,
        cursorWorkY: 0,
        screenWorkW: 1920,
        screenWorkH: 1040,
      );
      expect(s.left, 0, reason: 'no left headroom at the left edge');
      expect(s.top, 0, reason: 'no top headroom at the top edge');
    });

    test('headroom is exactly the cursor-to-edge distance (reserve to edge)',
        () {
      // Cursor 120 px from the left edge, ample top room: left reserves exactly the
      // 120px cursor-to-edge distance (window origin lands ON the work-area edge =
      // the C++ clamp target, so no clamp mismatch); top reserves its full 900px.
      final ({double left, double top}) s = computeCascadeHeadroomSeed(
        cursorWorkX: 120,
        cursorWorkY: 900,
        screenWorkW: 1920,
        screenWorkH: 1040,
      );
      expect(s.left, -120, reason: 'left reserved to the 120px edge distance');
      expect(s.top, -900, reason: 'top reserved to its full edge distance');
    });

    test('headroom never exceeds the work-area dimension (dirty-data guard)',
        () {
      // A cursorWork wider than the work area (only reachable via inconsistent
      // native data) is clamped to the work-area dimension so the reserved origin
      // still lands on-screen. Normal data has cursorWork <= screenWork already.
      final ({double left, double top}) s = computeCascadeHeadroomSeed(
        cursorWorkX: 5000,
        cursorWorkY: 900,
        screenWorkW: 500,
        screenWorkH: 1040,
      );
      expect(s.left, -500, reason: 'clamped to the work-area width (500)');
    });

    test('no work area reported (0) degenerates to no reservation (pre-fix)',
        () {
      final ({double left, double top}) s = computeCascadeHeadroomSeed(
        cursorWorkX: 0,
        cursorWorkY: 0,
        screenWorkW: 0,
        screenWorkH: 0,
      );
      expect(s.left, 0, reason: 'no work area -> no floor (pre-fix geometry)');
      expect(s.top, 0);
    });

    test('the seed is never positive (would clip the root inward)', () {
      // Whatever the inputs, the floor only ever reserves OUTWARD (<= 0). A
      // positive seed would pull the origin inward and clip the pinned root card.
      for (final double cx in const <double>[0, 50, 200, 1000, 5000]) {
        for (final double cy in const <double>[0, 50, 200, 1000, 5000]) {
          final ({double left, double top}) s = computeCascadeHeadroomSeed(
            cursorWorkX: cx,
            cursorWorkY: cy,
            screenWorkW: 1920,
            screenWorkH: 1040,
          );
          expect(s.left, lessThanOrEqualTo(0),
              reason: 'left seed never positive');
          expect(s.top, lessThanOrEqualTo(0),
              reason: 'top seed never positive');
        }
      }
    });
  });

  // TODO-1231 (BUG-670) -- the CORE root-cause guard: the reserved cascade floor
  // must be a lower bound on the window-local origin of EVERY cascade card that
  // computeFrameRect can ever produce, at ANY depth. Because the host freezes the
  // union-bbox origin at the floor (measureAndReport pulls minLeft out to the
  // floor), a card whose window-local left/top is >= the floor NEVER moves the
  // origin, so the pinned parent card has ZERO displacement when it appears. This
  // sweeps every anchor position across the work area (a child/grandchild can be
  // anchored anywhere inside an on-screen parent card) and asserts the invariant;
  // the OLD one-card floor FAILED it whenever cursorWork > card (exactly the
  // deep-cascade lurch users kept seeing).
  group('TODO-1231 (BUG-670) floor covers every cascade card (geometric guard)',
      () {
    const double screenW = 1920;
    const double screenH = 1040;
    const double cardW = 360;
    const double cardH = 480;

    void assertFloorCoversAllAnchors({
      required double cursorWorkX,
      required double cursorWorkY,
      required bool isVertical,
    }) {
      final ({double left, double top}) floor = computeCascadeHeadroomSeed(
        cursorWorkX: cursorWorkX,
        cursorWorkY: cursorWorkY,
        screenWorkW: screenW,
        screenWorkH: screenH,
      );
      // The window is positioned at the cursor; anchors + computeFrameRect work in
      // the work-area-absolute domain, then map back to window-local by subtracting
      // the cursor work-area offset (mirrors _frameRectMap / selectionScreenOffset
      // in global_lookup_render.dart).
      for (double ax = 0; ax <= screenW; ax += 160) {
        for (double ay = 0; ay <= screenH; ay += 130) {
          final GlobalLookupFrameRect r = computeFrameRect(
            selectionRect: Rect.fromLTWH(ax, ay, 40, 18),
            screenW: screenW,
            screenH: screenH,
            maxWidth: cardW,
            maxHeight: cardH,
            isVertical: isVertical,
          );
          final double windowLocalLeft = r.left - cursorWorkX;
          final double windowLocalTop = r.top - cursorWorkY;
          expect(windowLocalLeft, greaterThanOrEqualTo(floor.left - 1e-6),
              reason: 'anchor ($ax,$ay) card left must be >= reserved floor '
                  '(vertical=$isVertical cursor=$cursorWorkX,$cursorWorkY)');
          expect(windowLocalTop, greaterThanOrEqualTo(floor.top - 1e-6),
              reason: 'anchor ($ax,$ay) card top must be >= reserved floor '
                  '(vertical=$isVertical cursor=$cursorWorkX,$cursorWorkY)');
        }
      }
    }

    test(
        'horizontal cascade: floor covers all cards from a bottom-right cursor',
        () {
      // The exact user scenario: word near the bottom-right, children cascade
      // up/left. The one-card floor (-360,-480) was exceeded by cards near the
      // top-left edge (~ -1700,-900); the edge floor covers them all.
      assertFloorCoversAllAnchors(
          cursorWorkX: 1700, cursorWorkY: 900, isVertical: false);
    });

    test('vertical cascade: floor covers all cards from a bottom-right cursor',
        () {
      assertFloorCoversAllAnchors(
          cursorWorkX: 1700, cursorWorkY: 900, isVertical: true);
    });

    test('floor covers all cards for cursors sampled across the work area', () {
      for (final double cx in const <double>[300, 700, 1200, 1700]) {
        for (final double cy in const <double>[200, 500, 800, 1000]) {
          assertFloorCoversAllAnchors(
              cursorWorkX: cx, cursorWorkY: cy, isVertical: false);
          assertFloorCoversAllAnchors(
              cursorWorkX: cx, cursorWorkY: cy, isVertical: true);
        }
      }
    });
  });

  // TODO-1231（BUG-583/670 续·「弹窗生成在窗口外」）—— computeRootShellOffset 单测。
  // 根卡是级联里唯一不经 computeFrameRect clamp 的卡；reserve-to-edge 地板把 C++ 的
  // 窗口右/下 clamp 变成 no-op 后，光标靠屏右/下时根卡越出工作区被窗口边裁掉。该
  // 纯函数把根卡（光标+8 的工作区位置）按子卡同语义 clamp 进 [0, screenWork - card]，
  // 返回相对光标锚点的 window-local 偏移。
  group('TODO-1231 computeRootShellOffset (root card clamped into work area)',
      () {
    const double screenW = 1920;
    const double screenH = 1040;
    const double cardW = 400; // defaultPopupMaxWidth
    const double cardH = 360; // defaultPopupMaxHeight

    ({double left, double top}) offsetFor(double cx, double cy) {
      return computeRootShellOffset(
        cursorWorkX: cx,
        cursorWorkY: cy,
        screenWorkW: screenW,
        screenWorkH: screenH,
        cardW: cardW,
        cardH: cardH,
      );
    }

    test('interior cursor with ample space -> (0,0), pre-fix geometry', () {
      final ({double left, double top}) o = offsetFor(500, 300);
      expect(o.left, 0);
      expect(o.top, 0);
    });

    test(
        'REGRESSION LOCK: cursor near the RIGHT edge -> pulled back left by '
        'exactly the overflow', () {
      // cursorWork 1700 + card 400 = 2100 > 1920 -> overflow 180.
      final ({double left, double top}) o = offsetFor(1700, 300);
      expect(o.left, -180);
      expect(o.top, 0);
      // The clamped root card fits the work area completely.
      expect(1700 + o.left + cardW, lessThanOrEqualTo(screenW));
      expect(1700 + o.left, greaterThanOrEqualTo(0));
    });

    test('REGRESSION LOCK: cursor near the BOTTOM edge -> pulled back up', () {
      // cursorWork 900 + card 360 = 1260 > 1040 -> overflow 220.
      final ({double left, double top}) o = offsetFor(300, 900);
      expect(o.left, 0);
      expect(o.top, -220);
      expect(900 + o.top + cardH, lessThanOrEqualTo(screenH));
    });

    test(
        'REGRESSION LOCK: bottom-right corner (the user acceptance geometry) '
        '-> both axes clamped, card fully inside the work area', () {
      // 修前：卡在 (1900,1030) 起步、窗口右/下边 == 工作区边 -> 几乎整卡被裁
      // （「弹窗直接生成在窗口外面」）。修后：钳回 (1520,680)，完整可见。
      final ({double left, double top}) o = offsetFor(1900, 1030);
      expect(o.left, -380);
      expect(o.top, -350);
      expect(1900 + o.left, 1520); // == screenW - cardW
      expect(1030 + o.top, 680); // == screenH - cardH
    });

    test(
        'card wider/taller than the work area -> pinned at the near edge '
        '(clampLikeIos lower bound wins)', () {
      final ({double left, double top}) o = computeRootShellOffset(
        cursorWorkX: 200,
        cursorWorkY: 150,
        screenWorkW: 300,
        screenWorkH: 200,
        cardW: 400,
        cardH: 360,
      );
      expect(o.left, -200); // = -cursorWorkX: root pinned at the work edge.
      expect(o.top, -150);
    });

    test('no work area reported (screenWork <= 0) -> (0,0), pre-fix geometry',
        () {
      final ({double left, double top}) o = computeRootShellOffset(
        cursorWorkX: 0,
        cursorWorkY: 0,
        screenWorkW: 0,
        screenWorkH: -1,
        cardW: cardW,
        cardH: cardH,
      );
      expect(o.left, 0);
      expect(o.top, 0);
    });

    test(
        'negative cursorWork (cursor over a LEFT-side taskbar, work origin '
        'right of the cursor) -> positive offset pulls the card into work', () {
      final ({double left, double top}) o = offsetFor(-20, 300);
      expect(o.left, 20);
      expect(o.top, 0);
    });

    test(
        'cursorWork beyond the work far edge (cursor over a bottom taskbar) '
        '-> clamped back inside', () {
      final ({double left, double top}) o = offsetFor(300, 1100);
      expect(o.top, 680 - 1100); // root top lands at screenH - cardH.
    });

    // 关键不变量：根卡偏移恒 >= reserve-to-edge 地板（clamp 下界 0 保证），因此
    // measureAndReport 的 union-bbox 原点仍被地板托住、首帧后绝不再外移 ——
    // BUG-670 的「父卡任意层级零位移」保证不因本修复回退。同时（卡放得下时）
    // 根卡完整落在工作区内。
    test(
        'INVARIANT sweep: offset >= headroom floor (origin stays frozen) and '
        'the clamped root card fits the work area', () {
      for (double cx = 0; cx <= screenW; cx += 128) {
        for (double cy = 0; cy <= screenH; cy += 104) {
          final ({double left, double top}) o = offsetFor(cx, cy);
          final ({double left, double top}) floor = computeCascadeHeadroomSeed(
            cursorWorkX: cx,
            cursorWorkY: cy,
            screenWorkW: screenW,
            screenWorkH: screenH,
          );
          expect(o.left, greaterThanOrEqualTo(floor.left - 1e-9),
              reason: 'cursor ($cx,$cy): root offset must stay inside the '
                  'reserved floor so the window origin never moves');
          expect(o.top, greaterThanOrEqualTo(floor.top - 1e-9),
              reason: 'cursor ($cx,$cy): root offset must stay inside the '
                  'reserved floor so the window origin never moves');
          final double rootLeft = cx + o.left;
          final double rootTop = cy + o.top;
          expect(rootLeft, greaterThanOrEqualTo(0));
          expect(rootTop, greaterThanOrEqualTo(0));
          expect(rootLeft + cardW, lessThanOrEqualTo(screenW + 1e-9),
              reason: 'cursor ($cx,$cy): clamped root card must fit the work '
                  'area horizontally');
          expect(rootTop + cardH, lessThanOrEqualTo(screenH + 1e-9),
              reason: 'cursor ($cx,$cy): clamped root card must fit the work '
                  'area vertically');
        }
      }
    });
  });

  // TODO-1231（BUG-583/670 续）—— source guard：render 建造器必须真把根卡钳位接线。
  // 上面的行为锁只证明纯函数的数学；这里锁「谁在用它」——有人把 _frameRectMap 的
  // anchorless 分支改回恒 (0,0)、或不再从 buildStackRenderScript 传 rootShellOffset，
  // 本测试转红。
  group('TODO-1231 root clamp render wiring guard', () {
    test('buildStackRenderScript computes + threads computeRootShellOffset',
        () {
      final File render = File('lib/src/lookup/global_lookup_render.dart');
      final String body = render.readAsStringSync();
      expect(body.contains('computeRootShellOffset('), isTrue,
          reason: 'the render builder must clamp the root via the pure helper');
      expect(body.contains('rootShellOffset: rootShellOffset'), isTrue,
          reason: 'the offset must be threaded into _frameRectMap');
      // BUG-859 — the fan-out is horizontal-only (down): the former vertical
      // (rightward) branch is gone with the writingMode wiring.
      expect(body.contains("'left': rootShellOffset.left,"), isTrue,
          reason: 'the anchorless branch must base its left on the root clamp');
      expect(body.contains("'top': rootShellOffset.top + offset,"), isTrue,
          reason: 'the anchorless branch must base its top on the root clamp');
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
