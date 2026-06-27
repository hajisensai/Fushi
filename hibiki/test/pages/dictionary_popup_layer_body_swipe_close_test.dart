import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/src/utils/misc/swipe_dismiss_wrapper.dart';
import 'package:hibiki/src/utils/spacing.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

/// TODO-880: restore "horizontal swipe-to-close on the popup BODY".
///
/// TODO-406 narrowed the swipeable region to the 40px top bar only, and
/// TODO-805 wrapped the whole popup in an opaque `GestureDetector(onTap)` so
/// taps stop at the popup. On mobile that opaque tap layer + the header buttons
/// won the gesture arena in the 40px band, so the bare `Listener` of the top-bar
/// `SwipeDismissWrapper` could not reliably accumulate a horizontal drag → swipe
/// regressed. On desktop the only swipe path (the 716 barrier) lives OUTSIDE the
/// popup rect, so dragging ON the popup body never closed it ("switch does
/// nothing").
///
/// The fix adds `onHorizontalDrag*` to that same outer opaque GestureDetector
/// (gated on `enableSwipeToClose`). Tap and horizontal-drag share one detector,
/// so the Flutter arena routes a single tap to `onTap` and a drag to the drag
/// recognizer — mutually exclusive, no swallowing. These guards lock that
/// contract directly on [DictionaryPopupLayer] (the layer all five surfaces
/// share), independent of any host's barrier.
///
/// An empty result + not searching + not warm renders the no-results
/// placeholder, so no real WebView is mounted (no fake platform needed).
///
/// TODO-896 contract split (READ THIS before "fixing" the body-point asserts):
/// The popup-close contract has TWO halves that live in TWO test files —
///   (a) the `_BodySwipeDismissDetector` itself (the layer's opaque tap+drag
///       absorber that wraps the whole surface) STILL closes on an over-threshold
///       horizontal drag of its OWN region (top bar + the popup-frame margin
///       OUTSIDE the WebView). That half is what THIS file guards, and TODO-896
///       does NOT change it.
///   (b) a horizontal drag that STARTS on the real WebView body (a frame-select)
///       must be eaten by the WebView (TODO-896 symptom①: the WebView now
///       declares a `HorizontalDragGestureRecognizer`), so the detector never
///       sees it and the popup does NOT close. The test host here mounts the
///       no-results PLACEHOLDER (no real platform WebView competes in the
///       arena), so half (b) is INVISIBLE in a widget test and is locked at the
///       source level in `dictionary_popup_webview_test.dart` (the
///       `Factory<HorizontalDragGestureRecognizer>` guard). Do NOT invert the
///       asserts below to "body drag does not close" — that would break half (a)
///       (TODO-880's real contract) and still wouldn't prove half (b).
///
/// `_popupBodyPoint` below therefore exercises the DETECTOR region (no WebView
/// present), NOT a real WebView body. The name is kept for git continuity.

DictionaryPopupLayer _layer({
  required VoidCallback onDismiss,
  required bool enableSwipeToClose,
  Widget? headerWidget,
  VoidCallback? onClose,
  VoidCallback? onBack,
}) {
  return DictionaryPopupLayer(
    result: DictionarySearchResult(searchTerm: 'x'),
    webViewKey: GlobalKey<DictionaryPopupWebViewState>(),
    onDismiss: onDismiss,
    onTextSelected: (String _, Rect __) {},
    onLinkClick: (String _, Rect __) {},
    onMineEntry: (Map<String, String> _) async => const MinePopupResult(),
    onDuplicateCheck: (String _, String __) async => false,
    enableSwipeToClose: enableSwipeToClose,
    headerWidget: headerWidget,
    onClose: onClose,
    onBack: onBack,
  );
}

Widget _host(Widget layer) {
  return TranslationProvider(
    child: MaterialApp(
      builder: (context, child) => Spacing(
        dataBuilder: (context) => SpacingData.generate(10),
        child: child ?? const SizedBox.shrink(),
      ),
      home: Scaffold(
        body: Center(
          // Constrain the layer so it occupies a finite, hit-testable rect.
          child: SizedBox(width: 360, height: 360, child: layer),
        ),
      ),
    ),
  );
}

/// A point near the centre of the 360x360 popup surface (well below the 40px top
/// bar). With NO real WebView mounted (placeholder body), this lands on the
/// `_BodySwipeDismissDetector`'s own absorbing region — the half-(a) contract
/// above — so an over-threshold drag here exercises the detector's dismiss path,
/// not a real-WebView frame-select (half (b), source-guarded elsewhere).
const Offset _popupBodyPoint = Offset(400, 300);

