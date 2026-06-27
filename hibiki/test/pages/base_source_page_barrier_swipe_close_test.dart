import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/utils/spacing.dart';
import 'package:hibiki/src/utils/misc/swipe_dismiss_wrapper.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import '../helpers/fake_inappwebview_platform.dart';
import '../helpers/test_platform_services.dart';

/// TODO-716: desktop aligns with mobile swipe-to-close. On mobile only the popup
/// top bar is swipeable (SwipeDismissWrapper); desktop defaults swipe OFF so a
/// horizontal drag over the popup body did nothing (the "switch does nothing"
/// complaint). This guard locks the gesture-routing contract of the full-screen
/// barrier in [BaseSourcePageState.buildDictionary]:
///   - switch ON: horizontal drag past threshold -> close ONE layer
///     (dismissTopPopup, keeping the parent). Swipe-to-close is a directed
///     dismiss gesture (mobile parity) and stays layer-by-layer.
///   - bidirectional horizontal (left or right), like mobile _dragX.abs().
///   - threshold reuses [swipeDismissThreshold] (default sensitivity 0.6 ~94px);
///     below-threshold springs back without closing.
///   - TODO-834: a tap on the bare barrier (true blank outside all popups) now
///     routes through onTap -> clearDictionaryResult, clearing the WHOLE stack
///     (reverts TODO-720's close-one-layer) and keeping the hidden warm slot.
///     Tap/drag arena is mutually exclusive, no swallowing.
///   - switch OFF: barrier only taps, horizontal drag is inert (old desktop).
///   - hover is not swallowed (onDismissBarrierHover still reachable).
///
/// Empty results make a lookup reveal immediately (no WebView render callback
/// needed) so nested layers become visible in the unit harness and the barrier
/// renders (hasVisiblePopup).
class BarrierSwipeAppModel extends AppModel {
  BarrierSwipeAppModel() : super(testPlatformServices());

  @override
  int get maximumTerms => 10;

  @override
  double get popupMaxWidth => 360;

  @override
  double get popupMaxHeight => 360;

  @override
  bool get popupBottomDocked => false;

  @override
  double get appUiScale => 1.0;

  @override
  List<String> get enabledAudioSources => const <String>[];

  @override
  List<AudioSourceConfig> get audioSourceConfigs => const <AudioSourceConfig>[];

  @override
  bool get lowMemoryMode => false;

  @override
  void addToDictionaryHistory({required DictionarySearchResult result}) {}

  @override
  Future<DictionarySearchResult> searchDictionary({
    required String searchTerm,
    required bool searchWithWildcards,
    int? overrideMaximumTerms,
    bool useCache = true,
    bool allowRemoteLookup = true,
  }) async {
    return DictionarySearchResult(searchTerm: searchTerm);
  }
}

class BarrierSwipeHostPage extends BaseSourcePage {
  const BarrierSwipeHostPage({super.key}) : super(item: null);

  @override
  BaseSourcePageState<BarrierSwipeHostPage> createState() =>
      BarrierSwipeHostPageState();
}

class BarrierSwipeHostPageState
    extends BaseSourcePageState<BarrierSwipeHostPage> {
  int barrierHoverCalls = 0;

  @override
  void onDismissBarrierHover(PointerHoverEvent event) {
    barrierHoverCalls++;
  }

  Future<void> topSearch(String term) {
    prunePopupStack(0);
    return searchDictionaryResult(
      searchTerm: term,
      selectionRect: const Rect.fromLTWH(40, 40, 8, 8),
    );
  }

  Future<void> nestedSearch(String term) {
    prunePopupStack(1);
    return searchDictionaryResult(
      searchTerm: term,
      selectionRect: const Rect.fromLTWH(120, 120, 8, 8),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        const Positioned.fill(child: SizedBox.expand()),
        buildDictionary(),
      ],
    );
  }
}

Widget buildBarrierSwipeApp({
  required AppModel appModel,
  required GlobalKey<BarrierSwipeHostPageState> hostKey,
}) {
  return ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((ref) => appModel),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        builder: (context, child) => Spacing(
          dataBuilder: (context) => SpacingData.generate(10),
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: BarrierSwipeHostPage(key: hostKey)),
      ),
    ),
  );
}

Finder _barrierFinder() => find.byWidgetPredicate(
      (Widget w) => w is Container && w.color == Colors.transparent,
    );

/// A point on the bare barrier that is NOT covered by any popup layer.
/// Popups seed near (40,40) and (120,120) with up to 360px boxes, covering
/// the top-left quadrant of the 800x600 test screen; the bottom-right corner
/// is guaranteed bare barrier so the gesture lands on it, not on a popup.
const Offset _bareBarrierPoint = Offset(740, 560);

