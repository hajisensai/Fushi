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

/// A point near the centre of the 360x360 popup body (well below the 40px top
/// bar) so the drag lands on the popup body, not the header/buttons.
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
  await tester.pump();
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

  test('threshold sanity: default sensitivity 0.6 ~94px', () {
    expect(swipeDismissThreshold(0.6), closeTo(94, 0.5));
  });
}