Future<void> _dragOn(
  WidgetTester tester,
  Offset start, {
  required double dx,
  PointerDeviceKind kind = PointerDeviceKind.touch,
}) async {
  final TestGesture gesture = await tester.startGesture(start, kind: kind);
  const int steps = 12;
  final double step = dx / steps;
  for (int i = 0; i < steps; i++) {
    await gesture.moveBy(Offset(step, 0));
    await tester.pump();
  }
  await gesture.up();
  // TODO-890: onDismiss now fires only when the slide-out animation completes
  // (AnimationStatus.completed), so settle the 200ms tween before asserting.
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    await ReaderHibikiSource.instance.setDismissSwipeSensitivity(0.6);
  });

  testWidgets(
      'switch ON: horizontal drag past threshold on the popup body fires '
      'onDismiss (mobile regression + desktop switch)',
      (WidgetTester tester) async {
    int dismissed = 0;
    await tester.pumpWidget(_host(_layer(
      onDismiss: () => dismissed++,
      enableSwipeToClose: true,
      onClose: () {},
    )));
    await tester.pump();

    // 0.6 sensitivity -> ~94px threshold; 200px clears it.
    await _dragOn(tester, _popupBodyPoint, dx: 200);

    expect(dismissed, 1,
        reason: 'an over-threshold horizontal drag on the body closes a layer');
  });

  testWidgets(
      'switch ON: leftward drag past threshold on the body also fires '
      'onDismiss (bidirectional)', (WidgetTester tester) async {
    int dismissed = 0;
    await tester.pumpWidget(_host(_layer(
      onDismiss: () => dismissed++,
      enableSwipeToClose: true,
      onClose: () {},
    )));
    await tester.pump();

    await _dragOn(tester, _popupBodyPoint, dx: -200);

    expect(dismissed, 1,
        reason: 'a leftward over-threshold drag also closes a layer');
  });

  testWidgets('switch ON: below-threshold drag does NOT fire onDismiss',
      (WidgetTester tester) async {
    int dismissed = 0;
    await tester.pumpWidget(_host(_layer(
      onDismiss: () => dismissed++,
      enableSwipeToClose: true,
      onClose: () {},
    )));
    await tester.pump();

    await _dragOn(tester, _popupBodyPoint, dx: 40);

    expect(dismissed, 0,
        reason: 'a below-threshold drag springs back, closing nothing');
  });

  testWidgets(
      'switch ON: a single tap on the body does NOT fire onDismiss '
      '(tap/drag arena does not swallow each other)',
      (WidgetTester tester) async {
    int dismissed = 0;
    await tester.pumpWidget(_host(_layer(
      onDismiss: () => dismissed++,
      enableSwipeToClose: true,
      onClose: () {},
    )));
    await tester.pump();

    await tester.tapAt(_popupBodyPoint);
    await tester.pump();

    expect(dismissed, 0,
        reason: 'a tap stays an absorbing no-op onTap, never a dismiss');
  });

  testWidgets(
      'switch OFF: horizontal drag on the body is inert, X still closes',
      (WidgetTester tester) async {
    int dismissed = 0;
    int closed = 0;
    await tester.pumpWidget(_host(_layer(
      onDismiss: () => dismissed++,
      enableSwipeToClose: false,
      onClose: () => closed++,
    )));
    await tester.pump();

    await _dragOn(tester, _popupBodyPoint,
        dx: 200, kind: PointerDeviceKind.mouse);
    expect(dismissed, 0,
        reason: 'with the switch off the body drag must be inert');

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(closed, 1, reason: 'the X button still closes with swipe off');
  });

  testWidgets(
      'no top bar (bare body): switch ON drag still fires onDismiss via the '
      'top-level SwipeDismissWrapper path', (WidgetTester tester) async {
    int dismissed = 0;
    await tester.pumpWidget(_host(_layer(
      onDismiss: () => dismissed++,
      enableSwipeToClose: true,
      // no header / onClose / onBack -> _buildTopBar returns null
    )));
    await tester.pump();

    await _dragOn(tester, _popupBodyPoint, dx: 200);

    expect(dismissed, 1,
        reason: 'the headerless layer keeps the whole-window swipe semantics');
  });

  testWidgets(
      'TODO-890 switch ON: the popup follows the finger mid-drag '
      '(Transform.translate tracks accumulated dx)',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(_layer(
      onDismiss: () {},
      enableSwipeToClose: true,
      onClose: () {},
    )));
    await tester.pump();

    final TestGesture gesture = await tester.startGesture(_popupBodyPoint);
    // Drive the drag incrementally (mirrors _dragOn) so the horizontal-drag
    // recognizer wins the arena and _onHorizontalDragUpdate accumulates.
    for (int i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(8, 0));
      await tester.pump();
    }

    // The popup body is wrapped in a Transform.translate that follows the finger.
    final Iterable<Transform> transforms =
        tester.widgetList<Transform>(find.byType(Transform));
    final bool followed = transforms.any((Transform t) {
      final double dx = t.transform.getTranslation().x;
      return dx > 40; // tracks the ~96px drag (gesture slop trims a little)
    });
    expect(followed, isTrue,
        reason:
            'mid-drag the popup must translate with the finger (follow-hand)');

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets(
      'TODO-890 switch ON: over-threshold does NOT dismiss until the slide-out '
      'animation completes, then fires exactly once',
      (WidgetTester tester) async {
    int dismissed = 0;
    await tester.pumpWidget(_host(_layer(
      onDismiss: () => dismissed++,
      enableSwipeToClose: true,
      onClose: () {},
    )));
    await tester.pump();

    final TestGesture gesture = await tester.startGesture(_popupBodyPoint);
    for (int i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(20, 0)); // 240px total clears ~94px
      await tester.pump();
    }
    await gesture.up();
    // First frame after release: animation is running, NOT yet completed.
    await tester.pump();
    expect(dismissed, 0,
        reason: 'dismiss must wait for the slide-out animation to finish');
    // Settle the 200ms tween -> completion callback fires onDismiss once.
    await tester.pumpAndSettle();
    expect(dismissed, 1,
        reason: 'onDismiss fires once when the slide-out completes');
  });

  testWidgets(
      'TODO-890 switch ON: below-threshold springs the popup back to origin '
      '(translation returns to 0, no dismiss)', (WidgetTester tester) async {
    int dismissed = 0;
    await tester.pumpWidget(_host(_layer(
      onDismiss: () => dismissed++,
      enableSwipeToClose: true,
      onClose: () {},
    )));
    await tester.pump();

    final TestGesture gesture = await tester.startGesture(_popupBodyPoint);
    for (int i = 0; i < 5; i++) {
      await gesture.moveBy(const Offset(8, 0)); // 40px total, below ~94px
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(dismissed, 0, reason: 'a below-threshold drag closes nothing');
    final Iterable<Transform> transforms =
        tester.widgetList<Transform>(find.byType(Transform));
    final bool allBack = transforms
        .every((Transform t) => t.transform.getTranslation().x.abs() < 0.5);
    expect(allBack, isTrue,
        reason: 'spring-back returns the popup translation to 0');
  });

  test('threshold sanity: default sensitivity 0.6 ~94px', () {
    expect(swipeDismissThreshold(0.6), closeTo(94, 0.5));
  });

  // TODO-896 half-(b) reconciliation: the "frame-select on a real WebView body
  // must NOT close the popup" half of the contract can't be exercised in a widget
  // test (the host mounts the no-results placeholder; no real platform WebView
  // competes in the gesture arena). It is enforced by the WebView declaring a
  // HorizontalDragGestureRecognizer, locked at the source level. Asserting that
  // guard's existence HERE keeps the two files from drifting into opposite
  // contracts: this file owns half (a) (detector closes on its own region), the
  // WebView source owns half (b) (WebView eats the body drag).
  test(
      'TODO-896 half-(b): the popup WebView declares a horizontal-drag '
      'recognizer so a real-WebView frame-select never reaches this detector',
      () {
    final String webViewSource = File(
      'lib/src/pages/implementations/dictionary_popup_webview.dart',
    ).readAsStringSync();
    expect(
      webViewSource,
      contains('Factory<HorizontalDragGestureRecognizer>('),
      reason: 'Without the WebView winning the body-region horizontal drag, a '
          'frame-select would bubble into _BodySwipeDismissDetector and close '
          'the popup (TODO-896 symptom①). The detector half-(a) asserts above '
          'stay valid because they run with NO real WebView mounted.',
    );
  });
}