Future<void> _dragBarrier(
  WidgetTester tester, {
  required double dx,
  PointerDeviceKind kind = PointerDeviceKind.touch,
}) async {
  final Finder barrier = _barrierFinder();
  expect(barrier, findsOneWidget,
      reason: 'buildDictionary should render exactly one full-screen barrier '
          'while a popup is visible');
  final TestGesture gesture =
      await tester.startGesture(_bareBarrierPoint, kind: kind);
  const int steps = 12;
  final double step = dx / steps;
  for (int i = 0; i < steps; i++) {
    await gesture.moveBy(Offset(step, 0));
    await tester.pump();
  }
  await gesture.up();
  await tester.pump();
}

Future<void> _seedTwoVisibleLayers(
  WidgetTester tester,
  BarrierSwipeHostPageState host,
) async {
  await host.topSearch('first');
  await tester.pump();
  await host.nestedSearch('second');
  await tester.pump();
}

void main() {
  setUpAll(installFakeInAppWebViewPlatform);
  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    await ReaderHibikiSource.instance.setDismissSwipeSensitivity(0.6);
  });

  testWidgets(
      'switch ON: horizontal drag past threshold on the barrier closes ONE '
      'layer (keeps parent)', (WidgetTester tester) async {
    await ReaderHibikiSource.instance.setEnableSwipeToClose(true);
    final appModel = BarrierSwipeAppModel();
    final hostKey = GlobalKey<BarrierSwipeHostPageState>();
    await tester.pumpWidget(
      buildBarrierSwipeApp(appModel: appModel, hostKey: hostKey),
    );
    await tester.pump();
    await tester.pump();

    final host = hostKey.currentState!;
    await _seedTwoVisibleLayers(tester, host);
    expect(host.debugPopupStack, hasLength(2));
    expect(host.debugPopupStack.every((e) => e.visible), isTrue);

    await _dragBarrier(tester, dx: 240);

    expect(host.debugPopupStack, hasLength(1),
        reason: 'an over-threshold drag closes only the top layer');
    expect(host.debugPopupStack.single.visible, isTrue,
        reason: 'parent layer stays visible');
  });

  testWidgets(
      'switch ON: leftward (negative) drag past threshold also closes one '
      'layer (bidirectional like mobile)', (WidgetTester tester) async {
    await ReaderHibikiSource.instance.setEnableSwipeToClose(true);
    final appModel = BarrierSwipeAppModel();
    final hostKey = GlobalKey<BarrierSwipeHostPageState>();
    await tester.pumpWidget(
      buildBarrierSwipeApp(appModel: appModel, hostKey: hostKey),
    );
    await tester.pump();
    await tester.pump();

    final host = hostKey.currentState!;
    await _seedTwoVisibleLayers(tester, host);
    expect(host.debugPopupStack, hasLength(2));

    await _dragBarrier(tester, dx: -240);

    expect(host.debugPopupStack, hasLength(1),
        reason: 'a leftward over-threshold drag also closes one layer');
  });

  testWidgets('switch ON: drag below threshold does NOT close any layer',
      (WidgetTester tester) async {
    await ReaderHibikiSource.instance.setEnableSwipeToClose(true);
    final appModel = BarrierSwipeAppModel();
    final hostKey = GlobalKey<BarrierSwipeHostPageState>();
    await tester.pumpWidget(
      buildBarrierSwipeApp(appModel: appModel, hostKey: hostKey),
    );
    await tester.pump();
    await tester.pump();

    final host = hostKey.currentState!;
    await _seedTwoVisibleLayers(tester, host);
    expect(host.debugPopupStack, hasLength(2));

    await _dragBarrier(tester, dx: 40);

    expect(host.debugPopupStack, hasLength(2),
        reason: 'a below-threshold drag must spring back, closing nothing');
  });

  testWidgets(
      'switch OFF: horizontal drag past threshold does NOT close (no swipe), '
      'tap clears the whole stack (TODO-834)', (WidgetTester tester) async {
    await ReaderHibikiSource.instance.setEnableSwipeToClose(false);
    final appModel = BarrierSwipeAppModel();
    final hostKey = GlobalKey<BarrierSwipeHostPageState>();
    await tester.pumpWidget(
      buildBarrierSwipeApp(appModel: appModel, hostKey: hostKey),
    );
    await tester.pump();
    await tester.pump();

    final host = hostKey.currentState!;
    await _seedTwoVisibleLayers(tester, host);
    expect(host.debugPopupStack, hasLength(2));

    await _dragBarrier(tester, dx: 240, kind: PointerDeviceKind.mouse);
    expect(host.debugPopupStack, hasLength(2),
        reason: 'with the switch off the barrier only taps, drag is inert');

    // TODO-834：点 barrier（所有弹窗外真空白）一次性清整栈，保留隐藏热槽。
    await tester.tapAt(_bareBarrierPoint);
    await tester.pump();
    expect(host.dictionaryPopupShown, isFalse,
        reason:
            'tap-barrier clears the whole stack regardless of swipe switch');
    expect(host.debugPopupStack, hasLength(1),
        reason: 'the hidden warm slot survives (BUG-092)');
    expect(host.debugPopupStack.single.visible, isFalse);
    expect(host.debugPopupStack.single.isWarmSlot, isTrue);
  });

  testWidgets(
      'switch ON: a tap (not a drag) clears the whole stack (TODO-834; '
      'tap/drag arena does not swallow each other)',
      (WidgetTester tester) async {
    await ReaderHibikiSource.instance.setEnableSwipeToClose(true);
    final appModel = BarrierSwipeAppModel();
    final hostKey = GlobalKey<BarrierSwipeHostPageState>();
    await tester.pumpWidget(
      buildBarrierSwipeApp(appModel: appModel, hostKey: hostKey),
    );
    await tester.pump();
    await tester.pump();

    final host = hostKey.currentState!;
    await _seedTwoVisibleLayers(tester, host);
    expect(host.debugPopupStack, hasLength(2));

    await tester.tapAt(_bareBarrierPoint);
    await tester.pump();

    // TODO-834：tap 经手势竞技场仍走 onTap → clearDictionaryResult 清整栈。
    expect(host.dictionaryPopupShown, isFalse,
        reason: 'a tap still routes through onTap and clears the whole stack');
    expect(host.debugPopupStack, hasLength(1),
        reason: 'the hidden warm slot survives');
    expect(host.debugPopupStack.single.visible, isFalse);
  });

  testWidgets(
      'switch ON: pointer hover on the barrier still reaches '
      'onDismissBarrierHover (drag handlers do not swallow hover)',
      (WidgetTester tester) async {
    await ReaderHibikiSource.instance.setEnableSwipeToClose(true);
    final appModel = BarrierSwipeAppModel();
    final hostKey = GlobalKey<BarrierSwipeHostPageState>();
    await tester.pumpWidget(
      buildBarrierSwipeApp(appModel: appModel, hostKey: hostKey),
    );
    await tester.pump();
    await tester.pump();

    final host = hostKey.currentState!;
    await _seedTwoVisibleLayers(tester, host);
    expect(host.debugPopupStack, hasLength(2));
    host.barrierHoverCalls = 0;

    final TestGesture mouse =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: _bareBarrierPoint + const Offset(-5, -5));
    await mouse.moveTo(_bareBarrierPoint);
    await tester.pump();
    await mouse.removePointer();

    expect(host.barrierHoverCalls, greaterThan(0),
        reason: 'the drag handlers must not swallow onPointerHover');
    expect(host.debugPopupStack, hasLength(2));
  });

  testWidgets(
      'TODO-880 switch ON: horizontal drag on the TOP popup BODY closes only '
      'the top layer (keeps parent)', (WidgetTester tester) async {
    await ReaderHibikiSource.instance.setEnableSwipeToClose(true);
    final appModel = BarrierSwipeAppModel();
    final hostKey = GlobalKey<BarrierSwipeHostPageState>();
    await tester.pumpWidget(
      buildBarrierSwipeApp(appModel: appModel, hostKey: hostKey),
    );
    await tester.pump();
    await tester.pump();

    final host = hostKey.currentState!;
    await _seedTwoVisibleLayers(tester, host);
    expect(host.debugPopupStack, hasLength(2));

    // The top (nested) layer is the last DictionaryPopupLayer; drag across its
    // own body, not the bare barrier.
    final Finder topLayer = find.byType(DictionaryPopupLayer).last;
    final Offset topCenter = tester.getCenter(topLayer);
    final TestGesture g = await tester.startGesture(topCenter);
    for (int i = 0; i < 12; i++) {
      await g.moveBy(const Offset(20, 0));
      await tester.pump();
    }
    await g.up();
    await tester.pump();

    expect(host.debugPopupStack, hasLength(1),
        reason: 'a body drag on the top layer closes only the top layer');
    expect(host.debugPopupStack.single.visible, isTrue,
        reason: 'the parent layer survives');
  });

  group('swipeDismissThreshold pure function', () {
    test('default sensitivity 0.6 yields ~94px', () {
      expect(swipeDismissThreshold(0.6), closeTo(94, 0.5));
    });
    test('higher sensitivity lowers the threshold', () {
      expect(swipeDismissThreshold(1.0), 30);
      expect(swipeDismissThreshold(0.0), 190);
      expect(swipeDismissThreshold(0.9), lessThan(swipeDismissThreshold(0.1)));
    });
  });
}
