// TODO-867 P3c-B2: computeFrameRect pure-function unit tests.
//
// Covers the cascade-layout semantics ported from hoshi LookupPopupLayout.kt.
// Every expected value is hand-computed from the Hoshi algorithm; each case
// annotates the matching Hoshi branch (width/height/centerX/centerY/showBelow/
// showOnRight/clampLikeIos).

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
