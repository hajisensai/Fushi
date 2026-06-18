import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/src/utils/components/hibiki_icon_button.dart';
import 'package:hibiki/src/utils/misc/swipe_dismiss_wrapper.dart';

import '../widgets/widget_test_helpers.dart';

/// TODO-406/407 守卫：查词弹窗"滑动关闭"边界与"X 关闭"按钮。
///
/// 用 result==null 让弹窗 body 走占位分支（不实例化平台视图 WebView），既能稳定
/// 在 widget 测试里 pump，又保留与生产一致的"body 与可拖顶栏分层"结构。
void main() {
  const Key headerKey = Key('test-popup-header');
  const Key bodyAnchorKey = Key('test-popup-body-anchor');

  Widget popup({
    required VoidCallback onDismiss,
    VoidCallback? onClose,
    bool enableSwipeToClose = true,
  }) {
    return buildTestApp(
      Center(
        child: SizedBox(
          width: 320,
          height: 360,
          child: DictionaryPopupLayer(
            result: null,
            isSearching: false,
            webViewKey: GlobalKey<DictionaryPopupWebViewState>(),
            enableSwipeToClose: enableSwipeToClose,
            onClose: onClose,
            // header 给一个明确尺寸的盒子，模拟 reader/video 顶栏；body 占位区放一个
            // 带 key 的锚点，方便手势从"正文区"起手。
            headerWidget: const SizedBox(
              key: headerKey,
              height: 44,
              width: double.infinity,
              child: Center(child: Text('HEADER')),
            ),
            overlayWidget: const Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(key: bodyAnchorKey, height: 120, width: 200),
            ),
            onDismiss: onDismiss,
            onTextSelected: (text, rect) {},
            onLinkClick: (query, rect) {},
            onMineEntry: (fields) async => const MinePopupResult(),
            onDuplicateCheck: (expression, reading) async => false,
          ),
        ),
      ),
    );
  }

  // 默认灵敏度 0.6 → 阈值 ≈ 94px；水平拖 240px 必越阈值。
  Widget childPopup({
    required VoidCallback onDismiss,
    required VoidCallback onClose,
    bool enableSwipeToClose = true,
  }) {
    return buildTestApp(
      Center(
        child: SizedBox(
          width: 320,
          height: 360,
          child: DictionaryPopupLayer(
            result: null,
            isSearching: false,
            webViewKey: GlobalKey<DictionaryPopupWebViewState>(),
            enableSwipeToClose: enableSwipeToClose,
            swipeDismissible: true,
            onClose: onClose,
            onDismiss: onDismiss,
            onTextSelected: (text, rect) {},
            onLinkClick: (query, rect) {},
            onMineEntry: (fields) async => const MinePopupResult(),
            onDuplicateCheck: (expression, reading) async => false,
          ),
        ),
      ),
    );
  }

  Future<void> dragHorizontally(
    WidgetTester tester,
    Offset start, {
    double distance = 240,
    PointerDeviceKind kind = PointerDeviceKind.touch,
  }) async {
    final TestGesture gesture = await tester.startGesture(start, kind: kind);
    const int steps = 12;
    final double step = distance / steps;
    for (int i = 0; i < steps; i++) {
      await gesture.moveBy(Offset(step, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
  }

  Future<void> panZoomHorizontally(
    WidgetTester tester,
    Offset start, {
    double distance = 240,
  }) async {
    final TestPointer pointer = TestPointer(486, PointerDeviceKind.trackpad);
    tester.binding.handlePointerEvent(pointer.panZoomStart(start));
    await tester.pump();
    const int steps = 12;
    final double step = distance / steps;
    double pan = 0;
    for (int i = 0; i < steps; i++) {
      pan += step;
      tester.binding.handlePointerEvent(
        pointer.panZoomUpdate(start, pan: Offset(pan, 0)),
      );
      await tester.pump();
    }
    tester.binding.handlePointerEvent(pointer.panZoomEnd());
    await tester.pump();
  }

  testWidgets(
    'TODO-406: horizontal drag starting on the body does NOT dismiss',
    (WidgetTester tester) async {
      bool dismissed = false;
      await tester.pumpWidget(popup(onDismiss: () => dismissed = true));

      // 从 body 占位区中心起手水平拖动过阈值——body 不在 swipe 的 Listener 子树内，
      // 不应触发关闭（消除"WebView 正文框选误触滑动关闭"）。
      final Offset bodyCenter = tester.getCenter(find.byKey(bodyAnchorKey));

      // 判别力守卫：body 起手点必须落在 SwipeDismissWrapper（仅裹顶栏）矩形之外，
      // 否则本用例没有意义（手势其实落在了可滑区）。
      final Rect swipeRect = tester.getRect(find.byType(SwipeDismissWrapper));
      expect(swipeRect.contains(bodyCenter), isFalse,
          reason: 'body 起手点须在可滑顶栏区域之外，本用例才有判别力');

      await dragHorizontally(tester, bodyCenter);

      expect(dismissed, isFalse, reason: '正文区起手的水平拖动不得触发滑动关闭');
    },
  );

  testWidgets(
    'TODO-486: horizontal drag below threshold does NOT dismiss',
    (WidgetTester tester) async {
      bool dismissed = false;
      await tester.pumpWidget(popup(onDismiss: () => dismissed = true));

      final Offset headerCenter = tester.getCenter(find.byKey(headerKey));
      await dragHorizontally(
        tester,
        headerCenter,
        distance: 40,
        kind: PointerDeviceKind.mouse,
      );

      expect(dismissed, isFalse,
          reason:
              'desktop drag below the configured threshold must spring back');
    },
  );

  testWidgets(
    'TODO-486: touch drag over threshold on the header dismisses',
    (WidgetTester tester) async {
      bool dismissed = false;
      await tester.pumpWidget(popup(onDismiss: () => dismissed = true));

      final Offset headerCenter = tester.getCenter(find.byKey(headerKey));
      await dragHorizontally(tester, headerCenter);

      expect(dismissed, isTrue, reason: 'header（可拖区）的水平滑动应保留滑动关闭');
    },
  );

  testWidgets(
    'TODO-486: desktop mouse drag on child top bar dismisses without onClose',
    (WidgetTester tester) async {
      bool dismissed = false;
      bool closed = false;
      await tester.pumpWidget(
        childPopup(
          onDismiss: () => dismissed = true,
          onClose: () => closed = true,
        ),
      );

      final Rect swipeRect = tester.getRect(find.byType(SwipeDismissWrapper));
      final Offset blankTopBarPoint = swipeRect.center;
      final Rect closeIconRect = tester.getRect(find.byIcon(Icons.close));
      expect(closeIconRect.contains(blankTopBarPoint), isFalse,
          reason:
              'the drag starts from blank child top-bar space, not the icon');

      await dragHorizontally(
        tester,
        blankTopBarPoint,
        kind: PointerDeviceKind.mouse,
      );

      expect(dismissed, isTrue,
          reason: 'child swipe should close only the current child layer');
      expect(closed, isFalse,
          reason: 'swipe must not be implemented by invoking the child X');
    },
  );

  testWidgets(
    'TODO-486: trackpad pan zoom on the header dismisses',
    (WidgetTester tester) async {
      bool dismissed = false;
      await tester.pumpWidget(popup(onDismiss: () => dismissed = true));

      final Offset headerCenter = tester.getCenter(find.byKey(headerKey));
      await panZoomHorizontally(tester, headerCenter);

      expect(dismissed, isTrue,
          reason: 'trackpad PointerPanZoom sequences must drive swipe close');
    },
  );

  testWidgets('TODO-407①: tapping the X routes through onDismiss', (
    WidgetTester tester,
  ) async {
    bool closed = false;
    await tester.pumpWidget(
      popup(onDismiss: () {}, onClose: () => closed = true),
    );

    // 顶栏右端的 X 关闭按钮。
    expect(find.byIcon(Icons.close), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(closed, isTrue, reason: 'X 必须调用 onClose（各表面绑定到关闭汇聚点）');
  });

  testWidgets(
    'TODO-501: nested close button remains available when swipe is disabled',
    (WidgetTester tester) async {
      bool closed = false;
      await tester.pumpWidget(
        buildTestApp(
          Center(
            child: SizedBox(
              width: 320,
              height: 360,
              child: DictionaryPopupLayer(
                result: null,
                isSearching: false,
                webViewKey: GlobalKey<DictionaryPopupWebViewState>(),
                enableSwipeToClose: false,
                swipeDismissible: true,
                onClose: () => closed = true,
                onDismiss: () {},
                onTextSelected: (text, rect) {},
                onLinkClick: (query, rect) {},
                onMineEntry: (fields) async => const MinePopupResult(),
                onDuplicateCheck: (expression, reading) async => false,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(SwipeDismissWrapper), findsNothing);
      expect(find.byIcon(Icons.arrow_back), findsNothing);
      expect(find.byIcon(Icons.close), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(closed, isTrue, reason: '子层 X 必须独立于滑动关闭开关可用');
    },
  );

  testWidgets('TODO-501: top-bar action buttons are 36 boxes with 20px icons',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      buildTestApp(
        Center(
          child: SizedBox(
            width: 320,
            height: 360,
            child: DictionaryPopupLayer(
              result: null,
              isSearching: false,
              webViewKey: GlobalKey<DictionaryPopupWebViewState>(),
              enableSwipeToClose: false,
              onClose: () {},
              onDismiss: () {},
              onTextSelected: (text, rect) {},
              onLinkClick: (query, rect) {},
              onMineEntry: (fields) async => const MinePopupResult(),
              onDuplicateCheck: (expression, reading) async => false,
            ),
          ),
        ),
      ),
    );

    final HibikiIconButton button = tester.widget<HibikiIconButton>(
      find.widgetWithIcon(HibikiIconButton, Icons.close),
    );
    expect(button.size, 20);
    expect(
      button.constraints,
      const BoxConstraints.tightFor(width: 36, height: 36),
    );
    expect(button.padding, EdgeInsets.zero);
  });

  testWidgets(
    'TODO-407②: enableSwipeToClose=false drops the SwipeDismissWrapper on the '
    'top bar',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        popup(onDismiss: () {}, enableSwipeToClose: false),
      );
      // 平台/偏好禁用滑关时不挂 SwipeDismissWrapper（顶栏只剩 X 兜底）。
      expect(find.byType(SwipeDismissWrapper), findsNothing);
    },
  );

  testWidgets(
    'TODO-407②: enableSwipeToClose=true mounts the SwipeDismissWrapper',
    (WidgetTester tester) async {
      await tester
          .pumpWidget(popup(onDismiss: () {}, enableSwipeToClose: true));
      expect(find.byType(SwipeDismissWrapper), findsOneWidget);
    },
  );

  group('TODO-407②: defaultSwipeToClose platform truth table', () {
    test('desktop Windows/Linux default to false (no swipe-to-close)', () {
      expect(
          ReaderSettings.defaultSwipeToClose(TargetPlatform.windows), isFalse);
      expect(ReaderSettings.defaultSwipeToClose(TargetPlatform.linux), isFalse);
    });

    test('touch platforms (macOS/iOS/Android) default to true', () {
      expect(ReaderSettings.defaultSwipeToClose(TargetPlatform.macOS), isTrue);
      expect(ReaderSettings.defaultSwipeToClose(TargetPlatform.iOS), isTrue);
      expect(
          ReaderSettings.defaultSwipeToClose(TargetPlatform.android), isTrue);
    });

    test('the only false branch is exactly windows||linux', () {
      for (final TargetPlatform p in TargetPlatform.values) {
        final bool expected =
            !(p == TargetPlatform.windows || p == TargetPlatform.linux);
        expect(ReaderSettings.defaultSwipeToClose(p), expected,
            reason: '平台 $p 的默认滑关开关应为 $expected');
      }
    });
  });
}
