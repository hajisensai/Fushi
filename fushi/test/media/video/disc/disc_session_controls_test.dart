import 'dart:async';
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

  test('back on the menu: hidden bar is summoned, visible bar exits', () {
    for (final bool allowed in <bool>[true, false]) {
      expect(
        resolveDiscSessionBack(
          onMenu: true,
          barVisible: false,
          menuCallAllowed: allowed,
        ),
        DiscSessionBackRoute.showBar,
      );
      expect(
        resolveDiscSessionBack(
          onMenu: true,
          barVisible: true,
          menuCallAllowed: allowed,
        ),
        DiscSessionBackRoute.exitSession,
      );
    }
  });

  // 拍板台 58EoAZOXVN：正片的上一级是盘菜单，不是详情页——返回不能越级退出会话。
  test('back on a title returns to the disc menu, bar state aside', () {
    for (final bool barVisible in <bool>[true, false]) {
      expect(
        resolveDiscSessionBack(
          onMenu: false,
          barVisible: barVisible,
          menuCallAllowed: true,
        ),
        DiscSessionBackRoute.returnToMenu,
      );
    }
  });

  test('back on a title leaves when the disc forbids its menu call', () {
    expect(
      resolveDiscSessionBack(
        onMenu: false,
        barVisible: false,
        menuCallAllowed: false,
      ),
      DiscSessionBackRoute.exitSession,
    );
  });

  group('DiscMenuReturn', () {
    late _FakeDiscMenu disc;
    late DiscMenuReturn menuReturn;

    setUp(() {
      disc = _FakeDiscMenu();
      menuReturn = DiscMenuReturn(
        isRefusal: (Object error) => error is _DiscRefused,
      );
    });

    bool back([
      DiscSessionBackRoute? route = DiscSessionBackRoute.returnToMenu,
    ]) => menuReturn.handleBack(
      route,
      send: disc.sendTopMenu,
      onRefused: disc.exitSession,
      onFailed: disc.fail,
    );

    test(
      'back on a title sends the top menu and stays in the session',
      () async {
        expect(back(), isTrue);
        expect(disc.sends, 1);
        disc.pending.complete();
        expect(await menuReturn.pending, DiscMenuReturnOutcome.returned);
        expect(disc.exits, 0);
        expect(disc.failures, isEmpty);
        expect(menuReturn.inFlight, isFalse);
      },
    );

    test(
      'a quick second back while the call is in flight sends nothing',
      () async {
        expect(back(), isTrue);
        expect(back(), isTrue, reason: '在途时连按被吞掉，不落到退出会话');
        expect(back(DiscSessionBackRoute.exitSession), isTrue);
        expect(disc.sends, 1);
        disc.pending.complete();
        await menuReturn.pending;
        // 完成后下一次返回照常回菜单。
        expect(back(), isTrue);
        expect(disc.sends, 2);
      },
    );

    test('a transient failure keeps the user on the title', () async {
      expect(back(), isTrue);
      disc.pending.completeError(StateError('navigation-initializing'));
      expect(await menuReturn.pending, DiscMenuReturnOutcome.failed);
      expect(disc.exits, 0);
      expect(disc.failures, hasLength(1));
      expect(menuReturn.inFlight, isFalse);
      expect(back(), isTrue);
      expect(disc.sends, 2, reason: '失败后在途标记清掉，下一次返回能再试');
    });

    test('only the disc refusing the menu call leaves the session', () async {
      expect(back(), isTrue);
      disc.pending.completeError(const _DiscRefused());
      expect(await menuReturn.pending, DiscMenuReturnOutcome.refused);
      expect(disc.exits, 1);
      expect(disc.failures, isEmpty);
    });

    test('a synchronous failure still clears the in-flight mark', () async {
      final bool consumed = menuReturn.handleBack(
        DiscSessionBackRoute.returnToMenu,
        send: () => throw StateError('bridge'),
        onRefused: disc.exitSession,
        onFailed: disc.fail,
      );
      expect(consumed, isTrue);
      expect(await menuReturn.pending, isNull);
      expect(menuReturn.inFlight, isFalse);
      expect(disc.failures, hasLength(1));
    });

    test('other rungs and a leaving session are not consumed', () async {
      expect(back(DiscSessionBackRoute.exitSession), isFalse);
      expect(back(DiscSessionBackRoute.showBar), isFalse);
      expect(back(null), isFalse);
      expect(disc.sends, 0);
      // 已在退出（route 为 null）时，在途的回菜单请求不拦退出。
      expect(back(), isTrue);
      expect(back(null), isFalse);
      disc.pending.complete();
      await menuReturn.pending;
    });
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
        child: DiscExitHoldRing(
          holding: holding,
          color: Colors.white,
          label: 'hold to exit',
        ),
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

/// The disc's own refusal of a menu call (UO mask), as classified by the page.
class _DiscRefused implements Exception {
  const _DiscRefused();
}

/// Stands in for the disc session: each top-menu call waits on [pending].
class _FakeDiscMenu {
  int sends = 0;
  int exits = 0;
  final List<Object> failures = <Object>[];
  Completer<void> pending = Completer<void>();

  Future<void> sendTopMenu() {
    sends++;
    pending = Completer<void>();
    return pending.future;
  }

  Future<void> exitSession() async {
    exits++;
  }

  void fail(Object error, StackTrace stack) {
    failures.add(error);
  }
}
