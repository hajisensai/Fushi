import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/disc/disc_session_controls.dart';
import 'package:material_ui/material_ui.dart';

DiscSurfaceTapRoute _tap({
  bool overlayOpen = false,
  bool insideVideo = true,
  bool menuInteractive = true,
  bool bdj = false,
  bool inTopBand = false,
  bool menuStarting = false,
}) => resolveDiscSurfaceTap(
  overlayOpen: overlayOpen,
  insideVideo: insideVideo,
  menuInteractive: menuInteractive,
  bdj: bdj,
  inTopBand: inTopBand,
  menuStarting: menuStarting,
);

void main() {
  group('click layer rule', () {
    test('an open overlay is only closed: the tap neither reaches the disc '
        'nor toggles the bar', () {
      expect(_tap(overlayOpen: true), DiscSurfaceTapRoute.dismissOverlay);
      expect(
        _tap(overlayOpen: true, bdj: true, inTopBand: true),
        DiscSurfaceTapRoute.dismissOverlay,
      );
      expect(
        _tap(overlayOpen: true, insideVideo: false),
        DiscSurfaceTapRoute.dismissOverlay,
      );
    });

    test('HDMV: inside the picture the disc decides (button vs blank)', () {
      expect(_tap(), DiscSurfaceTapRoute.forwardToDisc);
      // The top band is not special on HDMV: the hit result is exact.
      expect(_tap(inTopBand: true), DiscSurfaceTapRoute.forwardToDisc);
    });

    test('HDMV: letterbox and button-less screens are blank', () {
      expect(_tap(insideVideo: false), DiscSurfaceTapRoute.toggleBar);
      expect(_tap(menuInteractive: false), DiscSurfaceTapRoute.toggleBar);
    });

    test('BD-J: never inferred blank; top band summons the bar', () {
      expect(_tap(bdj: true), DiscSurfaceTapRoute.forwardToDisc);
      expect(
        _tap(bdj: true, menuInteractive: false),
        DiscSurfaceTapRoute.forwardToDisc,
      );
      expect(_tap(bdj: true, inTopBand: true), DiscSurfaceTapRoute.toggleBar);
      expect(_tap(bdj: true, insideVideo: false), DiscSurfaceTapRoute.ignore);
    });

    test('nothing happens while the menu is still starting', () {
      expect(_tap(menuStarting: true), DiscSurfaceTapRoute.ignore);
    });

    test('an unconsumed HDMV click closes the disc popup or shows the bar', () {
      expect(
        resolveUnconsumedDiscClick(bdj: false, discTitle: 0),
        DiscUnconsumedClickRoute.showBar,
      );
      expect(
        resolveUnconsumedDiscClick(bdj: false, discTitle: 65535),
        DiscUnconsumedClickRoute.showBar,
      );
      expect(
        resolveUnconsumedDiscClick(bdj: false, discTitle: 3),
        DiscUnconsumedClickRoute.closeDiscPopup,
      );
      expect(resolveUnconsumedDiscClick(bdj: true, discTitle: 0), isNull);
    });

    test('top band is the top 10% of the surface', () {
      const Size viewport = Size(1000, 800);
      expect(isInDiscSessionTopBand(const Offset(10, 80), viewport), isTrue);
      expect(isInDiscSessionTopBand(const Offset(10, 81), viewport), isFalse);
    });
  });

  test('back: hidden bar is summoned, visible bar exits', () {
    expect(
      resolveDiscSessionBack(barVisible: false),
      DiscSessionBackRoute.showBar,
    );
    expect(
      resolveDiscSessionBack(barVisible: true),
      DiscSessionBackRoute.exitSession,
    );
  });

  group('DiscExitHold', () {
    test('a short press is handed back to the caller', () {
      fakeAsync((FakeAsync async) {
        int exits = 0;
        final DiscExitHold hold = DiscExitHold(onExit: () => exits++);
        hold.press('esc');
        expect(hold.holding.value, isTrue);
        async.elapse(const Duration(milliseconds: 400));
        expect(hold.release('esc'), isTrue);
        expect(hold.holding.value, isFalse);
        async.elapse(const Duration(seconds: 2));
        expect(exits, 0);
        hold.dispose();
      });
    });

    test('holding ~1 s exits once and swallows the release', () {
      fakeAsync((FakeAsync async) {
        int exits = 0;
        final DiscExitHold hold = DiscExitHold(onExit: () => exits++);
        hold.press('b');
        // Auto-repeat of the held key is not a new press.
        hold.press('b');
        async.elapse(const Duration(milliseconds: 999));
        expect(exits, 0);
        async.elapse(const Duration(milliseconds: 1));
        expect(exits, 1);
        expect(hold.holding.value, isFalse);
        expect(hold.release('b'), isFalse);
        expect(exits, 1);
        hold.dispose();
      });
    });

    test('releasing another source does not end the hold', () {
      fakeAsync((FakeAsync async) {
        final DiscExitHold hold = DiscExitHold(onExit: () {});
        hold.press('esc');
        expect(hold.release('b'), isFalse);
        expect(hold.active, isTrue);
        hold.cancel();
        expect(hold.active, isFalse);
        hold.dispose();
      });
    });
  });

  testWidgets('the hold ring is shown only while held', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<bool> holding = ValueNotifier<bool>(false);
    addTearDown(holding.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: DiscExitHoldRing(holding: holding, color: Colors.white),
      ),
    );
    final Finder ring = find.byKey(
      const ValueKey<String>('disc-exit-hold-ring'),
    );
    expect(ring, findsNothing);
    holding.value = true;
    await tester.pump();
    expect(ring, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    holding.value = false;
    await tester.pump();
    expect(ring, findsNothing);
  });

  group('launch transition', () {
    Widget host({required bool reduceMotion}) => MediaQuery(
      data: MediaQueryData(
        size: const Size(800, 600),
        disableAnimations: reduceMotion,
      ),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: DiscLaunchCoverTransition(
          cover: MemoryImage(_kTransparentPng),
          origin: const Rect.fromLTWH(10, 10, 100, 150),
        ),
      ),
    );

    testWidgets('grows the cover, fades it, then removes itself within 0.8 s', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(host(reduceMotion: false));
      final Finder cover = find.byKey(
        const ValueKey<String>('disc-launch-cover'),
      );
      expect(cover, findsOneWidget);
      final Rect start = tester.getRect(cover);
      expect(start.width, closeTo(100, 1));
      await tester.pump(const Duration(milliseconds: 450));
      expect(tester.getRect(cover).size, const Size(800, 600));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(cover, findsNothing);
    });

    testWidgets('renders nothing under reduced motion', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(host(reduceMotion: true));
      expect(
        find.byKey(const ValueKey<String>('disc-launch-cover')),
        findsNothing,
      );
    });
  });
}

/// 1×1 transparent PNG.
final List<int> _kTransparentPngBytes = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];
final Uint8List _kTransparentPng = Uint8List.fromList(_kTransparentPngBytes);
